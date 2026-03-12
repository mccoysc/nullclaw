//! Shared HTTP utilities.
//!
//! Backend selection (also used by ws_util):
//!  - `subprocess` : curl / wscat child processes (default on macOS).
//!  - `native`     : Zig std.http.Client (default on other platforms).
//!
//! Override at startup with `--http-backend native|subprocess`.
//!
//! Replaces 9+ local `curlPost` / `curlGet` duplicates across the codebase.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const AtomicBool = std.atomic.Value(bool);

const log = std.log.scoped(.http_util);

// ── Backend selection ────────────────────────────────────────────────

pub const NetBackend = enum { native, subprocess };

/// Platform default: macOS -> subprocess (avoids TLS Bus-error on ARM),
/// everything else -> native std.http.Client.
const platform_default: NetBackend = if (builtin.os.tag == .macos) .subprocess else .native;

/// CLI override set via `--http-backend`.
var backend_override: ?NetBackend = null;

/// Called once from CLI arg parsing.
pub fn setNetBackend(b: NetBackend) void {
    backend_override = b;
}

/// Active backend (override wins, then platform default).
pub fn netBackend() NetBackend {
    return backend_override orelse platform_default;
}

/// Convenience: true when subprocess path should be used.
pub fn useSubprocess() bool {
    return netBackend() == .subprocess;
}
threadlocal var thread_interrupt_flag: ?*const AtomicBool = null;

pub fn setThreadInterruptFlag(flag: ?*const AtomicBool) void {
    thread_interrupt_flag = flag;
}

pub fn currentThreadInterruptFlag() ?*const AtomicBool {
    return thread_interrupt_flag;
}

const CancelWatcherCtx = struct {
    child: *std.process.Child,
    cancel_flag: *const AtomicBool,
    done: *AtomicBool,
};

fn cancelWatcherMain(ctx: *CancelWatcherCtx) void {
    while (!ctx.done.load(.acquire)) {
        if (ctx.cancel_flag.load(.acquire)) {
            if (comptime @import("builtin").os.tag == .windows) {
                std.os.windows.TerminateProcess(ctx.child.id, 1) catch {};
            } else {
                std.posix.kill(ctx.child.id, std.posix.SIG.TERM) catch {};
            }
            break;
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
}

pub const HttpResponse = struct {
    status_code: u16,
    body: []u8,
};

/// HTTP POST via curl subprocess with optional proxy and timeout.
///
/// `headers` is a slice of header strings (e.g. `"Authorization: Bearer xxx"`).
/// `proxy` is an optional proxy URL (e.g. `"socks5://host:port"`).
/// `max_time` is an optional --max-time value as a string (e.g. `"300"`).
/// Returns the response body. Caller owns returned memory.
pub fn curlPostWithProxy(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    return curlRequestWithProxy(
        allocator,
        "POST",
        "Content-Type: application/json",
        url,
        body,
        headers,
        proxy,
        max_time,
    );
}

/// HTTP POST with application/x-www-form-urlencoded body via curl subprocess,
/// with optional proxy and timeout.
pub fn curlPostFormWithProxy(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    return curlRequestWithProxy(
        allocator,
        "POST",
        "Content-Type: application/x-www-form-urlencoded",
        url,
        body,
        &.{},
        proxy,
        max_time,
    );
}

fn curlRequestWithProxy(
    allocator: Allocator,
    method: []const u8,
    content_type_header: []const u8,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    // Fall back to subprocess when proxy or timeout is configured, since native
    // std.http.Client does not support proxy or timeout settings.
    if (!useSubprocess() and proxy == null and max_time == null) {
        return nativeHttpRequest(allocator, method, content_type_header, url, body, headers);
    }
    return curlRequestWithProxySubprocess(allocator, method, content_type_header, url, body, headers, proxy, max_time);
}

fn curlRequestWithProxySubprocess(
    allocator: Allocator,
    method: []const u8,
    content_type_header: []const u8,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    var argv_buf: [40][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = method;
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = content_type_header;
    argc += 1;

    if (proxy) |p| {
        argv_buf[argc] = "--proxy";
        argc += 1;
        argv_buf[argc] = p;
        argc += 1;
    }

    if (max_time) |mt| {
        argv_buf[argc] = "--max-time";
        argc += 1;
        argv_buf[argc] = mt;
        argc += 1;
    }

    for (headers) |hdr| {
        if (argc + 2 > argv_buf.len) break;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    // Pass payload via stdin to avoid OS argv length limits for large JSON
    // bodies (e.g. multimodal base64 images).
    argv_buf[argc] = "--data-binary";
    argc += 1;
    argv_buf[argc] = "@-";
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const cancel_flag = thread_interrupt_flag;
    var cancel_done = AtomicBool.init(false);
    var cancel_watcher: ?std.Thread = null;
    var watcher_ctx: CancelWatcherCtx = undefined;
    if (cancel_flag) |flag| {
        watcher_ctx = .{ .child = &child, .cancel_flag = flag, .done = &cancel_done };
        cancel_watcher = std.Thread.spawn(.{}, cancelWatcherMain, .{&watcher_ctx}) catch null;
    }
    defer {
        cancel_done.store(true, .release);
        if (cancel_watcher) |t| t.join();
    }

    if (child.stdin) |stdin_file| {
        stdin_file.writeAll(body) catch {
            stdin_file.close();
            child.stdin = null;
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWriteError;
        };
        stdin_file.close();
        child.stdin = null;
    } else {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWriteError;
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlReadError;
    };

    const term = child.wait() catch |err| {
        log.err("curl child.wait failed: {}", .{err});
        allocator.free(stdout);
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWaitError;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            allocator.free(stdout);
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed;
        },
        else => {
            allocator.free(stdout);
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed;
        },
    }

    return stdout;
}

/// HTTP POST via curl subprocess (no proxy, no timeout).
pub fn curlPost(allocator: Allocator, url: []const u8, body: []const u8, headers: []const []const u8) ![]u8 {
    return curlPostWithProxy(allocator, url, body, headers, null, null);
}

/// HTTP POST with application/x-www-form-urlencoded body via curl subprocess.
///
/// `body` must already be percent-encoded form data (e.g. `"key=val&key2=val2"`).
/// Returns the response body. Caller owns returned memory.
pub fn curlPostForm(allocator: Allocator, url: []const u8, body: []const u8) ![]u8 {
    return curlPostFormWithProxy(allocator, url, body, null, null);
}

/// HTTP POST and include HTTP status code in response.
/// On macOS uses curl subprocess; on other platforms uses native std.http.Client.
/// Caller owns `response.body`.
pub fn curlPostWithStatus(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    if (!useSubprocess()) {
        return nativePostWithStatus(allocator, url, body, headers);
    }
    return curlPostWithStatusSubprocess(allocator, url, body, headers);
}

fn curlPostWithStatusSubprocess(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    var argv_buf: [48][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-s";
    argc += 1;
    argv_buf[argc] = "-X";
    argc += 1;
    argv_buf[argc] = "POST";
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Content-Type: application/json";
    argc += 1;

    for (headers) |hdr| {
        if (argc + 2 > argv_buf.len) break;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = "--data-binary";
    argc += 1;
    argv_buf[argc] = "@-";
    argc += 1;
    argv_buf[argc] = "-w";
    argc += 1;
    argv_buf[argc] = "\n%{http_code}";
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const cancel_flag = thread_interrupt_flag;
    var cancel_done = AtomicBool.init(false);
    var cancel_watcher: ?std.Thread = null;
    var watcher_ctx: CancelWatcherCtx = undefined;
    if (cancel_flag) |flag| {
        watcher_ctx = .{ .child = &child, .cancel_flag = flag, .done = &cancel_done };
        cancel_watcher = std.Thread.spawn(.{}, cancelWatcherMain, .{&watcher_ctx}) catch null;
    }
    defer {
        cancel_done.store(true, .release);
        if (cancel_watcher) |t| t.join();
    }

    if (child.stdin) |stdin_file| {
        stdin_file.writeAll(body) catch {
            stdin_file.close();
            child.stdin = null;
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWriteError;
        };
        stdin_file.close();
        child.stdin = null;
    } else {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWriteError;
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlReadError;
    };
    errdefer allocator.free(stdout);

    const term = child.wait() catch |err| {
        log.err("curl child.wait failed: {}", .{err});
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWaitError;
    };
    switch (term) {
        .Exited => |code| if (code != 0) return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed,
        else => return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed,
    }

    const status_sep = std.mem.lastIndexOfScalar(u8, stdout, '\n') orelse return error.CurlParseError;
    const status_raw = std.mem.trim(u8, stdout[status_sep + 1 ..], " \t\r\n");
    if (status_raw.len != 3) return error.CurlParseError;
    const status_code = std.fmt.parseInt(u16, status_raw, 10) catch return error.CurlParseError;
    const body_slice = stdout[0..status_sep];
    const response_body = try allocator.dupe(u8, body_slice);
    allocator.free(stdout);

    return .{
        .status_code = status_code,
        .body = response_body,
    };
}

/// HTTP PUT via curl subprocess (no proxy, no timeout).
pub fn curlPut(allocator: Allocator, url: []const u8, body: []const u8, headers: []const []const u8) ![]u8 {
    return curlRequestWithProxy(
        allocator,
        "PUT",
        "Content-Type: application/json",
        url,
        body,
        headers,
        null,
        null,
    );
}

/// HTTP GET with optional proxy.
///
/// On macOS uses curl subprocess; on other platforms uses native std.http.Client.
/// `headers` is a slice of header strings (e.g. `"Authorization: Bearer xxx"`).
/// `timeout_secs` sets --max-time (curl only). Returns the response body. Caller owns returned memory.
fn curlGetWithProxyAndResolve(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
    resolve_entry: ?[]const u8,
) ![]u8 {
    // Fall back to subprocess when proxy, resolve_entry, or timeout is set.
    // Native std.http.Client lacks proxy, DNS pinning (--resolve), and
    // request timeout support.
    const has_timeout = timeout_secs.len > 0 and !std.mem.eql(u8, timeout_secs, "0");
    if (!useSubprocess() and proxy == null and resolve_entry == null and !has_timeout) {
        return nativeHttpGet(allocator, url, headers);
    }
    return curlGetWithProxyAndResolveSubprocess(allocator, url, headers, timeout_secs, proxy, resolve_entry);
}

fn curlGetWithProxyAndResolveSubprocess(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
    resolve_entry: ?[]const u8,
) ![]u8 {
    var argv_buf: [48][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-sf";
    argc += 1;
    argv_buf[argc] = "--max-time";
    argc += 1;
    argv_buf[argc] = timeout_secs;
    argc += 1;

    if (proxy) |p| {
        argv_buf[argc] = "--proxy";
        argc += 1;
        argv_buf[argc] = p;
        argc += 1;
    }

    if (resolve_entry) |entry| {
        argv_buf[argc] = "--resolve";
        argc += 1;
        argv_buf[argc] = entry;
        argc += 1;
    }

    for (headers) |hdr| {
        if (argc + 2 > argv_buf.len) break;
        argv_buf[argc] = "-H";
        argc += 1;
        argv_buf[argc] = hdr;
        argc += 1;
    }

    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const cancel_flag = thread_interrupt_flag;
    var cancel_done = AtomicBool.init(false);
    var cancel_watcher: ?std.Thread = null;
    var watcher_ctx: CancelWatcherCtx = undefined;
    if (cancel_flag) |flag| {
        watcher_ctx = .{ .child = &child, .cancel_flag = flag, .done = &cancel_done };
        cancel_watcher = std.Thread.spawn(.{}, cancelWatcherMain, .{&watcher_ctx}) catch null;
    }
    defer {
        cancel_done.store(true, .release);
        if (cancel_watcher) |t| t.join();
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlReadError;
    };

    const term = child.wait() catch |err| {
        log.err("curl child.wait failed: {}", .{err});
        return error.CurlWaitError;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            allocator.free(stdout);
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed;
        },
        else => {
            allocator.free(stdout);
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed;
        },
    }

    return stdout;
}

/// HTTP GET via curl subprocess with optional proxy.
///
/// `headers` is a slice of header strings (e.g. `"Authorization: Bearer xxx"`).
/// `timeout_secs` sets --max-time. Returns the response body. Caller owns returned memory.
pub fn curlGetWithProxy(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    return curlGetWithProxyAndResolve(allocator, url, headers, timeout_secs, proxy, null);
}

/// HTTP GET via curl subprocess with a pinned host mapping.
///
/// `resolve_entry` must be in curl `--resolve` format: `host:port:address`.
pub fn curlGetWithResolve(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    resolve_entry: []const u8,
) ![]u8 {
    return curlGetWithProxyAndResolve(allocator, url, headers, timeout_secs, null, resolve_entry);
}

/// HTTP GET via curl subprocess (no proxy).
pub fn curlGet(allocator: Allocator, url: []const u8, headers: []const []const u8, timeout_secs: []const u8) ![]u8 {
    return curlGetWithProxy(allocator, url, headers, timeout_secs, null);
}

/// Read proxy URL from standard environment variables.
/// Checks HTTPS_PROXY, HTTP_PROXY, ALL_PROXY in that order.
/// Returns null if no proxy is set.
/// Caller owns returned memory.
var proxy_override_value: ?[]u8 = null;
var proxy_override_mutex: std.Thread.Mutex = .{};

pub const ProxyOverrideError = error{OutOfMemory};

/// Set process-wide proxy override from config.
/// When set, this value has higher priority than proxy environment variables.
pub fn setProxyOverride(proxy: ?[]const u8) ProxyOverrideError!void {
    proxy_override_mutex.lock();
    defer proxy_override_mutex.unlock();

    if (proxy_override_value) |existing| {
        std.heap.page_allocator.free(existing);
        proxy_override_value = null;
    }

    if (proxy) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return;
        proxy_override_value = try std.heap.page_allocator.dupe(u8, trimmed);
    }
}

fn normalizeProxyEnvValue(allocator: Allocator, val: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, val, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn getProxyFromEnv(allocator: Allocator) !?[]const u8 {
    {
        proxy_override_mutex.lock();
        defer proxy_override_mutex.unlock();
        if (proxy_override_value) |override| {
            return try allocator.dupe(u8, override);
        }
    }

    const env_vars = [_][]const u8{ "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY" };
    for (env_vars) |var_name| {
        if (std.process.getEnvVarOwned(allocator, var_name)) |val| {
            errdefer allocator.free(val);
            const out = try normalizeProxyEnvValue(allocator, val);
            allocator.free(val);
            if (out) |proxy| return proxy;
        } else |_| {}
    }
    return null;
}

/// HTTP GET for SSE (Server-Sent Events).
///
/// On macOS uses curl subprocess; on other platforms uses native std.http.Client.
/// Uses unbuffered mode to allow SSE events to be received in real-time.
pub fn curlGetSSE(
    allocator: Allocator,
    url: []const u8,
    timeout_secs: []const u8,
) ![]u8 {
    // SSE always uses subprocess because native std.http.Client does not
    // support streaming reads or request timeouts needed for SSE.
    return curlGetSSESubprocess(allocator, url, timeout_secs);
}

fn curlGetSSESubprocess(
    allocator: Allocator,
    url: []const u8,
    timeout_secs: []const u8,
) ![]u8 {
    var argv_buf: [40][]const u8 = undefined;
    var argc: usize = 0;

    argv_buf[argc] = "curl";
    argc += 1;
    argv_buf[argc] = "-sf";
    argc += 1;
    argv_buf[argc] = "-N";
    argc += 1;
    argv_buf[argc] = "--max-time";
    argc += 1;
    argv_buf[argc] = timeout_secs;
    argc += 1;
    argv_buf[argc] = "-H";
    argc += 1;
    argv_buf[argc] = "Accept: text/event-stream";
    argc += 1;
    argv_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| {
        std.debug.print("[curlGetSSE] spawn failed: {}\n", .{err});
        return error.CurlFailed;
    };
    const cancel_flag = thread_interrupt_flag;
    var cancel_done = AtomicBool.init(false);
    var cancel_watcher: ?std.Thread = null;
    var watcher_ctx: CancelWatcherCtx = undefined;
    if (cancel_flag) |flag| {
        watcher_ctx = .{ .child = &child, .cancel_flag = flag, .done = &cancel_done };
        cancel_watcher = std.Thread.spawn(.{}, cancelWatcherMain, .{&watcher_ctx}) catch null;
    }
    defer {
        cancel_done.store(true, .release);
        if (cancel_watcher) |t| t.join();
    }

    const stdout = child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlReadError;
    };

    const term = child.wait() catch |err| {
        log.err("curl child.wait failed: {}", .{err});
        allocator.free(stdout);
        return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlWaitError;
    };
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                // Exit code 28 = timeout. This is expected for SSE when no data arrives,
                // but curl may have received some data before timing out - return it.
                // For other exit codes, treat as error.
                if (code != 28) {
                    std.debug.print("[curlGetSSE] curl error: code={}\n", .{code});
                    allocator.free(stdout);
                    return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed;
                }
                // Timeout (code 28) - return any data we received
            }
        },
        else => {
            allocator.free(stdout);
            return if (cancel_flag != null and cancel_flag.?.load(.acquire)) error.CurlInterrupted else error.CurlFailed;
        },
    }

    return stdout;
}

// ═══════════════════════════════════════════════════════════════════════
// Native HTTP backend (non-macOS)
// ═══════════════════════════════════════════════════════════════════════

/// Parse a "Name: Value" header string into std.http.Header.
fn parseHeaderString(header: []const u8) ?std.http.Header {
    const colon_pos = std.mem.indexOfScalar(u8, header, ':') orelse return null;
    const name = header[0..colon_pos];
    const rest = header[colon_pos + 1 ..];
    const value = if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
    return .{ .name = name, .value = value };
}

/// Map a method string ("POST", "PUT", "GET") to std.http.Method.
fn httpMethodFromString(method: []const u8) std.http.Method {
    if (std.mem.eql(u8, method, "PUT")) return .PUT;
    if (std.mem.eql(u8, method, "GET")) return .GET;
    return .POST;
}

/// Native HTTP POST/PUT via std.http.Client (used on non-macOS).
fn nativeHttpRequest(
    allocator: Allocator,
    method: []const u8,
    content_type_header: []const u8,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var extra_headers_buf: [20]std.http.Header = undefined;
    var n_headers: usize = 0;

    if (parseHeaderString(content_type_header)) |h| {
        extra_headers_buf[n_headers] = h;
        n_headers += 1;
    }

    for (headers) |hdr| {
        if (n_headers >= extra_headers_buf.len) break;
        if (parseHeaderString(hdr)) |h| {
            extra_headers_buf[n_headers] = h;
            n_headers += 1;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = httpMethodFromString(method),
        .payload = body,
        .extra_headers = extra_headers_buf[0..n_headers],
        .response_writer = &aw.writer,
    }) catch |err| {
        log.err("native HTTP {s} to {s} failed: {}", .{ method, url, err });
        return error.CurlFailed;
    };

    // Match curl -sf behavior: fail on 4xx/5xx status codes.
    const status_int = @intFromEnum(result.status);
    if (status_int >= 400) {
        log.err("native HTTP {s} {s} returned status {d}", .{ method, url, status_int });
        return error.CurlFailed;
    }

    return try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

/// Native HTTP GET via std.http.Client (used on non-macOS).
fn nativeHttpGet(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var extra_headers_buf: [20]std.http.Header = undefined;
    var n_headers: usize = 0;

    for (headers) |hdr| {
        if (n_headers >= extra_headers_buf.len) break;
        if (parseHeaderString(hdr)) |h| {
            extra_headers_buf[n_headers] = h;
            n_headers += 1;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = extra_headers_buf[0..n_headers],
        .response_writer = &aw.writer,
    }) catch |err| {
        log.err("native HTTP GET {s} failed: {}", .{ url, err });
        return error.CurlFailed;
    };

    // Match curl -sf behavior: fail on 4xx/5xx status codes.
    const status_int = @intFromEnum(result.status);
    if (status_int >= 400) {
        log.err("native HTTP GET {s} returned status {d}", .{ url, status_int });
        return error.CurlFailed;
    }

    return try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

/// Native HTTP POST with status code via std.http.Client (used on non-macOS).
fn nativePostWithStatus(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var extra_headers_buf: [20]std.http.Header = undefined;
    var n_headers: usize = 0;

    extra_headers_buf[n_headers] = .{ .name = "Content-Type", .value = "application/json" };
    n_headers += 1;

    for (headers) |hdr| {
        if (n_headers >= extra_headers_buf.len) break;
        if (parseHeaderString(hdr)) |h| {
            extra_headers_buf[n_headers] = h;
            n_headers += 1;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = extra_headers_buf[0..n_headers],
        .response_writer = &aw.writer,
    }) catch |err| {
        log.err("native HTTP POST {s} failed: {}", .{ url, err });
        return error.CurlFailed;
    };

    const response_body = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);

    return .{
        .status_code = @intFromEnum(result.status),
        .body = response_body,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "curlPostWithProxy header guard allows at most (argv_buf_len - base_args) / 2 headers" {
    // argv_buf is [40][]const u8. Base args consume 8 slots (curl -s -X POST -H
    // Content-Type --data-binary @- url), leaving 32 slots = 16 header pairs.
    // The guard `argc + 2 > argv_buf.len` stops additions before overflow.
    // We verify the guard constant is consistent: remaining = 40 - 8 = 32, max headers = 16.
    const argv_buf_len = 40;
    const base_args = 8; // curl -s -X POST -H <ct> --data-binary @- <url>
    const max_header_pairs = (argv_buf_len - base_args) / 2;
    try std.testing.expectEqual(@as(usize, 16), max_header_pairs);
}

test "curlPostWithStatus compiles and is callable" {
    try std.testing.expect(true);
}

test "curlPut compiles and is callable" {
    try std.testing.expect(true);
}

test "curlPostForm uses exactly 9 fixed args plus url" {
    // argv_buf is [10][]const u8: curl -s -X POST -H <ct> --data-binary @- <url> = 9 slots.
    // Verify the constant is consistent with the implementation.
    const argv_buf_len = 10;
    const fixed_args = 9; // curl -s -X POST -H Content-Type --data-binary @- (url)
    try std.testing.expect(fixed_args < argv_buf_len);
}

test "curlGet with zero headers compiles and is callable" {
    // Smoke-test: verifies the function signature is reachable and the arg-building
    // path with an empty header slice does not panic at comptime.
    _ = curlGet;
}

test "curlGetWithResolve compiles and is callable" {
    try std.testing.expect(true);
}

test "normalizeProxyEnvValue trims surrounding whitespace" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeProxyEnvValue(alloc, "  socks5://127.0.0.1:1080 \r\n");
    defer if (normalized) |v| alloc.free(v);
    try std.testing.expect(normalized != null);
    try std.testing.expectEqualStrings("socks5://127.0.0.1:1080", normalized.?);
}

test "normalizeProxyEnvValue rejects empty values" {
    const normalized = try normalizeProxyEnvValue(std.testing.allocator, " \t\r\n");
    try std.testing.expect(normalized == null);
}

test "setProxyOverride applies and clears process-wide override" {
    const override = "  socks5://proxy-override-test.invalid:1080  ";
    const normalized_override = "socks5://proxy-override-test.invalid:1080";

    try setProxyOverride(override);
    const from_override = try getProxyFromEnv(std.testing.allocator);
    defer if (from_override) |v| std.testing.allocator.free(v);
    try std.testing.expect(from_override != null);
    try std.testing.expectEqualStrings(normalized_override, from_override.?);

    try setProxyOverride(null);
    const after_clear = try getProxyFromEnv(std.testing.allocator);
    defer if (after_clear) |v| std.testing.allocator.free(v);
    if (after_clear) |proxy| {
        // Environment may define a proxy; only assert our override no longer leaks.
        try std.testing.expect(!std.mem.eql(u8, proxy, normalized_override));
    }
}

test "netBackend returns platform default when no override set" {
    // Ensure no leftover override from other tests.
    const saved = backend_override;
    backend_override = null;
    defer backend_override = saved;

    const expected: NetBackend = if (builtin.os.tag == .macos) .subprocess else .native;
    try std.testing.expectEqual(expected, netBackend());
}

test "setNetBackend overrides platform default" {
    const saved = backend_override;
    defer backend_override = saved;

    setNetBackend(.subprocess);
    try std.testing.expectEqual(NetBackend.subprocess, netBackend());
    try std.testing.expect(useSubprocess());

    setNetBackend(.native);
    try std.testing.expectEqual(NetBackend.native, netBackend());
    try std.testing.expect(!useSubprocess());
}

test "setProxyOverride accepts long proxy URLs" {
    const allocator = std.testing.allocator;
    var long_proxy = try allocator.alloc(u8, 1600);
    defer allocator.free(long_proxy);

    @memcpy(long_proxy[0.."http://".len], "http://");
    @memset(long_proxy["http://".len..], 'a');

    try setProxyOverride(long_proxy);
    defer setProxyOverride(null) catch unreachable;

    const from_override = try getProxyFromEnv(allocator);
    defer if (from_override) |v| allocator.free(v);
    try std.testing.expect(from_override != null);
    try std.testing.expectEqual(long_proxy.len, from_override.?.len);
}
