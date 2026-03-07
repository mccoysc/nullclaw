//! Python / Node.js script-based tool loader.
//!
//! # Discovery protocol
//!
//!   python3 script.py --nullclaw-list --nullclaw-output /tmp/nc_XXXX
//!   node   script.js  --nullclaw-list --nullclaw-output /tmp/nc_XXXX
//!
//!   Script writes a JSON array to the file specified by --nullclaw-output
//!   and exits 0:
//!     [{"name":"tool_name","description":"...","params_json":"{...}"}]
//!
//! # Execution protocol (one subprocess per call)
//!
//!   python3 script.py --nullclaw-call <tool_name> '<args_json>' --nullclaw-output /tmp/nc_XXXX
//!   node   script.js  --nullclaw-call <tool_name> '<args_json>' --nullclaw-output /tmp/nc_XXXX
//!
//!   Script writes result to the --nullclaw-output file and exits 0 for
//!   success, non-zero for failure.  Using a temp file instead of stdout
//!   avoids contamination from dependency import noise on stdout.
//!
//! No function-pointer lifetime issues — subprocess per call, no ref counting needed.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.loader_script);

// ── Temp-file helpers ───────────────────────────────────────────
//
// Scripts write their output to a temp file instead of stdout so that
// noisy dependency imports (which may print to stdout) do not
// contaminate the actual tool output.

/// Create a unique temp file path like "/tmp/nullclaw_XXXXXXXXXXXXXXXX".
fn makeTmpPath(allocator: Allocator) ![]const u8 {
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    return std.fmt.allocPrint(allocator, "/tmp/nullclaw_{s}", .{&hex});
}

/// Read the entire contents of a temp file.
fn readTmpFile(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 4 * 1024 * 1024);
}

/// Best-effort delete of a temp file.
fn deleteTmpFile(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

pub const ScriptKind = enum { python, node };

// ── Interpreter detection ─────────────────────────────────────────

/// Returns a heap-allocated interpreter name (e.g. "python3") if found in
/// PATH, or null. Caller frees.
fn detectInterpreter(allocator: Allocator, kind: ScriptKind) ?[]const u8 {
    const candidates: []const []const u8 = switch (kind) {
        .python => &.{ "python3", "python" },
        .node => &.{ "node", "nodejs" },
    };
    for (candidates) |cand| {
        const argv = [_][]const u8{ cand, "--version" };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch continue;
        const term = child.wait() catch continue;
        switch (term) {
            .Exited => |code| if (code == 0) {
                return allocator.dupe(u8, cand) catch null;
            },
            else => {},
        }
    }
    return null;
}

// ── ScriptToolWrapper — Tool vtable ──────────────────────────────

pub const ScriptToolWrapper = struct {
    allocator: Allocator,
    interp: []const u8, // owned
    script_path: []const u8, // owned (absolute)
    name_buf: []const u8, // owned
    description_buf: []const u8, // owned
    params_json_buf: []const u8, // owned

    pub const vtable = Tool.VTable{
        .execute = &executeImpl,
        .name = &nameImpl,
        .description = &descImpl,
        .parameters_json = &paramsImpl,
        .deinit = &deinitImpl,
    };

    pub fn tool(self: *ScriptToolWrapper) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn executeImpl(
        ptr: *anyopaque,
        allocator: Allocator,
        args: JsonObjectMap,
    ) anyerror!ToolResult {
        const self: *ScriptToolWrapper = @ptrCast(@alignCast(ptr));

        const args_json = try std.json.Stringify.valueAlloc(
            allocator,
            std.json.Value{ .object = args },
            .{},
        );
        defer allocator.free(args_json);

        // Create a temp file for the script to write its output into.
        const tmp_path = makeTmpPath(allocator) catch
            return ToolResult.fail("failed to create temp output path");
        defer allocator.free(tmp_path);
        defer deleteTmpFile(tmp_path);

        const argv = [_][]const u8{
            self.interp,
            self.script_path,
            "--nullclaw-call",
            self.name_buf,
            args_json,
            "--nullclaw-output",
            tmp_path,
        };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        const term = child.wait() catch return ToolResult.fail("script wait failed");
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        // Read output from the temp file.
        const output = readTmpFile(allocator, tmp_path) catch |err| {
            if (success) {
                log.warn("script succeeded but output file unreadable: {}", .{err});
                return ToolResult.fail("script output file unreadable");
            }
            return ToolResult.fail("script failed (no output)");
        };
        errdefer allocator.free(output);

        if (success) return ToolResult.ok(output);
        return ToolResult.fail(output);
    }

    fn nameImpl(ptr: *anyopaque) []const u8 {
        return (@as(*ScriptToolWrapper, @ptrCast(@alignCast(ptr)))).name_buf;
    }
    fn descImpl(ptr: *anyopaque) []const u8 {
        return (@as(*ScriptToolWrapper, @ptrCast(@alignCast(ptr)))).description_buf;
    }
    fn paramsImpl(ptr: *anyopaque) []const u8 {
        return (@as(*ScriptToolWrapper, @ptrCast(@alignCast(ptr)))).params_json_buf;
    }
    fn deinitImpl(ptr: *anyopaque, _: Allocator) void {
        const self: *ScriptToolWrapper = @ptrCast(@alignCast(ptr));
        const a = self.allocator;
        a.free(self.interp);
        a.free(self.script_path);
        a.free(self.name_buf);
        a.free(self.description_buf);
        a.free(self.params_json_buf);
        a.destroy(self);
    }
};

// ── Discovery ─────────────────────────────────────────────────────

pub const DiscoveredTool = struct {
    name: []const u8, // owned
    description: []const u8, // owned
    params_json: []const u8, // owned

    pub fn deinit(self: DiscoveredTool, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.params_json);
    }
};

fn runList(allocator: Allocator, interp: []const u8, script_path: []const u8) ![]DiscoveredTool {
    // Create a temp file for the script to write its tool list into.
    const tmp_path = makeTmpPath(allocator) catch return error.ScriptListFailed;
    defer allocator.free(tmp_path);
    defer deleteTmpFile(tmp_path);

    const argv = [_][]const u8{ interp, script_path, "--nullclaw-list", "--nullclaw-output", tmp_path };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const term = child.wait() catch return error.ScriptListFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return error.ScriptListFailed,
        else => return error.ScriptListFailed,
    }

    // Read the tool list from the temp file.
    const file_content = readTmpFile(allocator, tmp_path) catch return error.ScriptListFailed;
    defer allocator.free(file_content);

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        file_content,
        .{},
    ) catch return error.ScriptInvalidJson;
    defer parsed.deinit();

    if (parsed.value != .array) return error.ScriptInvalidJson;

    var out = std.ArrayListUnmanaged(DiscoveredTool).empty;
    errdefer {
        for (out.items) |d| d.deinit(allocator);
        out.deinit(allocator);
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const name_v = item.object.get("name") orelse continue;
        if (name_v != .string) continue;
        const desc = if (item.object.get("description")) |d|
            (if (d == .string) d.string else "")
        else
            "";
        const params = if (item.object.get("params_json")) |p|
            (if (p == .string) p.string else "{}")
        else
            "{}";

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name_v.string),
            .description = try allocator.dupe(u8, desc),
            .params_json = try allocator.dupe(u8, params),
        });
    }
    return out.toOwnedSlice(allocator);
}

// ── Public API ────────────────────────────────────────────────────

/// Load and wrap tools from a Python or Node.js script.
/// Returns `error.InterpreterNotFound` if the runtime is not in PATH.
pub fn loadScript(
    allocator: Allocator,
    kind: ScriptKind,
    path: []const u8,
) ![]Tool {
    const interp = detectInterpreter(allocator, kind) orelse {
        log.warn("{s} not found in PATH; skipping '{s}'", .{ @tagName(kind), path });
        return error.InterpreterNotFound;
    };
    errdefer allocator.free(interp);

    const defs = runList(allocator, interp, path) catch |err| {
        log.err("script '{s}' --nullclaw-list: {}", .{ path, err });
        return err;
    };
    defer {
        for (defs) |d| d.deinit(allocator);
        allocator.free(defs);
    }

    const abs_path = std.fs.realpathAlloc(allocator, path) catch
        try allocator.dupe(u8, path);
    defer allocator.free(abs_path);

    var list = std.ArrayListUnmanaged(Tool).empty;
    errdefer {
        for (list.items) |t| t.deinit(allocator);
        list.deinit(allocator);
    }

    for (defs) |def| {
        const w = try allocator.create(ScriptToolWrapper);
        errdefer allocator.destroy(w);
        w.* = .{
            .allocator = allocator,
            .interp = try allocator.dupe(u8, interp),
            .script_path = try allocator.dupe(u8, abs_path),
            .name_buf = try allocator.dupe(u8, def.name),
            .description_buf = try allocator.dupe(u8, def.description),
            .params_json_buf = try allocator.dupe(u8, def.params_json),
        };
        try list.append(allocator, w.tool());
    }

    // Free interp AFTER toOwnedSlice to avoid double-free if toOwnedSlice
    // fails (errdefer at top also frees interp on error paths).
    const result = list.toOwnedSlice(allocator);
    allocator.free(interp);
    return result;
}

// ── Tests ──────────────────────────────────────────────────────────

test "loader_script: ScriptToolWrapper deinit frees all owned strings" {
    const allocator = std.testing.allocator;
    const w = try allocator.create(ScriptToolWrapper);
    w.* = .{
        .allocator = allocator,
        .interp = try allocator.dupe(u8, "python3"),
        .script_path = try allocator.dupe(u8, "/tmp/test.py"),
        .name_buf = try allocator.dupe(u8, "test_tool"),
        .description_buf = try allocator.dupe(u8, "A test tool"),
        .params_json_buf = try allocator.dupe(u8, "{}"),
    };
    const t = w.tool();
    try std.testing.expectEqualStrings("test_tool", t.name());
    try std.testing.expectEqualStrings("A test tool", t.description());
    try std.testing.expectEqualStrings("{}", t.parametersJson());
    t.deinit(allocator);
    // Leak detector will catch double-free or missing free.
}

test "loader_script: ScriptKind tag names" {
    try std.testing.expectEqualStrings("python", @tagName(ScriptKind.python));
    try std.testing.expectEqualStrings("node", @tagName(ScriptKind.node));
}

// ── End-to-end tests against examples/plugins/ ─────────────────────

/// Helper: resolve examples/plugins/<filename> relative to repo root (CWD).
fn examplePath(allocator: Allocator, filename: []const u8) ![]const u8 {
    const rel = try std.fmt.allocPrint(allocator, "examples/plugins/{s}", .{filename});
    defer allocator.free(rel);
    return std.fs.cwd().realpathAlloc(allocator, rel) catch
        try allocator.dupe(u8, rel);
}

/// Helper: free a ToolResult produced by a ScriptToolWrapper.
/// On success the output is heap-allocated (read from temp file); on failure
/// the error_msg may be a static literal — we only free when we know the
/// test reached the success assertion.
fn freeToolResult(allocator: Allocator, result: root.ToolResult) void {
    if (result.output.len > 0) allocator.free(result.output);
    if (result.error_msg) |e| allocator.free(e);
}

test "loader_script: e2e Python discovers and executes tools from example_plugin.py" {
    const allocator = std.testing.allocator;

    const py_path = try examplePath(allocator, "example_plugin.py");
    defer allocator.free(py_path);

    const tools = loadScript(allocator, .python, py_path) catch |err| {
        if (err == error.InterpreterNotFound) return; // python3 not in PATH
        return err;
    };
    defer {
        for (tools) |t| t.deinit(allocator);
        allocator.free(tools);
    }

    // example_plugin.py exports py_upper and py_word_count.
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("py_upper", tools[0].name());
    try std.testing.expectEqualStrings("py_word_count", tools[1].name());

    // Execute py_upper.
    {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "{\"text\":\"hello world\"}",
            .{},
        );
        defer parsed.deinit();

        const result = try tools[0].execute(allocator, parsed.value.object);
        defer freeToolResult(allocator, result);

        try std.testing.expect(result.success);
        // Temp-file output has no trailing newline; trimRight is a no-op safety net.
        const out = std.mem.trimRight(u8, result.output, "\r\n");
        try std.testing.expectEqualStrings("HELLO WORLD", out);
    }

    // Execute py_word_count.
    {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "{\"text\":\"one two three\"}",
            .{},
        );
        defer parsed.deinit();

        const result = try tools[1].execute(allocator, parsed.value.object);
        defer freeToolResult(allocator, result);

        try std.testing.expect(result.success);
        const out = std.mem.trimRight(u8, result.output, "\r\n");
        try std.testing.expectEqualStrings("3", out);
    }
}

test "loader_script: e2e Node.js discovers and executes tools from example_plugin.js" {
    const allocator = std.testing.allocator;

    const js_path = try examplePath(allocator, "example_plugin.js");
    defer allocator.free(js_path);

    const tools = loadScript(allocator, .node, js_path) catch |err| {
        if (err == error.InterpreterNotFound) return; // node not in PATH
        return err;
    };
    defer {
        for (tools) |t| t.deinit(allocator);
        allocator.free(tools);
    }

    // example_plugin.js exports js_reverse and js_char_count.
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("js_reverse", tools[0].name());
    try std.testing.expectEqualStrings("js_char_count", tools[1].name());

    // Execute js_reverse.
    {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "{\"text\":\"nullclaw\"}",
            .{},
        );
        defer parsed.deinit();

        const result = try tools[0].execute(allocator, parsed.value.object);
        defer freeToolResult(allocator, result);

        try std.testing.expect(result.success);
        const out = std.mem.trimRight(u8, result.output, "\r\n");
        try std.testing.expectEqualStrings("walcllun", out);
    }

    // Execute js_char_count.
    {
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            "{\"text\":\"hello\"}",
            .{},
        );
        defer parsed.deinit();

        const result = try tools[1].execute(allocator, parsed.value.object);
        defer freeToolResult(allocator, result);

        try std.testing.expect(result.success);
        const out = std.mem.trimRight(u8, result.output, "\r\n");
        try std.testing.expectEqualStrings("5", out);
    }
}
