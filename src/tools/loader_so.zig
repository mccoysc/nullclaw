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
    ) callconv(.c) bool,
};

pub const SoListFn = fn (out_count: *usize) callconv(.c) [*]SoToolDef;
pub const SoFreeFn = fn (tools: [*]SoToolDef, count: usize) callconv(.c) void;

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
    execute_fn: *const fn ([*:0]const u8, [*]u8, usize, *usize) callconv(.c) bool,

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
        if (out_len > out_buf.len) {
            log.err("SO plugin returned out_len={} > out_cap={}", .{ out_len, out_buf.len });
            return ToolResult.fail(try allocator.dupe(u8, "plugin reported invalid output length"));
        }
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
    execute_fn: *const fn ([*:0]const u8, [*]u8, usize, *usize) callconv(.c) bool,

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
    errdefer free_fn(defs_ptr, count);

    const handle = SoHandle{
        .lib = lib,
        .defs_ptr = defs_ptr,
        .defs_len = count,
        .free_fn = free_fn,
    };

    if (count == 0) {
        log.warn("'{s}' exported zero tools", .{path});
        return .{ .handle = handle, .metas = try allocator.alloc(SoToolMeta, 0) };
    }

    // Duplicate all strings so they survive potential reuse after handle.deinit().
    var metas = std.ArrayListUnmanaged(SoToolMeta).empty;
    errdefer {
        for (metas.items) |m| m.deinit(allocator);
        metas.deinit(allocator);
    }

    for (defs_ptr[0..count]) |def| {
        try metas.ensureUnusedCapacity(allocator, 1);
        const name = try allocator.dupe(u8, std.mem.span(def.name));
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, std.mem.span(def.description));
        errdefer allocator.free(description);
        const params_json = try allocator.dupe(u8, std.mem.span(def.params_json));
        // ensureUnusedCapacity guarantees appendAssumeCapacity won't fail.
        metas.appendAssumeCapacity(.{
            .name = name,
            .description = description,
            .params_json = params_json,
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
    const name_buf = try allocator.dupe(u8, meta.name);
    errdefer allocator.free(name_buf);
    const description_buf = try allocator.dupe(u8, meta.description);
    errdefer allocator.free(description_buf);
    const params_json_buf = try allocator.dupe(u8, meta.params_json);
    w.* = .{
        .allocator = allocator,
        .slot_id = slot_id,
        .name_buf = name_buf,
        .description_buf = description_buf,
        .params_json_buf = params_json_buf,
        .execute_fn = meta.execute_fn,
    };
    return w;
}

// ── Tests ─────────────────────────────────────────────────────────

// End-to-end: compile examples/plugins/example_plugin.c, load it via
// openSo/wrapMeta, execute both exported tools, verify output.
// Skip on platforms without DynLib support or without a C compiler.
test "loader_so: e2e compile and execute example_plugin.c" {
    const builtin = @import("builtin");

    // Skip platforms that don't support dynamic library loading
    // std.DynLib is supported on: linux, macos, windows, freebsd, netbsd, openbsd
    const os_tag = builtin.os.tag;
    const supports_dynlib = switch (os_tag) {
        .linux, .macos, .windows, .freebsd, .netbsd, .openbsd => true,
        else => false,
    };
    if (comptime !supports_dynlib) return;

    const allocator = std.testing.allocator;

    // Compile the example C plugin into a temporary directory.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Platform-specific extension and compiler flags
    const ext = switch (builtin.os.tag) {
        .macos => "dylib",
        .windows => "dll",
        else => "so", // linux, freebsd, netbsd, openbsd
    };
    const so_path = try std.fmt.allocPrint(allocator, "{s}/example_plugin.{s}", .{ tmp_path, ext });
    defer allocator.free(so_path);

    // src path: resolve examples/plugins/example_plugin.c from CWD (repo root).
    const c_path = try std.fs.cwd().realpathAlloc(allocator, "examples/plugins/example_plugin.c");
    defer allocator.free(c_path);

    // Compile with cc - platform-specific flags
    const compile_argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &[_][]const u8{ "cc", "-shared", "-fPIC", "-o", so_path, c_path, "-undefined", "dynamic_lookup" },
        .windows => &[_][]const u8{ "gcc", "-shared", "-o", so_path, c_path },
        else => &[_][]const u8{ "cc", "-shared", "-fPIC", "-o", so_path, c_path }, // linux, freebsd, netbsd, openbsd
    };
    {
        var child = std.process.Child.init(compile_argv, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.CompileFailed,
        }
    }

    // Open the shared library.
    const opened = try openSo(allocator, so_path);
    var handle = opened.handle;
    defer handle.deinit();
    defer {
        for (opened.metas) |m| m.deinit(allocator);
        allocator.free(opened.metas);
    }

    try std.testing.expectEqual(@as(usize, 2), opened.metas.len);
    try std.testing.expectEqualStrings("so_echo", opened.metas[0].name);
    try std.testing.expectEqualStrings("so_reverse", opened.metas[1].name);

    // ── so_echo: wraps args JSON ──────────────────────────────────
    {
        const w = try wrapMeta(allocator, opened.metas[0], 0);
        const t = w.tool();
        defer t.deinit(allocator);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"x\":1}", .{});
        defer parsed.deinit();

        const result = try t.execute(allocator, parsed.value.object);
        defer if (result.output.len > 0) allocator.free(result.output);
        // SoToolWrapper.executeImpl always heap-allocates its output via
        // allocator.dupe — on success it ends up in result.output, on failure
        // in result.error_msg.  Both are safe to free here.
        defer if (result.error_msg) |e| allocator.free(e);

        try std.testing.expect(result.success);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "echo:") != null);
    }

    // ── so_reverse: reverses "text" ───────────────────────────────
    {
        const w = try wrapMeta(allocator, opened.metas[1], 0);
        const t = w.tool();
        defer t.deinit(allocator);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "{\"text\":\"hello\"}",
            .{},
        );
        defer parsed.deinit();

        const result = try t.execute(allocator, parsed.value.object);
        defer if (result.output.len > 0) allocator.free(result.output);
        defer if (result.error_msg) |e| allocator.free(e);

        try std.testing.expect(result.success);
        try std.testing.expectEqualStrings("olleh", result.output);
    }
}
