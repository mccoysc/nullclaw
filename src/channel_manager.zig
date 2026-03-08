//! Channel Manager — centralizes channel lifecycle (init, start, supervise, stop).
//!
//! Replaces the hardcoded Telegram/Signal-only logic in daemon.zig with a
//! generic system that handles all configured channels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bus_mod = @import("bus.zig");
const Config = @import("config.zig").Config;
const config_types = @import("config_types.zig");
const channel_catalog = @import("channel_catalog.zig");
const channel_adapters = @import("channel_adapters.zig");
const dispatch = @import("channels/dispatch.zig");
const channel_loop = @import("channel_loop.zig");
const health = @import("health.zig");
const daemon = @import("daemon.zig");
const channels_mod = @import("channels/root.zig");
const mattermost = channels_mod.mattermost;
const discord = channels_mod.discord;
const imessage = channels_mod.imessage;
const qq = channels_mod.qq;
const onebot = channels_mod.onebot;
const maixcam = channels_mod.maixcam;
const slack = channels_mod.slack;
const irc = channels_mod.irc;
const web = channels_mod.web;
const Channel = channels_mod.Channel;

const log = std.log.scoped(.channel_manager);

pub const ListenerType = enum {
    /// Telegram, Signal — poll in a loop
    polling,
    /// Discord, Mattermost, Slack, IRC, QQ(websocket), OneBot — internal socket/WebSocket loop
    gateway_loop,
    /// WhatsApp, Line, Lark — HTTP gateway receives
    webhook_only,
    /// Outbound-only channel lifecycle (start/stop/send, no inbound listener thread yet)
    send_only,
    /// Channel exists but no listener yet
    not_implemented,
};

pub const Entry = struct {
    name: []const u8,
    account_id: []const u8 = "default",
    channel: Channel,
    listener_type: ListenerType,
    supervised: dispatch.SupervisedChannel,
    thread: ?std.Thread = null,
    polling_state: ?PollingState = null,
};

pub const PollingState = channel_loop.PollingState;

pub const ChannelManager = struct {
    allocator: Allocator,
    config: *const Config,
    registry: *dispatch.ChannelRegistry,
    runtime: ?*channel_loop.ChannelRuntime = null,
    event_bus: ?*bus_mod.Bus = null,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    // Config hot-reload state
    config_watch_enabled: bool = false,
    config_watch_path: []const u8 = "",
    last_config_mtime: i128 = 0,
    backing_allocator: Allocator = undefined,
    // Previous configs kept alive to avoid dangling pointers in running channels.
    // Freed on deinit.
    prev_configs: std.ArrayListUnmanaged(*Config) = .empty,

    pub fn init(allocator: Allocator, config: *const Config, registry: *dispatch.ChannelRegistry) !*ChannelManager {
        const self = try allocator.create(ChannelManager);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .registry = registry,
        };
        return self;
    }

    pub fn deinit(self: *ChannelManager) void {
        // Stop all threads
        self.stopAll();

        // Free previous configs from hot-reloads
        for (self.prev_configs.items) |cfg| {
            var mutable_cfg = cfg;
            mutable_cfg.deinit();
            self.backing_allocator.destroy(cfg);
        }
        self.prev_configs.deinit(self.allocator);

        self.entries.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setRuntime(self: *ChannelManager, rt: *channel_loop.ChannelRuntime) void {
        self.runtime = rt;
    }

    pub fn setEventBus(self: *ChannelManager, eb: *bus_mod.Bus) void {
        self.event_bus = eb;
    }

    fn pollingLastActivity(state: PollingState) i64 {
        return switch (state) {
            .telegram => |ls| ls.last_activity.load(.acquire),
            .signal => |ls| ls.last_activity.load(.acquire),
            .matrix => |ls| ls.last_activity.load(.acquire),
        };
    }

    fn requestPollingStop(state: PollingState) void {
        switch (state) {
            .telegram => |ls| ls.stop_requested.store(true, .release),
            .signal => |ls| ls.stop_requested.store(true, .release),
            .matrix => |ls| ls.stop_requested.store(true, .release),
        }
    }

    fn destroyPollingState(self: *ChannelManager, state: PollingState) void {
        switch (state) {
            .telegram => |ls| self.allocator.destroy(ls),
            .signal => |ls| self.allocator.destroy(ls),
            .matrix => |ls| self.allocator.destroy(ls),
        }
    }

    fn spawnPollingThread(self: *ChannelManager, entry: *Entry, rt: *channel_loop.ChannelRuntime) !void {
        const polling_desc = channel_adapters.findPollingDescriptor(entry.name) orelse
            return error.UnsupportedChannel;
        const spawned = try polling_desc.spawn(self.allocator, self.config, rt, entry.channel);
        entry.polling_state = spawned.state;
        entry.thread = spawned.thread;
    }

    fn isPollingSourceDuplicate(
        allocator: Allocator,
        entries: []const Entry,
        current_index: usize,
        polling_desc: *const channel_adapters.PollingDescriptor,
    ) bool {
        const source_key_fn = polling_desc.source_key orelse return false;
        const current = entries[current_index];
        if (!std.mem.eql(u8, current.name, polling_desc.channel_name)) return false;
        if (current.listener_type != .polling) return false;

        const current_source = source_key_fn(allocator, current.channel) orelse return false;
        defer allocator.free(current_source);

        var i: usize = 0;
        while (i < current_index) : (i += 1) {
            const prev = entries[i];
            if (!std.mem.eql(u8, prev.name, polling_desc.channel_name)) continue;
            if (prev.listener_type != .polling) continue;
            if (prev.supervised.state != .running) continue;

            const prev_source = source_key_fn(allocator, prev.channel) orelse continue;
            const duplicate = std.mem.eql(u8, prev_source, current_source);
            allocator.free(prev_source);
            if (duplicate) return true;
        }
        return false;
    }

    fn stopPollingThread(self: *ChannelManager, entry: *Entry) void {
        if (entry.polling_state) |state| {
            requestPollingStop(state);
        }

        if (entry.thread) |t| {
            t.join();
            entry.thread = null;
        }

        if (entry.polling_state) |state| {
            self.destroyPollingState(state);
            entry.polling_state = null;
        }
    }

    fn listenerTypeFromMode(mode: channel_catalog.ListenerMode) ListenerType {
        return switch (mode) {
            .polling => .polling,
            .gateway_loop => .gateway_loop,
            .webhook_only => .webhook_only,
            .send_only => .send_only,
            .none => .not_implemented,
        };
    }

    fn listenerTypeForField(comptime field_name: []const u8) ListenerType {
        const meta = channel_catalog.findByKey(field_name) orelse
            @compileError("missing channel_catalog metadata for channel field: " ++ field_name);
        return listenerTypeFromMode(meta.listener_mode);
    }

    fn accountIdFromConfig(cfg: anytype) []const u8 {
        if (comptime @hasField(@TypeOf(cfg), "account_id")) {
            return cfg.account_id;
        }
        return "default";
    }

    fn maybeAttachBus(self: *ChannelManager, channel_ptr: anytype) void {
        const ChannelType = @TypeOf(channel_ptr.*);
        if (self.event_bus) |eb| {
            if (comptime @hasDecl(ChannelType, "setBus")) {
                channel_ptr.setBus(eb);
            }
        }
    }

    fn appendChannelFromConfig(self: *ChannelManager, comptime field_name: []const u8, cfg: anytype) !void {
        const channel_module = @field(channels_mod, field_name);
        const ChannelType = channelTypeForModule(channel_module, field_name);

        const ch_ptr = try self.allocator.create(ChannelType);
        ch_ptr.* = ChannelType.initFromConfig(self.allocator, cfg);
        self.maybeAttachBus(ch_ptr);

        const ch = ch_ptr.channel();
        const account_id = accountIdFromConfig(cfg);
        try self.registry.registerWithAccount(ch, account_id);

        var listener_type = comptime listenerTypeForField(field_name);
        if (comptime std.mem.eql(u8, field_name, "qq")) {
            listener_type = if (cfg.receive_mode == .webhook) .webhook_only else .gateway_loop;
        }
        try self.entries.append(self.allocator, .{
            .name = field_name,
            .account_id = account_id,
            .channel = ch,
            .listener_type = listener_type,
            .supervised = dispatch.spawnSupervisedChannel(ch, 5),
        });
    }

    fn channelTypeForModule(comptime module: type, comptime field_name: []const u8) type {
        inline for (std.meta.declarations(module)) |decl| {
            const candidate = @field(module, decl.name);
            if (comptime @TypeOf(candidate) == type) {
                const T = candidate;
                if (comptime @hasDecl(T, "initFromConfig") and @hasDecl(T, "channel")) {
                    return T;
                }
            }
        }
        @compileError("channel module has no type with initFromConfig+channel methods: " ++ field_name);
    }

    /// Scan config, create channel instances, register in registry.
    /// When no global default_model is configured, only channels/endpoints
    /// that have their own model_override.model are accepted; others are
    /// skipped with a warning.
    pub fn collectConfiguredChannels(self: *ChannelManager) !void {
        const has_global_model = if (self.config.default_model) |m| m.len > 0 else false;

        inline for (std.meta.fields(config_types.ChannelsConfig)) |field| {
            if (comptime std.mem.eql(u8, field.name, "cli") or std.mem.eql(u8, field.name, "webhook")) {
                continue;
            }
            if (comptime !channel_catalog.isBuildEnabledByKey(field.name)) {
                continue;
            }
            if (comptime !@hasDecl(channels_mod, field.name)) {
                @compileError("channels/root.zig is missing module export for channel: " ++ field.name);
            }

            // MQTT and Redis Stream have per-endpoint model_override — validate
            // each endpoint individually.  All other channel types lack
            // per-channel model config, so they require a global model.
            const is_endpoint_channel = comptime (std.mem.eql(u8, field.name, "mqtt") or
                std.mem.eql(u8, field.name, "redis_stream"));

            switch (@typeInfo(field.type)) {
                .pointer => |ptr| {
                    if (ptr.size != .slice) continue;
                    const items = @field(self.config.channels, field.name);
                    for (items) |cfg| {
                        if (!has_global_model) {
                            if (is_endpoint_channel) {
                                // Validate each endpoint has a model override
                                if (!channelConfigHasAllEndpointModels(cfg)) {
                                    log.warn("No global model configured and channel '{s}' (account '{s}') has endpoints without model_override.model — skipping", .{ field.name, accountIdFromConfig(cfg) });
                                    continue;
                                }
                            } else {
                                log.warn("No global model configured and channel '{s}' has no per-channel model support — skipping", .{field.name});
                                continue;
                            }
                        }
                        try self.appendChannelFromConfig(field.name, cfg);
                    }
                },
                .optional => |opt| {
                    if (@field(self.config.channels, field.name)) |cfg| {
                        if (!has_global_model) {
                            log.warn("No global model configured and channel '{s}' has no per-channel model support — skipping", .{field.name});
                        } else {
                            const inner = comptime blk: {
                                const info = @typeInfo(opt.child);
                                break :blk info == .pointer and info.pointer.size == .one;
                            };
                            if (inner) {
                                try self.appendChannelFromConfig(field.name, cfg.*);
                            } else {
                                try self.appendChannelFromConfig(field.name, cfg);
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Spawn listener threads for polling/gateway channels.
    pub fn startAll(self: *ChannelManager) !usize {
        var started: usize = 0;
        const runtime_available = self.runtime != null;

        for (self.entries.items, 0..) |*entry, index| {
            switch (entry.listener_type) {
                .polling => {
                    if (!runtime_available) {
                        log.warn("Cannot start {s}: no runtime available", .{entry.name});
                        continue;
                    }

                    if (channel_adapters.findPollingDescriptor(entry.name)) |polling_desc| {
                        if (isPollingSourceDuplicate(self.allocator, self.entries.items, index, polling_desc)) {
                            log.warn("Skipping duplicate {s} polling source for account_id={s}", .{ entry.name, entry.account_id });
                            continue;
                        }
                    }

                    self.spawnPollingThread(entry, self.runtime.?) catch |err| {
                        log.err("Failed to spawn {s} thread: {}", .{ entry.name, err });
                        continue;
                    };

                    entry.supervised.recordSuccess();
                    started += 1;
                    log.info("{s} polling thread started", .{entry.name});
                },
                .gateway_loop => {
                    if (!runtime_available) {
                        log.warn("Cannot start {s} gateway: no runtime available", .{entry.name});
                        continue;
                    }
                    // Gateway-loop channels (Discord, Mattermost, Slack, IRC, QQ, OneBot)
                    // manage their own connection/read loops.
                    entry.channel.start() catch |err| {
                        log.warn("Failed to start {s} gateway: {}", .{ entry.name, err });
                        continue;
                    };
                    started += 1;
                    log.info("{s} gateway started", .{entry.name});
                },
                .webhook_only => {
                    if (!runtime_available) {
                        log.warn("Cannot register {s} webhook: no runtime available", .{entry.name});
                        continue;
                    }
                    // Webhook channels don't need a thread — they receive via the HTTP gateway
                    entry.channel.start() catch |err| {
                        log.warn("Failed to start {s}: {}", .{ entry.name, err });
                        continue;
                    };
                    started += 1;
                    log.info("{s} registered (webhook-only)", .{entry.name});
                },
                .send_only => {
                    entry.channel.start() catch |err| {
                        log.warn("Failed to start {s}: {}", .{ entry.name, err });
                        continue;
                    };
                    started += 1;
                    log.info("{s} started (send-only)", .{entry.name});
                },
                .not_implemented => {
                    log.info("{s} configured but not implemented — skipping", .{entry.name});
                },
            }
        }

        return started;
    }

    /// Signal all threads to stop and join them.
    pub fn stopAll(self: *ChannelManager) void {
        for (self.entries.items) |*entry| {
            switch (entry.listener_type) {
                .polling => self.stopPollingThread(entry),
                .gateway_loop, .webhook_only, .send_only => entry.channel.stop(),
                .not_implemented => {},
            }
        }
    }

    /// Enable config file hot-reload watching.
    /// Call before supervisionLoop to enable automatic config reloading.
    pub fn enableConfigWatch(self: *ChannelManager, config_path: []const u8, backing_alloc: Allocator) void {
        self.config_watch_enabled = true;
        self.config_watch_path = config_path;
        self.backing_allocator = backing_alloc;
        self.last_config_mtime = getConfigFileMtime(config_path) catch 0;
        log.info("Config hot-reload enabled, watching: {s}", .{config_path});
    }

    /// Check if config file has changed and apply updates if so.
    /// Called from supervisionLoop on each iteration.
    fn checkConfigReload(self: *ChannelManager, state: *daemon.DaemonState) void {
        if (!self.config_watch_enabled) return;

        const current_mtime = getConfigFileMtime(self.config_watch_path) catch return;
        if (current_mtime == self.last_config_mtime) return;
        self.last_config_mtime = current_mtime;

        log.info("Config file changed, reloading...", .{});

        // Load the new config
        var new_config_val = Config.load(self.backing_allocator) catch |err| {
            log.err("Failed to reload config: {s}", .{@errorName(err)});
            return;
        };

        // Heap-allocate so we have a stable pointer
        const new_config = self.backing_allocator.create(Config) catch {
            new_config_val.deinit();
            log.err("Failed to allocate config", .{});
            return;
        };
        new_config.* = new_config_val;

        // Diff and apply changes
        self.applyConfigReload(new_config, state);

        // Save old config pointer before overwriting — needed for provider change detection.
        const old_config = self.config;

        // Store the old config (don't free — running channels may still reference it)
        self.prev_configs.append(self.allocator, @constCast(self.config)) catch {};

        // Update config pointer
        self.config = new_config;

        // Update session manager config so new sessions use the new config
        if (self.runtime) |rt| {
            rt.session_mgr.updateConfig(new_config);
            rt.config = new_config;

            // If provider credentials or default_provider changed, rebuild the
            // provider bundle so existing sessions pick up the new API key.
            if (providerConfigChanged(old_config, new_config)) {
                rt.rebuildProvider(new_config);
            }
        }

        log.info("Config reload complete", .{});
    }

    /// Apply config changes: stop removed channels, start added ones.
    /// Uses endpoint_id to correlate running sessions with config entries:
    ///   - endpoint_id gone          → delete session
    ///   - structural change (host/port/keys/topic) → reset (evict) session
    ///   - only model params changed → hot-update in place, keep state
    fn applyConfigReload(self: *ChannelManager, new_config: *const Config, state: *daemon.DaemonState) void {
        _ = state;
        const old = self.config;
        const global_model_changed = globalModelConfigChanged(old, new_config);

        var entries_to_remove: std.ArrayListUnmanaged(usize) = .empty;
        defer entries_to_remove.deinit(self.allocator);

        // ── MQTT channels ──────────────────────────────────────────────

        // 1a. Removed MQTT accounts
        for (old.channels.mqtt) |old_mqtt| {
            const found = for (new_config.channels.mqtt) |new_mqtt| {
                if (std.mem.eql(u8, old_mqtt.account_id, new_mqtt.account_id)) break true;
            } else false;
            if (!found) {
                log.info("MQTT account '{s}' removed", .{old_mqtt.account_id});
                self.stopAndRemoveByNameAccount("mqtt", old_mqtt.account_id, &entries_to_remove);
                self.evictSessionsForChannel("mqtt", old_mqtt.account_id);
            }
        }

        // 1b. Existing MQTT accounts — per-endpoint granular diff by endpoint_id
        for (old.channels.mqtt) |old_mqtt| {
            for (new_config.channels.mqtt) |new_mqtt| {
                if (!std.mem.eql(u8, old_mqtt.account_id, new_mqtt.account_id)) continue;

                var topology_changed = false;
                for (old_mqtt.endpoints) |old_ep| {
                    const matching_new = findMqttEndpointById(new_mqtt.endpoints, old_ep);
                    if (matching_new) |new_ep| {
                        // Endpoint still exists — classify the change
                        if (mqttEndpointStructuralChanged(old_ep, new_ep)) {
                            // Structural change (host/port/keys/topic) → reset session
                            log.info("MQTT endpoint '{s}' structural change, resetting session", .{endpointLabel(old_ep.endpoint_id, old_ep.listen_topic)});
                            topology_changed = true;
                            self.evictSessionByEndpoint("mqtt", old_mqtt.account_id, old_ep);
                        } else if (!modelOverrideEqual(old_ep.model_override, new_ep.model_override)) {
                            // Only model params changed → hot-update in place
                            log.info("MQTT endpoint '{s}' model config changed, hot-updating", .{endpointLabel(old_ep.endpoint_id, old_ep.listen_topic)});
                            self.hotUpdateSessionByEndpoint("mqtt", old_mqtt.account_id, old_ep, new_ep.model_override);
                        }
                        // else: no change at all — leave session untouched
                    } else {
                        // Endpoint removed (endpoint_id no longer in new config)
                        log.info("MQTT endpoint '{s}' removed, evicting session", .{endpointLabel(old_ep.endpoint_id, old_ep.listen_topic)});
                        topology_changed = true;
                        self.evictSessionByEndpoint("mqtt", old_mqtt.account_id, old_ep);
                    }
                }
                // Check for added endpoints (in new but not in old)
                for (new_mqtt.endpoints) |new_ep| {
                    if (findMqttEndpointById(old_mqtt.endpoints, new_ep) == null) topology_changed = true;
                }

                if (topology_changed) {
                    log.info("MQTT account '{s}' topology changed, restarting channel", .{old_mqtt.account_id});
                    self.stopAndRemoveByNameAccount("mqtt", old_mqtt.account_id, &entries_to_remove);
                    self.addMqttChannelFromConfig(new_mqtt);
                }

                // Global model change: hot-update ALL endpoints.
                // mergeGlobalWithEndpoint gives per-endpoint fields priority, so
                // endpoints with explicit model/provider/temperature keep their
                // own general settings while still receiving updated sub_agent
                // and tools_reviewer fields from global config.
                if (global_model_changed and !topology_changed) {
                    const global_mo = buildGlobalModelOverride(new_config);
                    for (new_mqtt.endpoints) |ep| {
                        log.info("Global model changed, hot-updating MQTT endpoint '{s}'", .{endpointLabel(ep.endpoint_id, ep.listen_topic)});
                        const merged = mergeGlobalWithEndpoint(global_mo, ep.model_override);
                        self.hotUpdateSessionByEndpoint("mqtt", new_mqtt.account_id, ep, merged);
                    }
                }
                break;
            }
        }

        // 1c. Added MQTT accounts
        for (new_config.channels.mqtt) |new_mqtt| {
            const found = for (old.channels.mqtt) |old_mqtt| {
                if (std.mem.eql(u8, old_mqtt.account_id, new_mqtt.account_id)) break true;
            } else false;
            if (!found) {
                log.info("MQTT account '{s}' added, starting channel", .{new_mqtt.account_id});
                self.addMqttChannelFromConfig(new_mqtt);
            }
        }

        // ── Redis Stream channels ──────────────────────────────────────

        // 2a. Removed Redis Stream accounts
        for (old.channels.redis_stream) |old_rs| {
            const found = for (new_config.channels.redis_stream) |new_rs| {
                if (std.mem.eql(u8, old_rs.account_id, new_rs.account_id)) break true;
            } else false;
            if (!found) {
                log.info("Redis Stream account '{s}' removed", .{old_rs.account_id});
                self.stopAndRemoveByNameAccount("redis_stream", old_rs.account_id, &entries_to_remove);
                self.evictSessionsForChannel("redis_stream", old_rs.account_id);
            }
        }

        // 2b. Existing Redis Stream accounts — per-endpoint granular diff by endpoint_id
        for (old.channels.redis_stream) |old_rs| {
            for (new_config.channels.redis_stream) |new_rs| {
                if (!std.mem.eql(u8, old_rs.account_id, new_rs.account_id)) continue;

                var topology_changed = false;
                for (old_rs.endpoints) |old_ep| {
                    const matching_new = findRsEndpointById(new_rs.endpoints, old_ep);
                    if (matching_new) |new_ep| {
                        if (rsEndpointStructuralChanged(old_ep, new_ep)) {
                            log.info("Redis Stream endpoint '{s}' structural change, resetting session", .{endpointLabel(old_ep.endpoint_id, old_ep.listen_topic)});
                            topology_changed = true;
                            self.evictSessionByRsEndpoint("redis_stream", old_rs.account_id, old_ep);
                        } else if (!modelOverrideEqual(old_ep.model_override, new_ep.model_override)) {
                            log.info("Redis Stream endpoint '{s}' model config changed, hot-updating", .{endpointLabel(old_ep.endpoint_id, old_ep.listen_topic)});
                            self.hotUpdateSessionByRsEndpoint("redis_stream", old_rs.account_id, old_ep, new_ep.model_override);
                        }
                    } else {
                        log.info("Redis Stream endpoint '{s}' removed, evicting session", .{endpointLabel(old_ep.endpoint_id, old_ep.listen_topic)});
                        topology_changed = true;
                        self.evictSessionByRsEndpoint("redis_stream", old_rs.account_id, old_ep);
                    }
                }
                for (new_rs.endpoints) |new_ep| {
                    if (findRsEndpointById(old_rs.endpoints, new_ep) == null) topology_changed = true;
                }

                if (topology_changed) {
                    log.info("Redis Stream account '{s}' topology changed, restarting channel", .{old_rs.account_id});
                    self.stopAndRemoveByNameAccount("redis_stream", old_rs.account_id, &entries_to_remove);
                    self.addRedisStreamChannelFromConfig(new_rs);
                }

                if (global_model_changed and !topology_changed) {
                    const global_mo_rs = buildGlobalModelOverride(new_config);
                    for (new_rs.endpoints) |ep| {
                        log.info("Global model changed, hot-updating Redis Stream endpoint '{s}'", .{endpointLabel(ep.endpoint_id, ep.listen_topic)});
                        const merged_rs = mergeGlobalWithEndpoint(global_mo_rs, ep.model_override);
                        self.hotUpdateSessionByRsEndpoint("redis_stream", new_rs.account_id, ep, merged_rs);
                    }
                }
                break;
            }
        }

        // 2c. Added Redis Stream accounts
        for (new_config.channels.redis_stream) |new_rs| {
            const found = for (old.channels.redis_stream) |old_rs| {
                if (std.mem.eql(u8, old_rs.account_id, new_rs.account_id)) break true;
            } else false;
            if (!found) {
                log.info("Redis Stream account '{s}' added, starting channel", .{new_rs.account_id});
                self.addRedisStreamChannelFromConfig(new_rs);
            }
        }

        // ── Hot-update ALL non-endpoint-based sessions ──
        // MQTT and Redis Stream sessions are already handled above with
        // per-endpoint merge logic.  All other channel types (Telegram,
        // Discord, Slack, Signal, Matrix, IRC, Web, etc.) inherit directly
        // from global config, so we update them here.
        //
        // Model params are always applied (not only when globalModelConfigChanged)
        // to ensure sessions stay in sync even when the change detection has
        // edge-case gaps.  Non-model config-derived fields (reasoning_effort,
        // exec_security, etc.) are also refreshed so that /debug reflects the
        // latest config.
        if (self.runtime) |rt| {
            const global_mo = buildGlobalModelOverride(new_config);
            const exclude = &[_][]const u8{ "mqtt:", "redis_stream:" };
            const model_updated = rt.session_mgr.updateModelParamsExcludingPrefixes(global_mo, exclude);
            const cfg_refreshed = rt.session_mgr.refreshNonModelConfig(new_config, exclude);
            if (model_updated > 0 or cfg_refreshed > 0) {
                log.info("Hot-updated {d} non-endpoint session(s)", .{cfg_refreshed});
            }
        }

        // ── Cleanup removed entries ────────────────────────────────────
        std.mem.sort(usize, entries_to_remove.items, {}, std.sort.desc(usize));
        for (entries_to_remove.items) |idx| {
            if (idx < self.entries.items.len) {
                _ = self.entries.orderedRemove(idx);
            }
        }
    }

    /// Stop a channel entry matching name and account_id, and mark its index for removal.
    fn stopAndRemoveByNameAccount(self: *ChannelManager, name: []const u8, account_id: []const u8, to_remove: *std.ArrayListUnmanaged(usize)) void {
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.account_id, account_id)) {
                switch (entry.listener_type) {
                    .polling => self.stopPollingThread(entry),
                    .gateway_loop, .webhook_only, .send_only => entry.channel.stop(),
                    .not_implemented => {},
                }
                to_remove.append(self.allocator, i) catch {};
            }
        }
    }

    /// Evict all sessions for a given channel type and account_id.
    fn evictSessionsForChannel(self: *ChannelManager, channel_type: []const u8, account_id: []const u8) void {
        if (self.runtime) |rt| {
            // Build prefix: "mqtt:account_id:" or "redis_stream:account_id:"
            var prefix_buf: [256]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "{s}:{s}:", .{ channel_type, account_id }) catch return;
            const evicted = rt.session_mgr.evictByPrefix(prefix);
            if (evicted > 0) {
                log.info("Evicted {d} session(s) for {s}:{s}", .{ evicted, channel_type, account_id });
            }
        }
    }

    /// Evict session(s) for a specific MQTT endpoint.
    /// Uses endpoint_id when available, falls back to account_id:topic.
    fn evictSessionByEndpoint(self: *ChannelManager, channel_type: []const u8, account_id: []const u8, ep: config_types.MqttEndpointConfig) void {
        if (self.runtime) |rt| {
            var key_buf: [512]u8 = undefined;
            const prefix = endpointSessionPrefix(&key_buf, channel_type, account_id, ep.endpoint_id, ep.listen_topic);
            const evicted = rt.session_mgr.evictByPrefix(prefix);
            if (evicted > 0) log.info("Evicted {d} session(s) for {s}", .{ evicted, prefix });
        }
    }

    /// Evict session(s) for a specific Redis Stream endpoint.
    fn evictSessionByRsEndpoint(self: *ChannelManager, channel_type: []const u8, account_id: []const u8, ep: config_types.RedisStreamEndpointConfig) void {
        if (self.runtime) |rt| {
            var key_buf: [512]u8 = undefined;
            const prefix = endpointSessionPrefix(&key_buf, channel_type, account_id, ep.endpoint_id, ep.listen_topic);
            const evicted = rt.session_mgr.evictByPrefix(prefix);
            if (evicted > 0) log.info("Evicted {d} session(s) for {s}", .{ evicted, prefix });
        }
    }

    /// Hot-update model params on an MQTT endpoint's session in place.
    fn hotUpdateSessionByEndpoint(self: *ChannelManager, channel_type: []const u8, account_id: []const u8, ep: config_types.MqttEndpointConfig, mo: config_types.ChannelModelOverride) void {
        if (self.runtime) |rt| {
            var key_buf: [512]u8 = undefined;
            const prefix = endpointSessionPrefix(&key_buf, channel_type, account_id, ep.endpoint_id, ep.listen_topic);
            const updated = rt.session_mgr.updateModelParamsByPrefix(prefix, mo);
            if (updated > 0) log.info("Hot-updated model on {d} session(s) for {s}", .{ updated, prefix });
        }
    }

    /// Hot-update model params on a Redis Stream endpoint's session in place.
    fn hotUpdateSessionByRsEndpoint(self: *ChannelManager, channel_type: []const u8, account_id: []const u8, ep: config_types.RedisStreamEndpointConfig, mo: config_types.ChannelModelOverride) void {
        if (self.runtime) |rt| {
            var key_buf: [512]u8 = undefined;
            const prefix = endpointSessionPrefix(&key_buf, channel_type, account_id, ep.endpoint_id, ep.listen_topic);
            const updated = rt.session_mgr.updateModelParamsByPrefix(prefix, mo);
            if (updated > 0) log.info("Hot-updated model on {d} session(s) for {s}", .{ updated, prefix });
        }
    }

    /// Hot-update model params for an MQTT endpoint that inherits global config.
    fn hotUpdateSessionByEndpointGlobal(self: *ChannelManager, channel_type: []const u8, account_id: []const u8, ep: config_types.MqttEndpointConfig, new_config: *const Config) void {
        self.hotUpdateSessionByEndpoint(channel_type, account_id, ep, buildGlobalModelOverride(new_config));
    }

    /// Hot-update model params for a Redis Stream endpoint that inherits global config.
    fn hotUpdateSessionByRsEndpointGlobal(self: *ChannelManager, channel_type: []const u8, account_id: []const u8, ep: config_types.RedisStreamEndpointConfig, new_config: *const Config) void {
        self.hotUpdateSessionByRsEndpoint(channel_type, account_id, ep, buildGlobalModelOverride(new_config));
    }

    /// Create and start a new MQTT channel from config at runtime.
    fn addMqttChannelFromConfig(self: *ChannelManager, cfg: config_types.MqttConfig) void {
        const mqtt_mod = channels_mod.mqtt;
        const ch_ptr = self.allocator.create(mqtt_mod.MqttChannel) catch {
            log.err("Failed to allocate MQTT channel for '{s}'", .{cfg.account_id});
            return;
        };
        ch_ptr.* = mqtt_mod.MqttChannel.initFromConfig(self.allocator, cfg);
        if (self.event_bus) |eb| ch_ptr.setBus(eb);

        const ch = ch_ptr.channel();
        self.registry.registerWithAccount(ch, cfg.account_id) catch {
            log.err("Failed to register MQTT channel '{s}'", .{cfg.account_id});
            return;
        };

        self.entries.append(self.allocator, .{
            .name = "mqtt",
            .account_id = cfg.account_id,
            .channel = ch,
            .listener_type = .gateway_loop,
            .supervised = dispatch.spawnSupervisedChannel(ch, 5),
        }) catch {
            log.err("Failed to append MQTT entry for '{s}'", .{cfg.account_id});
            return;
        };

        ch.start() catch |err| {
            log.err("Failed to start MQTT channel '{s}': {}", .{ cfg.account_id, err });
            return;
        };
        log.info("MQTT channel '{s}' started via hot-reload", .{cfg.account_id});
    }

    /// Create and start a new Redis Stream channel from config at runtime.
    fn addRedisStreamChannelFromConfig(self: *ChannelManager, cfg: config_types.RedisStreamConfig) void {
        const rs_mod = channels_mod.redis_stream;
        const ch_ptr = self.allocator.create(rs_mod.RedisStreamChannel) catch {
            log.err("Failed to allocate Redis Stream channel for '{s}'", .{cfg.account_id});
            return;
        };
        ch_ptr.* = rs_mod.RedisStreamChannel.initFromConfig(self.allocator, cfg);
        if (self.event_bus) |eb| ch_ptr.setBus(eb);

        const ch = ch_ptr.channel();
        self.registry.registerWithAccount(ch, cfg.account_id) catch {
            log.err("Failed to register Redis Stream channel '{s}'", .{cfg.account_id});
            return;
        };

        self.entries.append(self.allocator, .{
            .name = "redis_stream",
            .account_id = cfg.account_id,
            .channel = ch,
            .listener_type = .gateway_loop,
            .supervised = dispatch.spawnSupervisedChannel(ch, 5),
        }) catch {
            log.err("Failed to append Redis Stream entry for '{s}'", .{cfg.account_id});
            return;
        };

        ch.start() catch |err| {
            log.err("Failed to start Redis Stream channel '{s}': {}", .{ cfg.account_id, err });
            return;
        };
        log.info("Redis Stream channel '{s}' started via hot-reload", .{cfg.account_id});
    }

    /// Monitoring loop: check health, restart failed channels with backoff.
    /// Also checks for config file changes and applies hot-reload.
    /// Blocks until shutdown.
    pub fn supervisionLoop(self: *ChannelManager, state: *daemon.DaemonState) void {
        const STALE_THRESHOLD_SECS: i64 = 600;
        const WATCH_INTERVAL_SECS: u64 = 10;

        while (!daemon.isShutdownRequested()) {
            std.Thread.sleep(WATCH_INTERVAL_SECS * std.time.ns_per_s);
            if (daemon.isShutdownRequested()) break;

            // Check for config file changes and apply hot-reload
            self.checkConfigReload(state);

            for (self.entries.items) |*entry| {
                // Gateway-loop channels: health check + restart on failure
                if (entry.listener_type == .gateway_loop) {
                    const probe_ok = entry.channel.healthCheck();
                    if (probe_ok) {
                        health.markComponentOk(entry.name);
                        if (entry.supervised.state != .running) entry.supervised.recordSuccess();
                    } else {
                        log.warn("{s} gateway health check failed", .{entry.name});
                        health.markComponentError(entry.name, "gateway health check failed");
                        entry.supervised.recordFailure();

                        if (entry.supervised.shouldRestart()) {
                            log.info("Restarting {s} gateway (attempt {d})", .{ entry.name, entry.supervised.restart_count });
                            state.markError("channels", "gateway health check failed");
                            entry.channel.stop();
                            std.Thread.sleep(entry.supervised.currentBackoffMs() * std.time.ns_per_ms);
                            entry.channel.start() catch |err| {
                                log.err("Failed to restart {s} gateway: {}", .{ entry.name, err });
                                continue;
                            };
                            entry.supervised.recordSuccess();
                            state.markRunning("channels");
                            health.markComponentOk(entry.name);
                        } else if (entry.supervised.state == .gave_up) {
                            state.markError("channels", "gave up after max restarts");
                            health.markComponentError(entry.name, "gave up after max restarts");
                        }
                    }
                    continue;
                }

                if (entry.listener_type != .polling) continue;

                const polling_state = entry.polling_state orelse continue;
                const now = std.time.timestamp();
                const last = pollingLastActivity(polling_state);
                const stale = (now - last) > STALE_THRESHOLD_SECS;

                const probe_ok = entry.channel.healthCheck();

                if (!stale and probe_ok) {
                    health.markComponentOk(entry.name);
                    state.markRunning("channels");
                    if (entry.supervised.state != .running) entry.supervised.recordSuccess();
                } else {
                    const reason: []const u8 = if (stale) "polling thread stale" else "health check failed";
                    log.warn("{s} issue: {s}", .{ entry.name, reason });
                    health.markComponentError(entry.name, reason);

                    entry.supervised.recordFailure();

                    if (entry.supervised.shouldRestart()) {
                        log.info("Restarting {s} (attempt {d})", .{ entry.name, entry.supervised.restart_count });
                        state.markError("channels", reason);

                        // Stop old thread
                        self.stopPollingThread(entry);

                        // Backoff
                        std.Thread.sleep(entry.supervised.currentBackoffMs() * std.time.ns_per_ms);

                        // Respawn
                        if (self.runtime) |rt| {
                            self.spawnPollingThread(entry, rt) catch |err| {
                                log.err("Failed to respawn {s} thread: {}", .{ entry.name, err });
                                continue;
                            };
                            entry.supervised.recordSuccess();
                            state.markRunning("channels");
                            health.markComponentOk(entry.name);
                        }
                    } else if (entry.supervised.state == .gave_up) {
                        state.markError("channels", "gave up after max restarts");
                        health.markComponentError(entry.name, "gave up after max restarts");
                    }
                }
            }

            // If no polling channels, just mark healthy
            const has_polling = for (self.entries.items) |entry| {
                if (entry.listener_type == .polling) break true;
            } else false;
            if (!has_polling) {
                health.markComponentOk("channels");
            }
        }
    }

    /// Get all configured channel entries.
    pub fn channelEntries(self: *const ChannelManager) []const Entry {
        return self.entries.items;
    }

    /// Return the number of configured channels.
    pub fn count(self: *const ChannelManager) usize {
        return self.entries.items.len;
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Config hot-reload helpers (free functions)
// ════════════════════════════════════════════════════════════════════════════

/// Get the modification time of a config file.
fn getConfigFileMtime(path: []const u8) !i128 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.mtime;
}

/// Find an MQTT endpoint by endpoint_id (preferred) or listen_topic (fallback).
fn findMqttEndpointById(endpoints: []const config_types.MqttEndpointConfig, needle: config_types.MqttEndpointConfig) ?config_types.MqttEndpointConfig {
    // Primary: match by endpoint_id when both have one
    if (needle.endpoint_id.len > 0) {
        for (endpoints) |ep| {
            if (ep.endpoint_id.len > 0 and std.mem.eql(u8, ep.endpoint_id, needle.endpoint_id)) return ep;
        }
    }
    // Fallback: match by listen_topic (for configs without endpoint_id)
    if (needle.endpoint_id.len == 0) {
        for (endpoints) |ep| {
            if (ep.endpoint_id.len == 0 and std.mem.eql(u8, ep.listen_topic, needle.listen_topic)) return ep;
        }
    }
    return null;
}

/// Find a Redis Stream endpoint by endpoint_id (preferred) or listen_topic (fallback).
fn findRsEndpointById(endpoints: []const config_types.RedisStreamEndpointConfig, needle: config_types.RedisStreamEndpointConfig) ?config_types.RedisStreamEndpointConfig {
    if (needle.endpoint_id.len > 0) {
        for (endpoints) |ep| {
            if (ep.endpoint_id.len > 0 and std.mem.eql(u8, ep.endpoint_id, needle.endpoint_id)) return ep;
        }
    }
    if (needle.endpoint_id.len == 0) {
        for (endpoints) |ep| {
            if (ep.endpoint_id.len == 0 and std.mem.eql(u8, ep.listen_topic, needle.listen_topic)) return ep;
        }
    }
    return null;
}

/// Check if a ChannelModelOverride has any general (provider/model/temperature/tokens)
/// overrides set.  Used by hot-reload guards so that endpoints which only
/// override sub-agent / tools-reviewer fields still inherit global general-model
/// changes.
fn hasGeneralModelOverride(mo: config_types.ChannelModelOverride) bool {
    return mo.provider != null or mo.model != null or mo.max_context_tokens != 0 or mo.temperature != null;
}

/// Check if a ChannelModelOverride has *any* explicit overrides set (general
/// + sub-agent + tools-reviewer).  Useful for serialisation / equality checks.
fn hasModelOverride(mo: config_types.ChannelModelOverride) bool {
    return hasGeneralModelOverride(mo) or
        mo.sub_agent_provider != null or mo.sub_agent_model != null or
        mo.tools_reviewer_provider != null or mo.tools_reviewer_model != null;
}

/// Build the session key prefix for an endpoint: uses endpoint_id when set,
/// falls back to legacy "channel_type:account_id:topic" format.
fn endpointSessionPrefix(buf: []u8, channel_type: []const u8, account_id: []const u8, endpoint_id: []const u8, listen_topic: []const u8) []const u8 {
    if (endpoint_id.len > 0) {
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ channel_type, endpoint_id }) catch "";
    }
    // Legacy fallback must match the session key format used in
    // handleInboundLine / handleStreamEntry: "channel_type:account_id:topic"
    return std.fmt.bufPrint(buf, "{s}:{s}:{s}", .{ channel_type, account_id, listen_topic }) catch "";
}

/// Return a human-readable label for an endpoint (prefer endpoint_id, fall back to topic).
fn endpointLabel(endpoint_id: []const u8, listen_topic: []const u8) []const u8 {
    return if (endpoint_id.len > 0) endpoint_id else listen_topic;
}

/// Check if an MQTT endpoint had a structural change (anything that requires session reset).
/// Structural = host, port, TLS, keys, topic.  Model override is NOT structural.
fn mqttEndpointStructuralChanged(old: config_types.MqttEndpointConfig, new: config_types.MqttEndpointConfig) bool {
    if (!std.mem.eql(u8, old.host, new.host)) return true;
    if (old.port != new.port) return true;
    if (old.tls != new.tls) return true;
    if (!std.mem.eql(u8, old.listen_topic, new.listen_topic)) return true;
    if (!optionalStrEql(old.reply_topic, new.reply_topic)) return true;
    // Key changes → reset session (different peer or local identity)
    if (!std.mem.eql(u8, old.peer_pubkey, new.peer_pubkey)) return true;
    if (!std.mem.eql(u8, old.local_privkey, new.local_privkey)) return true;
    if (!std.mem.eql(u8, old.local_pubkey, new.local_pubkey)) return true;
    return false;
}

/// Check if a Redis Stream endpoint had a structural change.
fn rsEndpointStructuralChanged(old: config_types.RedisStreamEndpointConfig, new: config_types.RedisStreamEndpointConfig) bool {
    if (!std.mem.eql(u8, old.host, new.host)) return true;
    if (old.port != new.port) return true;
    if (old.tls != new.tls) return true;
    if (old.db != new.db) return true;
    if (!std.mem.eql(u8, old.listen_topic, new.listen_topic)) return true;
    if (!optionalStrEql(old.reply_topic, new.reply_topic)) return true;
    if (!std.mem.eql(u8, old.peer_pubkey, new.peer_pubkey)) return true;
    if (!std.mem.eql(u8, old.local_privkey, new.local_privkey)) return true;
    if (!std.mem.eql(u8, old.local_pubkey, new.local_pubkey)) return true;
    return false;
}

/// Build a ChannelModelOverride from the global config for hot-updating sessions
/// that don't have per-channel overrides.
fn buildGlobalModelOverride(cfg: *const Config) config_types.ChannelModelOverride {
    // Prefer max_context_tokens (auto-resolve cap) when configured.  When it is
    // unset (0) but the user explicitly pinned token_limit in config, use that
    // value so hot-reload propagates the explicit cap to existing sessions.
    const max_ctx = if (cfg.agent.max_context_tokens > 0)
        cfg.agent.max_context_tokens
    else if (cfg.agent.token_limit_explicit)
        cfg.agent.token_limit
    else
        0;
    return .{
        .provider = if (cfg.default_provider.len > 0) cfg.default_provider else null,
        .model = if (cfg.default_model) |m| (if (m.len > 0) m else null) else null,
        .max_context_tokens = max_ctx,
        .temperature = cfg.default_temperature,
        .sub_agent_provider = if (cfg.sub_agent_provider) |p| (if (p.len > 0) p else null) else null,
        .sub_agent_model = if (cfg.sub_agent_model) |m| (if (m.len > 0) m else null) else null,
        .sub_agent_temperature = cfg.sub_agent_temperature,
        .sub_agent_max_context_tokens = cfg.sub_agent_max_context_tokens,
        .sub_agent_base_url = if (cfg.sub_agent_base_url) |u| (if (u.len > 0) u else null) else null,
        .tools_reviewer_provider = if (cfg.tools_reviewer_provider) |p| (if (p.len > 0) p else null) else null,
        .tools_reviewer_model = if (cfg.tools_reviewer_model) |m| (if (m.len > 0) m else null) else null,
        .tools_reviewer_temperature = cfg.tools_reviewer_temperature,
        .tools_reviewer_max_context_tokens = cfg.tools_reviewer_max_context_tokens,
        .tools_reviewer_base_url = if (cfg.tools_reviewer_base_url) |u| (if (u.len > 0) u else null) else null,
    };
}

/// Compare two ChannelModelOverride structs for equality.
fn modelOverrideEqual(a: config_types.ChannelModelOverride, b: config_types.ChannelModelOverride) bool {
    if (a.max_context_tokens != b.max_context_tokens) return false;
    if (!optionalStrEql(a.provider, b.provider)) return false;
    if (!optionalStrEql(a.model, b.model)) return false;
    if (!optionalF64Eql(a.temperature, b.temperature)) return false;
    if (!optionalStrEql(a.sub_agent_provider, b.sub_agent_provider)) return false;
    if (!optionalStrEql(a.sub_agent_model, b.sub_agent_model)) return false;
    if (!optionalF64Eql(a.sub_agent_temperature, b.sub_agent_temperature)) return false;
    if (a.sub_agent_max_context_tokens != b.sub_agent_max_context_tokens) return false;
    if (!optionalStrEql(a.sub_agent_base_url, b.sub_agent_base_url)) return false;
    if (!optionalStrEql(a.tools_reviewer_provider, b.tools_reviewer_provider)) return false;
    if (!optionalStrEql(a.tools_reviewer_model, b.tools_reviewer_model)) return false;
    if (!optionalF64Eql(a.tools_reviewer_temperature, b.tools_reviewer_temperature)) return false;
    if (a.tools_reviewer_max_context_tokens != b.tools_reviewer_max_context_tokens) return false;
    if (!optionalStrEql(a.tools_reviewer_base_url, b.tools_reviewer_base_url)) return false;
    if (a.sub_agent_max_iterations != b.sub_agent_max_iterations) return false;
    if (a.sub_agent_review_after != b.sub_agent_review_after) return false;
    return true;
}

fn optionalF64Eql(a: ?f64, b: ?f64) bool {
    if (a == null and b == null) return true;
    if (a != null and b != null) return @abs(a.? - b.?) <= 0.001;
    return false;
}

/// Check if a channel config (MQTT or Redis Stream) has model_override.model
/// set on ALL of its endpoints.  Used to validate that every endpoint can
/// resolve an LLM model when no global default_model is configured.
fn channelConfigHasAllEndpointModels(cfg: anytype) bool {
    if (@hasField(@TypeOf(cfg), "endpoints")) {
        for (cfg.endpoints) |ep| {
            if (ep.model_override.model == null) return false;
        }
        return cfg.endpoints.len > 0;
    }
    return false;
}

/// Merge a global ChannelModelOverride with an endpoint's own override.
/// Endpoint-level fields take priority; global fields fill in the gaps.
/// This prevents hot-reload of global config from clobbering per-endpoint
/// sub_agent/tools_reviewer overrides.
fn mergeGlobalWithEndpoint(global: config_types.ChannelModelOverride, endpoint: config_types.ChannelModelOverride) config_types.ChannelModelOverride {
    return .{
        .provider = endpoint.provider orelse global.provider,
        .model = endpoint.model orelse global.model,
        .max_context_tokens = if (endpoint.max_context_tokens > 0) endpoint.max_context_tokens else global.max_context_tokens,
        .temperature = endpoint.temperature orelse global.temperature,
        .sub_agent_provider = endpoint.sub_agent_provider orelse global.sub_agent_provider,
        .sub_agent_model = endpoint.sub_agent_model orelse global.sub_agent_model,
        .sub_agent_temperature = endpoint.sub_agent_temperature orelse global.sub_agent_temperature,
        .sub_agent_max_context_tokens = if (endpoint.sub_agent_max_context_tokens > 0) endpoint.sub_agent_max_context_tokens else global.sub_agent_max_context_tokens,
        .sub_agent_base_url = endpoint.sub_agent_base_url orelse global.sub_agent_base_url,
        .tools_reviewer_provider = endpoint.tools_reviewer_provider orelse global.tools_reviewer_provider,
        .tools_reviewer_model = endpoint.tools_reviewer_model orelse global.tools_reviewer_model,
        .tools_reviewer_temperature = endpoint.tools_reviewer_temperature orelse global.tools_reviewer_temperature,
        .tools_reviewer_max_context_tokens = if (endpoint.tools_reviewer_max_context_tokens > 0) endpoint.tools_reviewer_max_context_tokens else global.tools_reviewer_max_context_tokens,
        .tools_reviewer_base_url = endpoint.tools_reviewer_base_url orelse global.tools_reviewer_base_url,
        .sub_agent_max_iterations = if (endpoint.sub_agent_max_iterations > 0) endpoint.sub_agent_max_iterations else global.sub_agent_max_iterations,
        .sub_agent_review_after = if (endpoint.sub_agent_review_after > 0) endpoint.sub_agent_review_after else global.sub_agent_review_after,
    };
}

fn optionalStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Check if global model config changed between old and new configs.
fn globalModelConfigChanged(old: *const Config, new: *const Config) bool {
    if (!optionalStrEql(old.default_model, new.default_model)) return true;
    if (!std.mem.eql(u8, old.default_provider, new.default_provider)) return true;
    if (@abs(old.default_temperature - new.default_temperature) > 0.001) return true;
    if (old.agent.max_context_tokens != new.agent.max_context_tokens) return true;
    if (old.agent.token_limit != new.agent.token_limit) return true;
    if (old.agent.token_limit_explicit != new.agent.token_limit_explicit) return true;
    if (!optionalStrEql(old.sub_agent_provider, new.sub_agent_provider)) return true;
    if (!optionalStrEql(old.sub_agent_model, new.sub_agent_model)) return true;
    if (!optionalStrEql(old.tools_reviewer_provider, new.tools_reviewer_provider)) return true;
    if (!optionalStrEql(old.tools_reviewer_model, new.tools_reviewer_model)) return true;
    if (!optionalF64Eql(old.sub_agent_temperature, new.sub_agent_temperature)) return true;
    if (old.sub_agent_max_context_tokens != new.sub_agent_max_context_tokens) return true;
    if (!optionalStrEql(old.sub_agent_base_url, new.sub_agent_base_url)) return true;
    if (!optionalF64Eql(old.tools_reviewer_temperature, new.tools_reviewer_temperature)) return true;
    if (old.tools_reviewer_max_context_tokens != new.tools_reviewer_max_context_tokens) return true;
    if (!optionalStrEql(old.tools_reviewer_base_url, new.tools_reviewer_base_url)) return true;
    return false;
}

/// Check if provider credentials or the default provider changed between
/// old and new configs.  When true, the RuntimeProviderBundle must be
/// rebuilt so that existing sessions pick up the new API key.
///
/// Note: provider entries are compared positionally (same order as the
/// JSON array in config.json).  Reordering entries without changing
/// their content is treated as a change, which is harmless — it simply
/// triggers a provider rebuild.
fn providerConfigChanged(old: *const Config, new: *const Config) bool {
    // Default provider name changed → need a new provider.
    if (!std.mem.eql(u8, old.default_provider, new.default_provider)) return true;

    // Compare provider entries: count, names, api_keys, base_urls.
    if (old.providers.len != new.providers.len) return true;
    for (old.providers, new.providers) |o, n| {
        if (!std.mem.eql(u8, o.name, n.name)) return true;
        if (!optionalStrEql(o.api_key, n.api_key)) return true;
        if (!optionalStrEql(o.base_url, n.base_url)) return true;
        if (!optionalStrEql(o.user_agent, n.user_agent)) return true;
        if (o.native_tools != n.native_tools) return true;
    }

    // Reliability API keys (key rotation) changed.
    if (old.reliability.api_keys.len != new.reliability.api_keys.len) return true;
    for (old.reliability.api_keys, new.reliability.api_keys) |o, n| {
        if (!std.mem.eql(u8, o, n)) return true;
    }

    // Fallback provider list changed.
    if (old.reliability.fallback_providers.len != new.reliability.fallback_providers.len) return true;
    for (old.reliability.fallback_providers, new.reliability.fallback_providers) |o, n| {
        if (!std.mem.eql(u8, o, n)) return true;
    }

    // Retry settings changed.
    if (old.reliability.provider_retries != new.reliability.provider_retries) return true;
    if (old.reliability.provider_backoff_ms != new.reliability.provider_backoff_ms) return true;

    return false;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "hasGeneralModelOverride only checks general fields" {
    try std.testing.expect(!hasGeneralModelOverride(.{}));
    try std.testing.expect(hasGeneralModelOverride(.{ .provider = "p" }));
    try std.testing.expect(hasGeneralModelOverride(.{ .model = "m" }));
    try std.testing.expect(hasGeneralModelOverride(.{ .max_context_tokens = 1024 }));
    try std.testing.expect(hasGeneralModelOverride(.{ .temperature = 0.5 }));
    // sub-agent / tools-reviewer only → should NOT count as general override
    try std.testing.expect(!hasGeneralModelOverride(.{ .sub_agent_model = "m" }));
    try std.testing.expect(!hasGeneralModelOverride(.{ .sub_agent_provider = "p" }));
    try std.testing.expect(!hasGeneralModelOverride(.{ .tools_reviewer_model = "m" }));
    try std.testing.expect(!hasGeneralModelOverride(.{ .tools_reviewer_provider = "p" }));
}

test "hasModelOverride detects all fields including sub_agent" {
    try std.testing.expect(!hasModelOverride(.{}));
    try std.testing.expect(hasModelOverride(.{ .sub_agent_model = "m" }));
    try std.testing.expect(hasModelOverride(.{ .sub_agent_provider = "p" }));
    try std.testing.expect(hasModelOverride(.{ .tools_reviewer_model = "m" }));
    try std.testing.expect(hasModelOverride(.{ .tools_reviewer_provider = "p" }));
    // existing fields still work
    try std.testing.expect(hasModelOverride(.{ .provider = "p" }));
    try std.testing.expect(hasModelOverride(.{ .model = "m" }));
    try std.testing.expect(hasModelOverride(.{ .max_context_tokens = 1024 }));
    try std.testing.expect(hasModelOverride(.{ .temperature = 0.5 }));
}

test "modelOverrideEqual compares sub_agent and tools_reviewer fields" {
    const a = config_types.ChannelModelOverride{
        .sub_agent_provider = "prov-a",
        .sub_agent_model = "model-a",
        .tools_reviewer_provider = "prov-b",
        .tools_reviewer_model = "model-b",
    };
    // Same values
    try std.testing.expect(modelOverrideEqual(a, .{
        .sub_agent_provider = "prov-a",
        .sub_agent_model = "model-a",
        .tools_reviewer_provider = "prov-b",
        .tools_reviewer_model = "model-b",
    }));
    // Different sub_agent_model
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_provider = "prov-a",
        .sub_agent_model = "model-x",
        .tools_reviewer_provider = "prov-b",
        .tools_reviewer_model = "model-b",
    }));
    // Different tools_reviewer_provider
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_provider = "prov-a",
        .sub_agent_model = "model-a",
        .tools_reviewer_provider = "prov-x",
        .tools_reviewer_model = "model-b",
    }));
    // null vs set
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_provider = null,
        .sub_agent_model = "model-a",
    }));
    // Both null
    try std.testing.expect(modelOverrideEqual(.{}, .{}));
}

test "globalModelConfigChanged detects sub_agent and tools_reviewer changes" {
    const base = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .sub_agent_model = "sa-model",
        .tools_reviewer_model = "tr-model",
    };
    // No change
    try std.testing.expect(!globalModelConfigChanged(&base, &base));

    // sub_agent_model changed
    var changed_sa = base;
    changed_sa.sub_agent_model = "sa-model-new";
    try std.testing.expect(globalModelConfigChanged(&base, &changed_sa));

    // tools_reviewer_model changed
    var changed_tr = base;
    changed_tr.tools_reviewer_model = "tr-model-new";
    try std.testing.expect(globalModelConfigChanged(&base, &changed_tr));

    // sub_agent_provider changed
    var changed_sap = base;
    changed_sap.sub_agent_provider = "new-prov";
    try std.testing.expect(globalModelConfigChanged(&base, &changed_sap));

    // tools_reviewer_provider changed
    var changed_trp = base;
    changed_trp.tools_reviewer_provider = "new-prov";
    try std.testing.expect(globalModelConfigChanged(&base, &changed_trp));
}

test "globalModelConfigChanged detects token_limit_explicit change" {
    const base = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .agent = .{ .token_limit = 8192, .token_limit_explicit = false },
    };
    // No change
    try std.testing.expect(!globalModelConfigChanged(&base, &base));

    // token_limit_explicit flipped to true
    var changed = base;
    changed.agent.token_limit_explicit = true;
    try std.testing.expect(globalModelConfigChanged(&base, &changed));

    // token_limit_explicit flipped back to false
    var base_explicit = base;
    base_explicit.agent.token_limit_explicit = true;
    var changed_back = base_explicit;
    changed_back.agent.token_limit_explicit = false;
    try std.testing.expect(globalModelConfigChanged(&base_explicit, &changed_back));
}

test "buildGlobalModelOverride includes sub_agent and tools_reviewer fields" {
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .sub_agent_provider = "sa-prov",
        .sub_agent_model = "sa-model",
        .tools_reviewer_provider = "tr-prov",
        .tools_reviewer_model = "tr-model",
    };
    const mo = buildGlobalModelOverride(&cfg);
    try std.testing.expectEqualStrings("sa-prov", mo.sub_agent_provider.?);
    try std.testing.expectEqualStrings("sa-model", mo.sub_agent_model.?);
    try std.testing.expectEqualStrings("tr-prov", mo.tools_reviewer_provider.?);
    try std.testing.expectEqualStrings("tr-model", mo.tools_reviewer_model.?);
}

test "buildGlobalModelOverride null when not configured" {
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    const mo = buildGlobalModelOverride(&cfg);
    try std.testing.expect(mo.sub_agent_provider == null);
    try std.testing.expect(mo.sub_agent_model == null);
    try std.testing.expect(mo.tools_reviewer_provider == null);
    try std.testing.expect(mo.tools_reviewer_model == null);
}

// ---------------------------------------------------------------------------
// Unified model config fields tests
// ---------------------------------------------------------------------------

test "buildGlobalModelOverride includes temperature, max_context_tokens, base_url for sub_agent and tools_reviewer" {
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .sub_agent_provider = "sa-prov",
        .sub_agent_model = "sa-model",
        .sub_agent_temperature = 0.3,
        .sub_agent_max_context_tokens = 4096,
        .sub_agent_base_url = "https://sa.example.com",
        .tools_reviewer_provider = "tr-prov",
        .tools_reviewer_model = "tr-model",
        .tools_reviewer_temperature = 0.1,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://tr.example.com",
    };
    const mo = buildGlobalModelOverride(&cfg);
    try std.testing.expectEqualStrings("sa-prov", mo.sub_agent_provider.?);
    try std.testing.expectEqualStrings("sa-model", mo.sub_agent_model.?);
    try std.testing.expect(@abs(mo.sub_agent_temperature.? - 0.3) < 0.001);
    try std.testing.expectEqual(@as(u64, 4096), mo.sub_agent_max_context_tokens);
    try std.testing.expectEqualStrings("https://sa.example.com", mo.sub_agent_base_url.?);
    try std.testing.expectEqualStrings("tr-prov", mo.tools_reviewer_provider.?);
    try std.testing.expectEqualStrings("tr-model", mo.tools_reviewer_model.?);
    try std.testing.expect(@abs(mo.tools_reviewer_temperature.? - 0.1) < 0.001);
    try std.testing.expectEqual(@as(u64, 2048), mo.tools_reviewer_max_context_tokens);
    try std.testing.expectEqualStrings("https://tr.example.com", mo.tools_reviewer_base_url.?);
}

test "buildGlobalModelOverride normalizes empty base_url to null" {
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .sub_agent_base_url = "",
        .tools_reviewer_base_url = "",
    };
    const mo = buildGlobalModelOverride(&cfg);
    try std.testing.expect(mo.sub_agent_base_url == null);
    try std.testing.expect(mo.tools_reviewer_base_url == null);
}

test "buildGlobalModelOverride propagates token_limit when explicit and max_context_tokens unset" {
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .agent = .{ .token_limit = 64000, .token_limit_explicit = true },
    };
    const mo = buildGlobalModelOverride(&cfg);
    // token_limit_explicit=true and max_context_tokens=0 → token_limit used as cap
    try std.testing.expectEqual(@as(u64, 64000), mo.max_context_tokens);
}

test "buildGlobalModelOverride prefers max_context_tokens over token_limit when both set" {
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .agent = .{ .max_context_tokens = 32000, .token_limit = 64000, .token_limit_explicit = true },
    };
    const mo = buildGlobalModelOverride(&cfg);
    // max_context_tokens wins over token_limit
    try std.testing.expectEqual(@as(u64, 32000), mo.max_context_tokens);
}

test "buildGlobalModelOverride max_context_tokens zero when neither explicitly set" {
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
    };
    const mo = buildGlobalModelOverride(&cfg);
    try std.testing.expectEqual(@as(u64, 0), mo.max_context_tokens);
}

test "mergeGlobalWithEndpoint propagates global sub_agent to endpoint with general override" {
    // Endpoint has explicit model (general override) but no sub_agent override.
    // When global sub_agent_model changes, the merged result should carry the
    // global sub_agent into the endpoint.
    const global = config_types.ChannelModelOverride{
        .model = "claude-3-5",
        .sub_agent_model = "gpt-4o-mini",
        .sub_agent_provider = "openai",
    };
    const endpoint = config_types.ChannelModelOverride{
        .model = "gpt-4", // endpoint has its own general model
    };
    const merged = mergeGlobalWithEndpoint(global, endpoint);
    // Endpoint model wins over global
    try std.testing.expectEqualStrings("gpt-4", merged.model.?);
    // Global sub_agent propagates because endpoint has no sub_agent override
    try std.testing.expectEqualStrings("gpt-4o-mini", merged.sub_agent_model.?);
    try std.testing.expectEqualStrings("openai", merged.sub_agent_provider.?);
}

test "mergeGlobalWithEndpoint endpoint sub_agent wins over global" {
    const global = config_types.ChannelModelOverride{
        .sub_agent_model = "gpt-4o-mini",
    };
    const endpoint = config_types.ChannelModelOverride{
        .model = "gpt-4",
        .sub_agent_model = "claude-3-haiku", // endpoint has its own sub_agent
    };
    const merged = mergeGlobalWithEndpoint(global, endpoint);
    // Endpoint sub_agent wins
    try std.testing.expectEqualStrings("claude-3-haiku", merged.sub_agent_model.?);
}

test "modelOverrideEqual compares temperature, max_context_tokens, base_url fields" {
    const a = config_types.ChannelModelOverride{
        .sub_agent_temperature = 0.3,
        .sub_agent_max_context_tokens = 4096,
        .sub_agent_base_url = "https://sa.example.com",
        .tools_reviewer_temperature = 0.1,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://tr.example.com",
    };
    // Same values
    try std.testing.expect(modelOverrideEqual(a, .{
        .sub_agent_temperature = 0.3,
        .sub_agent_max_context_tokens = 4096,
        .sub_agent_base_url = "https://sa.example.com",
        .tools_reviewer_temperature = 0.1,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://tr.example.com",
    }));
    // Different sub_agent_temperature
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_temperature = 0.5,
        .sub_agent_max_context_tokens = 4096,
        .sub_agent_base_url = "https://sa.example.com",
        .tools_reviewer_temperature = 0.1,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://tr.example.com",
    }));
    // Different sub_agent_max_context_tokens
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_temperature = 0.3,
        .sub_agent_max_context_tokens = 8192,
        .sub_agent_base_url = "https://sa.example.com",
        .tools_reviewer_temperature = 0.1,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://tr.example.com",
    }));
    // Different sub_agent_base_url
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_temperature = 0.3,
        .sub_agent_max_context_tokens = 4096,
        .sub_agent_base_url = "https://other.example.com",
        .tools_reviewer_temperature = 0.1,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://tr.example.com",
    }));
    // Different tools_reviewer_temperature
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_temperature = 0.3,
        .sub_agent_max_context_tokens = 4096,
        .sub_agent_base_url = "https://sa.example.com",
        .tools_reviewer_temperature = 0.9,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://tr.example.com",
    }));
    // null vs set temperature
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_temperature = null,
        .sub_agent_max_context_tokens = 4096,
        .sub_agent_base_url = "https://sa.example.com",
        .tools_reviewer_temperature = 0.1,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://tr.example.com",
    }));
}

test "modelOverrideEqual compares sub_agent_max_iterations and review_after" {
    const a = config_types.ChannelModelOverride{
        .sub_agent_max_iterations = 5,
        .sub_agent_review_after = 3,
    };
    try std.testing.expect(modelOverrideEqual(a, .{
        .sub_agent_max_iterations = 5,
        .sub_agent_review_after = 3,
    }));
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_max_iterations = 10,
        .sub_agent_review_after = 3,
    }));
    try std.testing.expect(!modelOverrideEqual(a, .{
        .sub_agent_max_iterations = 5,
        .sub_agent_review_after = 7,
    }));
}

test "mergeGlobalWithEndpoint merges temperature, max_context_tokens, base_url" {
    const global = config_types.ChannelModelOverride{
        .provider = "global-prov",
        .model = "global-model",
        .sub_agent_temperature = 0.3,
        .sub_agent_max_context_tokens = 4096,
        .sub_agent_base_url = "https://global-sa.example.com",
        .tools_reviewer_temperature = 0.1,
        .tools_reviewer_max_context_tokens = 2048,
        .tools_reviewer_base_url = "https://global-tr.example.com",
        .sub_agent_max_iterations = 5,
        .sub_agent_review_after = 3,
    };

    // Endpoint with no overrides → uses global values
    {
        const merged = mergeGlobalWithEndpoint(global, .{});
        try std.testing.expect(@abs(merged.sub_agent_temperature.? - 0.3) < 0.001);
        try std.testing.expectEqual(@as(u64, 4096), merged.sub_agent_max_context_tokens);
        try std.testing.expectEqualStrings("https://global-sa.example.com", merged.sub_agent_base_url.?);
        try std.testing.expect(@abs(merged.tools_reviewer_temperature.? - 0.1) < 0.001);
        try std.testing.expectEqual(@as(u64, 2048), merged.tools_reviewer_max_context_tokens);
        try std.testing.expectEqualStrings("https://global-tr.example.com", merged.tools_reviewer_base_url.?);
        try std.testing.expectEqual(@as(u32, 5), merged.sub_agent_max_iterations);
        try std.testing.expectEqual(@as(u32, 3), merged.sub_agent_review_after);
    }

    // Endpoint overrides specific fields → endpoint wins
    {
        const endpoint = config_types.ChannelModelOverride{
            .sub_agent_temperature = 0.8,
            .sub_agent_max_context_tokens = 16384,
            .sub_agent_base_url = "https://ep-sa.example.com",
            .tools_reviewer_temperature = 0.5,
            .sub_agent_max_iterations = 10,
        };
        const merged = mergeGlobalWithEndpoint(global, endpoint);
        try std.testing.expect(@abs(merged.sub_agent_temperature.? - 0.8) < 0.001);
        try std.testing.expectEqual(@as(u64, 16384), merged.sub_agent_max_context_tokens);
        try std.testing.expectEqualStrings("https://ep-sa.example.com", merged.sub_agent_base_url.?);
        try std.testing.expect(@abs(merged.tools_reviewer_temperature.? - 0.5) < 0.001);
        // tools_reviewer_max_context_tokens and base_url fall back to global
        try std.testing.expectEqual(@as(u64, 2048), merged.tools_reviewer_max_context_tokens);
        try std.testing.expectEqualStrings("https://global-tr.example.com", merged.tools_reviewer_base_url.?);
        try std.testing.expectEqual(@as(u32, 10), merged.sub_agent_max_iterations);
        try std.testing.expectEqual(@as(u32, 3), merged.sub_agent_review_after); // from global
    }
}

test "mergeGlobalWithEndpoint does not cascade general temperature to sub_agent" {
    // Global has general temperature but NO sub_agent_temperature
    const global = config_types.ChannelModelOverride{
        .temperature = 0.7,
        .model = "global-model",
    };
    // Endpoint also has no sub_agent_temperature
    const endpoint = config_types.ChannelModelOverride{};
    const merged = mergeGlobalWithEndpoint(global, endpoint);
    // sub_agent_temperature should remain null (not cascaded from general 0.7)
    try std.testing.expect(merged.sub_agent_temperature == null);
    try std.testing.expect(merged.tools_reviewer_temperature == null);
    // But general temperature IS preserved
    try std.testing.expect(@abs(merged.temperature.? - 0.7) < 0.001);
}

test "globalModelConfigChanged detects temperature and base_url changes" {
    const base = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .sub_agent_temperature = 0.3,
        .tools_reviewer_temperature = 0.1,
        .sub_agent_base_url = "https://sa.example.com",
        .tools_reviewer_base_url = "https://tr.example.com",
    };
    // No change
    try std.testing.expect(!globalModelConfigChanged(&base, &base));

    // sub_agent_temperature changed
    var changed_sat = base;
    changed_sat.sub_agent_temperature = 0.5;
    try std.testing.expect(globalModelConfigChanged(&base, &changed_sat));

    // tools_reviewer_temperature changed
    var changed_trt = base;
    changed_trt.tools_reviewer_temperature = 0.9;
    try std.testing.expect(globalModelConfigChanged(&base, &changed_trt));

    // sub_agent_base_url changed
    var changed_sabu = base;
    changed_sabu.sub_agent_base_url = "https://new.example.com";
    try std.testing.expect(globalModelConfigChanged(&base, &changed_sabu));

    // tools_reviewer_base_url changed
    var changed_trbu = base;
    changed_trbu.tools_reviewer_base_url = "https://new.example.com";
    try std.testing.expect(globalModelConfigChanged(&base, &changed_trbu));
}

test "PollingState has telegram signal and matrix variants" {
    try std.testing.expect(@intFromEnum(@as(std.meta.Tag(PollingState), .telegram)) !=
        @intFromEnum(@as(std.meta.Tag(PollingState), .signal)));
    try std.testing.expect(@intFromEnum(@as(std.meta.Tag(PollingState), .signal)) !=
        @intFromEnum(@as(std.meta.Tag(PollingState), .matrix)));
}

test "ListenerType enum values distinct" {
    try std.testing.expect(@intFromEnum(ListenerType.polling) != @intFromEnum(ListenerType.gateway_loop));
    try std.testing.expect(@intFromEnum(ListenerType.gateway_loop) != @intFromEnum(ListenerType.webhook_only));
    try std.testing.expect(@intFromEnum(ListenerType.webhook_only) != @intFromEnum(ListenerType.not_implemented));
}

test "isPollingSourceDuplicate detects duplicate signal source" {
    const allocator = std.testing.allocator;

    var sig_a = @import("channels/signal.zig").SignalChannel.init(
        allocator,
        "http://127.0.0.1:8080",
        "+15550001111",
        &.{},
        &.{},
        false,
        false,
    );
    sig_a.account_id = "main";
    var sig_b = @import("channels/signal.zig").SignalChannel.init(
        allocator,
        "http://127.0.0.1:8080",
        "+15550001111",
        &.{},
        &.{},
        false,
        false,
    );
    sig_b.account_id = "backup";

    var sup_a = dispatch.spawnSupervisedChannel(sig_a.channel(), 5);
    sup_a.recordSuccess();
    const sup_b = dispatch.spawnSupervisedChannel(sig_b.channel(), 5);

    var entries = [_]Entry{
        .{
            .name = "signal",
            .account_id = "main",
            .channel = sig_a.channel(),
            .listener_type = .polling,
            .supervised = sup_a,
            .thread = null,
        },
        .{
            .name = "signal",
            .account_id = "backup",
            .channel = sig_b.channel(),
            .listener_type = .polling,
            .supervised = sup_b,
            .thread = null,
        },
    };

    const desc = channel_adapters.findPollingDescriptor("signal").?;
    try std.testing.expect(ChannelManager.isPollingSourceDuplicate(allocator, &entries, 1, desc));
}

test "isPollingSourceDuplicate ignores distinct signal source" {
    const allocator = std.testing.allocator;

    var sig_a = @import("channels/signal.zig").SignalChannel.init(
        allocator,
        "http://127.0.0.1:8080",
        "+15550001111",
        &.{},
        &.{},
        false,
        false,
    );
    var sig_b = @import("channels/signal.zig").SignalChannel.init(
        allocator,
        "http://127.0.0.1:8080",
        "+15550002222",
        &.{},
        &.{},
        false,
        false,
    );

    var sup_a = dispatch.spawnSupervisedChannel(sig_a.channel(), 5);
    sup_a.recordSuccess();
    const sup_b = dispatch.spawnSupervisedChannel(sig_b.channel(), 5);

    var entries = [_]Entry{
        .{
            .name = "signal",
            .account_id = "main",
            .channel = sig_a.channel(),
            .listener_type = .polling,
            .supervised = sup_a,
            .thread = null,
        },
        .{
            .name = "signal",
            .account_id = "backup",
            .channel = sig_b.channel(),
            .listener_type = .polling,
            .supervised = sup_b,
            .thread = null,
        },
    };

    const desc = channel_adapters.findPollingDescriptor("signal").?;
    try std.testing.expect(!ChannelManager.isPollingSourceDuplicate(allocator, &entries, 1, desc));
}

test "isPollingSourceDuplicate detects duplicate telegram source" {
    const allocator = std.testing.allocator;

    var tg_a = @import("channels/telegram.zig").TelegramChannel.init(
        allocator,
        "same-token",
        &.{},
        &.{},
        "allowlist",
    );
    tg_a.account_id = "main";
    var tg_b = @import("channels/telegram.zig").TelegramChannel.init(
        allocator,
        "same-token",
        &.{},
        &.{},
        "allowlist",
    );
    tg_b.account_id = "backup";

    var sup_a = dispatch.spawnSupervisedChannel(tg_a.channel(), 5);
    sup_a.recordSuccess();
    const sup_b = dispatch.spawnSupervisedChannel(tg_b.channel(), 5);

    var entries = [_]Entry{
        .{
            .name = "telegram",
            .account_id = "main",
            .channel = tg_a.channel(),
            .listener_type = .polling,
            .supervised = sup_a,
            .thread = null,
        },
        .{
            .name = "telegram",
            .account_id = "backup",
            .channel = tg_b.channel(),
            .listener_type = .polling,
            .supervised = sup_b,
            .thread = null,
        },
    };

    const desc = channel_adapters.findPollingDescriptor("telegram").?;
    try std.testing.expect(ChannelManager.isPollingSourceDuplicate(allocator, &entries, 1, desc));
}

test "isPollingSourceDuplicate ignores distinct telegram source" {
    const allocator = std.testing.allocator;

    var tg_a = @import("channels/telegram.zig").TelegramChannel.init(
        allocator,
        "token-a",
        &.{},
        &.{},
        "allowlist",
    );
    var tg_b = @import("channels/telegram.zig").TelegramChannel.init(
        allocator,
        "token-b",
        &.{},
        &.{},
        "allowlist",
    );

    var sup_a = dispatch.spawnSupervisedChannel(tg_a.channel(), 5);
    sup_a.recordSuccess();
    const sup_b = dispatch.spawnSupervisedChannel(tg_b.channel(), 5);

    var entries = [_]Entry{
        .{
            .name = "telegram",
            .account_id = "main",
            .channel = tg_a.channel(),
            .listener_type = .polling,
            .supervised = sup_a,
            .thread = null,
        },
        .{
            .name = "telegram",
            .account_id = "backup",
            .channel = tg_b.channel(),
            .listener_type = .polling,
            .supervised = sup_b,
            .thread = null,
        },
    };

    const desc = channel_adapters.findPollingDescriptor("telegram").?;
    try std.testing.expect(!ChannelManager.isPollingSourceDuplicate(allocator, &entries, 1, desc));
}

test "ChannelManager init and deinit" {
    const allocator = std.testing.allocator;
    var reg = dispatch.ChannelRegistry.init(allocator);
    defer reg.deinit();
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
    };
    const mgr = try ChannelManager.init(allocator, &config, &reg);
    try std.testing.expectEqual(@as(usize, 0), mgr.count());
    mgr.deinit();
}

test "ChannelManager no channels configured" {
    const allocator = std.testing.allocator;
    var reg = dispatch.ChannelRegistry.init(allocator);
    defer reg.deinit();
    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = allocator,
    };
    const mgr = try ChannelManager.init(allocator, &config, &reg);
    defer mgr.deinit();

    try mgr.collectConfiguredChannels();
    try std.testing.expectEqual(@as(usize, 0), mgr.count());
    try std.testing.expectEqual(@as(usize, 0), mgr.channelEntries().len);
}

fn countEntriesByListenerType(entries: []const Entry, listener_type: ListenerType) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry.listener_type == listener_type) count += 1;
    }
    return count;
}

fn findEntryByNameAccount(entries: []const Entry, name: []const u8, account_id: []const u8) ?*const Entry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.account_id, account_id)) {
            return entry;
        }
    }
    return null;
}

fn expectEntryPresence(entries: []const Entry, name: []const u8, account_id: []const u8, should_exist: bool) !void {
    try std.testing.expectEqual(should_exist, findEntryByNameAccount(entries, name, account_id) != null);
}

test "ChannelManager collectConfiguredChannels wires listener types accounts and bus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const telegram_accounts = [_]@import("config_types.zig").TelegramConfig{
        .{ .account_id = "main", .bot_token = "tg-main-token" },
        .{ .account_id = "backup", .bot_token = "tg-backup-token" },
    };
    const signal_accounts = [_]@import("config_types.zig").SignalConfig{
        .{
            .account_id = "sig-main",
            .http_url = "http://localhost:8080",
            .account = "+15550001111",
        },
    };
    const discord_accounts = [_]@import("config_types.zig").DiscordConfig{
        .{ .account_id = "dc-main", .token = "discord-token" },
    };
    const qq_accounts = [_]@import("config_types.zig").QQConfig{
        .{
            .account_id = "qq-main",
            .app_id = "appid",
            .app_secret = "appsecret",
            .bot_token = "bottoken",
            .receive_mode = .websocket,
        },
    };
    const onebot_accounts = [_]@import("config_types.zig").OneBotConfig{
        .{ .account_id = "ob-main", .url = "ws://localhost:6700" },
    };
    const mattermost_accounts = [_]@import("config_types.zig").MattermostConfig{
        .{
            .account_id = "mm-main",
            .bot_token = "mm-token",
            .base_url = "https://chat.example.com",
            .allow_from = &.{"user-a"},
            .group_policy = "allowlist",
        },
    };
    const slack_allow = [_][]const u8{"slack-admin"};
    const slack_accounts = [_]@import("config_types.zig").SlackConfig{
        .{
            .account_id = "sl-main",
            .bot_token = "xoxb-token",
            .allow_from = &slack_allow,
            .dm_policy = "deny",
            .group_policy = "allowlist",
        },
    };
    const maixcam_accounts = [_]@import("config_types.zig").MaixCamConfig{
        .{ .account_id = "cam-main", .name = "maixcam-main" },
    };

    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .default_model = "test-model",
        .allocator = allocator,
        .channels = .{
            .telegram = &telegram_accounts,
            .signal = &signal_accounts,
            .discord = &discord_accounts,
            .qq = &qq_accounts,
            .onebot = &onebot_accounts,
            .mattermost = &mattermost_accounts,
            .slack = &slack_accounts,
            .maixcam = &maixcam_accounts,
            .whatsapp = &[_]@import("config_types.zig").WhatsAppConfig{
                .{
                    .account_id = "wa-main",
                    .access_token = "wa-access",
                    .phone_number_id = "123456",
                    .verify_token = "wa-verify",
                },
            },
            .line = &[_]@import("config_types.zig").LineConfig{
                .{
                    .account_id = "line-main",
                    .access_token = "line-token",
                    .channel_secret = "line-secret",
                },
            },
            .lark = &[_]@import("config_types.zig").LarkConfig{
                .{
                    .account_id = "lark-main",
                    .app_id = "cli_xxx",
                    .app_secret = "secret_xxx",
                },
            },
            .matrix = &[_]@import("config_types.zig").MatrixConfig{
                .{
                    .account_id = "mx-main",
                    .homeserver = "https://matrix.example",
                    .access_token = "mx-token",
                    .room_id = "!room:example",
                },
            },
            .irc = &[_]@import("config_types.zig").IrcConfig{
                .{
                    .account_id = "irc-main",
                    .host = "irc.example.net",
                    .nick = "nullclaw",
                },
            },
            .imessage = &[_]@import("config_types.zig").IMessageConfig{
                .{
                    .account_id = "imain",
                    .allow_from = &.{"user@example.com"},
                    .enabled = true,
                },
            },
            .email = &[_]@import("config_types.zig").EmailConfig{
                .{
                    .account_id = "email-main",
                    .username = "bot@example.com",
                    .password = "secret",
                    .from_address = "bot@example.com",
                },
            },
            .dingtalk = &[_]@import("config_types.zig").DingTalkConfig{
                .{
                    .account_id = "ding-main",
                    .client_id = "ding-id",
                    .client_secret = "ding-secret",
                },
            },
        },
    };

    var reg = dispatch.ChannelRegistry.init(allocator);
    defer reg.deinit();

    var event_bus = bus_mod.Bus.init();

    const mgr = try ChannelManager.init(allocator, &config, &reg);
    defer mgr.deinit();
    mgr.setEventBus(&event_bus);

    try mgr.collectConfiguredChannels();

    var expected_total: usize = 0;
    var expected_polling: usize = 0;
    var expected_gateway_loop: usize = 0;
    var expected_webhook_only: usize = 0;
    var expected_send_only: usize = 0;

    if (channel_catalog.isBuildEnabled(.telegram)) {
        expected_total += telegram_accounts.len;
        expected_polling += telegram_accounts.len;
    }
    if (channel_catalog.isBuildEnabled(.signal)) {
        expected_total += signal_accounts.len;
        expected_polling += signal_accounts.len;
    }
    if (channel_catalog.isBuildEnabled(.discord)) {
        expected_total += discord_accounts.len;
        expected_gateway_loop += discord_accounts.len;
    }
    if (channel_catalog.isBuildEnabled(.qq)) {
        expected_total += qq_accounts.len;
        expected_gateway_loop += qq_accounts.len;
    }
    if (channel_catalog.isBuildEnabled(.onebot)) {
        expected_total += onebot_accounts.len;
        expected_gateway_loop += onebot_accounts.len;
    }
    if (channel_catalog.isBuildEnabled(.mattermost)) {
        expected_total += mattermost_accounts.len;
        expected_gateway_loop += mattermost_accounts.len;
    }
    if (channel_catalog.isBuildEnabled(.slack)) {
        expected_total += slack_accounts.len;
        expected_gateway_loop += slack_accounts.len;
    }
    if (channel_catalog.isBuildEnabled(.maixcam)) {
        expected_total += maixcam_accounts.len;
        expected_send_only += maixcam_accounts.len;
    }
    if (channel_catalog.isBuildEnabled(.whatsapp)) {
        expected_total += config.channels.whatsapp.len;
        expected_webhook_only += config.channels.whatsapp.len;
    }
    if (channel_catalog.isBuildEnabled(.line)) {
        expected_total += config.channels.line.len;
        expected_webhook_only += config.channels.line.len;
    }
    if (channel_catalog.isBuildEnabled(.lark)) {
        expected_total += config.channels.lark.len;
        expected_webhook_only += config.channels.lark.len;
    }
    if (channel_catalog.isBuildEnabled(.matrix)) {
        expected_total += config.channels.matrix.len;
        expected_polling += config.channels.matrix.len;
    }
    if (channel_catalog.isBuildEnabled(.irc)) {
        expected_total += config.channels.irc.len;
        expected_gateway_loop += config.channels.irc.len;
    }
    if (channel_catalog.isBuildEnabled(.imessage)) {
        expected_total += config.channels.imessage.len;
        expected_gateway_loop += config.channels.imessage.len;
    }
    if (channel_catalog.isBuildEnabled(.email)) {
        expected_total += config.channels.email.len;
        expected_send_only += config.channels.email.len;
    }
    if (channel_catalog.isBuildEnabled(.dingtalk)) {
        expected_total += config.channels.dingtalk.len;
        expected_send_only += config.channels.dingtalk.len;
    }

    try std.testing.expectEqual(expected_total, mgr.count());
    try std.testing.expectEqual(expected_total, reg.count());

    const entries = mgr.channelEntries();
    try std.testing.expectEqual(expected_polling, countEntriesByListenerType(entries, .polling));
    try std.testing.expectEqual(expected_gateway_loop, countEntriesByListenerType(entries, .gateway_loop));
    try std.testing.expectEqual(expected_webhook_only, countEntriesByListenerType(entries, .webhook_only));
    try std.testing.expectEqual(expected_send_only, countEntriesByListenerType(entries, .send_only));
    try std.testing.expectEqual(@as(usize, 0), countEntriesByListenerType(entries, .not_implemented));

    try expectEntryPresence(entries, "telegram", "main", channel_catalog.isBuildEnabled(.telegram));
    try expectEntryPresence(entries, "telegram", "backup", channel_catalog.isBuildEnabled(.telegram));
    try expectEntryPresence(entries, "signal", "sig-main", channel_catalog.isBuildEnabled(.signal));
    try expectEntryPresence(entries, "discord", "dc-main", channel_catalog.isBuildEnabled(.discord));
    try expectEntryPresence(entries, "qq", "qq-main", channel_catalog.isBuildEnabled(.qq));
    try expectEntryPresence(entries, "onebot", "ob-main", channel_catalog.isBuildEnabled(.onebot));
    try expectEntryPresence(entries, "mattermost", "mm-main", channel_catalog.isBuildEnabled(.mattermost));
    try expectEntryPresence(entries, "slack", "sl-main", channel_catalog.isBuildEnabled(.slack));
    try expectEntryPresence(entries, "maixcam", "cam-main", channel_catalog.isBuildEnabled(.maixcam));
    try expectEntryPresence(entries, "whatsapp", "wa-main", channel_catalog.isBuildEnabled(.whatsapp));
    try expectEntryPresence(entries, "line", "line-main", channel_catalog.isBuildEnabled(.line));
    try expectEntryPresence(entries, "lark", "lark-main", channel_catalog.isBuildEnabled(.lark));
    try expectEntryPresence(entries, "matrix", "mx-main", channel_catalog.isBuildEnabled(.matrix));
    try expectEntryPresence(entries, "irc", "irc-main", channel_catalog.isBuildEnabled(.irc));
    try expectEntryPresence(entries, "imessage", "imain", channel_catalog.isBuildEnabled(.imessage));
    try expectEntryPresence(entries, "email", "email-main", channel_catalog.isBuildEnabled(.email));
    try expectEntryPresence(entries, "dingtalk", "ding-main", channel_catalog.isBuildEnabled(.dingtalk));

    if (channel_catalog.isBuildEnabled(.discord)) {
        const discord_entry = findEntryByNameAccount(entries, "discord", "dc-main") orelse
            return error.TestUnexpectedResult;
        const discord_ptr: *discord.DiscordChannel = @ptrCast(@alignCast(discord_entry.channel.ptr));
        try std.testing.expect(discord_ptr.bus == &event_bus);
    }

    if (channel_catalog.isBuildEnabled(.qq)) {
        const qq_entry = findEntryByNameAccount(entries, "qq", "qq-main") orelse
            return error.TestUnexpectedResult;
        const qq_ptr: *qq.QQChannel = @ptrCast(@alignCast(qq_entry.channel.ptr));
        try std.testing.expect(qq_ptr.event_bus == &event_bus);
    }

    if (channel_catalog.isBuildEnabled(.onebot)) {
        const onebot_entry = findEntryByNameAccount(entries, "onebot", "ob-main") orelse
            return error.TestUnexpectedResult;
        const onebot_ptr: *onebot.OneBotChannel = @ptrCast(@alignCast(onebot_entry.channel.ptr));
        try std.testing.expect(onebot_ptr.event_bus == &event_bus);
    }

    if (channel_catalog.isBuildEnabled(.mattermost)) {
        const mattermost_entry = findEntryByNameAccount(entries, "mattermost", "mm-main") orelse
            return error.TestUnexpectedResult;
        const mattermost_ptr: *mattermost.MattermostChannel = @ptrCast(@alignCast(mattermost_entry.channel.ptr));
        try std.testing.expect(mattermost_ptr.bus == &event_bus);
    }

    if (channel_catalog.isBuildEnabled(.irc)) {
        const irc_entry = findEntryByNameAccount(entries, "irc", "irc-main") orelse
            return error.TestUnexpectedResult;
        const irc_ptr: *irc.IrcChannel = @ptrCast(@alignCast(irc_entry.channel.ptr));
        try std.testing.expect(irc_ptr.bus == &event_bus);
    }

    if (channel_catalog.isBuildEnabled(.imessage)) {
        const imessage_entry = findEntryByNameAccount(entries, "imessage", "imain") orelse
            return error.TestUnexpectedResult;
        const imessage_ptr: *imessage.IMessageChannel = @ptrCast(@alignCast(imessage_entry.channel.ptr));
        try std.testing.expect(imessage_ptr.bus == &event_bus);
    }

    if (channel_catalog.isBuildEnabled(.maixcam)) {
        const maixcam_entry = findEntryByNameAccount(entries, "maixcam", "cam-main") orelse
            return error.TestUnexpectedResult;
        const maixcam_ptr: *maixcam.MaixCamChannel = @ptrCast(@alignCast(maixcam_entry.channel.ptr));
        try std.testing.expect(maixcam_ptr.event_bus == &event_bus);
    }

    if (channel_catalog.isBuildEnabled(.slack)) {
        const slack_entry = findEntryByNameAccount(entries, "slack", "sl-main") orelse
            return error.TestUnexpectedResult;
        const slack_ptr: *slack.SlackChannel = @ptrCast(@alignCast(slack_entry.channel.ptr));
        try std.testing.expect(slack_ptr.bus == &event_bus);
        try std.testing.expect(slack_ptr.policy.dm == .deny);
        try std.testing.expect(slack_ptr.policy.group == .allowlist);
        try std.testing.expectEqual(@as(usize, 1), slack_ptr.policy.allowlist.len);
        try std.testing.expectEqualStrings("slack-admin", slack_ptr.policy.allowlist[0]);
    }
}

test "ChannelManager marks qq webhook receive_mode as webhook_only" {
    if (!channel_catalog.isBuildEnabled(.qq)) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const qq_accounts = [_]config_types.QQConfig{
        .{
            .account_id = "qq-main",
            .app_id = "appid",
            .app_secret = "appsecret",
            .bot_token = "bottoken",
            .receive_mode = .webhook,
        },
    };

    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .default_model = "test-model",
        .allocator = allocator,
        .channels = .{
            .qq = &qq_accounts,
        },
    };

    var reg = dispatch.ChannelRegistry.init(allocator);
    defer reg.deinit();

    const mgr = try ChannelManager.init(allocator, &config, &reg);
    defer mgr.deinit();

    try mgr.collectConfiguredChannels();
    const qq_entry = findEntryByNameAccount(mgr.channelEntries(), "qq", "qq-main") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(ListenerType.webhook_only, qq_entry.listener_type);
}

test "ChannelManager collects web channel from config" {
    if (comptime !@import("build_options").enable_channel_web) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const web_accounts = [_]config_types.WebConfig{
        .{
            .account_id = "local",
            .port = 32123,
            .path = "/relay/",
            .auth_token = "relay-token-0123456789",
        },
    };

    const config = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .default_model = "test-model",
        .allocator = allocator,
        .channels = .{
            .web = &web_accounts,
        },
    };

    var reg = dispatch.ChannelRegistry.init(allocator);
    defer reg.deinit();

    var event_bus = bus_mod.Bus.init();

    const mgr = try ChannelManager.init(allocator, &config, &reg);
    defer mgr.deinit();
    mgr.setEventBus(&event_bus);

    try mgr.collectConfiguredChannels();

    try expectEntryPresence(mgr.channelEntries(), "web", "local", true);

    // Verify it was registered with correct listener type
    const web_entry = findEntryByNameAccount(mgr.channelEntries(), "web", "local").?;
    try std.testing.expectEqual(ListenerType.gateway_loop, web_entry.listener_type);

    const web_ptr: *web.WebChannel = @ptrCast(@alignCast(web_entry.channel.ptr));
    try std.testing.expect(web_ptr.bus == &event_bus);
    try std.testing.expectEqualStrings("/relay", web_ptr.ws_path);
    try std.testing.expectEqualStrings("relay-token-0123456789", web_ptr.configured_auth_token.?);
}

// ════════════════════════════════════════════════════════════════════════════
// providerConfigChanged tests
// ════════════════════════════════════════════════════════════════════════════

test "providerConfigChanged detects api_key addition" {
    const no_key = [_]config_types.ProviderEntry{
        .{ .name = "openrouter" },
    };
    const with_key = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "sk-or-test" },
    };

    var base = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .providers = &no_key,
    };

    var changed = base;
    changed.providers = &with_key;

    try std.testing.expect(providerConfigChanged(&base, &changed));
    try std.testing.expect(!providerConfigChanged(&base, &base));
}

test "providerConfigChanged detects api_key change" {
    const key_a = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "key-a" },
    };
    const key_b = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "key-b" },
    };

    var a = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .providers = &key_a,
    };

    var b = a;
    b.providers = &key_b;

    try std.testing.expect(providerConfigChanged(&a, &b));
}

test "providerConfigChanged detects default_provider change" {
    var a = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
    };

    var b = a;
    b.default_provider = "anthropic";

    try std.testing.expect(providerConfigChanged(&a, &b));
}

test "providerConfigChanged detects provider count change" {
    const one = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "key" },
    };
    const two = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "key" },
        .{ .name = "anthropic", .api_key = "key2" },
    };

    var a = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .providers = &one,
    };

    var b = a;
    b.providers = &two;

    try std.testing.expect(providerConfigChanged(&a, &b));
}

test "providerConfigChanged detects base_url change" {
    const base = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "key", .base_url = null },
    };
    const with_url = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "key", .base_url = "https://custom.example.com/v1" },
    };

    var a = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .providers = &base,
    };

    var b = a;
    b.providers = &with_url;

    try std.testing.expect(providerConfigChanged(&a, &b));
}

test "providerConfigChanged returns false for identical configs" {
    const providers = [_]config_types.ProviderEntry{
        .{ .name = "openrouter", .api_key = "key" },
    };

    const a = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
        .providers = &providers,
    };

    try std.testing.expect(!providerConfigChanged(&a, &a));
}

test "providerConfigChanged detects retry settings change" {
    var a = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
    };

    var b = a;
    b.reliability.provider_retries = 5;

    try std.testing.expect(providerConfigChanged(&a, &b));
}

test "providerConfigChanged detects fallback_providers change" {
    var a = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .default_model = "test/model",
    };

    var b = a;
    b.reliability.fallback_providers = &.{"anthropic"};

    try std.testing.expect(providerConfigChanged(&a, &b));
}
