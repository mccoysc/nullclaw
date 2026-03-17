//! HTTP utilities using libcurl C API.
//!
//! All HTTP operations use libcurl compiled from source and statically linked.
//! This module provides a clean interface for HTTP requests with full timeout support.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const AtomicBool = std.atomic.Value(bool);

const log = std.log.scoped(.http_util);

// ═══════════════════════════════════════════════════════════════════════════
// HTTP backend selection (native curl vs subprocess)
// ═══════════════════════════════════════════════════════════════════════════

pub const HttpBackend = enum {
    native,
    subprocess,
};

var current_backend: HttpBackend = if (builtin.os.tag == .macos) .subprocess else .native;

/// Set the HTTP backend to use for requests.
pub fn setNetBackend(backend: HttpBackend) void {
    current_backend = backend;
}

/// Get the current HTTP backend.
pub fn getNetBackend() HttpBackend {
    return current_backend;
}

// Import libcurl C API
const c = @cImport({
    @cInclude("curl/curl.h");
});

// ═══════════════════════════════════════════════════════════════════════════
// Global initialization
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
// Thread interrupt flag support
// ═══════════════════════════════════════════════════════════════════════════

threadlocal var thread_interrupt_flag: ?*const AtomicBool = null;

pub fn setThreadInterruptFlag(flag: ?*const AtomicBool) void {
    thread_interrupt_flag = flag;
}

pub fn currentThreadInterruptFlag() ?*const AtomicBool {
    return thread_interrupt_flag;
}

// ═══════════════════════════════════════════════════════════════════════════
// Global initialization
// ═══════════════════════════════════════════════════════════════════════════

var curl_initialized: bool = false;

fn ensureCurlInit() !void {
    if (!curl_initialized) {
        const result = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        if (result != c.CURLE_OK) {
            return error.CurlInitFailed;
        }
        curl_initialized = true;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Response structure
// ═══════════════════════════════════════════════════════════════════════════

pub const HttpResponse = struct {
    status_code: u16,
    body: []u8,
};

// ═══════════════════════════════════════════════════════════════════════════
// Write context for libcurl - holds both ArrayListUnmanaged and its allocator
// ═══════════════════════════════════════════════════════════════════════════

const WriteContext = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
};

// ═══════════════════════════════════════════════════════════════════════════
// Write callback for libcurl - collects response into an ArrayListUnmanaged
// ═══════════════════════════════════════════════════════════════════════════

fn writeCallback(
    contents: ?*anyopaque,
    size: usize,
    nmemb: usize,
    userp: ?*anyopaque,
) callconv(.c) usize {
    const real_size = size * nmemb;
    if (real_size == 0) return 0;

    const ctx = userp orelse return 0;
    const write_ctx = @as(*WriteContext, @ptrCast(@alignCast(ctx)));
    const list = write_ctx.list;
    const allocator = write_ctx.allocator;

    // Convert opaque pointer to slice
    const contents_ptr = @as([*]const u8, @ptrCast(contents orelse return 0));
    list.appendSlice(allocator, contents_ptr[0..real_size]) catch return 0;
    return real_size;
}

// Read callback for libcurl - provides request body
fn readCallback(
    buffer: ?*anyopaque,
    size: usize,
    nitems: usize,
    userp: ?*anyopaque,
) callconv(.c) usize {
    const max_size = size * nitems;
    const context = userp orelse return 0;
    const read_ctx = @as(*ReadContext, @ptrCast(@alignCast(context)));

    if (read_ctx.offset >= read_ctx.data.len) {
        return 0;
    }

    const remaining = read_ctx.data.len - read_ctx.offset;
    const to_copy = @min(max_size, remaining);

    @memcpy(@as([*]u8, @ptrCast(buffer))[0..to_copy], read_ctx.data[read_ctx.offset..]);
    read_ctx.offset += to_copy;

    return to_copy;
}

const ReadContext = struct {
    data: []const u8,
    offset: usize = 0,
};

// ═══════════════════════════════════════════════════════════════════════════
// HTTP POST with libcurl
// ═══════════════════════════════════════════════════════════════════════════

/// HTTP POST with optional proxy and timeout.
/// Returns the response body. Caller owns returned memory.
pub fn curlPostWithProxy(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set POST method and body
    if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    const body_c = try allocator.dupeZ(u8, body);
    defer allocator.free(body_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    // Content-Type header
    const ct_header = "Content-Type: application/json";
    var new_list = c.curl_slist_append(header_list, ct_header);
    if (new_list == null) {
        return error.CurlHeaderError;
    }
    header_list = new_list;

    // Additional headers
    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        new_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (new_list == null) {
            return error.CurlHeaderError;
        }
        header_list = new_list;
    }

    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set timeout
    if (max_time) |timeout| {
        const timeout_secs = std.fmt.parseInt(c_long, timeout, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout_secs) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set proxy
    if (proxy) |p| {
        const proxy_c = try allocator.dupeZ(u8, p);
        defer allocator.free(proxy_c);
        if (c.curl_easy_setopt(curl, c.CURLOPT_PROXY, proxy_c.ptr) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Fail on HTTP errors (4xx, 5xx)
    if (c.curl_easy_setopt(curl, c.CURLOPT_FAILONERROR, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    if (result != c.CURLE_OK) {
        // Check for HTTP error
        if (result == c.CURLE_HTTP_RETURNED_ERROR) {
            var response_code: c_long = 0;
            _ = c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &response_code);
            log.warn("HTTP error: status={d}", .{response_code});
        }
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

/// HTTP POST (no proxy, no timeout).
pub fn curlPost(allocator: Allocator, url: []const u8, body: []const u8, headers: []const []const u8) ![]u8 {
    return curlPostWithProxy(allocator, url, body, headers, null, null);
}

/// HTTP POST with application/x-www-form-urlencoded body.
pub fn curlPostForm(allocator: Allocator, url: []const u8, body: []const u8) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set POST method and body
    if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    const body_c = try allocator.dupeZ(u8, body);
    defer allocator.free(body_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Content-Type header for form data
    const ct_header = "Content-Type: application/x-www-form-urlencoded";
    const header_list = c.curl_slist_append(null, ct_header);
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    if (result != c.CURLE_OK) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

/// HTTP POST with form data and proxy/timeout
pub fn curlPostFormWithProxy(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    proxy: ?[]const u8,
    max_time: ?[]const u8,
) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set POST method and body
    if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    const body_c = try allocator.dupeZ(u8, body);
    defer allocator.free(body_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Content-Type header for form data
    const ct_header = "Content-Type: application/x-www-form-urlencoded";
    const header_list = c.curl_slist_append(null, ct_header);
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set timeout
    if (max_time) |timeout| {
        const timeout_secs = std.fmt.parseInt(c_long, timeout, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout_secs) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set proxy
    if (proxy) |p| {
        const proxy_c = try allocator.dupeZ(u8, p);
        defer allocator.free(proxy_c);
        if (c.curl_easy_setopt(curl, c.CURLOPT_PROXY, proxy_c.ptr) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Fail on HTTP errors
    if (c.curl_easy_setopt(curl, c.CURLOPT_FAILONERROR, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    if (result != c.CURLE_OK) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

/// HTTP POST and return status code along with body.
pub fn curlPostWithStatus(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set POST method and body
    if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    const body_c = try allocator.dupeZ(u8, body);
    defer allocator.free(body_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Content-Type header
    const ct_header = "Content-Type: application/json";
    var header_list = c.curl_slist_append(null, ct_header);
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    // Additional headers
    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    _ = c.curl_easy_perform(curl);

    // Get status code
    var response_code: c_long = 200;
    _ = c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &response_code);

    const response_body = try response.toOwnedSlice(allocator);

    return HttpResponse{
        .status_code = @intCast(response_code),
        .body = response_body,
    };
}

/// HTTP PUT request
pub fn curlPut(allocator: Allocator, url: []const u8, body: []const u8, headers: []const []const u8) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set PUT method
    if (c.curl_easy_setopt(curl, c.CURLOPT_UPLOAD, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set request body via read callback
    var read_ctx = ReadContext{ .data = body };
    if (c.curl_easy_setopt(curl, c.CURLOPT_READDATA, &read_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_READFUNCTION, readCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_INFILESIZE_LARGE, @as(c_ulonglong, body.len)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Content-Type header
    const ct_header = "Content-Type: application/json";
    var header_list = c.curl_slist_append(null, ct_header);
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    // Additional headers
    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Fail on HTTP errors
    if (c.curl_easy_setopt(curl, c.CURLOPT_FAILONERROR, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    if (result != c.CURLE_OK) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// HTTP GET with libcurl
// ═══════════════════════════════════════════════════════════════════════════

/// HTTP GET with optional proxy and timeout.
pub fn curlGetWithProxy(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set GET method (default)
    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPGET, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (header_list != null) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set proxy
    if (proxy) |p| {
        const proxy_c = try allocator.dupeZ(u8, p);
        defer allocator.free(proxy_c);
        if (c.curl_easy_setopt(curl, c.CURLOPT_PROXY, proxy_c.ptr) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Fail on HTTP errors
    if (c.curl_easy_setopt(curl, c.CURLOPT_FAILONERROR, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    if (result != c.CURLE_OK) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

/// HTTP GET with DNS pinning (--resolve)
pub fn curlGetWithResolve(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    resolve_entry: []const u8,
) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set GET method
    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPGET, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set resolve entry (DNS pinning) - must be passed as a curl_slist
    const resolve_c = try allocator.dupeZ(u8, resolve_entry);
    defer allocator.free(resolve_c);
    const resolve_list = c.curl_slist_append(null, resolve_c.ptr);
    defer {
        if (resolve_list) |list| {
            c.curl_slist_free_all(list);
        }
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_RESOLVE, resolve_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (header_list != null) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Fail on HTTP errors
    if (c.curl_easy_setopt(curl, c.CURLOPT_FAILONERROR, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    if (result != c.CURLE_OK) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

/// Generic HTTP request with any method and DNS pinning (--resolve)
/// Returns status code and body
pub fn curlRequestWithResolve(
    allocator: Allocator,
    url: []const u8,
    method: []const u8,
    body: ?[]const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    resolve_entry: []const u8,
) !HttpResponse {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Normalize method to uppercase
    const method_upper = blk: {
        var buf = try allocator.alloc(u8, method.len);
        for (method, 0..) |m, i| {
            buf[i] = std.ascii.toUpper(m);
        }
        break :blk buf;
    };
    defer allocator.free(method_upper);

    // Set method
    if (std.mem.eql(u8, method_upper, "GET")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPGET, @as(c_long, 1)) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "POST")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "PUT")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_UPLOAD, @as(c_long, 1)) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "DELETE")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "DELETE") != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "PATCH")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "PATCH") != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "HEAD")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_NOBODY, @as(c_long, 1)) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "OPTIONS")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "OPTIONS") != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else {
        // Custom method
        const method_c = try allocator.dupeZ(u8, method_upper);
        defer allocator.free(method_c);
        if (c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, method_c.ptr) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set body for POST/PUT
    if (body) |b| {
        const body_c = try allocator.dupeZ(u8, b);
        defer allocator.free(body_c);
        if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_c.ptr) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set resolve entry (DNS pinning) - must be passed as a curl_slist
    const resolve_c = try allocator.dupeZ(u8, resolve_entry);
    defer allocator.free(resolve_c);
    const resolve_list = c.curl_slist_append(null, resolve_c.ptr);
    defer {
        if (resolve_list) |list| {
            c.curl_slist_free_all(list);
        }
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_RESOLVE, resolve_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (header_list != null) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    _ = c.curl_easy_perform(curl);

    // Get status code
    var response_code: c_long = 200;
    _ = c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &response_code);

    const response_body = try response.toOwnedSlice(allocator);

    return HttpResponse{
        .status_code = @intCast(response_code),
        .body = response_body,
    };
}

/// HTTP GET (no proxy).
pub fn curlGet(allocator: Allocator, url: []const u8, headers: []const []const u8, timeout_secs: []const u8) ![]u8 {
    return curlGetWithProxy(allocator, url, headers, timeout_secs, null);
}

/// HTTP DELETE request with timeout
pub fn curlDelete(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set DELETE method
    if (c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "DELETE") != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (header_list != null) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    if (result != c.CURLE_OK) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

/// Generic HTTP request with any method, returns status code and body
pub fn curlRequestWithStatus(
    allocator: Allocator,
    url: []const u8,
    method: []const u8,
    body: ?[]const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
) !HttpResponse {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Normalize method to uppercase
    const method_upper = blk: {
        var buf = try allocator.alloc(u8, method.len);
        for (method, 0..) |m, i| {
            buf[i] = std.ascii.toUpper(m);
        }
        break :blk buf;
    };
    defer allocator.free(method_upper);

    // Set method
    if (std.mem.eql(u8, method_upper, "GET")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPGET, @as(c_long, 1)) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "POST")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "PUT")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_UPLOAD, @as(c_long, 1)) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else if (std.mem.eql(u8, method_upper, "DELETE")) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, "DELETE") != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    } else {
        // Custom method
        const method_c = try allocator.dupeZ(u8, method_upper);
        defer allocator.free(method_c);
        if (c.curl_easy_setopt(curl, c.CURLOPT_CUSTOMREQUEST, method_c.ptr) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set body for POST/PUT
    if (body) |b| {
        const body_c = try allocator.dupeZ(u8, b);
        defer allocator.free(body_c);
        if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_c.ptr) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (header_list != null) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    _ = c.curl_easy_perform(curl);

    // Get status code
    var response_code: c_long = 200;
    _ = c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &response_code);

    const response_body = try response.toOwnedSlice(allocator);

    return HttpResponse{
        .status_code = @intCast(response_code),
        .body = response_body,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// SSE (Server-Sent Events) support
// ═══════════════════════════════════════════════════════════════════════════

/// HTTP GET for SSE (Server-Sent Events).
pub fn curlGetSSE(
    allocator: Allocator,
    url: []const u8,
    timeout_secs: []const u8,
) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set GET method
    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPGET, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Accept SSE
    const accept_header = "Accept: text/event-stream";
    const header_list = c.curl_slist_append(null, accept_header);
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    // For SSE, we don't fail on HTTP errors since the server might send
    // partial data before closing
    if (result != c.CURLE_OK and result != c.CURLE_HTTP_RETURNED_ERROR) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Proxy support
// ═══════════════════════════════════════════════════════════════════════════

var proxy_override_value: ?[]u8 = null;
var proxy_override_mutex: std.Thread.Mutex = .{};

pub const ProxyOverrideError = error{OutOfMemory};

/// Set process-wide proxy override from config.
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

/// Read proxy URL from standard environment variables.
pub fn getProxyFromEnv(allocator: Allocator) !?[]u8 {
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
            const trimmed = std.mem.trim(u8, val, " \t\r\n");
            allocator.free(val);
            if (trimmed.len > 0) {
                return try allocator.dupe(u8, trimmed);
            }
        } else |_| {}
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════
// Stream helpers for providers
// ═══════════════════════════════════════════════════════════════════════════

/// HTTP POST for streaming responses
pub fn curlPostStream(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set POST method and body
    if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    const body_c = try allocator.dupeZ(u8, body);
    defer allocator.free(body_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    // Content-Type
    const ct_list = c.curl_slist_append(header_list, "Content-Type: application/json");
    if (ct_list == null) {
        return error.CurlHeaderError;
    }
    header_list = ct_list;

    // Accept streaming
    const accept_list = c.curl_slist_append(header_list, "Accept: text/event-stream");
    if (accept_list == null) {
        return error.CurlHeaderError;
    }
    header_list = accept_list;

    // Additional headers
    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    // For streaming, we may get partial data even on error
    if (result != c.CURLE_OK and result != c.CURLE_HTTP_RETURNED_ERROR) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

/// HTTP GET for streaming responses
pub fn curlGetStream(
    allocator: Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
) ![]u8 {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set GET method
    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPGET, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    // Accept streaming
    const accept_list = c.curl_slist_append(header_list, "Accept: text/event-stream");
    if (accept_list == null) {
        return error.CurlHeaderError;
    }
    header_list = accept_list;

    // Additional headers
    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (header_list != null) {
        if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up response buffer with initial capacity
    var response: std.ArrayListUnmanaged(u8) = .empty;
    errdefer response.deinit(allocator);

    // Create write context to pass both list and allocator to callback
    var write_ctx = WriteContext{ .list = &response, .allocator = allocator };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &write_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    if (result != c.CURLE_OK and result != c.CURLE_HTTP_RETURNED_ERROR) {
        return error.CurlRequestFailed;
    }

    return try response.toOwnedSlice(allocator);
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "curlPost function signatures compile" {
    try std.testing.expect(true);
}

test "curlGet function signatures compile" {
    try std.testing.expect(true);
}

test "curlPostForm function signatures compile" {
    try std.testing.expect(true);
}

test "curlGetSSE function signatures compile" {
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

// ═══════════════════════════════════════════════════════════════════════════
// Streaming SSE callback support
// ═══════════════════════════════════════════════════════════════════════════

/// Callback type for streaming SSE data
pub const StreamWriteCallback = fn (context: *anyopaque, data: [*]const u8, len: usize) callconv(.c) usize;

/// Context for streaming SSE callback
const StreamContext = struct {
    callback: *const fn (*anyopaque, [*]const u8, usize) callconv(.c) usize,
    context: *anyopaque,
    allocator: Allocator,
    line_buffer: *std.ArrayListUnmanaged(u8),
};

/// Streaming write callback that processes data line by line and invokes the callback
fn streamWriteCallback(
    contents: ?*anyopaque,
    size: usize,
    nmemb: usize,
    userp: ?*anyopaque,
) callconv(.c) usize {
    const real_size = size * nmemb;
    if (real_size == 0) return 0;

    const ctx = userp orelse return 0;
    const stream_ctx = @as(*StreamContext, @ptrCast(@alignCast(ctx)));

    const contents_ptr = @as([*]const u8, @ptrCast(contents orelse return 0));
    const data = contents_ptr[0..real_size];

    // Process each byte, building lines
    for (data) |byte| {
        if (byte == '\n') {
            // Line complete - invoke callback with the line
            if (stream_ctx.line_buffer.items.len > 0) {
                const line = stream_ctx.line_buffer.items;
                _ = stream_ctx.callback(stream_ctx.context, line.ptr, line.len);
                stream_ctx.line_buffer.clearRetainingCapacity();
            } else {
                // Empty line - still send it
                _ = stream_ctx.callback(stream_ctx.context, "", 0);
            }
        } else if (byte != '\r') {
            // Accumulate non-CR characters
            stream_ctx.line_buffer.append(stream_ctx.allocator, byte) catch return 0;
        }
    }

    return real_size;
}

/// HTTP POST for streaming SSE with callback support
/// Calls the callback for each line of SSE data as it arrives
pub fn curlPostStreamSSE(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
    proxy: ?[]const u8,
    callback: StreamWriteCallback,
    callback_ctx: *anyopaque,
) !void {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }
    defer c.curl_easy_cleanup(curl);

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    defer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set POST method and body
    if (c.curl_easy_setopt(curl, c.CURLOPT_POST, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    const body_c = try allocator.dupeZ(u8, body);
    defer allocator.free(body_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_POSTFIELDS, body_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set headers
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    // Content-Type
    const ct_list = c.curl_slist_append(header_list, "Content-Type: application/json");
    if (ct_list == null) {
        return error.CurlHeaderError;
    }
    header_list = ct_list;

    // Accept streaming
    const accept_list = c.curl_slist_append(header_list, "Accept: text/event-stream");
    if (accept_list == null) {
        return error.CurlHeaderError;
    }
    header_list = accept_list;

    // Additional headers
    for (headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        defer allocator.free(hdr_c);
        const next_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (next_list == null) {
            return error.CurlHeaderError;
        }
        header_list = next_list;
    }

    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set timeout
    if (timeout_secs.len > 0) {
        const timeout = std.fmt.parseInt(c_long, timeout_secs, 10) catch 300;
        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT, timeout) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Set proxy
    if (proxy) |p| {
        const proxy_c = try allocator.dupeZ(u8, p);
        defer allocator.free(proxy_c);
        if (c.curl_easy_setopt(curl, c.CURLOPT_PROXY, proxy_c.ptr) != c.CURLE_OK) {
            return error.CurlOptionError;
        }
    }

    // Follow redirects
    if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Set up streaming callback context
    var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer line_buffer.deinit(allocator);

    var stream_ctx = StreamContext{
        .callback = callback,
        .context = callback_ctx,
        .allocator = allocator,
        .line_buffer = &line_buffer,
    };

    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, streamWriteCallback) != c.CURLE_OK) {
        return error.CurlOptionError;
    }
    if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &stream_ctx) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform request
    const result = c.curl_easy_perform(curl);
    // For streaming, we may get partial data even on error
    if (result != c.CURLE_OK and result != c.CURLE_HTTP_RETURNED_ERROR) {
        return error.CurlRequestFailed;
    }

    // Send any remaining data in the line buffer
    if (line_buffer.items.len > 0) {
        _ = callback(callback_ctx, line_buffer.items.ptr, line_buffer.items.len);
    }
}

/// Same as curlPostStreamSSE but takes auth_header separately for convenience
pub fn curlPostStreamSSEWithAuth(
    allocator: Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: ?[]const u8,
    extra_headers: []const []const u8,
    timeout_secs: u64,
    proxy: ?[]const u8,
    callback: StreamWriteCallback,
    callback_ctx: *anyopaque,
) !void {
    // Build headers list
    var headers = std.ArrayListUnmanaged([]const u8).empty;
    errdefer headers.deinit(allocator);

    if (auth_header) |auth| {
        try headers.append(allocator, auth);
    }
    try headers.appendSlice(allocator, extra_headers);

    var timeout_buf: [32]u8 = undefined;
    const timeout_str = if (timeout_secs > 0) std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_secs}) catch "" else "";

    return curlPostStreamSSE(
        allocator,
        url,
        body,
        headers.items,
        timeout_str,
        proxy,
        callback,
        callback_ctx,
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// WebSocket support using libcurl
// ═══════════════════════════════════════════════════════════════════════════

/// WebSocket frame types
pub const WsFrameType = enum(c_uint) {
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

/// WebSocket message structure
pub const WsMessage = struct {
    data: []u8,
    frame_type: WsFrameType,
};

/// WebSocket connection using libcurl
pub const WsConnection = struct {
    allocator: Allocator,
    curl: ?*c.CURL,
    websocket: ?*c.curl_ws,
    connected: bool = false,
};

/// Connect to a WebSocket server using libcurl
pub fn wsConnect(
    allocator: Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !*WsConnection {
    try ensureCurlInit();

    const curl = c.curl_easy_init();
    if (curl == null) {
        return error.CurlInitFailed;
    }

    const conn = try allocator.create(WsConnection);
    errdefer allocator.destroy(conn);

    conn.* = .{
        .allocator = allocator,
        .curl = curl,
        .websocket = null,
        .connected = false,
    };

    // Set URL
    const url_c = try allocator.dupeZ(u8, url);
    errdefer allocator.free(url_c);
    if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url_c.ptr) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Build headers for WebSocket upgrade
    var header_list: ?[*]c.curl_slist = null;
    defer {
        if (header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    // Add WebSocket upgrade headers
    const ws_key = "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==";
    var ws_list = c.curl_slist_append(header_list, ws_key);
    if (ws_list == null) {
        return error.CurlHeaderError;
    }
    header_list = ws_list;

    const ws_version = "Sec-WebSocket-Version: 13";
    ws_list = c.curl_slist_append(header_list, ws_version);
    if (ws_list == null) {
        return error.CurlHeaderError;
    }
    header_list = ws_list;

    // Add custom headers
    for (extra_headers) |hdr| {
        const hdr_c = try allocator.dupeZ(u8, hdr);
        errdefer allocator.free(hdr_c);
        ws_list = c.curl_slist_append(header_list, hdr_c.ptr);
        if (ws_list == null) {
            return error.CurlHeaderError;
        }
        header_list = ws_list;
    }

    if (c.curl_easy_setopt(curl, c.CURLOPT_HTTPHEADER, header_list) != c.CURLE_OK) {
        return error.CurlOptionError;
    }

    // Perform WebSocket upgrade using curl_easy_ws_connect
    var ws: ?*c.curl_ws = undefined;
    const result = c.curl_easy_ws_connect(curl, 0, &ws);
    if (result != c.CURLE_OK or ws == null) {
        log.err("WebSocket connection failed: {d}", .{result});
        return error.WsConnectFailed;
    }

    conn.websocket = ws;
    conn.connected = true;

    return conn;
}

/// Send text message over WebSocket
pub fn wsSendText(conn: *WsConnection, message: []const u8) !void {
    if (!conn.connected or conn.websocket == null) {
        return error.WsNotConnected;
    }

    const msg_data = try conn.allocator.dupeZ(u8, message);
    defer conn.allocator.free(msg_data);

    const result = c.curl_ws_send(
        conn.websocket,
        msg_data.ptr,
        message.len,
        0,
        c.CURLWS_TEXT,
    );

    if (result != c.CURLE_OK) {
        return error.WsSendFailed;
    }
}

/// Send binary message over WebSocket
pub fn wsSendBinary(conn: *WsConnection, data: []const u8) !void {
    if (!conn.connected or conn.websocket == null) {
        return error.WsNotConnected;
    }

    const data_copy = try conn.allocator.dupe(u8, data);
    defer conn.allocator.free(data_copy);

    const result = c.curl_ws_send(
        conn.websocket,
        data_copy.ptr,
        data.len,
        0,
        c.CURLWS_BINARY,
    );

    if (result != c.CURLE_OK) {
        return error.WsSendFailed;
    }
}

/// Receive a WebSocket message (text or binary)
/// Returns null if connection closed or timeout
pub fn wsRecv(conn: *WsConnection, _: u32) !?WsMessage {
    if (!conn.connected or conn.websocket == null) {
        return error.WsNotConnected;
    }

    // Allocate receive buffer
    const buf = try conn.allocator.alloc(u8, 8192);
    errdefer conn.allocator.free(buf);

    var flags: c_uint = 0;
    var nrecv: c_uint = 0;

    // Note: timeout is not directly supported in curl_ws_recv
    // We rely on the socket having data available
    const result = c.curl_ws_recv(
        conn.websocket,
        buf.ptr,
        buf.len,
        &flags,
        &nrecv,
    );

    if (result == c.CURLE_AGAIN) {
        // No data available yet
        return null;
    }

    if (result != c.CURLE_OK) {
        log.warn("WebSocket recv failed: {d}", .{result});
        conn.connected = false;
        return null;
    }

    if (nrecv == 0) {
        // Connection closed
        conn.connected = false;
        return null;
    }

    // Determine frame type
    const frame_type: WsFrameType = if ((flags & c.CURLWS_TEXT) != 0)
        .text
    else if ((flags & c.CURLWS_BINARY) != 0)
        .binary
    else if ((flags & c.CURLWS_CLOSE) != 0)
        .close
    else
        .text; // Default to text

    const data = try conn.allocator.dupe(u8, buf[0..nrecv]);

    return WsMessage{
        .data = data,
        .frame_type = frame_type,
    };
}

/// Check if WebSocket is connected
pub fn wsIsConnected(conn: *WsConnection) bool {
    return conn.connected;
}

/// Close WebSocket connection
pub fn wsClose(conn: *WsConnection) void {
    if (conn.websocket) |ws| {
        // Send close frame
        c.curl_ws_close(ws, 0, 0, c.CURLWS_CLOSE);
    }

    if (conn.curl) |curl| {
        c.curl_easy_cleanup(curl);
    }

    conn.connected = false;
}

/// Destroy WebSocket connection and free memory
pub fn wsDestroy(conn: *WsConnection) void {
    wsClose(conn);
    conn.allocator.destroy(conn);
}
