//! Dynamic tool registry with SO ref-counting and hot-reload.
//!
//! # Ownership model
//!
//!   - Built-in tools: registry.tools owns them (deinit called on removal).
//!   - SO tools: each wrapper (SoToolWrapper) is owned by registry.tools.
//!     The corresponding SoHandle is owned by a SoSlot in registry.so_slots.
//!     The slot is freed only after (1) all wrappers referencing it are removed
//!     from registry.tools AND (2) active_so_calls drops to zero.
//!   - Script tools: subprocess per call; no persistent handle.
//!
//! # SO unload sequence
//!
//!   1. isPendingDrain() → true  (blocks new channel messages)
//!   2. Wait until active_so_calls == 0
//!   3. Remove SoToolWrapper entries from registry.tools (deinit each)
//!   4. Remove SoSlot from so_slots; call slot.deinit() (closes library)
//!   5. isPendingDrain() → false
//!
//! # Hot-reload
//!
//!   Background thread polls the config file mtime. On change, re-parses
//!   tools.plugins and calls applyPlugins(). Blocks channel traffic during any
//!   SO drain phase.
//!
//! # currentToolsList write-back
//!
//!   After every applyPlugins() call, writes a JSON array to a configured path.
//!   Each entry: { "name", "description", "params_json", "source" }
//!   source = "builtin" | "so:<path>" | "script:<path>"
//!   Function pointers are NOT serialized (process-local, meaningless outside).

const std = @import("std");
const root = @import("root.zig");
const config_mod = @import("../config.zig");
const loader_so = @import("loader_so.zig");
const loader_script = @import("loader_script.zig");

const Tool = root.Tool;
const ToolSpec = root.ToolSpec;
const Allocator = std.mem.Allocator;
const ExternalToolConfig = config_mod.ExternalToolConfig;
const ExternalToolKind = config_mod.ExternalToolKind;
const ToolPluginsConfig = config_mod.ToolPluginsConfig;

const log = std.log.scoped(.tool_registry);

// ── SoSlot — owns one loaded library ─────────────────────────────

/// Stable heap-allocated record for a loaded SO library.
/// Does NOT own the Tool wrappers (registry.tools does).
const SoSlot = struct {
    id: usize, // unique, monotonically increasing
    path: []const u8, // owned copy for logging / currentToolsList
    handle: loader_so.SoHandle,

    fn deinit(self: *SoSlot, allocator: Allocator) void {
        self.handle.deinit();
        allocator.free(self.path);
    }
};

// ── ToolSourceTag — tracks which plugin produced a tool ──────────

/// Metadata stored alongside each Tool so we can write currentToolsList
/// without relying on vtable comparison for source identification.
const ToolEntry = struct {
    tool: Tool,
    /// "builtin", "so:<path>", "script:<path>"
    source: []const u8, // owned
    /// Non-null for SO tools; used during unload to find all tools from a slot.
    so_slot_id: ?usize = null,
};

// ── ToolRegistry ──────────────────────────────────────────────────

pub const ToolRegistry = struct {
    allocator: Allocator,

    // ── tool list ─────────────────────────────────────────────────
    mutex: std.Thread.Mutex = .{},
    entries: std.ArrayListUnmanaged(ToolEntry) = .empty,
    so_slots: std.ArrayListUnmanaged(*SoSlot) = .empty,
    next_slot_id: usize = 0,

    // ── SO reference counting ─────────────────────────────────────
    active_so_calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// true while old SO tools are being drained before library unload.
    /// Channel managers MUST check this and refuse new messages.
    draining: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    drain_mutex: std.Thread.Mutex = .{},
    drain_cond: std.Thread.Condition = .{},

    // ── hot-reload ────────────────────────────────────────────────
    config_path: ?[]const u8 = null,
    last_mtime: i128 = 0,
    reload_thread: ?std.Thread = null,
    reload_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reload_interval_secs: u64 = 5,

    // ── currentToolsList output ───────────────────────────────────
    current_tools_list_path: ?[]const u8 = null,

    // ─────────────────────────────────────────────────────────────
    // Init / deinit
    // ─────────────────────────────────────────────────────────────

    pub fn init(allocator: Allocator) ToolRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.stopHotReload();

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.entries.items) |*e| {
            e.tool.deinit(self.allocator);
            self.allocator.free(e.source);
        }
        self.entries.deinit(self.allocator);

        for (self.so_slots.items) |slot| {
            slot.deinit(self.allocator);
            self.allocator.destroy(slot);
        }
        self.so_slots.deinit(self.allocator);

        if (self.config_path) |p| self.allocator.free(p);
        if (self.current_tools_list_path) |p| self.allocator.free(p);
    }

    // ─────────────────────────────────────────────────────────────
    // Public read API
    // ─────────────────────────────────────────────────────────────

    /// Copy tool pointers into `out`. Returns the slice of `out` that was filled.
    /// Caller provides a buffer; call with out.len == 0 to get count first.
    /// For performance in the agent dispatch loop, prefer `withSlice`.
    pub fn copySlice(self: *ToolRegistry, out: []Tool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(out.len, self.entries.items.len);
        for (self.entries.items[0..n], 0..) |e, i| out[i] = e.tool;
        return n;
    }

    /// Invoke `func(tools, ctx)` while holding the registry mutex.
    /// This is the preferred way to iterate tools without copying.
    pub fn withSlice(
        self: *ToolRegistry,
        ctx: anytype,
        comptime func: fn (@TypeOf(ctx), []const Tool) void,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Build a temporary slice of Tool from entries.
        // Use a small stack buffer; fall back to heap for large registries.
        var stack_buf: [64]Tool = undefined;
        if (self.entries.items.len <= stack_buf.len) {
            for (self.entries.items, 0..) |e, i| stack_buf[i] = e.tool;
            func(ctx, stack_buf[0..self.entries.items.len]);
        } else {
            const heap = self.allocator.alloc(Tool, self.entries.items.len) catch return;
            defer self.allocator.free(heap);
            for (self.entries.items, 0..) |e, i| heap[i] = e.tool;
            func(ctx, heap);
        }
    }

    /// Returns current tool count (mutex-protected).
    pub fn count(self: *ToolRegistry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    /// Returns true while SO tools are being drained.
    /// Channel managers should refuse new inbound messages when this returns true.
    pub fn isPendingDrain(self: *ToolRegistry) bool {
        return self.draining.load(.acquire);
    }

    // ─────────────────────────────────────────────────────────────
    // SO call ref-counting
    // ─────────────────────────────────────────────────────────────

    /// Call BEFORE executing any SO-backed tool (vtable == SoToolWrapper.vtable).
    pub fn acquireSoCall(self: *ToolRegistry) void {
        _ = self.active_so_calls.fetchAdd(1, .release);
    }

    /// Call AFTER an SO-backed tool returns (success or error).
    pub fn releaseSoCall(self: *ToolRegistry) void {
        const prev = self.active_so_calls.fetchSub(1, .release);
        if (prev == 1) {
            self.drain_mutex.lock();
            defer self.drain_mutex.unlock();
            self.drain_cond.broadcast();
        }
    }

    /// Returns true if this Tool is backed by a shared library.
    pub fn isSoTool(_: *ToolRegistry, t: Tool) bool {
        return t.vtable == &loader_so.SoToolWrapper.vtable;
    }

    // ─────────────────────────────────────────────────────────────
    // Dynamic registration (built-in tools)
    // ─────────────────────────────────────────────────────────────

    /// Add a built-in tool. If a tool with the same name exists it is replaced.
    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.registerEntry(.{
            .tool = tool,
            .source = try self.allocator.dupe(u8, "builtin"),
        });
    }

    /// Remove a tool by name. Returns true if found and removed.
    pub fn remove(self: *ToolRegistry, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.removeLocked(name);
    }

    fn removeLocked(self: *ToolRegistry, name: []const u8) bool {
        for (self.entries.items, 0..) |*e, i| {
            if (std.mem.eql(u8, e.tool.name(), name)) {
                e.tool.deinit(self.allocator);
                self.allocator.free(e.source);
                _ = self.entries.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    fn registerEntry(self: *ToolRegistry, entry: ToolEntry) !void {
        // Replace existing by name.
        for (self.entries.items, 0..) |*e, i| {
            if (std.mem.eql(u8, e.tool.name(), entry.tool.name())) {
                e.tool.deinit(self.allocator);
                self.allocator.free(e.source);
                self.entries.items[i] = entry;
                return;
            }
        }
        try self.entries.append(self.allocator, entry);
    }

    // ─────────────────────────────────────────────────────────────
    // Plugin loading — applyPlugins
    // ─────────────────────────────────────────────────────────────

    /// Apply a ToolPluginsConfig: `overwrite` then `add`.
    /// After completion, writes currentToolsList if path is configured.
    pub fn applyPlugins(self: *ToolRegistry, cfg: ToolPluginsConfig) !void {
        // Phase 1: overwrite — only replace already-registered names.
        for (cfg.overwrite) |entry| {
            self.applyOverwrite(entry) catch |err| {
                log.warn("overwrite plugin '{s}' skipped: {}", .{ entry.path, err });
            };
        }

        // Phase 2: add — register or replace unconditionally.
        for (cfg.add) |entry| {
            self.applyAdd(entry) catch |err| {
                log.warn("add plugin '{s}' skipped: {}", .{ entry.path, err });
            };
        }

        self.writeCurrentToolsList();
    }

    fn applyOverwrite(self: *ToolRegistry, entry: ExternalToolConfig) !void {
        const loaded = try self.loadExternal(entry);
        defer {
            for (loaded.tools) |t| t.deinit(self.allocator);
            self.allocator.free(loaded.tools);
            for (loaded.sources) |s| self.allocator.free(s);
            self.allocator.free(loaded.sources);
            for (loaded.slot_ids) |_| {} // slot_ids are usize, no free
            self.allocator.free(loaded.slot_ids);
        }

        // Drain SO calls if any replaced tool is currently SO-backed.
        {
            self.mutex.lock();
            const needs_drain = blk: {
                for (loaded.tools) |new_t| {
                    for (self.entries.items) |e| {
                        if (std.mem.eql(u8, e.tool.name(), new_t.name()) and
                            self.isSoTool(e.tool))
                        {
                            break :blk true;
                        }
                    }
                }
                break :blk false;
            };
            self.mutex.unlock();

            if (needs_drain) {
                self.draining.store(true, .release);
                self.waitForSoDrain();
            }
        }

        self.mutex.lock();
        for (loaded.tools, loaded.sources, loaded.slot_ids) |new_t, src, sid| {
            var found = false;
            for (self.entries.items, 0..) |*e, i| {
                if (std.mem.eql(u8, e.tool.name(), new_t.name())) {
                    // Clean up any slot that is now empty.
                    const old_sid = e.so_slot_id;
                    e.tool.deinit(self.allocator);
                    self.allocator.free(e.source);
                    self.entries.items[i] = .{
                        .tool = new_t,
                        .source = src,
                        .so_slot_id = sid,
                    };
                    if (old_sid) |oid| self.gcSoSlotLocked(oid);
                    found = true;
                    break;
                }
            }
            if (!found) {
                log.debug("overwrite: '{s}' not in registry; ignoring", .{new_t.name()});
                new_t.deinit(self.allocator);
                self.allocator.free(src);
            }
        }
        self.mutex.unlock();

        self.draining.store(false, .release);
    }

    fn applyAdd(self: *ToolRegistry, entry: ExternalToolConfig) !void {
        const loaded = try self.loadExternal(entry);
        defer {
            // The loop below moves ownership into registry; on error or
            // duplicates the caller freed above already runs via errdefer in loadExternal.
            self.allocator.free(loaded.tools);
            self.allocator.free(loaded.sources);
            self.allocator.free(loaded.slot_ids);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (loaded.tools, loaded.sources, loaded.slot_ids) |t, src, sid| {
            self.registerEntry(.{
                .tool = t,
                .source = src,
                .so_slot_id = sid,
            }) catch |err| {
                t.deinit(self.allocator);
                self.allocator.free(src);
                log.err("add plugin: failed to register '{s}': {}", .{ t.name(), err });
            };
        }
    }

    const LoadedBatch = struct {
        tools: []Tool,
        sources: [][]const u8,
        slot_ids: []?usize,
    };

    fn loadExternal(self: *ToolRegistry, entry: ExternalToolConfig) !LoadedBatch {
        return switch (entry.kind) {
            .so => self.loadSo(entry.path),
            .python => self.loadScript(.python, entry.path),
            .node => self.loadScript(.node, entry.path),
        };
    }

    fn loadSo(self: *ToolRegistry, path: []const u8) !LoadedBatch {
        const opened = try loader_so.openSo(self.allocator, path);

        // Register the SoSlot (owns the handle).
        const slot = try self.allocator.create(SoSlot);
        errdefer self.allocator.destroy(slot);
        const slot_id = self.next_slot_id;
        self.next_slot_id += 1;
        slot.* = .{
            .id = slot_id,
            .path = try self.allocator.dupe(u8, path),
            .handle = opened.handle,
        };
        {
            self.mutex.lock();
            self.so_slots.append(self.allocator, slot) catch |err| {
                self.mutex.unlock();
                slot.deinit(self.allocator);
                self.allocator.destroy(slot);
                for (opened.metas) |m| m.deinit(self.allocator);
                self.allocator.free(opened.metas);
                return err;
            };
            self.mutex.unlock();
        }
        defer {
            for (opened.metas) |m| m.deinit(self.allocator);
            self.allocator.free(opened.metas);
        }

        // Wrap each meta into a SoToolWrapper.
        var tools_list = std.ArrayListUnmanaged(Tool).empty;
        var sources_list = std.ArrayListUnmanaged([]const u8).empty;
        var slot_ids_list = std.ArrayListUnmanaged(?usize).empty;
        errdefer {
            for (tools_list.items) |t| t.deinit(self.allocator);
            tools_list.deinit(self.allocator);
            for (sources_list.items) |s| self.allocator.free(s);
            sources_list.deinit(self.allocator);
            slot_ids_list.deinit(self.allocator);
        }

        const source_tag = try std.fmt.allocPrint(self.allocator, "so:{s}", .{path});
        defer self.allocator.free(source_tag);

        for (opened.metas) |meta| {
            const w = try loader_so.wrapMeta(self.allocator, meta, slot_id);
            try tools_list.append(self.allocator, w.tool());
            try sources_list.append(self.allocator, try self.allocator.dupe(u8, source_tag));
            try slot_ids_list.append(self.allocator, slot_id);
        }

        return .{
            .tools = try tools_list.toOwnedSlice(self.allocator),
            .sources = try sources_list.toOwnedSlice(self.allocator),
            .slot_ids = try slot_ids_list.toOwnedSlice(self.allocator),
        };
    }

    fn loadScript(self: *ToolRegistry, kind: loader_script.ScriptKind, path: []const u8) !LoadedBatch {
        const raw_tools = try loader_script.loadScript(self.allocator, kind, path);
        defer self.allocator.free(raw_tools);

        const source_tag = try std.fmt.allocPrint(self.allocator, "script:{s}", .{path});
        defer self.allocator.free(source_tag);

        var tools_list = std.ArrayListUnmanaged(Tool).empty;
        var sources_list = std.ArrayListUnmanaged([]const u8).empty;
        var slot_ids_list = std.ArrayListUnmanaged(?usize).empty;
        errdefer {
            for (tools_list.items) |t| t.deinit(self.allocator);
            tools_list.deinit(self.allocator);
            for (sources_list.items) |s| self.allocator.free(s);
            sources_list.deinit(self.allocator);
            slot_ids_list.deinit(self.allocator);
        }

        for (raw_tools) |t| {
            try tools_list.append(self.allocator, t);
            try sources_list.append(self.allocator, try self.allocator.dupe(u8, source_tag));
            try slot_ids_list.append(self.allocator, null);
        }

        return .{
            .tools = try tools_list.toOwnedSlice(self.allocator),
            .sources = try sources_list.toOwnedSlice(self.allocator),
            .slot_ids = try slot_ids_list.toOwnedSlice(self.allocator),
        };
    }

    /// Remove SoSlot `id` if no tools in the registry still reference it.
    /// Caller must hold mutex.
    fn gcSoSlotLocked(self: *ToolRegistry, id: usize) void {
        // Check if any entry still references this slot.
        for (self.entries.items) |e| {
            if (e.so_slot_id != null and e.so_slot_id.? == id) return;
        }
        // No references — remove and deinit the slot.
        for (self.so_slots.items, 0..) |slot, i| {
            if (slot.id == id) {
                slot.deinit(self.allocator);
                self.allocator.destroy(slot);
                _ = self.so_slots.swapRemove(i);
                return;
            }
        }
    }

    fn waitForSoDrain(self: *ToolRegistry) void {
        self.drain_mutex.lock();
        defer self.drain_mutex.unlock();
        while (self.active_so_calls.load(.acquire) > 0) {
            self.drain_cond.wait(&self.drain_mutex);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // currentToolsList write-back
    // ─────────────────────────────────────────────────────────────

    pub fn setCurrentToolsListPath(self: *ToolRegistry, path: []const u8) !void {
        if (self.current_tools_list_path) |p| self.allocator.free(p);
        self.current_tools_list_path = try self.allocator.dupe(u8, path);
    }

    /// Serialize the registry to currentToolsList.json.
    /// Fields per entry: name, description, params_json, source.
    /// Function pointers are NOT included (process-local).
    pub fn writeCurrentToolsList(self: *ToolRegistry) void {
        const out_path = self.current_tools_list_path orelse return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        self.mutex.lock();
        buf.appendSlice(self.allocator, "[\n") catch {};
        var first = true;
        for (self.entries.items) |e| {
            if (!first) buf.appendSlice(self.allocator, ",\n") catch {};
            first = false;
            buf.appendSlice(self.allocator, "  {\"name\":") catch {};
            appendJsonString(&buf, self.allocator, e.tool.name()) catch {};
            buf.appendSlice(self.allocator, ",\"description\":") catch {};
            appendJsonString(&buf, self.allocator, e.tool.description()) catch {};
            buf.appendSlice(self.allocator, ",\"params_json\":") catch {};
            appendJsonString(&buf, self.allocator, e.tool.parametersJson()) catch {};
            buf.appendSlice(self.allocator, ",\"source\":") catch {};
            appendJsonString(&buf, self.allocator, e.source) catch {};
            buf.append(self.allocator, '}') catch {};
        }
        self.mutex.unlock();

        buf.appendSlice(self.allocator, "\n]\n") catch {};

        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = buf.items }) catch |err| {
            log.warn("writeCurrentToolsList '{s}': {}", .{ out_path, err });
        };
    }

    fn appendJsonString(buf: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
        try buf.append(allocator, '"');
        for (s) |c| switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    // "\\u" (2 chars) + 4 hex digits = 6 bytes exactly.
                    comptime std.debug.assert(2 + 4 == 6);
                    var tmp: [6]u8 = undefined;
                    const s2 = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(allocator, s2);
                } else {
                    try buf.append(allocator, c);
                }
            },
        };
        try buf.append(allocator, '"');
    }

    // ─────────────────────────────────────────────────────────────
    // Hot-reload
    // ─────────────────────────────────────────────────────────────

    /// Start background polling thread.
    pub fn startHotReload(
        self: *ToolRegistry,
        config_path: []const u8,
        interval_secs: u64,
    ) !void {
        if (self.reload_thread != null) return;
        if (self.config_path) |p| self.allocator.free(p);
        self.config_path = try self.allocator.dupe(u8, config_path);
        self.reload_interval_secs = if (interval_secs == 0) 5 else interval_secs;
        self.reload_stop.store(false, .release);
        self.last_mtime = fileMtime(config_path);
        self.reload_thread = try std.Thread.spawn(.{}, hotReloadLoop, .{self});
    }

    pub fn stopHotReload(self: *ToolRegistry) void {
        self.reload_stop.store(true, .release);
        if (self.reload_thread) |t| {
            t.join();
            self.reload_thread = null;
        }
    }

    fn hotReloadLoop(self: *ToolRegistry) void {
        while (!self.reload_stop.load(.acquire)) {
            std.Thread.sleep(self.reload_interval_secs * std.time.ns_per_s);
            if (self.reload_stop.load(.acquire)) break;

            const cfg_path = self.config_path orelse continue;
            const mtime = fileMtime(cfg_path);
            if (mtime == self.last_mtime) continue;
            self.last_mtime = mtime;

            log.info("config changed, hot-reloading tool plugins", .{});
            self.hotReloadFromFile(cfg_path);
        }
    }

    fn hotReloadFromFile(self: *ToolRegistry, cfg_path: []const u8) void {
        const data = std.fs.cwd().readFileAlloc(
            self.allocator,
            cfg_path,
            4 * 1024 * 1024,
        ) catch |err| {
            log.err("hot-reload: read '{s}': {}", .{ cfg_path, err });
            return;
        };
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            data,
            .{},
        ) catch |err| {
            log.err("hot-reload: JSON parse: {}", .{err});
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const tools_v = parsed.value.object.get("tools") orelse return;
        if (tools_v != .object) return;
        const plugins_v = tools_v.object.get("plugins") orelse return;
        if (plugins_v != .object) return;

        const overwrite = parsePluginArray(
            self.allocator,
            plugins_v.object.get("overwrite"),
        ) catch return;
        defer {
            for (overwrite) |e| self.allocator.free(e.path);
            self.allocator.free(overwrite);
        }
        const add_arr = parsePluginArray(
            self.allocator,
            plugins_v.object.get("add"),
        ) catch return;
        defer {
            for (add_arr) |e| self.allocator.free(e.path);
            self.allocator.free(add_arr);
        }

        self.applyPlugins(.{ .overwrite = overwrite, .add = add_arr }) catch |err| {
            log.err("hot-reload: applyPlugins: {}", .{err});
        };
    }

    fn fileMtime(path: []const u8) i128 {
        const stat = std.fs.cwd().statFile(path) catch return 0;
        return stat.mtime;
    }

    fn parsePluginArray(allocator: Allocator, val: ?std.json.Value) ![]ExternalToolConfig {
        const arr = val orelse return &.{};
        if (arr != .array) return &.{};
        var out = std.ArrayListUnmanaged(ExternalToolConfig).empty;
        errdefer {
            for (out.items) |e| allocator.free(e.path);
            out.deinit(allocator);
        }
        for (arr.array.items) |item| {
            if (item != .object) continue;
            const kind_v = item.object.get("kind") orelse continue;
            if (kind_v != .string) continue;
            const path_v = item.object.get("path") orelse continue;
            if (path_v != .string) continue;
            const kind: ExternalToolKind = if (std.mem.eql(u8, kind_v.string, "so"))
                .so
            else if (std.mem.eql(u8, kind_v.string, "python"))
                .python
            else if (std.mem.eql(u8, kind_v.string, "node"))
                .node
            else {
                log.warn("unknown plugin kind '{s}'; skipping", .{kind_v.string});
                continue;
            };
            try out.append(allocator, .{
                .kind = kind,
                .path = try allocator.dupe(u8, path_v.string),
            });
        }
        return out.toOwnedSlice(allocator);
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "registry register and count" {
    var reg = ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const FakeTool = struct {
        pub const tool_name = "fake";
        pub const tool_description = "test";
        pub const tool_params = "{}";
        pub const vtable = root.ToolVTable(@This());
        pub fn tool(self: *@This()) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
        pub fn execute(_: *@This(), _: Allocator, _: root.JsonObjectMap) anyerror!root.ToolResult {
            return root.ToolResult.ok("ok");
        }
    };

    var ft = FakeTool{};
    // Override deinit to null — ft is stack-allocated, registry must not free it.
    const static_vtable = root.Tool.VTable{
        .execute = FakeTool.vtable.execute,
        .name = FakeTool.vtable.name,
        .description = FakeTool.vtable.description,
        .parameters_json = FakeTool.vtable.parameters_json,
        .deinit = null,
    };
    try reg.register(Tool{ .ptr = @ptrCast(&ft), .vtable = &static_vtable });
    try std.testing.expectEqual(@as(usize, 1), reg.count());
}

test "registry remove" {
    var reg = ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();

    const FakeTool = struct {
        pub const tool_name = "rm";
        pub const tool_description = "";
        pub const tool_params = "{}";
        pub const vtable = root.ToolVTable(@This());
        pub fn tool(self: *@This()) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
        pub fn execute(_: *@This(), _: Allocator, _: root.JsonObjectMap) anyerror!root.ToolResult {
            return root.ToolResult.ok("");
        }
    };

    var ft = FakeTool{};
    const no_deinit = root.Tool.VTable{
        .execute = FakeTool.vtable.execute,
        .name = FakeTool.vtable.name,
        .description = FakeTool.vtable.description,
        .parameters_json = FakeTool.vtable.parameters_json,
        .deinit = null,
    };
    try reg.register(Tool{ .ptr = @ptrCast(&ft), .vtable = &no_deinit });
    try std.testing.expect(reg.remove("rm"));
    try std.testing.expectEqual(@as(usize, 0), reg.count());
    try std.testing.expect(!reg.remove("rm"));
}

test "registry SO ref counting" {
    var reg = ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try std.testing.expect(!reg.isPendingDrain());
    reg.acquireSoCall();
    try std.testing.expectEqual(@as(u32, 1), reg.active_so_calls.load(.acquire));
    reg.releaseSoCall();
    try std.testing.expectEqual(@as(u32, 0), reg.active_so_calls.load(.acquire));
}

// ── End-to-end integration tests ─────────────────────────────────

// applyPlugins with examples/plugins/example_plugin.py:
// verifies that Python tools are added to the registry and execute correctly.
test "registry: applyPlugins adds Python tools from example_plugin.py" {
    const allocator = std.testing.allocator;

    const rel = "examples/plugins/example_plugin.py";
    const py_path = std.fs.cwd().realpathAlloc(allocator, rel) catch
        try allocator.dupe(u8, rel);
    defer allocator.free(py_path);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const cfg = ToolPluginsConfig{
        .add = &.{.{ .kind = .python, .path = py_path }},
    };
    reg.applyPlugins(cfg) catch |err| {
        if (err == error.InterpreterNotFound) return; // python3 not in PATH
        return err;
    };

    // example_plugin.py exposes py_upper and py_word_count.
    try std.testing.expectEqual(@as(usize, 2), reg.count());

    // Copy tools to a buffer to execute outside the mutex.
    var tool_buf: [4]Tool = undefined;
    const n = reg.copySlice(&tool_buf);
    try std.testing.expectEqual(@as(usize, 2), n);

    // Verify names via copySlice result.
    try std.testing.expectEqualStrings("py_upper", tool_buf[0].name());
    try std.testing.expectEqualStrings("py_word_count", tool_buf[1].name());

    // Execute py_upper (first tool).
    {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "{\"text\":\"hello registry\"}",
            .{},
        );
        defer parsed.deinit();

        const result = try tool_buf[0].execute(allocator, parsed.value.object);
        defer if (result.output.len > 0) allocator.free(result.output);
        defer if (result.error_msg) |e| allocator.free(e);

        try std.testing.expect(result.success);
        const out = std.mem.trimRight(u8, result.output, "\r\n");
        try std.testing.expectEqualStrings("HELLO REGISTRY", out);
    }
}

// applyPlugins with example_plugin.py, then writeCurrentToolsList:
// verifies JSON output contains expected tool names.
test "registry: writeCurrentToolsList produces valid JSON after applyPlugins" {
    const allocator = std.testing.allocator;

    const rel = "examples/plugins/example_plugin.py";
    const py_path = std.fs.cwd().realpathAlloc(allocator, rel) catch
        try allocator.dupe(u8, rel);
    defer allocator.free(py_path);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    // Use a tmpDir for the output file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const out_file = try std.fmt.allocPrint(allocator, "{s}/tools.json", .{tmp_path});
    defer allocator.free(out_file);
    try reg.setCurrentToolsListPath(out_file);

    const cfg = ToolPluginsConfig{
        .add = &.{.{ .kind = .python, .path = py_path }},
    };
    reg.applyPlugins(cfg) catch |err| {
        if (err == error.InterpreterNotFound) return;
        return err;
    };

    // Read and parse the generated JSON.
    const json_data = try std.fs.cwd().readFileAlloc(allocator, out_file, 64 * 1024);
    defer allocator.free(json_data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);

    // Verify each entry has the required fields.
    for (arr) |entry| {
        try std.testing.expect(entry == .object);
        try std.testing.expect(entry.object.contains("name"));
        try std.testing.expect(entry.object.contains("description"));
        try std.testing.expect(entry.object.contains("params_json"));
        try std.testing.expect(entry.object.contains("source"));
        // source must start with "script:"
        const src = entry.object.get("source").?;
        try std.testing.expect(src == .string);
        try std.testing.expect(std.mem.startsWith(u8, src.string, "script:"));
    }

    // First tool must be py_upper.
    const name0 = arr[0].object.get("name").?;
    try std.testing.expectEqualStrings("py_upper", name0.string);
}
