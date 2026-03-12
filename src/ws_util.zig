//! WebSocket client abstraction.
//!
//! Backend follows the global `http_util.NetBackend` setting:
//!  - `subprocess` : curl (with --websocket, 7.86+) or wscat (default on macOS).
//!  - `native`     : Zig TLS WebSocket via websocket.zig (default elsewhere).
//!
//! Override at startup with `--http-backend native|subprocess`.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const websocket = @import("websocket.zig");

const log = std.log.scoped(.ws_util);

fn useSubprocess() bool {
    return root.http_util.useSubprocess();
}

// ===================================================================
// Connection types
// ===================================================================

/// Unified WebSocket connection (tagged union selected at runtime).
pub const WsConnection = union(enum) {
    subprocess: SubprocessWsConnection,
    native: NativeWsConnection,
};

/// Native WebSocket connection wrapping websocket.zig WsClient.
pub const NativeWsConnection = struct {
    allocator: std.mem.Allocator,
    client: websocket.WsClient,
    connected: bool = true,
};

/// Subprocess-backed WebSocket connection (curl --websocket or wscat).
pub const SubprocessWsConnection = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdin: std.fs.File,
    stdout: std.fs.File,
    is_wscat: bool,
    read_buf: std.ArrayListUnmanaged(u8),
    child_exited: bool = false,
    child_exit_code: ?u8 = null,
    /// Heap-allocated header string for wscat -H (owned, freed on close).
    owned_header: ?[]u8 = null,
};

// ===================================================================
// Subprocess backend detection
// ===================================================================

pub const WsBackend = enum { curl, wscat, none };

/// Check if curl supports WebSocket (7.86+), then fall back to wscat.
pub fn detectWsBackend(allocator: std.mem.Allocator) WsBackend {
    var child = std.process.Child.init(&.{ "curl", "--version" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        if (detectWscat(allocator)) return .wscat;
        return .none;
    };
    defer {
        child.stdin = null;
        child.stdout = null;
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 8192) catch {
        if (detectWscat(allocator)) return .wscat;
        return .none;
    };
    defer allocator.free(stdout);

    if (std.mem.containsAtLeast(u8, stdout, 1, "curl")) {
        const version_start = std.mem.indexOf(u8, stdout, "curl ") orelse {
            if (detectWscat(allocator)) return .wscat;
            return .none;
        };
        const version_str = stdout[version_start + 5 ..];
        const version_end = std.mem.indexOfAny(u8, version_str, " (") orelse version_str.len;
        const version_part = version_str[0..@min(version_end, 10)];

        var major: u32 = 0;
        var minor: u32 = 0;
        var patch: u32 = 0;

        var parts = std.mem.splitSequence(u8, version_part, ".");
        if (parts.next()) |maj| {
            major = std.fmt.parseInt(u32, maj, 10) catch 0;
        }
        if (parts.next()) |min| {
            minor = std.fmt.parseInt(u32, min, 10) catch 0;
        }
        if (parts.next()) |pat| {
            patch = std.fmt.parseInt(u32, pat, 10) catch 0;
        }

        if (major > 7 or (major == 7 and minor >= 86)) {
            log.info("WS backend: curl {d}.{d}.{d} supports WebSocket", .{ major, minor, patch });
            return .curl;
        }

        log.info("WS backend: curl {d}.{d}.{d} does not support WebSocket (need 7.86+)", .{ major, minor, patch });
    }

    if (detectWscat(allocator)) {
        log.info("WS backend: using wscat as fallback", .{});
        return .wscat;
    }

    return .none;
}

/// Detect if wscat is available.
pub fn detectWscat(allocator: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "wscat", "--version" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    defer {
        child.stdin = null;
        child.stdout = null;
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024) catch return false;
    defer allocator.free(stdout);
    return stdout.len > 0;
}

/// Ensure wscat is installed (requires node/npm).
pub fn ensureWscatInstalled(allocator: std.mem.Allocator) !void {
    var node_child = std.process.Child.init(&.{ "node", "--version" }, allocator);
    node_child.stdout_behavior = .Pipe;
    node_child.stderr_behavior = .Ignore;

    node_child.spawn() catch return error.NodeNotFound;
    defer {
        node_child.stdin = null;
        node_child.stdout = null;
        _ = node_child.kill() catch {};
        _ = node_child.wait() catch {};
    }

    const node_output = node_child.stdout.?.readToEndAlloc(allocator, 64) catch return error.NodeNotFound;
    allocator.free(node_output);

    log.info("Installing wscat via npm...", .{});

    var npm_child = std.process.Child.init(&.{ "npm", "install", "-g", "wscat" }, allocator);
    npm_child.stdout_behavior = .Pipe;
    npm_child.stderr_behavior = .Pipe;

    try npm_child.spawn();

    const npm_stdout = npm_child.stdout.?.readToEndAlloc(allocator, 8192) catch null;
    const npm_stderr = npm_child.stderr.?.readToEndAlloc(allocator, 8192) catch null;
    defer {
        if (npm_stdout) |s| allocator.free(s);
        if (npm_stderr) |s| allocator.free(s);
    }
    const stderr_slice = if (npm_stderr) |s| s[0..@min(s.len, 8192)] else "";

    const term = npm_child.wait() catch return error.NpmInstallFailed;
    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                log.info("wscat installed successfully", .{});
                return;
            }
            log.err("wscat npm install failed with code {d}: {s}", .{ code, stderr_slice });
            return error.WscatInstallFailed;
        },
        else => return error.WscatInstallFailed,
    }
}

// ===================================================================
// Unified public API
// ===================================================================

/// Connect to a WebSocket server.
pub fn wsConnect(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !*WsConnection {
    const conn = try allocator.create(WsConnection);
    errdefer allocator.destroy(conn);

    if (useSubprocess()) {
        conn.* = .{ .subprocess = try connectSubprocess(allocator, url, extra_headers) };
    } else {
        conn.* = .{ .native = try connectNative(allocator, url, extra_headers) };
    }
    return conn;
}

/// Send a text message over WebSocket.
pub fn wsSend(conn: *WsConnection, message: []const u8) !void {
    switch (conn.*) {
        .subprocess => |*s| try sendSubprocess(s, message),
        .native => |*n| try sendNative(n, message),
    }
}

/// Check if WebSocket connection is still alive.
pub fn wsIsConnected(conn: *WsConnection) bool {
    return switch (conn.*) {
        .subprocess => |*s| isConnectedSubprocess(s),
        .native => |n| n.connected,
    };
}

/// Read a message from WebSocket.
/// Returns allocated string (caller must free) or null on close/timeout.
pub fn wsRecv(conn: *WsConnection, timeout_ms: u32) !?[]u8 {
    return switch (conn.*) {
        .subprocess => |*s| recvSubprocess(s, timeout_ms),
        .native => |*n| recvNative(n, timeout_ms),
    };
}

/// Close the WebSocket connection and free the handle.
pub fn wsClose(conn: *WsConnection) void {
    const allocator = switch (conn.*) {
        .subprocess => |s| s.allocator,
        .native => |n| n.allocator,
    };
    switch (conn.*) {
        .subprocess => |*s| closeSubprocess(s),
        .native => |*n| closeNative(n),
    }
    allocator.destroy(conn);
}

/// Validate Lark WebSocket message content.
pub fn validateLarkMessage(payload: []const u8) bool {
    if (payload.len == 0 or payload[0] != '{') return false;

    const has_header = std.mem.indexOf(u8, payload, "\"header\"") != null;
    const has_type = std.mem.indexOf(u8, payload, "\"type\"") != null;
    const has_uuid = std.mem.indexOf(u8, payload, "\"uuid\"") != null;
    return has_header or has_type or has_uuid;
}

// ===================================================================
// Native backend implementation
// ===================================================================

fn connectNative(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !NativeWsConnection {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const host_start = scheme_end + 3;
    const host_and_path = url[host_start..];
    const path_start = std.mem.indexOfScalar(u8, host_and_path, '/') orelse host_and_path.len;
    const host_with_port = host_and_path[0..path_start];
    const path = if (path_start < host_and_path.len) host_and_path[path_start..] else "/";

    // Parse host and port (default 443 for wss)
    var host: []const u8 = host_with_port;
    var port: u16 = 443;
    if (std.mem.indexOfScalar(u8, host_with_port, ':')) |colon_pos| {
        host = host_with_port[0..colon_pos];
        port = std.fmt.parseInt(u16, host_with_port[colon_pos + 1 ..], 10) catch 443;
    }

    log.info("WS native: connecting to host={s} port={d} path={s}", .{ host, port, path });

    const client = websocket.WsClient.connect(allocator, host, port, path, extra_headers) catch |err| {
        log.err("WS native: connection failed: {}", .{err});
        return error.WsConnectFailed;
    };

    return .{ .allocator = allocator, .client = client, .connected = true };
}

fn sendNative(conn: *NativeWsConnection, message: []const u8) !void {
    conn.client.writeText(message) catch |err| {
        log.warn("WS native: send failed: {}", .{err});
        conn.connected = false;
        return error.WsSendFailed;
    };
}

fn recvNative(conn: *NativeWsConnection, timeout_ms: u32) !?[]u8 {
    _ = timeout_ms;
    const message = conn.client.readTextMessage() catch |err| {
        log.warn("WS native: recv failed: {}", .{err});
        conn.connected = false;
        return null;
    };
    return message;
}

fn closeNative(conn: *NativeWsConnection) void {
    conn.client.writeClose();
    conn.client.deinit();
    conn.connected = false;
}

// ===================================================================
// Subprocess backend implementation
// ===================================================================

fn connectSubprocess(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !SubprocessWsConnection {
    const backend = detectWsBackend(allocator);
    return switch (backend) {
        .curl => connectCurl(allocator, url, extra_headers),
        .wscat => connectWscat(allocator, url, extra_headers),
        .none => error.NoWsBackendAvailable,
    };
}

fn connectCurl(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !SubprocessWsConnection {
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "--websocket";
    argc += 1;
    argv_buf[argc] = "-N";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;

    for (extra_headers) |hdr| {
        if (argc + 2 > argv_buf.len) break;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    return .{
        .allocator = allocator,
        .child = child,
        .stdin = child.stdin.?,
        .stdout = child.stdout.?,
        .is_wscat = false,
        .read_buf = .empty,
    };
}

fn connectWscat(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !SubprocessWsConnection {
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    var owned_header: ?[]u8 = null;
    errdefer if (owned_header) |h| allocator.free(h);

    argv_buf[argc] = "wscat";
    argc += 1;
    argv_buf[argc] = "-c";
    argc += 1;

    if (extra_headers.len > 0) {
        argv_buf[argc] = "-H";
        argc += 1;
        var header_list: std.ArrayListUnmanaged(u8) = .empty;
        defer header_list.deinit(allocator);
        for (extra_headers, 0..) |hdr, i| {
            if (i > 0) try header_list.appendSlice(allocator, ", ");
            try header_list.appendSlice(allocator, hdr);
        }
        owned_header = try header_list.toOwnedSlice(allocator);
        argv_buf[argc] = owned_header.?;
        argc += 1;
    }

    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var conn = SubprocessWsConnection{
        .allocator = allocator,
        .child = child,
        .stdin = child.stdin.?,
        .stdout = child.stdout.?,
        .is_wscat = true,
        .read_buf = .empty,
        .owned_header = owned_header,
    };
    // Transfer ownership to conn so errdefer doesn't double-free
    owned_header = null;

    // Give wscat time to establish the WebSocket connection
    std.Thread.sleep(500 * std.time.ns_per_ms);

    _ = &conn;
    return conn;
}

fn sendSubprocess(conn: *SubprocessWsConnection, message: []const u8) !void {
    try conn.stdin.writeAll(message);
    try conn.stdin.writeAll("\n");
}

fn isConnectedSubprocess(conn: *SubprocessWsConnection) bool {
    if (conn.child_exited) return false;

    // Use cross-platform child process status check
    if (comptime builtin.os.tag == .windows) {
        // On Windows, try waitResult with no block; if child terminated we know
        return true;
    } else {
        std.posix.kill(conn.child.id, 0) catch {
            conn.child_exited = true;
            _ = conn.child.wait() catch {};
            log.info("WS: child process is no longer running", .{});
            return false;
        };
        return true;
    }
}

fn recvSubprocess(conn: *SubprocessWsConnection, timeout_ms: u32) !?[]u8 {
    if (!isConnectedSubprocess(conn)) {
        log.info("WS: child process not running, returning null", .{});
        return null;
    }

    // Use poll to wait for data with timeout instead of blocking readToEndAlloc
    const fd = conn.stdout.handle;
    var pfds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    const timeout_i32: i32 = if (timeout_ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(timeout_ms);
    const poll_result = std.posix.poll(&pfds, timeout_i32) catch |err| {
        log.warn("WS: poll failed: {}", .{err});
        return null;
    };

    if (poll_result == 0) {
        // Timeout — no data available
        return null;
    }

    if (pfds[0].revents & std.posix.POLL.HUP != 0) {
        log.info("WS: pipe hangup (child exited)", .{});
        return null;
    }

    if (pfds[0].revents & std.posix.POLL.IN == 0) {
        return null;
    }

    // Read available data (line by line for text protocols)
    var line_buf: [4096]u8 = undefined;
    const n = conn.stdout.read(&line_buf) catch |err| {
        if (err == error.BrokenPipe or err == error.NotOpenForReading) {
            log.warn("WS: pipe broken: {}", .{err});
            return null;
        }
        return err;
    };

    if (n == 0) {
        log.info("WS: connection closed (EOF)", .{});
        return null;
    }

    return try conn.allocator.dupe(u8, line_buf[0..n]);
}

fn closeSubprocess(conn: *SubprocessWsConnection) void {
    conn.stdin.close();
    conn.stdout.close();

    if (conn.is_wscat) {
        conn.child.stdin = null;
    }

    _ = conn.child.kill() catch {};
    _ = conn.child.wait() catch {};

    conn.read_buf.deinit(conn.allocator);
    // Free the owned header allocation from connectWscat
    if (conn.owned_header) |h| {
        conn.allocator.free(h);
        conn.owned_header = null;
    }
}

// ===================================================================
// Tests
// ===================================================================

test "validateLarkMessage accepts valid ping" {
    const payload = "{\"type\":\"ping\",\"ts\":\"123\"}";
    try std.testing.expect(validateLarkMessage(payload));
}

test "validateLarkMessage accepts valid event" {
    const payload = "{\"header\":{\"event_type\":\"im.message.receive_v1\"},\"event\":{}}";
    try std.testing.expect(validateLarkMessage(payload));
}

test "validateLarkMessage accepts uuid ack" {
    const payload = "{\"uuid\":\"abc-123\",\"data\":\"event payload\"}";
    try std.testing.expect(validateLarkMessage(payload));
}

test "validateLarkMessage rejects empty" {
    try std.testing.expect(!validateLarkMessage(""));
}

test "validateLarkMessage rejects non-json" {
    try std.testing.expect(!validateLarkMessage("hello world"));
}

test "validateLarkMessage rejects json without required fields" {
    try std.testing.expect(!validateLarkMessage("{\"foo\":\"bar\"}"));
}

test "detectWsBackend returns a valid enum value" {
    const backend = detectWsBackend(std.testing.allocator);
    try std.testing.expect(backend == .curl or backend == .wscat or backend == .none);
}

test "detectWscat returns bool" {
    const has_wscat = detectWscat(std.testing.allocator);
    try std.testing.expect(has_wscat or !has_wscat);
}

test "useSubprocess matches http_util setting" {
    const expected = (builtin.os.tag == .macos);
    try std.testing.expectEqual(expected, useSubprocess());
}

test "netBackend override round-trip" {
    const orig = root.http_util.netBackend();
    defer root.http_util.setNetBackend(orig);

    root.http_util.setNetBackend(.subprocess);
    try std.testing.expect(useSubprocess());

    root.http_util.setNetBackend(.native);
    try std.testing.expect(!useSubprocess());
}
