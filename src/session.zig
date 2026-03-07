//! Session Manager — persistent in-process Agent sessions.
//!
//! Replaces subprocess spawning with reusable Agent instances keyed by
//! session_key (e.g. "telegram:chat123"). Each session maintains its own
//! conversation history across turns.
//!
//! Thread safety: SessionManager.mutex guards the sessions map (short hold),
//! Session.mutex serializes turn() per session (may be long). Different
//! sessions are processed in parallel.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const config_types = @import("config_types.zig");
const agent_root = @import("agent/root.zig");
const Agent = agent_root.Agent;
const context_tokens = agent_root.context_tokens;
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const memory_mod = @import("memory/root.zig");
const Memory = memory_mod.Memory;
const observability = @import("observability.zig");
const Observer = observability.Observer;
const tools_mod = @import("tools/root.zig");
const Tool = tools_mod.Tool;
const SecurityPolicy = @import("security/policy.zig").SecurityPolicy;
const streaming = @import("streaming.zig");
const skills_mod = @import("skills.zig");
const platform = @import("platform.zig");
const log = std.log.scoped(.session);
const MESSAGE_LOG_MAX_BYTES: usize = 4096;
const TOKEN_USAGE_LEDGER_FILENAME = "llm_token_usage.jsonl";
const NS_PER_SEC: i128 = std.time.ns_per_s;

/// Load workspace skills for channel hook evaluation.
/// Also consumes any `.reload` sentinel files in the skills directories.
fn loadSessionSkills(allocator: Allocator, workspace_dir: []const u8) ?[]skills_mod.Skill {
    const home_dir = platform.getHomeDir(allocator) catch null;
    defer if (home_dir) |h| allocator.free(h);
    const community_base = if (home_dir) |h|
        std.fs.path.join(allocator, &.{ h, ".nullclaw", "skills" }) catch null
    else
        null;
    defer if (community_base) |cb| allocator.free(cb);

    // Consume reload sentinels (best-effort; result unused here because
    // skills are always loaded fresh from disk on every turn).
    if (community_base) |cb| _ = skills_mod.consumeReloadSentinel(allocator, cb);
    _ = skills_mod.consumeReloadSentinel(allocator, workspace_dir);

    if (community_base) |cb| {
        return skills_mod.listSkillsMerged(allocator, cb, workspace_dir) catch
            skills_mod.listSkills(allocator, workspace_dir) catch null;
    }
    return skills_mod.listSkills(allocator, workspace_dir) catch null;
}

fn messageLogPreview(text: []const u8) struct { slice: []const u8, truncated: bool } {
    if (text.len <= MESSAGE_LOG_MAX_BYTES) {
        return .{ .slice = text, .truncated = false };
    }
    return .{ .slice = text[0..MESSAGE_LOG_MAX_BYTES], .truncated = true };
}

// ═══════════════════════════════════════════════════════════════════════════
// Session
// ═══════════════════════════════════════════════════════════════════════════

pub const Session = struct {
    agent: Agent,
    created_at: i64,
    last_active: i64,
    last_consolidated: u64 = 0,
    session_key: []const u8, // owned copy
    turn_count: u64,
    mutex: std.Thread.Mutex,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        self.agent.deinit();
        allocator.free(self.session_key);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// SessionManager
// ═══════════════════════════════════════════════════════════════════════════

pub const SessionManager = struct {
    allocator: Allocator,
    config: *const Config,
    provider: Provider,
    tools: []const Tool,
    /// Optional dynamic tool registry. When non-null, every new session's
    /// agent has its `registry` field set to this pointer so that tool
    /// dispatch goes through the registry (enabling plugin tools and SO
    /// ref-counting).  The registry is NOT owned by SessionManager — it is
    /// owned by ChannelRuntime.
    tool_registry: ?*tools_mod.ToolRegistry = null,
    mem: ?Memory,
    session_store: ?memory_mod.SessionStore = null,
    response_cache: ?*memory_mod.cache.ResponseCache = null,
    mem_rt: ?*memory_mod.MemoryRuntime = null,
    observer: Observer,
    policy: ?*const SecurityPolicy = null,

    mutex: std.Thread.Mutex,
    usage_log_mutex: std.Thread.Mutex,
    usage_ledger_state_initialized: bool,
    usage_ledger_window_started_at: i64,
    usage_ledger_line_count: u64,
    sessions: std.StringHashMapUnmanaged(*Session),

    pub fn init(
        allocator: Allocator,
        config: *const Config,
        provider: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
        session_store: ?memory_mod.SessionStore,
        response_cache: ?*memory_mod.cache.ResponseCache,
    ) SessionManager {
        tools_mod.bindMemoryTools(tools, mem);

        return .{
            .allocator = allocator,
            .config = config,
            .provider = provider,
            .tools = tools,
            .mem = mem,
            .session_store = session_store,
            .response_cache = response_cache,
            .observer = observer_i,
            .mutex = .{},
            .usage_log_mutex = .{},
            .usage_ledger_state_initialized = false,
            .usage_ledger_window_started_at = 0,
            .usage_ledger_line_count = 0,
            .sessions = .{},
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
    }

    /// Look up per-channel model override from config based on session_key.
    /// Session keys for MQTT/Redis follow the pattern: "mqtt:<account_id>:<topic>"
    /// or "redis_stream:<account_id>:<topic>".
    fn lookupChannelModelOverride(config: *const Config, session_key: []const u8) config_types.ChannelModelOverride {
        // Try MQTT prefix — supports both "mqtt:<endpoint_id>" and legacy "mqtt:<account_id>:<topic>"
        if (std.mem.startsWith(u8, session_key, "mqtt:")) {
            const rest = session_key["mqtt:".len..];
            // First try endpoint_id match (no colon in rest means it's an endpoint_id)
            for (config.channels.mqtt) |mqtt_cfg| {
                for (mqtt_cfg.endpoints) |ep| {
                    if (ep.endpoint_id.len > 0 and std.mem.eql(u8, ep.endpoint_id, rest)) {
                        return ep.model_override;
                    }
                }
            }
            // Fall back to legacy account_id:topic match
            const sep = std.mem.indexOfScalar(u8, rest, ':');
            if (sep) |s| {
                const account_id = rest[0..s];
                const topic = rest[s + 1 ..];
                for (config.channels.mqtt) |mqtt_cfg| {
                    if (std.mem.eql(u8, mqtt_cfg.account_id, account_id)) {
                        for (mqtt_cfg.endpoints) |ep| {
                            if (std.mem.eql(u8, ep.listen_topic, topic)) {
                                return ep.model_override;
                            }
                        }
                    }
                }
            }
        }
        // Try Redis Stream prefix — supports both "redis_stream:<endpoint_id>" and legacy format
        if (std.mem.startsWith(u8, session_key, "redis_stream:")) {
            const rest = session_key["redis_stream:".len..];
            // First try endpoint_id match
            for (config.channels.redis_stream) |rs_cfg| {
                for (rs_cfg.endpoints) |ep| {
                    if (ep.endpoint_id.len > 0 and std.mem.eql(u8, ep.endpoint_id, rest)) {
                        return ep.model_override;
                    }
                }
            }
            // Fall back to legacy account_id:topic match
            const sep = std.mem.indexOfScalar(u8, rest, ':');
            if (sep) |s| {
                const account_id = rest[0..s];
                const topic = rest[s + 1 ..];
                for (config.channels.redis_stream) |rs_cfg| {
                    if (std.mem.eql(u8, rs_cfg.account_id, account_id)) {
                        for (rs_cfg.endpoints) |ep| {
                            if (std.mem.eql(u8, ep.listen_topic, topic)) {
                                return ep.model_override;
                            }
                        }
                    }
                }
            }
        }
        return .{};
    }

    /// Apply per-channel model overrides to an agent.
    /// Only overrides fields that are explicitly set in the override config.
    ///
    /// Fallback chains for sub-agent / tools-reviewer model resolution:
    ///   channel sub_agent_* → channel general (provider/model) → global sub_agent_* → global default
    ///   channel tools_reviewer_* → channel general (provider/model) → global tools_reviewer_* → global default
    /// The global sub_agent_*/tools_reviewer_* values are already set on the Agent
    /// from Config via fromConfig().  This function layers the channel-level
    /// overrides on top.
    fn applyModelOverride(agent: *Agent, mo: config_types.ChannelModelOverride) void {
        if (mo.provider) |prov| {
            agent.default_provider = prov;
        }
        if (mo.model) |model| {
            agent.model_name = model;
            agent.default_model = model;
            // Re-resolve token_limit with the new model
            const new_token_limit = context_tokens.resolveContextTokens(agent.token_limit_override, model);
            if (mo.max_context_tokens > 0 and (new_token_limit == 0 or mo.max_context_tokens < new_token_limit)) {
                agent.token_limit = mo.max_context_tokens;
            } else {
                agent.token_limit = new_token_limit;
            }
        } else if (mo.max_context_tokens > 0) {
            // No model override but max_context_tokens is set — cap the current token_limit
            if (agent.token_limit == 0 or mo.max_context_tokens < agent.token_limit) {
                agent.token_limit = mo.max_context_tokens;
            }
        }
        if (mo.temperature) |temp| {
            agent.temperature = temp;
        }

        // ── Sub-agent fallback chain ─────────────────────────────────────
        // model/provider: fall back to channel general, then preserve existing (from global init).
        // temperature/max_context_tokens/base_url: only override when the type-specific
        // field is explicitly configured — the general config's values must NOT cascade
        // into specialized types (each type has its own compiled default, e.g. 0.3 for
        // sub-agent vs 0.7 for general).
        agent.sub_agent_model = mo.sub_agent_model orelse mo.model orelse agent.sub_agent_model;
        agent.sub_agent_provider = mo.sub_agent_provider orelse mo.provider orelse agent.sub_agent_provider;
        if (mo.sub_agent_temperature) |t| agent.sub_agent_temperature = t;
        if (mo.sub_agent_max_context_tokens > 0) agent.sub_agent_max_context_tokens = mo.sub_agent_max_context_tokens;
        if (mo.sub_agent_base_url) |u| agent.sub_agent_base_url = u;
        if (mo.sub_agent_max_iterations > 0) agent.sub_agent_max_iterations = mo.sub_agent_max_iterations;
        if (mo.sub_agent_review_after > 0) agent.sub_agent_review_after = mo.sub_agent_review_after;

        // ── Tools-reviewer fallback chain ────────────────────────────────
        agent.tools_reviewer_model = mo.tools_reviewer_model orelse mo.model orelse agent.tools_reviewer_model;
        agent.tools_reviewer_provider = mo.tools_reviewer_provider orelse mo.provider orelse agent.tools_reviewer_provider;
        if (mo.tools_reviewer_temperature) |t| agent.tools_reviewer_temperature = t;
        if (mo.tools_reviewer_max_context_tokens > 0) agent.tools_reviewer_max_context_tokens = mo.tools_reviewer_max_context_tokens;
        if (mo.tools_reviewer_base_url) |u| agent.tools_reviewer_base_url = u;
    }

    /// Refresh non-model config-derived fields on an agent from the given config.
    /// Called during config hot-reload to ensure fields displayed by /debug
    /// (and used at runtime) reflect the latest config.  Model-related fields
    /// are handled separately by applyModelOverride.
    fn applyNonModelConfigRefresh(agent: *Agent, cfg: *const Config) void {
        // Fields visible in /debug (formatStatus)
        agent.reasoning_effort = cfg.reasoning_effort;
        agent.status_show_emojis = cfg.agent.status_show_emojis;
        agent.exec_security = switch (cfg.autonomy.level) {
            .full => .full,
            .read_only => .deny,
            .supervised => .allowlist,
        };
        agent.exec_ask = switch (cfg.autonomy.level) {
            .full, .read_only => .off,
            .supervised => .on_miss,
        };
        // Agent-loop settings
        agent.max_tool_iterations = cfg.agent.max_tool_iterations;
        agent.max_history_messages = cfg.agent.max_history_messages;
        agent.auto_save = cfg.memory.auto_save;
        agent.message_timeout_secs = cfg.agent.message_timeout_secs;
        agent.compaction_keep_recent = cfg.agent.compaction_keep_recent;
        agent.compaction_max_summary_chars = cfg.agent.compaction_max_summary_chars;
        agent.compaction_max_source_chars = cfg.agent.compaction_max_source_chars;
        agent.log_tool_calls = cfg.diagnostics.log_tool_calls;
        agent.log_llm_io = cfg.diagnostics.log_llm_io;
        // Provider fallbacks (slices point into config arena, kept alive via prev_configs)
        agent.configured_providers = cfg.providers;
        agent.fallback_providers = cfg.reliability.fallback_providers;
        agent.model_fallbacks = cfg.reliability.model_fallbacks;
        agent.allowed_paths = cfg.autonomy.allowed_paths;
        agent.tool_filter_groups = cfg.agent.tool_filter_groups;
        agent.sub_agent_max_iterations = cfg.agent.sub_agent_max_iterations;
        agent.sub_agent_review_after = cfg.agent.sub_agent_review_after;
        agent.max_tokens_override = cfg.max_tokens;
        // Recompute max_tokens using the same resolution as fromConfigInner
        const resolved_raw = agent_root.max_tokens_resolver.resolveMaxTokens(cfg.max_tokens, agent.model_name);
        const token_cap: u32 = @intCast(@min(agent.token_limit, @as(u64, std.math.maxInt(u32))));
        agent.max_tokens = @min(resolved_raw, token_cap);
    }

    /// Hot-refresh non-model config-derived fields on sessions whose key does
    /// NOT start with any of the given prefixes.  MQTT / Redis Stream sessions
    /// have per-endpoint sub_agent_max_iterations / sub_agent_review_after set
    /// by applyModelOverride; refreshing them with global values would clobber
    /// endpoint-specific overrides.  Returns the number of sessions refreshed.
    pub fn refreshNonModelConfig(self: *SessionManager, cfg: *const Config, exclude_prefixes: []const []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const excluded = for (exclude_prefixes) |pfx| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, pfx)) break true;
            } else false;
            if (!excluded) {
                const session = entry.value_ptr.*;
                session.mutex.lock();
                applyNonModelConfigRefresh(&session.agent, cfg);
                session.mutex.unlock();
                count += 1;
            }
        }
        return count;
    }

    /// Evict all sessions whose key starts with the given prefix.
    /// Used during config hot-reload to clean up sessions for removed channels.
    /// Returns the number of sessions evicted.
    pub fn evictByPrefix(self: *SessionManager, prefix: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                kv.value.deinit(self.allocator);
                self.allocator.destroy(kv.value);
            }
        }
        return to_remove.items.len;
    }

    /// Hot-update model parameters on an existing session without destroying it.
    /// The session keeps its conversation history and state; only model-related
    /// agent fields are patched in place.  Returns true if a matching session was
    /// found and updated.
    pub fn updateSessionModelParams(self: *SessionManager, session_key: []const u8, mo: config_types.ChannelModelOverride) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sess = self.sessions.get(session_key) orelse return false;
        applyModelOverride(&sess.agent, mo);
        return true;
    }

    /// Hot-update model parameters on all sessions whose key starts with the
    /// given prefix.  Returns the number of sessions updated.
    pub fn updateModelParamsByPrefix(self: *SessionManager, prefix: []const u8, mo: config_types.ChannelModelOverride) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                applyModelOverride(&entry.value_ptr.*.agent, mo);
                count += 1;
            }
        }
        return count;
    }

    /// Hot-update model parameters on all sessions whose key does NOT start
    /// with any of the given prefixes.  Returns the number of sessions updated.
    /// Used for global model changes: MQTT / Redis Stream sessions are handled
    /// individually with per-endpoint merge logic, so we exclude them here and
    /// update every other channel type (Telegram, Discord, Slack, etc.).
    pub fn updateModelParamsExcludingPrefixes(self: *SessionManager, mo: config_types.ChannelModelOverride, exclude_prefixes: []const []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const excluded = for (exclude_prefixes) |pfx| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, pfx)) break true;
            } else false;
            if (!excluded) {
                applyModelOverride(&entry.value_ptr.*.agent, mo);
                count += 1;
            }
        }
        return count;
    }

    /// Update the config pointer for all future session creations.
    /// Existing sessions keep their agent state; new sessions will use the new config.
    pub fn updateConfig(self: *SessionManager, new_config: *const Config) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.config = new_config;
    }

    /// Replace the provider used by the session manager AND all existing
    /// sessions.  Called during config hot-reload when API keys or provider
    /// settings change.  Each session's agent.provider is patched in-place
    /// under its own mutex to avoid racing with in-flight turns (processMessage
    /// acquires the same session mutex before calling agent.turn).
    pub fn updateProvider(self: *SessionManager, new_provider: Provider) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Update the manager-level provider (used for newly created sessions).
        self.provider = new_provider;

        // Patch every existing session's agent.
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            session.mutex.lock();
            session.agent.provider = new_provider;
            session.mutex.unlock();
        }
    }

    /// Find or create a session for the given key. Thread-safe.
    pub fn getOrCreate(self: *SessionManager, session_key: []const u8) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_key)) |session| {
            session.last_active = std.time.timestamp();
            return session;
        }

        // Create new session
        const owned_key = try self.allocator.dupe(u8, session_key);
        errdefer self.allocator.free(owned_key);

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);

        // Look up per-channel model overrides BEFORE creating the agent so that
        // channels with their own model work even when no global model is set.
        const mo = lookupChannelModelOverride(self.config, session_key);

        var agent = try Agent.fromConfigWithChannelModel(
            self.allocator,
            self.config,
            self.provider,
            self.tools,
            self.mem,
            self.observer,
            mo.model,
        );
        agent.policy = self.policy;
        agent.session_store = self.session_store;
        agent.response_cache = self.response_cache;
        agent.mem_rt = self.mem_rt;
        agent.memory_session_id = owned_key;
        // Wire dynamic registry so agent dispatches through plugin tools.
        if (self.tool_registry) |reg| agent.registry = reg;
        if (self.config.diagnostics.token_usage_ledger_enabled) {
            agent.usage_record_callback = usageRecordForwarder;
            agent.usage_record_ctx = @ptrCast(self);
        }

        // Apply remaining per-channel model overrides (provider, temperature,
        // sub_agent/tools_reviewer fields, etc.)
        applyModelOverride(&agent, mo);

        session.* = .{
            .agent = agent,
            .created_at = std.time.timestamp(),
            .last_active = std.time.timestamp(),
            .last_consolidated = 0,
            .session_key = owned_key,
            .turn_count = 0,
            .mutex = .{},
        };
        // From here, session owns agent — must deinit on error.
        errdefer session.agent.deinit();

        // Restore persisted conversation history from session store
        if (self.session_store) |store| {
            const entries = store.loadMessages(self.allocator, session_key) catch &.{};
            if (entries.len > 0) {
                session.agent.loadHistory(entries) catch {};
                for (entries) |entry| {
                    self.allocator.free(entry.role);
                    self.allocator.free(entry.content);
                }
                self.allocator.free(entries);
            }
        }

        try self.sessions.put(self.allocator, owned_key, session);
        return session;
    }

    fn slashCommandName(message: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");
        if (trimmed.len <= 1 or trimmed[0] != '/') return null;

        const body = trimmed[1..];
        var split_idx: usize = 0;
        while (split_idx < body.len) : (split_idx += 1) {
            const ch = body[split_idx];
            if (ch == ':' or ch == ' ' or ch == '\t') break;
        }
        if (split_idx == 0) return null;
        return body[0..split_idx];
    }

    fn slashClearsSession(message: []const u8) bool {
        const cmd = slashCommandName(message) orelse return false;
        return std.ascii.eqlIgnoreCase(cmd, "new") or
            std.ascii.eqlIgnoreCase(cmd, "reset") or
            std.ascii.eqlIgnoreCase(cmd, "restart");
    }

    const StreamAdapterCtx = struct {
        sink: streaming.Sink,
    };

    fn streamChunkForwarder(ctx_ptr: *anyopaque, chunk: providers.StreamChunk) void {
        const adapter: *StreamAdapterCtx = @ptrCast(@alignCast(ctx_ptr));
        streaming.forwardProviderChunk(adapter.sink, chunk);
    }

    fn usageRecordForwarder(ctx_ptr: *anyopaque, record: Agent.UsageRecord) void {
        const self: *SessionManager = @ptrCast(@alignCast(ctx_ptr));
        self.appendUsageRecord(record);
    }

    fn usageLedgerPath(self: *SessionManager) ?[]u8 {
        if (!self.config.diagnostics.token_usage_ledger_enabled) return null;
        const config_dir = std.fs.path.dirname(self.config.config_path) orelse return null;
        return std.fs.path.join(self.allocator, &.{ config_dir, TOKEN_USAGE_LEDGER_FILENAME }) catch null;
    }

    fn usageWindowSeconds(self: *SessionManager) i64 {
        const hours = self.config.diagnostics.token_usage_ledger_window_hours;
        if (hours == 0) return 0;
        return @as(i64, @intCast(hours)) * 60 * 60;
    }

    fn countLedgerLines(file: *std.fs.File) !u64 {
        try file.seekTo(0);
        var lines: u64 = 0;
        var saw_data = false;
        var last_byte: u8 = '\n';
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try file.read(&buf);
            if (n == 0) break;
            saw_data = true;
            last_byte = buf[n - 1];
            lines += @intCast(std.mem.count(u8, buf[0..n], "\n"));
        }
        if (saw_data and last_byte != '\n') lines += 1;
        return lines;
    }

    fn initializeUsageLedgerState(
        self: *SessionManager,
        file: *std.fs.File,
        stat: std.fs.File.Stat,
        now_ts: i64,
    ) void {
        if (self.usage_ledger_state_initialized) return;
        self.usage_ledger_state_initialized = true;
        if (stat.size > 0) {
            const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, NS_PER_SEC));
            self.usage_ledger_window_started_at = if (mtime_secs > 0) mtime_secs else now_ts;
            if (self.config.diagnostics.token_usage_ledger_max_lines > 0) {
                self.usage_ledger_line_count = countLedgerLines(file) catch 0;
            } else {
                self.usage_ledger_line_count = 0;
            }
        } else {
            self.usage_ledger_window_started_at = now_ts;
            self.usage_ledger_line_count = 0;
        }
    }

    fn shouldResetUsageLedger(
        self: *SessionManager,
        stat: std.fs.File.Stat,
        now_ts: i64,
        pending_bytes: usize,
        pending_lines: u64,
    ) bool {
        const window_secs = self.usageWindowSeconds();
        if (window_secs > 0) {
            const started_at = self.usage_ledger_window_started_at;
            if (started_at > 0 and now_ts - started_at >= window_secs) return true;
        }

        const max_bytes = self.config.diagnostics.token_usage_ledger_max_bytes;
        if (max_bytes > 0) {
            const projected = @as(u64, @intCast(stat.size)) + @as(u64, @intCast(pending_bytes));
            if (projected > max_bytes) return true;
        }

        const max_lines = self.config.diagnostics.token_usage_ledger_max_lines;
        if (max_lines > 0 and self.usage_ledger_line_count + pending_lines > max_lines) return true;

        return false;
    }

    fn appendUsageRecord(self: *SessionManager, record: Agent.UsageRecord) void {
        self.usage_log_mutex.lock();
        defer self.usage_log_mutex.unlock();

        const ledger_path = self.usageLedgerPath() orelse return;
        defer self.allocator.free(ledger_path);

        var file = std.fs.openFileAbsolute(ledger_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => std.fs.createFileAbsolute(ledger_path, .{ .truncate = false, .read = true }) catch return,
            else => return,
        };
        var file_needs_close = true;
        defer if (file_needs_close) file.close();

        const now_ts = std.time.timestamp();
        const stat = file.stat() catch return;
        self.initializeUsageLedgerState(&file, stat, now_ts);

        const record_line = std.fmt.allocPrint(
            self.allocator,
            "{{\"ts\":{d},\"provider\":{f},\"model\":{f},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"success\":{}}}\n",
            .{
                record.ts,
                std.json.fmt(record.provider, .{}),
                std.json.fmt(record.model, .{}),
                record.usage.prompt_tokens,
                record.usage.completion_tokens,
                record.usage.total_tokens,
                record.success,
            },
        ) catch return;
        defer self.allocator.free(record_line);

        const pending_bytes: usize = record_line.len;
        if (self.shouldResetUsageLedger(stat, now_ts, pending_bytes, 1)) {
            file.close();
            file_needs_close = false;
            file = std.fs.createFileAbsolute(ledger_path, .{ .truncate = true, .read = true }) catch return;
            file_needs_close = true;
            self.usage_ledger_state_initialized = true;
            self.usage_ledger_window_started_at = now_ts;
            self.usage_ledger_line_count = 0;
        }

        // Zig 0.15 buffered File.writer ignores manual seek position for append-style writes.
        // Use direct file.writeAll after seek to guarantee true append semantics.
        file.seekFromEnd(0) catch return;
        file.writeAll(record_line) catch return;

        if (self.usage_ledger_window_started_at == 0) {
            self.usage_ledger_window_started_at = now_ts;
        }
        if (self.config.diagnostics.token_usage_ledger_max_lines > 0) {
            self.usage_ledger_line_count += 1;
        }
    }

    /// Process a message within a session context.
    /// Finds or creates the session, locks it, runs agent.turn(), returns owned response.
    pub fn processMessage(self: *SessionManager, session_key: []const u8, content: []const u8, conversation_context: ?ConversationContext) ![]const u8 {
        return self.processMessageStreaming(session_key, content, conversation_context, null);
    }

    /// Process a message within a session context and optionally forward text deltas.
    /// Deltas are only emitted when provider streaming is active.
    pub fn processMessageStreaming(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        stream_sink: ?streaming.Sink,
    ) ![]const u8 {
        const channel = if (conversation_context) |ctx| (ctx.channel orelse "unknown") else "unknown";
        const session_hash = std.hash.Wyhash.hash(0, session_key);

        if (self.config.diagnostics.log_message_receipts) {
            log.info("message receipt channel={s} session=0x{x} bytes={d}", .{ channel, session_hash, content.len });
        }
        if (self.config.diagnostics.log_message_payloads) {
            const preview = messageLogPreview(content);
            log.info(
                "message inbound channel={s} session=0x{x} bytes={d} content={f}{s}",
                .{
                    channel,
                    session_hash,
                    content.len,
                    std.json.fmt(preview.slice, .{}),
                    if (preview.truncated) " [truncated]" else "",
                },
            );
        }

        const session = try self.getOrCreate(session_key);

        session.mutex.lock();
        defer session.mutex.unlock();

        // Set conversation context for this turn (Signal-specific for now)
        session.agent.conversation_context = conversation_context;
        defer session.agent.conversation_context = null;

        const prev_stream_callback = session.agent.stream_callback;
        const prev_stream_ctx = session.agent.stream_ctx;
        defer {
            session.agent.stream_callback = prev_stream_callback;
            session.agent.stream_ctx = prev_stream_ctx;
        }

        var stream_adapter: StreamAdapterCtx = undefined;
        if (stream_sink) |sink| {
            stream_adapter = .{ .sink = sink };
            session.agent.stream_callback = streamChunkForwarder;
            session.agent.stream_ctx = @ptrCast(&stream_adapter);
        } else {
            session.agent.stream_callback = null;
            session.agent.stream_ctx = null;
        }

        // ── Load skills for channel hooks ──
        const hook_skills = loadSessionSkills(self.allocator, session.agent.workspace_dir);
        defer if (hook_skills) |hs| skills_mod.freeSkills(self.allocator, hs);

        // ── on_channel_receive_before hook ──
        var effective_content = content;
        var effective_content_owned = false;
        defer if (effective_content_owned) self.allocator.free(effective_content);

        if (hook_skills) |hs| {
            if (skills_mod.hasSkillsForTrigger(hs, .on_channel_receive_before)) {
                // 1. Run all [action:agent] skills in chain
                const agent_skills = skills_mod.collectAgentSkills(self.allocator, hs, .on_channel_receive_before) catch &.{};
                defer if (agent_skills.len > 0) self.allocator.free(agent_skills);
                var hook_result = session.agent.runSkillSubAgentChain(self.allocator, agent_skills, content);
                defer skills_mod.freeHookResult(self.allocator, &hook_result);

                // 2. If chain didn't intercept, run plain skills
                if (hook_result.action != .intercept and hook_result.action != .agent_error) {
                    const effective = if (hook_result.action == .continue_with and hook_result.content.len > 0) hook_result.content else content;
                    var plain_result = skills_mod.evaluateSkillHook(self.allocator, hs, .on_channel_receive_before, effective) catch skills_mod.SkillHookResult{};
                    if (plain_result.action == .continue_with or plain_result.action == .intercept or plain_result.action == .agent_error) {
                        skills_mod.freeHookResult(self.allocator, &hook_result);
                        hook_result = plain_result;
                    } else {
                        skills_mod.freeHookResult(self.allocator, &plain_result);
                    }
                }

                switch (hook_result.action) {
                    .agent_error => {
                        const err_response = if (hook_result.content.len > 0)
                            try self.allocator.dupe(u8, hook_result.content)
                        else
                            try self.allocator.dupe(u8, "[skill hook agent error]");
                        return err_response;
                    },
                    .intercept => {
                        const intercept_response = if (hook_result.content.len > 0)
                            try self.allocator.dupe(u8, hook_result.content)
                        else
                            try self.allocator.dupe(u8, "[intercepted by on_channel_receive_before hook]");
                        return intercept_response;
                    },
                    .continue_with => {
                        if (hook_result.content.len > 0) {
                            effective_content = try self.allocator.dupe(u8, hook_result.content);
                            effective_content_owned = true;
                        }
                    },
                    .passthrough, .agent, .async_agent => {},
                }
            }
        }

        const response = try session.agent.turn(effective_content);
        errdefer self.allocator.free(response);
        session.turn_count += 1;
        session.last_active = std.time.timestamp();

        // ── on_channel_receive_after hook ──
        var post_receive_response = response;
        var post_receive_owned = false;
        if (hook_skills) |hs| {
            if (skills_mod.hasSkillsForTrigger(hs, .on_channel_receive_after)) {
                // 1. Run all [action:agent] skills in chain
                const agent_skills = skills_mod.collectAgentSkills(self.allocator, hs, .on_channel_receive_after) catch &.{};
                defer if (agent_skills.len > 0) self.allocator.free(agent_skills);
                var hook_result = session.agent.runSkillSubAgentChain(self.allocator, agent_skills, response);
                defer skills_mod.freeHookResult(self.allocator, &hook_result);

                // 2. If chain didn't intercept, run plain skills
                if (hook_result.action != .intercept and hook_result.action != .agent_error) {
                    const effective = if (hook_result.action == .continue_with and hook_result.content.len > 0) hook_result.content else response;
                    var plain_result = skills_mod.evaluateSkillHook(self.allocator, hs, .on_channel_receive_after, effective) catch skills_mod.SkillHookResult{};
                    if (plain_result.action == .continue_with or plain_result.action == .intercept or plain_result.action == .agent_error) {
                        skills_mod.freeHookResult(self.allocator, &hook_result);
                        hook_result = plain_result;
                    } else {
                        skills_mod.freeHookResult(self.allocator, &plain_result);
                    }
                }

                switch (hook_result.action) {
                    .agent_error => {
                        self.allocator.free(response);
                        const err_response = if (hook_result.content.len > 0)
                            try self.allocator.dupe(u8, hook_result.content)
                        else
                            try self.allocator.dupe(u8, "[skill hook agent error]");
                        return err_response;
                    },
                    .continue_with => {
                        if (hook_result.content.len > 0) {
                            post_receive_response = try self.allocator.dupe(u8, hook_result.content);
                            post_receive_owned = true;
                        }
                    },
                    .intercept => {
                        if (hook_result.content.len > 0) {
                            self.allocator.free(response);
                            return try self.allocator.dupe(u8, hook_result.content);
                        }
                    },
                    .passthrough, .agent, .async_agent => {},
                }
            }
        }

        // ── on_channel_send_before hook ──
        var send_response = post_receive_response;
        var send_owned = false;
        if (hook_skills) |hs| {
            if (skills_mod.hasSkillsForTrigger(hs, .on_channel_send_before)) {
                // 1. Run all [action:agent] skills in chain
                const agent_skills = skills_mod.collectAgentSkills(self.allocator, hs, .on_channel_send_before) catch &.{};
                defer if (agent_skills.len > 0) self.allocator.free(agent_skills);
                var hook_result = session.agent.runSkillSubAgentChain(self.allocator, agent_skills, post_receive_response);
                defer skills_mod.freeHookResult(self.allocator, &hook_result);

                // 2. If chain didn't intercept, run plain skills
                if (hook_result.action != .intercept and hook_result.action != .agent_error) {
                    const effective = if (hook_result.action == .continue_with and hook_result.content.len > 0) hook_result.content else post_receive_response;
                    var plain_result = skills_mod.evaluateSkillHook(self.allocator, hs, .on_channel_send_before, effective) catch skills_mod.SkillHookResult{};
                    if (plain_result.action == .continue_with or plain_result.action == .intercept or plain_result.action == .agent_error) {
                        skills_mod.freeHookResult(self.allocator, &hook_result);
                        hook_result = plain_result;
                    } else {
                        skills_mod.freeHookResult(self.allocator, &plain_result);
                    }
                }

                switch (hook_result.action) {
                    .agent_error => {
                        // Free both allocations: response (from agent.turn) and
                        // post_receive_response (if owned, from on_channel_receive_after continue_with)
                        self.allocator.free(response);
                        if (post_receive_owned) self.allocator.free(post_receive_response);
                        return if (hook_result.content.len > 0)
                            try self.allocator.dupe(u8, hook_result.content)
                        else
                            try self.allocator.dupe(u8, "[skill hook agent error]");
                    },
                    .intercept => {
                        self.allocator.free(response);
                        if (post_receive_owned) self.allocator.free(post_receive_response);
                        return if (hook_result.content.len > 0)
                            try self.allocator.dupe(u8, hook_result.content)
                        else
                            try self.allocator.dupe(u8, "[intercepted by on_channel_send_before hook]");
                    },
                    .continue_with => {
                        if (hook_result.content.len > 0) {
                            send_response = try self.allocator.dupe(u8, hook_result.content);
                            send_owned = true;
                        }
                    },
                    .passthrough, .agent, .async_agent => {},
                }
            }
        }

        // Determine the final response to return
        const final_response = if (send_owned) blk: {
            // Always free the original response from agent.turn(), then
            // conditionally free post_receive_response if it was a separate allocation.
            self.allocator.free(response);
            if (post_receive_owned) self.allocator.free(post_receive_response);
            break :blk send_response;
        } else if (post_receive_owned) blk: {
            self.allocator.free(response);
            break :blk post_receive_response;
        } else response;

        // Track consolidation timestamp
        if (session.agent.last_turn_compacted) {
            session.last_consolidated = @intCast(@max(0, std.time.timestamp()));
        }

        // Persist messages via session store
        if (self.session_store) |store| {
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (slashClearsSession(trimmed)) {
                store.clearMessages(session_key) catch {};
                store.clearAutoSaved(session_key) catch {};
            } else if (!std.mem.startsWith(u8, trimmed, "/")) {
                store.saveMessage(session_key, "user", content) catch {};
                store.saveMessage(session_key, "assistant", final_response) catch {};
            }
        }

        if (self.config.diagnostics.log_message_payloads) {
            const preview = messageLogPreview(final_response);
            log.info(
                "message outbound channel={s} session=0x{x} bytes={d} content={f}{s}",
                .{
                    channel,
                    session_hash,
                    final_response.len,
                    std.json.fmt(preview.slice, .{}),
                    if (preview.truncated) " [truncated]" else "",
                },
            );
        }

        // ── on_channel_send_after hook (fire-and-forget, does not modify return) ──
        if (hook_skills) |hs| {
            if (skills_mod.hasSkillsForTrigger(hs, .on_channel_send_after)) {
                // 1. Run all [action:agent] skills in chain
                const agent_skills = skills_mod.collectAgentSkills(self.allocator, hs, .on_channel_send_after) catch &.{};
                defer if (agent_skills.len > 0) self.allocator.free(agent_skills);
                var hook_result = session.agent.runSkillSubAgentChain(self.allocator, agent_skills, final_response);

                // 2. If chain didn't intercept, run plain skills
                if (hook_result.action != .intercept and hook_result.action != .agent_error) {
                    const effective = if (hook_result.action == .continue_with and hook_result.content.len > 0) hook_result.content else final_response;
                    var plain_result = skills_mod.evaluateSkillHook(self.allocator, hs, .on_channel_send_after, effective) catch skills_mod.SkillHookResult{};
                    if (plain_result.action == .continue_with or plain_result.action == .intercept or plain_result.action == .agent_error) {
                        skills_mod.freeHookResult(self.allocator, &hook_result);
                        hook_result = plain_result;
                    } else {
                        skills_mod.freeHookResult(self.allocator, &plain_result);
                    }
                }

                skills_mod.freeHookResult(self.allocator, &hook_result);
                // on_channel_send_after is observational — response already committed
            }
        }

        return final_response;
    }

    /// Number of active sessions.
    pub fn sessionCount(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }

    pub const ReloadSkillsResult = struct {
        sessions_seen: usize = 0,
        sessions_reloaded: usize = 0,
        failures: usize = 0,
    };

    /// Reload skill-backed system prompts for all active sessions.
    /// Each session is reloaded under its own lock to avoid in-flight turn races.
    pub fn reloadSkillsAll(self: *SessionManager) ReloadSkillsResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = ReloadSkillsResult{};

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            result.sessions_seen += 1;
            session.mutex.lock();
            session.agent.has_system_prompt = false;
            session.mutex.unlock();
            result.sessions_reloaded += 1;
        }

        return result;
    }

    /// Evict sessions idle longer than max_idle_secs. Returns number evicted.
    pub fn evictIdle(self: *SessionManager, max_idle_secs: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        var evicted: usize = 0;

        // Collect keys to remove (can't modify map while iterating)
        var to_remove: std.ArrayListUnmanaged([]const u8) = .{};
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            const idle_secs: u64 = @intCast(@max(0, now - session.last_active));
            if (idle_secs > max_idle_secs) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                const session = kv.value;
                session.deinit(self.allocator);
                self.allocator.destroy(session);
                evicted += 1;
            }
        }

        return evicted;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

// ---------------------------------------------------------------------------
// MockProvider — returns a fixed response, no network calls
// ---------------------------------------------------------------------------

const MockProvider = struct {
    response: []const u8,

    const vtable = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .getName = mockGetName,
        .deinit = mockDeinit,
    };

    fn provider(self: *MockProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        _: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return self.response;
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn mockDeinit(_: *anyopaque) void {}
};

const MockStreamingProvider = struct {
    response: []const u8,

    const vtable = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .getName = mockGetName,
        .deinit = mockDeinit,
        .supports_streaming = mockSupportsStreaming,
        .stream_chat = mockStreamChat,
    };

    fn provider(self: *MockStreamingProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        _: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        return self.response;
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock_stream";
    }

    fn mockDeinit(_: *anyopaque) void {}

    fn mockSupportsStreaming(_: *anyopaque) bool {
        return true;
    }

    fn mockStreamChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        model: []const u8,
        _: f64,
        callback: providers.StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!providers.StreamChatResult {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        const mid = self.response.len / 2;
        if (mid > 0) callback(callback_ctx, providers.StreamChunk.textDelta(self.response[0..mid]));
        callback(callback_ctx, providers.StreamChunk.textDelta(self.response[mid..]));
        callback(callback_ctx, providers.StreamChunk.finalChunk());
        return .{
            .content = try allocator.dupe(u8, self.response),
            .model = try allocator.dupe(u8, model),
        };
    }
};

const DeltaCollector = struct {
    allocator: Allocator,
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn onEvent(ctx_ptr: *anyopaque, event: streaming.Event) void {
        if (event.stage != .chunk or event.text.len == 0) return;
        const self: *DeltaCollector = @ptrCast(@alignCast(ctx_ptr));
        self.data.appendSlice(self.allocator, event.text) catch {};
    }

    fn deinit(self: *DeltaCollector) void {
        self.data.deinit(self.allocator);
    }
};

/// Create a test SessionManager with mock provider.
fn testSessionManager(allocator: Allocator, mock: *MockProvider, cfg: *const Config) SessionManager {
    return testSessionManagerWithMemory(allocator, mock, cfg, null, null);
}

fn testSessionManagerWithMemory(allocator: Allocator, mock: *MockProvider, cfg: *const Config, mem: ?Memory, session_store: ?memory_mod.SessionStore) SessionManager {
    var noop = observability.NoopObserver{};
    return SessionManager.init(
        allocator,
        cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        session_store,
        null,
    );
}

fn testConfig() Config {
    return .{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .allocator = testing.allocator,
    };
}

// ---------------------------------------------------------------------------
// 1. Struct tests
// ---------------------------------------------------------------------------

test "SessionManager init/deinit — no leaks" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    sm.deinit();
}

test "usage ledger appends records when retention limits are disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 101,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 102,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 2, .total_tokens = 4 },
        .success = true,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":101") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":102") != null);
}

test "usage ledger resets when max line limit is reached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 2;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 1,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 2, .total_tokens = 3 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 2,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 3, .total_tokens = 5 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 3,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 3, .completion_tokens = 4, .total_tokens = 7 },
        .success = true,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":3") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":7") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger resets when window expires" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 1;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 10,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        .success = true,
    });

    sm.usage_ledger_state_initialized = true;
    sm.usage_ledger_window_started_at = std.time.timestamp() - 2 * 60 * 60;

    sm.appendUsageRecord(.{
        .ts = 11,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 2, .total_tokens = 4 },
        .success = true,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":11") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":4") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger resets when byte limit would be exceeded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 140;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 21,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 2, .total_tokens = 3 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 22,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 3, .total_tokens = 5 },
        .success = true,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":22") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":5") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger records failed response flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 31,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0 },
        .success = false,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":31") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":false") != null);
}

test "getOrCreate creates new session for unknown key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("telegram:chat1");
    try testing.expect(session.turn_count == 0);
    try testing.expectEqualStrings("telegram:chat1", session.session_key);
}

test "getOrCreate returns same session for same key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("key1");
    const s2 = try sm.getOrCreate("key1");
    try testing.expect(s1 == s2); // pointer equality
}

test "getOrCreate creates separate sessions for different keys" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("telegram:a");
    const s2 = try sm.getOrCreate("discord:b");
    try testing.expect(s1 != s2);
}

test "sessionCount reflects active sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
    _ = try sm.getOrCreate("a");
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
    _ = try sm.getOrCreate("b");
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
    _ = try sm.getOrCreate("a"); // existing
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
}

test "session has correct initial state" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:init");
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(!s.agent.has_system_prompt);
    try testing.expectEqual(@as(usize, 0), s.agent.historyLen());
}

// ---------------------------------------------------------------------------
// 2. processMessage tests
// ---------------------------------------------------------------------------

test "processMessage returns mock response" {
    var mock = MockProvider{ .response = "Hello from mock" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp = try sm.processMessage("user:1", "hi", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("Hello from mock", resp);
}

test "processMessageStreaming forwards provider deltas" {
    var mock = MockStreamingProvider{ .response = "streaming reply" };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    var collector = DeltaCollector{ .allocator = testing.allocator };
    defer collector.deinit();

    const resp = try sm.processMessageStreaming(
        "stream:1",
        "hi",
        null,
        .{
            .callback = DeltaCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
    );
    defer testing.allocator.free(resp);

    try testing.expectEqualStrings("streaming reply", resp);
    try testing.expectEqualStrings("streaming reply", collector.data.items);
}

test "processMessage refreshes system prompt when conversation context is cleared" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const sender_uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
    const with_context: ?ConversationContext = .{
        .channel = "signal",
        .sender_number = "+15551234567",
        .sender_uuid = sender_uuid,
        .group_id = null,
        .is_group = false,
    };

    const resp1 = try sm.processMessage("ctx:user", "first", with_context);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("ctx:user");
    try testing.expect(session.agent.history.items.len > 0);
    const sys1 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys1, "## Conversation Context") != null);
    try testing.expect(std.mem.indexOf(u8, sys1, sender_uuid) != null);

    const resp2 = try sm.processMessage("ctx:user", "second", null);
    defer testing.allocator.free(resp2);

    try testing.expect(session.agent.history.items.len > 0);
    const sys2 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys2, "## Conversation Context") == null);
    try testing.expect(std.mem.indexOf(u8, sys2, sender_uuid) == null);
}

test "processMessage updates last_active" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("user:2");
    const before = session.last_active;

    // Small sleep so timestamp changes
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const resp = try sm.processMessage("user:2", "hello", null);
    defer testing.allocator.free(resp);

    try testing.expect(session.last_active >= before);
}

test "processMessage increments turn_count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("user:3", "msg1", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("user:3");
    try testing.expectEqual(@as(u64, 1), session.turn_count);

    const resp2 = try sm.processMessage("user:3", "msg2", null);
    defer testing.allocator.free(resp2);
    try testing.expectEqual(@as(u64, 2), session.turn_count);
}

test "processMessage preserves session across calls" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("persist:1", "first", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("persist:1");
    // After first processMessage: system prompt + user msg + assistant response
    try testing.expect(session.agent.historyLen() > 0);

    const history_before = session.agent.historyLen();

    const resp2 = try sm.processMessage("persist:1", "second", null);
    defer testing.allocator.free(resp2);

    // History should have grown (user msg + assistant response added)
    try testing.expect(session.agent.historyLen() > history_before);
}

test "processMessage different keys — independent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp_a = try sm.processMessage("user:a", "hello a", null);
    defer testing.allocator.free(resp_a);

    const resp_b = try sm.processMessage("user:b", "hello b", null);
    defer testing.allocator.free(resp_b);

    const sa = try sm.getOrCreate("user:a");
    const sb = try sm.getOrCreate("user:b");
    try testing.expect(sa != sb);
    try testing.expectEqual(@as(u64, 1), sa.turn_count);
    try testing.expectEqual(@as(u64, 1), sb.turn_count);
}

test "processMessage /new clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    // Seed autosave entries for two different sessions.
    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /new with model clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new gpt-4o-mini", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /reset clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/reset", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /restart clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/restart", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage with sqlite memory first turn does not panic" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const resp = try sm.processMessage("signal:session:1", "hello", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("ok", resp);

    const entries = try sqlite_mem.loadMessages(testing.allocator, "signal:session:1");
    defer {
        for (entries) |entry| {
            testing.allocator.free(entry.role);
            testing.allocator.free(entry.content);
        }
        testing.allocator.free(entries);
    }
    // One user + one assistant message should be persisted.
    try testing.expect(entries.len >= 2);
}

// ---------------------------------------------------------------------------
// 3. evictIdle tests
// ---------------------------------------------------------------------------

test "evictIdle removes old sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("old:1");
    // Force last_active to the past
    session.last_active = std.time.timestamp() - 1000;

    const evicted = sm.evictIdle(500);
    try testing.expectEqual(@as(usize, 1), evicted);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
}

test "evictIdle preserves recent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("recent:1");
    // This session was just created, last_active is now

    const evicted = sm.evictIdle(3600); // 1 hour threshold
    try testing.expectEqual(@as(usize, 0), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle returns correct count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Create 3 sessions, make 2 old
    const s1 = try sm.getOrCreate("s1");
    const s2 = try sm.getOrCreate("s2");
    _ = try sm.getOrCreate("s3");

    s1.last_active = std.time.timestamp() - 2000;
    s2.last_active = std.time.timestamp() - 2000;
    // s3 stays recent

    const evicted = sm.evictIdle(1000);
    try testing.expectEqual(@as(usize, 2), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle with no sessions returns 0" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.evictIdle(60));
}

// ---------------------------------------------------------------------------
// 4. Thread safety tests
// ---------------------------------------------------------------------------

test "concurrent getOrCreate same key — single Session created" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;

    for (0..num_threads) |t| {
        handles[t] = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
            fn run(mgr: *SessionManager, out: **Session) void {
                out.* = mgr.getOrCreate("shared:key") catch unreachable;
            }
        }.run, .{ &sm, &sessions[t] });
    }

    for (handles) |h| h.join();

    // All threads should have gotten the same session pointer
    for (1..num_threads) |i| {
        try testing.expect(sessions[0] == sessions[i]);
    }
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "concurrent getOrCreate different keys — separate Sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "key:{d}", .{t}) catch "?";
        handles[t] = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, out: **Session) void {
                out.* = mgr.getOrCreate(key) catch unreachable;
            }
        }.run, .{ &sm, keys[t], &sessions[t] });
    }

    for (handles) |h| h.join();

    // All sessions should be distinct
    for (0..num_threads) |i| {
        for (i + 1..num_threads) |j| {
            try testing.expect(sessions[i] != sessions[j]);
        }
    }
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage different keys — no crash" {
    var mock = MockProvider{ .response = "concurrent ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "conc:{d}", .{t}) catch "?";
        handles[t] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator) void {
                for (0..3) |_| {
                    const resp = mgr.processMessage(key, "hello", null) catch return;
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator });
    }

    for (handles) |h| h.join();
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage with sqlite memory does not panic" {
    var mock = MockProvider{ .response = "concurrent sqlite ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][24]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;
    var failed = std.atomic.Value(bool).init(false);

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "sqlite-conc:{d}", .{t}) catch "?";
        handles[t] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator, failed_flag: *std.atomic.Value(bool)) void {
                for (0..5) |_| {
                    const resp = mgr.processMessage(key, "hello sqlite", null) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator, &failed });
    }

    for (handles) |h| h.join();
    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());

    const count = try mem.count();
    try testing.expect(count > 0);
}

// ---------------------------------------------------------------------------
// 5. Session consolidation tests
// ---------------------------------------------------------------------------

test "session last_consolidated defaults to zero" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:consolidation");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
}

test "session initial state includes last_consolidated" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:fields");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(s.created_at > 0);
    try testing.expect(s.last_active > 0);
}

// ---------------------------------------------------------------------------
// 6. reloadSkillsAll tests
// ---------------------------------------------------------------------------

test "reloadSkillsAll with no sessions returns zero counts" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const result = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 0), result.sessions_seen);
    try testing.expectEqual(@as(usize, 0), result.sessions_reloaded);
    try testing.expectEqual(@as(usize, 0), result.failures);
}

test "reloadSkillsAll invalidates system prompt on all sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("reload:a");
    const s2 = try sm.getOrCreate("reload:b");
    s1.agent.has_system_prompt = true;
    s2.agent.has_system_prompt = true;

    const result = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 2), result.sessions_seen);
    try testing.expectEqual(@as(usize, 2), result.sessions_reloaded);
    try testing.expect(!s1.agent.has_system_prompt);
    try testing.expect(!s2.agent.has_system_prompt);
}

test "reloadSkillsAll does not affect session count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("reload:c");
    _ = try sm.getOrCreate("reload:d");
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());

    _ = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
}

// ---------------------------------------------------------------------------
// 7. applyModelOverride sub-agent / tools-reviewer fallback tests
// ---------------------------------------------------------------------------

test "applyModelOverride sets sub_agent_model from channel override" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sa1");
    // Simulate global sub_agent_model already set on agent
    s.agent.sub_agent_model = "global/sub-agent-model";

    // Channel override explicitly sets sub_agent_model
    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_model = "channel/sub-agent-model",
    });
    try testing.expectEqualStrings("channel/sub-agent-model", s.agent.sub_agent_model.?);
}

test "applyModelOverride sub_agent_model falls back to channel general model" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sa2");
    s.agent.sub_agent_model = "global/sub-agent-model";

    // Channel has general model but no sub_agent_model
    SessionManager.applyModelOverride(&s.agent, .{
        .model = "channel/general-model",
    });
    // sub_agent_model should use channel's general model
    try testing.expectEqualStrings("channel/general-model", s.agent.sub_agent_model.?);
}

test "applyModelOverride sub_agent_model keeps global when no channel override" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sa3");
    s.agent.sub_agent_model = "global/sub-agent-model";

    // Channel override has no model and no sub_agent_model
    SessionManager.applyModelOverride(&s.agent, .{
        .temperature = 0.5,
    });
    // sub_agent_model should stay as global
    try testing.expectEqualStrings("global/sub-agent-model", s.agent.sub_agent_model.?);
}

test "applyModelOverride sub_agent_model channel-specific beats channel general" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sa4");
    s.agent.sub_agent_model = "global/sub-agent-model";

    // Channel has both general model and sub_agent_model
    SessionManager.applyModelOverride(&s.agent, .{
        .model = "channel/general-model",
        .sub_agent_model = "channel/sub-agent-specific",
    });
    // sub_agent_model should use the channel-specific one, not general
    try testing.expectEqualStrings("channel/sub-agent-specific", s.agent.sub_agent_model.?);
}

test "applyModelOverride tools_reviewer_model from channel override" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:tr1");
    s.agent.tools_reviewer_model = "global/tools-reviewer-model";

    SessionManager.applyModelOverride(&s.agent, .{
        .tools_reviewer_model = "channel/tools-reviewer-model",
    });
    try testing.expectEqualStrings("channel/tools-reviewer-model", s.agent.tools_reviewer_model.?);
}

test "applyModelOverride tools_reviewer_model falls back to channel general model" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:tr2");
    s.agent.tools_reviewer_model = "global/tools-reviewer-model";

    SessionManager.applyModelOverride(&s.agent, .{
        .model = "channel/general-model",
    });
    try testing.expectEqualStrings("channel/general-model", s.agent.tools_reviewer_model.?);
}

test "applyModelOverride tools_reviewer_model keeps global when no channel override" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:tr3");
    s.agent.tools_reviewer_model = "global/tools-reviewer-model";

    SessionManager.applyModelOverride(&s.agent, .{
        .temperature = 0.5,
    });
    try testing.expectEqualStrings("global/tools-reviewer-model", s.agent.tools_reviewer_model.?);
}

test "applyModelOverride sub_agent_provider from channel override" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sap1");
    s.agent.sub_agent_provider = null;

    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_provider = "anthropic",
    });
    try testing.expectEqualStrings("anthropic", s.agent.sub_agent_provider.?);
}

test "applyModelOverride sub_agent_provider falls back to channel general provider" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sap2");
    s.agent.sub_agent_provider = null;

    SessionManager.applyModelOverride(&s.agent, .{
        .provider = "openrouter",
    });
    try testing.expectEqualStrings("openrouter", s.agent.sub_agent_provider.?);
}

test "applyModelOverride tools_reviewer_provider from channel override" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:trp1");
    s.agent.tools_reviewer_provider = null;

    SessionManager.applyModelOverride(&s.agent, .{
        .tools_reviewer_provider = "gemini",
    });
    try testing.expectEqualStrings("gemini", s.agent.tools_reviewer_provider.?);
}

test "applyModelOverride tools_reviewer_provider falls back to channel general provider" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:trp2");
    s.agent.tools_reviewer_provider = null;

    SessionManager.applyModelOverride(&s.agent, .{
        .provider = "openai",
    });
    try testing.expectEqualStrings("openai", s.agent.tools_reviewer_provider.?);
}

// ---------------------------------------------------------------------------
// 8. applyModelOverride unified fields: temperature no-cascade, base_url, max_context_tokens
// ---------------------------------------------------------------------------

test "applyModelOverride: general temperature does NOT cascade to sub_agent" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:temp_nocascade1");
    // Agent starts with sub_agent_temperature from global init (null = use compiled default 0.3)
    s.agent.sub_agent_temperature = null;
    s.agent.tools_reviewer_temperature = null;

    // Channel override sets general temperature but NOT sub_agent/tools_reviewer temperature
    SessionManager.applyModelOverride(&s.agent, .{
        .temperature = 0.9,
    });
    // General temperature IS applied
    try testing.expectEqual(@as(f64, 0.9), s.agent.temperature);
    // sub_agent_temperature must remain null (compiled default 0.3 will be used at call time)
    try testing.expect(s.agent.sub_agent_temperature == null);
    // tools_reviewer_temperature must remain null (compiled default 0.1 will be used at call time)
    try testing.expect(s.agent.tools_reviewer_temperature == null);
}

test "applyModelOverride: explicit sub_agent_temperature overrides agent value" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:temp_explicit1");
    s.agent.sub_agent_temperature = null;

    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_temperature = 0.5,
    });
    try testing.expect(@abs(s.agent.sub_agent_temperature.? - 0.5) < 0.001);
}

test "applyModelOverride: explicit tools_reviewer_temperature overrides agent value" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:temp_explicit2");
    s.agent.tools_reviewer_temperature = null;

    SessionManager.applyModelOverride(&s.agent, .{
        .tools_reviewer_temperature = 0.2,
    });
    try testing.expect(@abs(s.agent.tools_reviewer_temperature.? - 0.2) < 0.001);
}

test "applyModelOverride: sub_agent_max_context_tokens only set when > 0" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sa_ctx1");
    s.agent.sub_agent_max_context_tokens = 8192;

    // Override with 0 → keeps existing
    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_max_context_tokens = 0,
    });
    try testing.expectEqual(@as(u64, 8192), s.agent.sub_agent_max_context_tokens);

    // Override with > 0 → applies
    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_max_context_tokens = 16384,
    });
    try testing.expectEqual(@as(u64, 16384), s.agent.sub_agent_max_context_tokens);
}

test "applyModelOverride: sub_agent_base_url only set when non-null" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sa_url1");
    s.agent.sub_agent_base_url = "https://existing.example.com";

    // Override with null → keeps existing
    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_base_url = null,
    });
    try testing.expectEqualStrings("https://existing.example.com", s.agent.sub_agent_base_url.?);

    // Override with value → applies
    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_base_url = "https://new.example.com",
    });
    try testing.expectEqualStrings("https://new.example.com", s.agent.sub_agent_base_url.?);
}

test "applyModelOverride: sub_agent_max_iterations and review_after per-channel" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("override:sa_iters1");
    s.agent.sub_agent_max_iterations = 5;
    s.agent.sub_agent_review_after = 3;

    // Override with 0 → keeps existing
    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_max_iterations = 0,
        .sub_agent_review_after = 0,
    });
    try testing.expectEqual(@as(u32, 5), s.agent.sub_agent_max_iterations);
    try testing.expectEqual(@as(u32, 3), s.agent.sub_agent_review_after);

    // Override with > 0 → applies
    SessionManager.applyModelOverride(&s.agent, .{
        .sub_agent_max_iterations = 10,
        .sub_agent_review_after = 7,
    });
    try testing.expectEqual(@as(u32, 10), s.agent.sub_agent_max_iterations);
    try testing.expectEqual(@as(u32, 7), s.agent.sub_agent_review_after);
}

test "applyModelOverride full fallback chain: channel sub_agent > channel general > global sub_agent" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Test 1: global sub_agent_model set, no channel override → keeps global
    {
        const s = try sm.getOrCreate("override:chain1");
        s.agent.sub_agent_model = "global/sa";
        s.agent.sub_agent_provider = "global-prov";
        s.agent.tools_reviewer_model = "global/tr";
        s.agent.tools_reviewer_provider = "global-prov";

        SessionManager.applyModelOverride(&s.agent, .{});

        try testing.expectEqualStrings("global/sa", s.agent.sub_agent_model.?);
        try testing.expectEqualStrings("global-prov", s.agent.sub_agent_provider.?);
        try testing.expectEqualStrings("global/tr", s.agent.tools_reviewer_model.?);
        try testing.expectEqualStrings("global-prov", s.agent.tools_reviewer_provider.?);
    }

    // Test 2: global sub_agent_model set, channel has general model → channel general wins
    {
        const s = try sm.getOrCreate("override:chain2");
        s.agent.sub_agent_model = "global/sa";
        s.agent.sub_agent_provider = "global-prov";

        SessionManager.applyModelOverride(&s.agent, .{
            .provider = "ch-prov",
            .model = "ch/general",
        });

        try testing.expectEqualStrings("ch/general", s.agent.sub_agent_model.?);
        try testing.expectEqualStrings("ch-prov", s.agent.sub_agent_provider.?);
    }

    // Test 3: global + channel general + channel specific → channel specific wins
    {
        const s = try sm.getOrCreate("override:chain3");
        s.agent.sub_agent_model = "global/sa";
        s.agent.sub_agent_provider = "global-prov";

        SessionManager.applyModelOverride(&s.agent, .{
            .provider = "ch-prov",
            .model = "ch/general",
            .sub_agent_provider = "ch-sa-prov",
            .sub_agent_model = "ch/sa-specific",
        });

        try testing.expectEqualStrings("ch/sa-specific", s.agent.sub_agent_model.?);
        try testing.expectEqualStrings("ch-sa-prov", s.agent.sub_agent_provider.?);
    }
}

test "updateModelParamsExcludingPrefixes skips mqtt and redis_stream sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Create sessions across multiple channel types
    _ = try sm.getOrCreate("telegram:default:user1");
    _ = try sm.getOrCreate("discord:default:user2");
    _ = try sm.getOrCreate("slack:default:user3");
    _ = try sm.getOrCreate("mqtt:account1:topic1");
    _ = try sm.getOrCreate("redis_stream:account2:topic2");

    const exclude = &[_][]const u8{ "mqtt:", "redis_stream:" };
    const updated = sm.updateModelParamsExcludingPrefixes(.{ .model = "global-new" }, exclude);

    // Only Telegram, Discord, Slack should be updated (3), not MQTT/RS (2)
    try testing.expectEqual(@as(usize, 3), updated);

    // Verify non-excluded sessions were updated
    const s_tg = try sm.getOrCreate("telegram:default:user1");
    try testing.expectEqualStrings("global-new", s_tg.agent.default_model);
    const s_dc = try sm.getOrCreate("discord:default:user2");
    try testing.expectEqualStrings("global-new", s_dc.agent.default_model);
    const s_sl = try sm.getOrCreate("slack:default:user3");
    try testing.expectEqualStrings("global-new", s_sl.agent.default_model);

    // Verify excluded sessions were NOT updated
    const s_mqtt = try sm.getOrCreate("mqtt:account1:topic1");
    try testing.expectEqualStrings("test/mock-model", s_mqtt.agent.default_model);
    const s_rs = try sm.getOrCreate("redis_stream:account2:topic2");
    try testing.expectEqualStrings("test/mock-model", s_rs.agent.default_model);
}

test "updateModelParamsExcludingPrefixes with empty exclude updates all" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("telegram:default:user1");
    _ = try sm.getOrCreate("mqtt:account1:topic1");

    const exclude = &[_][]const u8{};
    const updated = sm.updateModelParamsExcludingPrefixes(.{ .model = "all-new" }, exclude);
    try testing.expectEqual(@as(usize, 2), updated);

    const s1 = try sm.getOrCreate("telegram:default:user1");
    try testing.expectEqualStrings("all-new", s1.agent.default_model);
    const s2 = try sm.getOrCreate("mqtt:account1:topic1");
    try testing.expectEqualStrings("all-new", s2.agent.default_model);
}

test "updateModelParamsExcludingPrefixes covers all non-endpoint channel types" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Create sessions for many different channel types
    _ = try sm.getOrCreate("telegram:default:u1");
    _ = try sm.getOrCreate("discord:default:u2");
    _ = try sm.getOrCreate("slack:default:u3");
    _ = try sm.getOrCreate("signal:default:u4");
    _ = try sm.getOrCreate("matrix:default:u5");
    _ = try sm.getOrCreate("irc:default:u6");
    _ = try sm.getOrCreate("web:default:u7");
    _ = try sm.getOrCreate("whatsapp:default:u8");
    _ = try sm.getOrCreate("mattermost:default:u9");
    _ = try sm.getOrCreate("imessage:default:u10");
    _ = try sm.getOrCreate("mqtt:a1:t1");
    _ = try sm.getOrCreate("redis_stream:a2:t2");

    const exclude = &[_][]const u8{ "mqtt:", "redis_stream:" };
    const updated = sm.updateModelParamsExcludingPrefixes(.{ .provider = "new-prov" }, exclude);

    // 10 non-endpoint channels updated, 2 endpoint channels skipped
    try testing.expectEqual(@as(usize, 10), updated);

    // Spot-check a few updated sessions
    const s_tg = try sm.getOrCreate("telegram:default:u1");
    try testing.expectEqualStrings("new-prov", s_tg.agent.default_provider);
    const s_web = try sm.getOrCreate("web:default:u7");
    try testing.expectEqualStrings("new-prov", s_web.agent.default_provider);

    // Verify MQTT/RS not updated
    const s_mqtt = try sm.getOrCreate("mqtt:a1:t1");
    try testing.expect(s_mqtt.agent.default_provider.len > 0);
    try testing.expect(!std.mem.eql(u8, s_mqtt.agent.default_provider, "new-prov"));
}

test "refreshNonModelConfig updates config-derived fields on all sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("telegram:default:user1");
    _ = try sm.getOrCreate("discord:default:user2");

    // Build a new config with different non-model settings
    var new_cfg = testConfig();
    new_cfg.reasoning_effort = "high";
    new_cfg.agent.max_tool_iterations = 42;
    new_cfg.agent.max_history_messages = 200;
    new_cfg.agent.status_show_emojis = false;
    new_cfg.autonomy.level = .read_only;

    const exclude = &[_][]const u8{ "mqtt:", "redis_stream:" };
    const refreshed = sm.refreshNonModelConfig(&new_cfg, exclude);
    try testing.expectEqual(@as(usize, 2), refreshed);

    const s1 = try sm.getOrCreate("telegram:default:user1");
    try testing.expectEqualStrings("high", s1.agent.reasoning_effort.?);
    try testing.expectEqual(@as(u32, 42), s1.agent.max_tool_iterations);
    try testing.expectEqual(@as(u32, 200), s1.agent.max_history_messages);
    try testing.expect(!s1.agent.status_show_emojis);
    try testing.expectEqualStrings("deny", s1.agent.exec_security.toSlice());
    try testing.expectEqualStrings("off", s1.agent.exec_ask.toSlice());

    const s2 = try sm.getOrCreate("discord:default:user2");
    try testing.expectEqualStrings("high", s2.agent.reasoning_effort.?);
    try testing.expectEqual(@as(u32, 42), s2.agent.max_tool_iterations);
}

test "refreshNonModelConfig does not change model fields" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("telegram:default:user1");

    // Change the default_model in the new config — refreshNonModelConfig should NOT touch it
    var new_cfg = testConfig();
    new_cfg.default_model = "other/model";
    new_cfg.reasoning_effort = "low";

    const no_exclude = &[_][]const u8{};
    _ = sm.refreshNonModelConfig(&new_cfg, no_exclude);

    const s = try sm.getOrCreate("telegram:default:user1");
    // model_name should still be the original
    try testing.expectEqualStrings("test/mock-model", s.agent.model_name);
    // but reasoning_effort should be updated
    try testing.expectEqualStrings("low", s.agent.reasoning_effort.?);
}

test "refreshNonModelConfig excludes mqtt and redis_stream sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("telegram:default:user1");
    _ = try sm.getOrCreate("mqtt:account1:topic1");
    _ = try sm.getOrCreate("redis_stream:account2:topic2");

    var new_cfg = testConfig();
    new_cfg.agent.sub_agent_max_iterations = 99;
    new_cfg.agent.sub_agent_review_after = 77;
    new_cfg.reasoning_effort = "high";

    const exclude = &[_][]const u8{ "mqtt:", "redis_stream:" };
    const refreshed = sm.refreshNonModelConfig(&new_cfg, exclude);

    // Only Telegram updated (1), not MQTT/RS (2)
    try testing.expectEqual(@as(usize, 1), refreshed);

    // Telegram session got the update
    const s_tg = try sm.getOrCreate("telegram:default:user1");
    try testing.expectEqual(@as(u32, 99), s_tg.agent.sub_agent_max_iterations);
    try testing.expectEqualStrings("high", s_tg.agent.reasoning_effort.?);

    // MQTT session was NOT updated (still has default values)
    const s_mqtt = try sm.getOrCreate("mqtt:account1:topic1");
    try testing.expect(s_mqtt.agent.sub_agent_max_iterations != 99);
    try testing.expect(s_mqtt.agent.reasoning_effort == null);
}

test "updateProvider propagates new provider to existing sessions" {
    var mock_a = MockProvider{ .response = "provider-a" };
    var mock_b = MockProvider{ .response = "provider-b" };
    var cfg = testConfig();

    var sm = testSessionManager(testing.allocator, &mock_a, &cfg);
    defer sm.deinit();

    // Create two sessions using the original provider.
    const s1 = try sm.getOrCreate("telegram:default:user1");
    const s2 = try sm.getOrCreate("telegram:default:user2");

    // Both sessions should reference mock_a's vtable.
    try testing.expectEqualStrings("mock", s1.agent.provider.getName());
    try testing.expectEqualStrings("mock", s2.agent.provider.getName());

    // Swap provider.
    sm.updateProvider(mock_b.provider());

    // Session manager and existing sessions all point to mock_b.
    try testing.expect(sm.provider.ptr == @as(*anyopaque, @ptrCast(&mock_b)));
    try testing.expect(s1.agent.provider.ptr == @as(*anyopaque, @ptrCast(&mock_b)));
    try testing.expect(s2.agent.provider.ptr == @as(*anyopaque, @ptrCast(&mock_b)));

    // New session also gets mock_b.
    const s3 = try sm.getOrCreate("telegram:default:user3");
    try testing.expect(s3.agent.provider.ptr == @as(*anyopaque, @ptrCast(&mock_b)));
}
