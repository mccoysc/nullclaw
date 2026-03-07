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

/// Maximum time (in nanoseconds) to wait for a script subprocess.
/// Discovery (--nullclaw-list): 30 seconds.
/// Execution (--nullclaw-call): 120 seconds.
const list_timeout_ns: u64 = 30 * std.time.ns_per_s;
const call_timeout_ns: u64 = 120 * std.time.ns_per_s;

/// Poll interval when checking if a child has exited.
const poll_interval_ns: u64 = 50 * std.time.ns_per_ms; // 50 ms

/// Wait for a child process with a timeout.
///
/// * **Windows** – uses `WaitForSingleObject(hProcess, timeout_ms)`.
///   On timeout the process is killed with `TerminateProcess` and
///   `error.ScriptTimeout` is returned.
/// * **POSIX** – spawns a watchdog thread that sends SIGKILL after
///   `timeout_ns`.  The main thread calls `child.wait()`.
///
/// Returns `error.ScriptTimeout` if the child was killed by the timeout.
fn waitWithTimeout(child: *std.process.Child, timeout_ns: u64) !std.process.Child.Term {
    const builtin = @import("builtin");

    if (comptime builtin.os.tag == .windows) {
        return waitWithTimeoutWindows(child, timeout_ns);
    }

    const pid = child.id;
    var done = std.atomic.Value(bool).init(false);

    const watchdog = std.Thread.spawn(.{}, struct {
        fn run(p: std.posix.pid_t, d: *std.atomic.Value(bool), ns: u64) void {
            // Sleep in small increments so we can bail early once done.
            var remaining: u64 = ns;
            const step: u64 = 100 * std.time.ns_per_ms; // 100ms
            while (remaining > 0) {
                if (d.load(.acquire)) return; // child already exited
                const sleep_ns = @min(remaining, step);
                std.Thread.sleep(sleep_ns);
                remaining -|= sleep_ns;
            }
            if (!d.load(.acquire)) {
                std.posix.kill(p, std.posix.SIG.KILL) catch {};
            }
        }
    }.run, .{ pid, &done, timeout_ns }) catch {
        // Cannot spawn watchdog — fall back to unbounded wait.
        return child.wait();
    };

    const term = child.wait() catch |err| {
        done.store(true, .release);
        watchdog.join();
        return err;
    };
    done.store(true, .release);
    watchdog.join();

    // Detect if the child was killed by our watchdog (SIGKILL).
    switch (term) {
        .Signal => |sig| if (sig == std.posix.SIG.KILL) return error.ScriptTimeout,
        else => {},
    }
    return term;
}

/// Windows implementation: WaitForSingleObject with a millisecond timeout.
/// If the wait times out, TerminateProcess is called and ScriptTimeout returned.
///
/// On the **success path** we avoid calling `child.wait()` directly (which would
/// do a redundant `WaitForSingleObjectEx(INFINITE)` inside `waitUnwrappedWindows`).
/// Instead we harvest the exit code with `GetExitCodeProcess`, close the process
/// and thread handles ourselves, then set `child.term` so that a final
/// `child.wait()` only runs `cleanupStreams()` — no double-wait.
fn waitWithTimeoutWindows(child: *std.process.Child, timeout_ns: u64) !std.process.Child.Term {
    const windows = std.os.windows;
    const timeout_ms: windows.DWORD = @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(windows.DWORD)));

    // Wait for the process to exit or timeout.
    windows.WaitForSingleObjectEx(child.id, timeout_ms, false) catch |err| switch (err) {
        error.WaitTimeOut => {
            // Timeout — kill the child process.
            windows.TerminateProcess(child.id, 1) catch {};
            // Reap via child.wait() — the process is already dead so the
            // internal INFINITE wait returns immediately.
            _ = child.wait() catch {};
            return error.ScriptTimeout;
        },
        else => {
            // Unexpected wait error — fall back to blocking wait.
            return child.wait();
        },
    };

    // ── Success path: process exited within timeout ──────────────────
    //
    // Harvest exit code directly instead of going through child.wait()
    // which would redundantly call WaitForSingleObjectEx(INFINITE).
    var exit_code: windows.DWORD = undefined;
    const exit_term: std.process.Child.Term = if (windows.kernel32.GetExitCodeProcess(child.id, &exit_code) != 0)
        .{ .Exited = @as(u8, @truncate(exit_code)) }
    else
        .{ .Unknown = 0 };

    // Close process + thread handles (mirrors waitUnwrappedWindows).
    std.posix.close(child.id);
    std.posix.close(child.thread_handle);

    // Mark the child as terminated so child.wait() short-circuits via
    // the `if (self.term)` early-return and only runs cleanupStreams().
    child.term = @as(std.process.Child.SpawnError!std.process.Child.Term, exit_term);
    child.id = undefined;

    // Let wait() run cleanupStreams() for any remaining pipe handles.
    _ = child.wait() catch {};
    return exit_term;
}

// ── Temp-file helpers ───────────────────────────────────────────
//
// Scripts write their output to a temp file instead of stdout so that
// noisy dependency imports (which may print to stdout) do not
// contaminate the actual tool output.

/// Create a unique temp file path using the platform temp directory.
/// On Windows uses %TEMP%, on POSIX uses TMPDIR or falls back to /tmp.
fn makeTmpPath(allocator: Allocator) ![]const u8 {
    const builtin = @import("builtin");
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    const tmp_dir: []const u8 = if (comptime builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "TEMP") catch
            std.process.getEnvVarOwned(allocator, "TMP") catch
            return std.fmt.allocPrint(allocator, "C:\\Temp\\nullclaw_{s}", .{&hex})
    else
        std.process.getEnvVarOwned(allocator, "TMPDIR") catch
            try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_dir);
    const sep: []const u8 = if (comptime builtin.os.tag == .windows) "\\" else "/";
    return std.fmt.allocPrint(allocator, "{s}{s}nullclaw_{s}", .{ tmp_dir, sep, &hex });
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
        // Use a short timeout (5 s) so a broken interpreter doesn't block
        // loadScript() indefinitely.
        const term = waitWithTimeout(&child, 5 * std.time.ns_per_s) catch continue;
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

        const term = waitWithTimeout(&child, call_timeout_ns) catch |err| {
            if (err == error.ScriptTimeout) {
                log.err("script '{s}' timed out after {d}s", .{ self.script_path, call_timeout_ns / std.time.ns_per_s });
                return ToolResult.fail(try allocator.dupe(u8, "script execution timed out"));
            }
            return ToolResult.fail(try allocator.dupe(u8, "script wait failed"));
        };
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

    const term = waitWithTimeout(&child, list_timeout_ns) catch return error.ScriptListFailed;
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
        // Skip empty tool names — they would create un-callable tools.
        if (name_v.string.len == 0) {
            log.warn("script discovery: skipping tool with empty name", .{});
            continue;
        }
        const desc = if (item.object.get("description")) |d|
            (if (d == .string) d.string else "")
        else
            "";
        const params = if (item.object.get("params_json")) |p|
            (if (p == .string) p.string else "{}")
        else
            "{}";

        // Validate params_json is parseable as a JSON value.
        // We must deinit the result to free the arena allocated by parseFromSlice.
        const validation = std.json.parseFromSlice(std.json.Value, allocator, params, .{}) catch {
            log.warn("script discovery: skipping tool '{s}' with invalid params_json", .{name_v.string});
            continue;
        };
        validation.deinit();

        try out.ensureUnusedCapacity(allocator, 1);
        const name_d = try allocator.dupe(u8, name_v.string);
        errdefer allocator.free(name_d);
        const desc_d = try allocator.dupe(u8, desc);
        errdefer allocator.free(desc_d);
        const params_d = try allocator.dupe(u8, params);
        // ensureUnusedCapacity guarantees appendAssumeCapacity won't fail.
        out.appendAssumeCapacity(.{
            .name = name_d,
            .description = desc_d,
            .params_json = params_d,
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
        // Stage each dupe in a local with errdefer so partial failures
        // don't leak earlier allocations.
        const interp_d = try allocator.dupe(u8, interp);
        errdefer allocator.free(interp_d);
        const path_d = try allocator.dupe(u8, abs_path);
        errdefer allocator.free(path_d);
        const name_d = try allocator.dupe(u8, def.name);
        errdefer allocator.free(name_d);
        const desc_d = try allocator.dupe(u8, def.description);
        errdefer allocator.free(desc_d);
        const params_d = try allocator.dupe(u8, def.params_json);
        errdefer allocator.free(params_d);
        w.* = .{
            .allocator = allocator,
            .interp = interp_d,
            .script_path = path_d,
            .name_buf = name_d,
            .description_buf = desc_d,
            .params_json_buf = params_d,
        };
        try list.append(allocator, w.tool());
    }

    // Use `try` so that on OOM the errdefer at line 281 frees interp exactly
    // once.  Without `try`, the unconditional free below would double-free
    // when errdefer also fires.
    const result = try list.toOwnedSlice(allocator);
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
/// test reached the success path.
///
/// Only call this for results where `result.success == true`.  Failed results
/// may contain static string literals in `.output` / `.error_msg` that must
/// NOT be passed to allocator.free().
fn freeToolResult(allocator: Allocator, result: root.ToolResult) void {
    if (!result.success) return; // static literals — nothing to free
    allocator.free(result.output);
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
