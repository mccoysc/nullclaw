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

    // ── operation-level mutex — serializes applyPlugins / hot-reload ──
    plugin_op_mutex: std.Thread.Mutex = .{},

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
            const heap = self.allocator.alloc(Tool, self.entries.items.len) catch {
                log.err("withSlice: heap alloc failed for {d} tools; callback skipped", .{self.entries.items.len});
                return;
            };
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
                const old_slot_id = e.so_slot_id;
                e.tool.deinit(self.allocator);
                self.allocator.free(e.source);
                _ = self.entries.swapRemove(i);
                if (old_slot_id) |sid| self.gcSoSlotLocked(sid);
                return true;
            }
        }
        return false;
    }

    fn registerEntry(self: *ToolRegistry, entry: ToolEntry) !void {
        // Replace existing by name.
        for (self.entries.items, 0..) |*e, i| {
            if (std.mem.eql(u8, e.tool.name(), entry.tool.name())) {
                const old_slot_id = e.so_slot_id;
                e.tool.deinit(self.allocator);
                self.allocator.free(e.source);
                self.entries.items[i] = entry;
                if (old_slot_id) |sid| self.gcSoSlotLocked(sid);
                return;
            }
        }
        try self.entries.append(self.allocator, entry);
    }

    // ─────────────────────────────────────────────────────────────
    // Plugin loading — applyPlugins
    // ─────────────────────────────────────────────────────────────

    /// Apply a ToolPluginsConfig: `overwrite` then `add`.
    ///
    /// `overwrite` semantics (new):
    ///   If any entries are present, load ALL tools from ALL overwrite entries,
    ///   drain in-flight SO calls, wipe the entire existing registry (every tool,
    ///   every SO slot), then register the freshly-loaded set.
    ///   If `overwrite` is empty this phase is skipped — existing tools are kept.
    ///
    /// `add` semantics (unchanged):
    ///   For each entry, load its tools and append them; same name = overwrite
    ///   that specific entry only.
    ///
    /// After both phases, writes currentToolsList if a path is configured.
    pub fn applyPlugins(self: *ToolRegistry, cfg: ToolPluginsConfig) !void {
        // Serialize all plugin mutation operations so that concurrent
        // hot-reload or applyAdd calls cannot interleave and leak slots.
        self.plugin_op_mutex.lock();
        defer self.plugin_op_mutex.unlock();

        // Phase 1: overwrite — collect all tools, clear registry, register new set.
        if (cfg.overwrite.len > 0) {
            self.applyOverwriteAll(cfg.overwrite);
        }

        // Phase 2: add — register or replace unconditionally by name.
        for (cfg.add) |entry| {
            self.applyAdd(entry) catch |err| {
                log.warn("add plugin '{s}' skipped: {}", .{ entry.path, err });
            };
        }

        self.writeCurrentToolsList();
    }

    /// Load all tools from every entry in `entries`, then atomically replace
    /// the ENTIRE registry with those tools.
    ///
    /// Sequence:
    ///   1. Snapshot `so_slots` length so we can distinguish pre-existing slots
    ///      from ones created as a side-effect of loading the new SO plugins.
    ///   2. Load each entry's tools (SO/python/node). Failures are logged and
    ///      skipped. Successfully loaded tools accumulate in `all`.
    ///   3. If any currently-registered tool is SO-backed, set `draining = true`
    ///      and wait for `active_so_calls` to reach zero.
    ///   4. Free every existing tool entry and every pre-existing SO slot.
    ///      Newly-loaded SO slots (added in step 2) are shifted to the front.
    ///   5. Register all tools collected in step 2.
    ///   6. Clear the drain flag.
    fn applyOverwriteAll(self: *ToolRegistry, entries: []const ExternalToolConfig) void {
        // Step 1 — snapshot old slot count.
        // loadSo() appends SoSlot records as a side-effect; the snapshot lets us
        // free only OLD slots while keeping newly-loaded ones.
        self.mutex.lock();
        const old_slot_count = self.so_slots.items.len;
        self.mutex.unlock();

        // Step 2 — load all new tools.
        // Each entry's tools are appended to `new_entries`. Load failures are
        // logged and skipped intentionally — the caller has no recovery action.
        // OOM mid-batch: remaining unmoved items in that batch are freed inline;
        // already-accumulated items in `new_entries` survive and are used in
        // Step 5 (or freed by `new_entries.deinit` if Step 5 is never reached).
        var new_entries = std.ArrayListUnmanaged(ToolEntry).empty;
        for (entries) |entry| {
            const loaded = self.loadExternal(entry) catch |err| {
                log.warn("overwrite plugin '{s}' load failed: {}", .{ entry.path, err });
                continue;
            };
            // Move each batch item into `new_entries`. On OOM free remaining
            // unmoved items in this batch; already-moved ones stay in new_entries.
            var i: usize = 0;
            while (i < loaded.tools.len) : (i += 1) {
                new_entries.append(self.allocator, .{
                    .tool = loaded.tools[i],
                    .source = loaded.sources[i],
                    .so_slot_id = loaded.slot_ids[i],
                }) catch {
                    for (loaded.tools[i..]) |t| t.deinit(self.allocator);
                    for (loaded.sources[i..]) |s| self.allocator.free(s);
                    break;
                };
            }
            // Free slice containers only — individual items are moved or freed above.
            self.allocator.free(loaded.tools);
            self.allocator.free(loaded.sources);
            self.allocator.free(loaded.slot_ids);
        }

        // Guard — abort if every plugin load failed (new_entries is empty).
        // Proceeding would wipe built-ins + all existing plugins, leaving the
        // agent with zero tools.  Keep the current registry as a safe fallback.
        //
        // Also clean up any SO slots appended during Step 2 as side-effects of
        // loadSo() but whose corresponding tool entries were lost to OOM: those
        // slots (indices old_slot_count..) have no tool referencing them and
        // would otherwise leak open shared-library handles until deinit().
        if (new_entries.items.len == 0) {
            log.warn("overwrite: all plugin loads failed; keeping existing registry", .{});
            new_entries.deinit(self.allocator);
            self.mutex.lock();
            for (self.so_slots.items[old_slot_count..]) |slot| {
                slot.deinit(self.allocator);
                self.allocator.destroy(slot);
            }
            self.so_slots.shrinkRetainingCapacity(old_slot_count);
            self.mutex.unlock();
            return;
        }

        // Step 3 — drain in-flight SO calls if any current entry is SO-backed.
        {
            self.mutex.lock();
            var has_so = false;
            for (self.entries.items) |e| {
                if (self.isSoTool(e.tool)) {
                    has_so = true;
                    break;
                }
            }
            self.mutex.unlock();

            if (has_so) {
                self.draining.store(true, .release);
                self.waitForSoDrain();
            }
        }

        // Steps 4 and 5 — free ALL existing entries/SO slots, then register new tools.
        // Both steps run under a single mutex hold so that concurrent readers
        // (copySlice, count, executeTool) never observe an empty registry window.
        self.mutex.lock();

        for (self.entries.items) |*e| {
            e.tool.deinit(self.allocator);
            self.allocator.free(e.source);
        }
        self.entries.clearRetainingCapacity();

        // `so_slots` holds *SoSlot (heap-allocated structs).
        // Free old slots (indices 0 .. old_slot_count); keep newly-loaded ones.
        for (self.so_slots.items[0..old_slot_count]) |slot| {
            slot.deinit(self.allocator); // closes the shared library
            self.allocator.destroy(slot); // frees the SoSlot heap record
        }
        // Shift newly-loaded slots (old_slot_count .. end) down to the front.
        // copyForwards (front-to-back) is correct for a left-shift even when
        // the source and destination ranges overlap.
        const new_slot_count = self.so_slots.items.len - old_slot_count;
        if (new_slot_count > 0) {
            std.mem.copyForwards(
                *SoSlot,
                self.so_slots.items[0..new_slot_count],
                self.so_slots.items[old_slot_count..],
            );
        }
        self.so_slots.shrinkRetainingCapacity(new_slot_count);

        // Step 5 — register all new tools (mutex is still held from Step 4).
        // Keeping the single lock hold across both clear+repopulate prevents
        // concurrent readers (copySlice, count, executeTool) from observing an
        // empty registry between the two steps.
        // Failures (OOM) are logged and the affected tool is freed; partial
        // success is acceptable — the caller observes the actual registry state
        // via currentToolsList.
        for (new_entries.items) |e| {
            self.registerEntry(e) catch |err| {
                const tool_name = e.tool.name();
                e.tool.deinit(self.allocator);
                self.allocator.free(e.source);
                log.err("overwrite: failed to register '{s}': {}", .{ tool_name, err });
            };
        }
        self.mutex.unlock();
        // Free the backing array only — individual items are now owned by the registry
        // (or were freed inline on registerEntry failure above).
        new_entries.deinit(self.allocator);

        // Step 6 — clear drain flag unconditionally.
        // `draining` is an atomic, not mutex-protected, so it is safe to clear
        // it after releasing the mutex.  Setting it false when it was never set
        // true is a benign no-op.
        self.draining.store(false, .release);
    }

    fn applyAdd(self: *ToolRegistry, entry: ExternalToolConfig) !void {
        const loaded = try self.loadExternal(entry);
        defer {
            // Slice containers are freed here; individual items are either
            // moved into the registry or freed explicitly in the loop below.
            self.allocator.free(loaded.tools);
            self.allocator.free(loaded.sources);
            self.allocator.free(loaded.slot_ids);
        }

        // Drain in-flight SO calls if any incoming tool would replace an
        // existing SO-backed entry.  Must happen before holding the mutex so
        // that executing SO tools can call releaseSoCall() unblocked.
        {
            self.mutex.lock();
            var needs_drain = false;
            outer: for (loaded.tools) |new_t| {
                for (self.entries.items) |e| {
                    if (std.mem.eql(u8, e.tool.name(), new_t.name()) and
                        self.isSoTool(e.tool))
                    {
                        needs_drain = true;
                        break :outer;
                    }
                }
            }
            self.mutex.unlock();

            if (needs_drain) {
                self.draining.store(true, .release);
                self.waitForSoDrain();
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (loaded.tools, loaded.sources, loaded.slot_ids) |t, src, sid| {
            // Capture the old SO slot id (if any) BEFORE registering the
            // replacement, so we can GC the slot once the entry is gone.
            var old_so_slot: ?usize = null;
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.tool.name(), t.name())) {
                    old_so_slot = e.so_slot_id;
                    break;
                }
            }

            const ok = blk: {
                self.registerEntry(.{
                    .tool = t,
                    .source = src,
                    .so_slot_id = sid,
                }) catch |err| {
                    const tool_name = t.name();
                    t.deinit(self.allocator);
                    self.allocator.free(src);
                    log.err("add plugin: failed to register '{s}': {}", .{ tool_name, err });
                    break :blk false;
                };
                break :blk true;
            };

            // GC the old SO slot only when the replacement was committed.
            if (ok) {
                if (old_so_slot) |oid| self.gcSoSlotLocked(oid);
            }
        }

        // Clear the drain flag regardless of whether draining was needed.
        self.draining.store(false, .release);
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
        // Guard opened.handle and opened.metas against leaks if any
        // subsequent allocation fails before ownership is transferred.
        var handle_transferred = false;
        errdefer if (!handle_transferred) {
            for (opened.metas) |m| m.deinit(self.allocator);
            self.allocator.free(opened.metas);
            var h = opened.handle;
            h.deinit();
        };

        // Register the SoSlot (owns the handle).
        const slot = try self.allocator.create(SoSlot);
        errdefer self.allocator.destroy(slot);
        const slot_id = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const id = self.next_slot_id;
            self.next_slot_id += 1;
            break :blk id;
        };
        slot.* = .{
            .id = slot_id,
            .path = try self.allocator.dupe(u8, path),
            .handle = opened.handle,
        };
        {
            self.mutex.lock();
            self.so_slots.append(self.allocator, slot) catch |err| {
                self.mutex.unlock();
                // Free only the path; let errdefer at line 553 destroy the
                // slot struct and errdefer at line 544 close the handle.
                self.allocator.free(slot.path);
                return err;
            };
            self.mutex.unlock();
        }
        // Ownership of opened.handle has been transferred into slot.
        handle_transferred = true;
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
        // On mid-loop OOM the errdefer below frees already-moved tools via
        // tools_list; we must also free the NOT-yet-moved remainder of raw_tools.
        // Track how many have been moved so we can free [moved..] on error.
        var raw_moved: usize = 0;
        defer self.allocator.free(raw_tools);
        errdefer {
            for (raw_tools[raw_moved..]) |t| t.deinit(self.allocator);
        }

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
            raw_moved += 1;
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
        const arr = val orelse return try allocator.alloc(ExternalToolConfig, 0);
        if (arr != .array) return try allocator.alloc(ExternalToolConfig, 0);
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

// ── Overwrite semantic tests ──────────────────────────────────────

// Registers two builtin stubs, then calls applyPlugins with an overwrite entry
// (Python plugin). After the call only the python tools must remain — the two
// builtins must be gone, proving the "clear all existing" semantic.
test "registry: overwrite clears ALL existing tools before registering new ones" {
    const allocator = std.testing.allocator;

    const rel = "examples/plugins/example_plugin.py";
    const py_path = std.fs.cwd().realpathAlloc(allocator, rel) catch
        try allocator.dupe(u8, rel);
    defer allocator.free(py_path);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const StubA = struct {
        pub const tool_name = "stub_a";
        pub const tool_description = "a";
        pub const tool_params = "{}";
        pub const vtable = root.ToolVTable(@This());
        pub fn tool(self: *@This()) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
        pub fn execute(_: *@This(), _: Allocator, _: root.JsonObjectMap) anyerror!root.ToolResult {
            return root.ToolResult.ok("");
        }
    };
    const StubB = struct {
        pub const tool_name = "stub_b";
        pub const tool_description = "b";
        pub const tool_params = "{}";
        pub const vtable = root.ToolVTable(@This());
        pub fn tool(self: *@This()) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
        pub fn execute(_: *@This(), _: Allocator, _: root.JsonObjectMap) anyerror!root.ToolResult {
            return root.ToolResult.ok("");
        }
    };
    const no_deinit_a = root.Tool.VTable{
        .execute = StubA.vtable.execute,
        .name = StubA.vtable.name,
        .description = StubA.vtable.description,
        .parameters_json = StubA.vtable.parameters_json,
        .deinit = null,
    };
    const no_deinit_b = root.Tool.VTable{
        .execute = StubB.vtable.execute,
        .name = StubB.vtable.name,
        .description = StubB.vtable.description,
        .parameters_json = StubB.vtable.parameters_json,
        .deinit = null,
    };
    var sa = StubA{};
    var sb = StubB{};
    try reg.register(Tool{ .ptr = @ptrCast(&sa), .vtable = &no_deinit_a });
    try reg.register(Tool{ .ptr = @ptrCast(&sb), .vtable = &no_deinit_b });
    try std.testing.expectEqual(@as(usize, 2), reg.count());

    const cfg = ToolPluginsConfig{
        .overwrite = &.{.{ .kind = .python, .path = py_path }},
    };
    reg.applyPlugins(cfg) catch |err| {
        if (err == error.InterpreterNotFound) return;
        return err;
    };

    // Both stubs must be gone; only the two python tools remain.
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    var buf: [4]Tool = undefined;
    const n = reg.copySlice(&buf);
    for (buf[0..n]) |t| {
        try std.testing.expect(!std.mem.eql(u8, t.name(), "stub_a"));
        try std.testing.expect(!std.mem.eql(u8, t.name(), "stub_b"));
    }
    try std.testing.expectEqualStrings("py_upper", buf[0].name());
    try std.testing.expectEqualStrings("py_word_count", buf[1].name());
}

// If overwrite slice is empty the registry must be unchanged.
test "registry: overwrite empty is a no-op" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const StubC = struct {
        pub const tool_name = "stub_c";
        pub const tool_description = "c";
        pub const tool_params = "{}";
        pub const vtable = root.ToolVTable(@This());
        pub fn tool(self: *@This()) Tool {
            return .{ .ptr = @ptrCast(self), .vtable = &vtable };
        }
        pub fn execute(_: *@This(), _: Allocator, _: root.JsonObjectMap) anyerror!root.ToolResult {
            return root.ToolResult.ok("");
        }
    };
    const no_deinit_c = root.Tool.VTable{
        .execute = StubC.vtable.execute,
        .name = StubC.vtable.name,
        .description = StubC.vtable.description,
        .parameters_json = StubC.vtable.parameters_json,
        .deinit = null,
    };
    var sc = StubC{};
    try reg.register(Tool{ .ptr = @ptrCast(&sc), .vtable = &no_deinit_c });

    reg.applyPlugins(.{}) catch {};
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    var buf: [2]Tool = undefined;
    _ = reg.copySlice(&buf);
    try std.testing.expectEqualStrings("stub_c", buf[0].name());
}

// add replacing a same-named entry must not duplicate it.
test "registry: add same-name python tool replaces without duplication" {
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
        if (err == error.InterpreterNotFound) return;
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), reg.count());

    // Add the same plugin again — names collide, registry must stay at 2.
    reg.applyPlugins(cfg) catch |err| {
        if (err == error.InterpreterNotFound) return;
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    // Drain flag must be clear after the (non-SO) replacement.
    try std.testing.expect(!reg.isPendingDrain());
}

// add SO same-name: simulate an in-flight call and verify applyAdd waits for
// drain before replacing. Linux only (requires dlopen + cc).
test "registry: add SO same-name drains in-flight calls before replacing" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .linux) return;

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const so_path = try std.fmt.allocPrint(allocator, "{s}/ep.so", .{tmp_path});
    defer allocator.free(so_path);
    const c_src = try std.fs.cwd().realpathAlloc(allocator, "examples/plugins/example_plugin.c");
    defer allocator.free(c_src);
    {
        const argv = [_][]const u8{ "cc", "-shared", "-fPIC", "-o", so_path, c_src };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.CompileFailed,
        }
    }

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    // Load the SO plugin.
    reg.applyPlugins(.{
        .add = &.{.{ .kind = .so, .path = so_path }},
    }) catch |err| return err;
    try std.testing.expectEqual(@as(usize, 2), reg.count()); // so_echo + so_reverse

    // Simulate an in-flight SO call.
    reg.acquireSoCall();

    // Release the in-flight call in a background thread after a small delay
    // so that the add below actually has to wait for drain.
    const Releaser = struct {
        fn run(r: *ToolRegistry) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            r.releaseSoCall();
        }
    };
    const thr = try std.Thread.spawn(.{}, Releaser.run, .{&reg});
    defer thr.join();

    // Adding the same SO plugin again triggers the drain path because so_echo
    // and so_reverse are both SO-backed with the same names.
    reg.applyPlugins(.{
        .add = &.{.{ .kind = .so, .path = so_path }},
    }) catch |err| return err;

    // Drain flag cleared, count stable, no active calls.
    try std.testing.expect(!reg.isPendingDrain());
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expectEqual(@as(u32, 0), reg.active_so_calls.load(.acquire));
}
