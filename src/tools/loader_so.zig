//! Shared-library (.so / .dll / .dylib) tool loader.
//!
//! The library must export two C-ABI symbols:
//!
//!   NullclawToolDef* nullclaw_tools_list(size_t* out_count);
//!   void             nullclaw_tools_free(NullclawToolDef* tools, size_t count);
//!
//! Where `NullclawToolDef` is (in C):
//!
//!   typedef struct {
//!       const char* name;
//!       const char* description;
//!       const char* params_json;
//!       bool (*execute)(const char* args_json,
//!                       char*       out_buf,
//!                       size_t      out_cap,
//!                       size_t*     out_len);
//!   } NullclawToolDef;

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.loader_so);

/// Maximum output buffer handed to SO tool execute functions (1 MiB).
pub const SO_RESULT_BUF = 1024 * 1024;

// ── C-ABI layout ─────────────────────────────────────────────────

pub const SoToolDef = extern struct {
    name: [*:0]const u8,
    description: [*:0]const u8,
    params_json: [*:0]const u8,
    execute: *const fn (
        args_json: [*:0]const u8,
        out_buf: [*]u8,
        out_cap: usize,
        out_len: *usize,
    ) callconv(.C) bool,
};

pub const SoListFn = fn (out_count: *usize) callconv(.C) [*]SoToolDef;
pub const SoFreeFn = fn (tools: [*]SoToolDef, count: usize) callconv(.C) void;

// ── SoHandle — owns one loaded library ───────────────────────────

/// Owns a loaded shared library. Must be kept alive as long as any
/// SoToolWrapper that references it (enforced via ToolRegistry ref counting).
pub const SoHandle = struct {
    lib: std.DynLib,
    defs_ptr: [*]SoToolDef,
    defs_len: usize,
    free_fn: *const SoFreeFn,

    /// Release the def array and close the library.
    pub fn deinit(self: *SoHandle) void {
        self.free_fn(self.defs_ptr, self.defs_len);
        self.lib.close();
    }
};

// ── SoToolWrapper — Tool vtable backed by one SoToolDef ──────────

/// Each instance wraps one function pointer from a loaded SO.
/// The wrapper does NOT own the SO handle — the ToolRegistry (via SoSlot) does.
/// Strings (name/desc/params) are duplicated so they survive library unload.
pub const SoToolWrapper = struct {
    allocator: Allocator,
    /// Identifies which SoSlot this wrapper came from (for registry cleanup).
    slot_id: usize,
    name_buf: []const u8,
    description_buf: []const u8,
    params_json_buf: []const u8,
    execute_fn: *const fn ([*:0]const u8, [*]u8, usize, *usize) callconv(.C) bool,

    pub const vtable = Tool.VTable{
        .execute = &executeImpl,
        .name = &nameImpl,
        .description = &descImpl,
        .parameters_json = &paramsImpl,
        .deinit = &deinitImpl,
    };

    pub fn tool(self: *SoToolWrapper) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(
        ptr: *anyopaque,
        allocator: Allocator,
        args: JsonObjectMap,
    ) anyerror!ToolResult {
        const self: *SoToolWrapper = @ptrCast(@alignCast(ptr));

        const args_json = try std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .object = args },
            .{},
        );
        defer allocator.free(args_json);

        const args_z = try allocator.dupeZ(u8, args_json);
        defer allocator.free(args_z);

        const out_buf = try allocator.alloc(u8, SO_RESULT_BUF);
        defer allocator.free(out_buf);
        var out_len: usize = 0;

        const ok = self.execute_fn(args_z.ptr, out_buf.ptr, out_buf.len, &out_len);
        const output = try allocator.dupe(u8, out_buf[0..out_len]);
        return if (ok) ToolResult.ok(output) else ToolResult.fail(output);
    }

    fn nameImpl(ptr: *anyopaque) []const u8 {
        return (@as(*SoToolWrapper, @ptrCast(@alignCast(ptr)))).name_buf;
    }
    fn descImpl(ptr: *anyopaque) []const u8 {
        return (@as(*SoToolWrapper, @ptrCast(@alignCast(ptr)))).description_buf;
    }
    fn paramsImpl(ptr: *anyopaque) []const u8 {
        return (@as(*SoToolWrapper, @ptrCast(@alignCast(ptr)))).params_json_buf;
    }
    fn deinitImpl(ptr: *anyopaque, _: Allocator) void {
        const self: *SoToolWrapper = @ptrCast(@alignCast(ptr));
        const a = self.allocator;
        a.free(self.name_buf);
        a.free(self.description_buf);
        a.free(self.params_json_buf);
        a.destroy(self);
    }
};

// ── Public API ───────────────────────────────────────────────────

/// Discovered tool metadata from a shared library (before wrapping).
pub const SoToolMeta = struct {
    name: []const u8, // owned
    description: []const u8, // owned
    params_json: []const u8, // owned
    execute_fn: *const fn ([*:0]const u8, [*]u8, usize, *usize) callconv(.C) bool,

    pub fn deinit(self: SoToolMeta, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.params_json);
    }
};

/// Open a shared library and return the loaded handle + metadata for each
/// exported tool. Caller is responsible for calling `handle.deinit()` and
/// freeing `metas`.
pub fn openSo(allocator: Allocator, path: []const u8) !struct {
    handle: SoHandle,
    metas: []SoToolMeta,
} {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var lib = std.DynLib.open(path_z) catch |err| {
        log.err("cannot open '{s}': {}", .{ path, err });
        return err;
    };
    errdefer lib.close();

    const list_fn = lib.lookup(*const SoListFn, "nullclaw_tools_list") orelse {
        log.err("'{s}' missing export: nullclaw_tools_list", .{path});
        return error.MissingExport;
    };
    const free_fn = lib.lookup(*const SoFreeFn, "nullclaw_tools_free") orelse {
        log.err("'{s}' missing export: nullclaw_tools_free", .{path});
        return error.MissingExport;
    };

    var count: usize = 0;
    const defs_ptr = list_fn(&count);

    const handle = SoHandle{
        .lib = lib,
        .defs_ptr = defs_ptr,
        .defs_len = count,
        .free_fn = free_fn,
    };

    if (count == 0) {
        log.warn("'{s}' exported zero tools", .{path});
        return .{ .handle = handle, .metas = &.{} };
    }

    // Duplicate all strings so they survive potential reuse after handle.deinit().
    var metas = std.ArrayListUnmanaged(SoToolMeta).empty;
    errdefer {
        for (metas.items) |m| m.deinit(allocator);
        metas.deinit(allocator);
    }

    for (defs_ptr[0..count]) |def| {
        try metas.append(allocator, .{
            .name = try allocator.dupe(u8, std.mem.span(def.name)),
            .description = try allocator.dupe(u8, std.mem.span(def.description)),
            .params_json = try allocator.dupe(u8, std.mem.span(def.params_json)),
            .execute_fn = def.execute,
        });
    }

    return .{ .handle = handle, .metas = try metas.toOwnedSlice(allocator) };
}

/// Create a heap-allocated SoToolWrapper from metadata + a slot_id.
pub fn wrapMeta(
    allocator: Allocator,
    meta: SoToolMeta,
    slot_id: usize,
) !*SoToolWrapper {
    const w = try allocator.create(SoToolWrapper);
    errdefer allocator.destroy(w);
    w.* = .{
        .allocator = allocator,
        .slot_id = slot_id,
        .name_buf = try allocator.dupe(u8, meta.name),
        .description_buf = try allocator.dupe(u8, meta.description),
        .params_json_buf = try allocator.dupe(u8, meta.params_json),
        .execute_fn = meta.execute_fn,
    };
    return w;
}
