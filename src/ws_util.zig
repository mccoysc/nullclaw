//! WebSocket client via curl subprocess or wscat.
//!
//! Fallback chain: curl (with --websocket) -> wscat (node) -> error
//! This avoids Zig 0.15 std.crypto.tls.Client bus error crashes on macOS.

const std = @import("std");
const root = @import("root.zig");

const log = std.log.scoped(.ws_util);

/// WebSocket connection state
pub const WsConnection = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdin: std.fs.File,
    stdout: std.fs.File,
    /// True if using wscat, false if using curl
    is_wscat: bool,
    /// Buffer for reading responses
    read_buf: std.ArrayListUnmanaged(u8),
    /// Track if child process has exited (can't call wait() twice)
    child_exited: bool = false,
    /// Store exit code when child exits
    child_exit_code: ?u8 = null,
};

/// Detect which WebSocket backend is available
pub const WsBackend = enum {
    curl,
    wscat,
    none,
};

/// Check if curl supports WebSocket (7.86+)
pub fn detectWsBackend(allocator: std.mem.Allocator) WsBackend {
    // Try curl --websocket first
    var child = std.process.Child.init(&.{ "curl", "--version" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        // curl not found, try wscat
        return .none;
    };
    defer {
        child.stdin = null;
        child.stdout = null;
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 8192) catch {
        return .none;
    };
    defer allocator.free(stdout);

    // Check curl version for WebSocket support
    // curl 7.86+ has WebSocket support via --websocket flag
    if (std.mem.containsAtLeast(u8, stdout, 1, "curl")) {
        // Parse version - look for 7.86 or higher
        const version_start = std.mem.indexOf(u8, stdout, "curl ") orelse return .none;
        const version_str = stdout[version_start + 5 ..];
        const version_end = std.mem.indexOfAny(u8, version_str, " (") orelse version_str.len;
        const version_part = version_str[0..@min(version_end, 10)];

        // Parse version number
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

        // curl 7.86+ supports WebSocket
        if (major > 7 or (major == 7 and minor >= 86)) {
            log.info("WS backend: curl {d}.{d}.{d} supports WebSocket", .{ major, minor, patch });
            return .curl;
        }

        log.info("WS backend: curl {d}.{d}.{d} does not support WebSocket (need 7.86+)", .{ major, minor, patch });
    }

    // Fall back to wscat
    return .none;
}

/// Detect if wscat is available
fn detectWscat(allocator: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "wscat", "--version" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        return false;
    };
    defer {
        child.stdin = null;
        child.stdout = null;
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024) catch {
        return false;
    };
    defer allocator.free(stdout);

    // wscat outputs version info
    return stdout.len > 0;
}

/// Ensure wscat is installed (requires node/npm)
pub fn ensureWscatInstalled(allocator: std.mem.Allocator) !void {
    // First check if node/npm are available
    var node_child = std.process.Child.init(&.{ "node", "--version" }, allocator);
    node_child.stdout_behavior = .Pipe;
    node_child.stderr_behavior = .Ignore;

    node_child.spawn() catch {
        return error.NodeNotFound;
    };
    defer {
        node_child.stdin = null;
        node_child.stdout = null;
        _ = node_child.kill() catch {};
        _ = node_child.wait() catch {};
    }

    const node_output = node_child.stdout.?.readToEndAlloc(allocator, 64) catch {
        return error.NodeNotFound;
    };
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

/// Connect to a WebSocket server using curl or wscat
pub fn wsConnect(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !*WsConnection {
    const backend = detectWsBackend(allocator);
    switch (backend) {
        .curl => return wsConnectCurl(allocator, url, extra_headers),
        .wscat => return wsConnectWscat(allocator, url, extra_headers),
        .none => return error.NoWsBackendAvailable,
    }
}

/// Connect using curl (WebSocket support added in 7.86)
fn wsConnectCurl(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !*WsConnection {
    // curl --websocket -N <url>
    // -N = no buffer (like curl -N for SSE)
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

    // Add extra headers
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

    const conn = try allocator.create(WsConnection);
    conn.* = .{
        .allocator = allocator,
        .child = child,
        .stdin = child.stdin.?,
        .stdout = child.stdout.?,
        .is_wscat = false,
        .read_buf = .empty,
    };

    return conn;
}

/// Connect using wscat
fn wsConnectWscat(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !*WsConnection {
    // wscat -c <url>
    // Note: wscat doesn't support custom headers easily, so we pass auth via URL if needed
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "wscat";
    argc += 1;
    argv_buf[argc] = "-c";
    argc += 1;

    // Note: wscat has limited header support, but we can try
    // For Lark, the auth is typically in the URL path
    if (extra_headers.len > 0) {
        argv_buf[argc] = "-H";
        argc += 1;
        // Join headers with comma (wscat accepts multiple -H)
        var header_buf: std.ArrayList(u8) = .empty;
        defer header_buf.deinit(allocator);
        for (extra_headers, 0..) |hdr, i| {
            if (i > 0) try header_buf.appendSlice(allocator, ", ");
            try header_buf.appendSlice(allocator, hdr);
        }
        argv_buf[argc] = try header_buf.toOwnedSlice(allocator);
        argc += 1;
    }

    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const conn = try allocator.create(WsConnection);
    errdefer allocator.destroy(conn);

    conn.* = .{
        .allocator = allocator,
        .child = child,
        .stdin = child.stdin.?,
        .stdout = child.stdout.?,
        .is_wscat = true,
        .read_buf = .empty,
    };

    // For wscat, we need to wait a bit for connection
    // Give it time to establish the WebSocket connection
    std.Thread.sleep(500 * std.time.ns_per_ms);

    return conn;
}

/// Send a text message over WebSocket
pub fn wsSend(conn: *WsConnection, message: []const u8) !void {
    if (conn.is_wscat) {
        // wscat expects raw text on stdin, newline-terminated
        try conn.stdin.writeAll(message);
        try conn.stdin.writeAll("\n");
    } else {
        // curl --websocket sends raw WebSocket frames
        // For text messages, we need to send properly framed data
        // This is a simplified version - curl's --websocket handles framing
        try conn.stdin.writeAll(message);
        try conn.stdin.writeAll("\n");
    }
}

/// Check if child process is still running
/// Returns false if the process has exited (normally or crashed)
/// This function is safe to call multiple times - it tracks exit state internally
pub fn wsIsConnected(conn: *WsConnection) bool {
    if (conn.child_exited) {
        return false;
    }

    // Use kill(0) to check if process is still alive
    // This doesn't actually send a signal, just checks if the process exists
    const pid = conn.child.id;
    const is_windows = @import("builtin").os.tag == .windows;
    if (is_windows) {
        // On Windows, we can't easily check without waiting
        // Return true and rely on pipe errors to detect disconnection
        return true;
    }

    // On Unix, kill(pid, 0) checks if process exists without sending signal
    // Using std.posix.kill for POSIX systems
    std.posix.kill(pid, 0) catch {
        // Process doesn't exist or we can't signal it
        conn.child_exited = true;
        // Try to reap the exit status
        _ = conn.child.wait() catch {};
        log.info("WS: child process is no longer running", .{});
        return false;
    };
    // If we get here, kill succeeded - process is running
    return true;
}

/// Read a message from WebSocket (blocking)
/// Returns allocated string, caller must free
/// Returns null if connection is closed or process exited
pub fn wsRecv(conn: *WsConnection, timeout_ms: u32) !?[]u8 {
    _ = timeout_ms; // Note: current implementation is blocking; timeout not yet implemented

    // Check if child process has exited before attempting read
    if (!wsIsConnected(conn)) {
        log.info("WS: child process not running, returning null", .{});
        return null;
    }

    // Use readToEndAlloc for simplicity - this reads until EOF
    // For WebSocket, we need to read from the pipe continuously
    // Since curl/wscat outputs line by line, we use a reasonable buffer
    const output = conn.stdout.readToEndAlloc(conn.allocator, 4096) catch |err| {
        if (err == error.EndOfStream) {
            // Connection closed by remote or process exited
            log.info("WS: connection closed (EOF)", .{});
            return null;
        }
        if (err == error.BrokenPipe or err == error.NotOpenForReading) {
            // Process may have crashed or pipe broken
            log.warn("WS: pipe broken, process may have exited: {}", .{err});
            return null;
        }
        return err;
    };

    if (output.len == 0) {
        return null;
    }

    return output;
}

/// Validate Lark WebSocket message content
/// Returns true if the message appears to be valid Lark WebSocket JSON
/// Valid messages should have "header" object with "event_type" field,
/// or be a ping/pong/ack control message
pub fn validateLarkMessage(payload: []const u8) bool {
    // Must start with { for JSON object
    if (payload.len == 0 or payload[0] != '{') {
        return false;
    }

    // Quick check for JSON structure - look for required fields
    // Lark messages have: header.event_type OR type (ping/pong/uuid)
    const has_header = std.mem.indexOf(u8, payload, "\"header\"") != null;
    const has_type = std.mem.indexOf(u8, payload, "\"type\"") != null;
    const has_uuid = std.mem.indexOf(u8, payload, "\"uuid\"") != null;

    // Valid if has header (event message) or type (control message) or uuid (ack)
    return has_header or has_type or has_uuid;
}

/// Close the WebSocket connection
pub fn wsClose(conn: *WsConnection) void {
    conn.stdin.close();
    conn.stdout.close();

    // Send close signal to wscat
    if (conn.is_wscat) {
        // Send Ctrl+C equivalent
        conn.child.stdin = null;
    }

    _ = conn.child.kill() catch {};
    _ = conn.child.wait() catch {};

    conn.read_buf.deinit(conn.allocator);
    conn.allocator.destroy(conn);
}
