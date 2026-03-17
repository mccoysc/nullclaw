const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const http_util = @import("../http_util.zig");
const error_classify = @import("error_classify.zig");
const platform = @import("../platform.zig");
const log = std.log.scoped(.provider_sse);

fn finalizeStreamResult(
    allocator: std.mem.Allocator,
    accumulated: []const u8,
    output_tokens: ?u32,
) !root.StreamChatResult {
    const content = if (accumulated.len > 0)
        try allocator.dupe(u8, accumulated)
    else
        null;

    const completion_tokens = if (output_tokens) |ot|
        (if (ot > 0) ot else @as(u32, @intCast((accumulated.len + 3) / 4)))
    else
        @as(u32, @intCast((accumulated.len + 3) / 4));

    return .{
        .content = content,
        .usage = .{ .completion_tokens = completion_tokens },
        .model = "",
    };
}

/// Read stderr pipe into an owned buffer. Returns empty slice on failure.
/// Must be called before child.wait() to avoid pipe deadlock.
fn drainStderr(allocator: std.mem.Allocator, stderr_pipe: ?std.fs.File) []const u8 {
    const stderr_file = stderr_pipe orelse return &.{};
    return stderr_file.readToEndAlloc(allocator, 4096) catch return &.{};
}

/// Log pre-read curl stderr content when the process fails.
/// Helps diagnose network errors (DNS, TLS, timeout, proxy, etc.).
fn logCurlStderr(allocator: std.mem.Allocator, stderr_content: []const u8, exit_code: ?u8) void {
    _ = allocator;
    const trimmed = std.mem.trimRight(u8, stderr_content, " \t\r\n");
    if (trimmed.len > 0) {
        log.err("curlStream failed (exit_code={?d}): {s}", .{ exit_code, trimmed });
    } else {
        log.err("curlStream failed (exit_code={?d}) stderr empty", .{exit_code});
    }
}

const CurlBodyArg = struct {
    arg: []const u8,
    temp_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    temp_path_len: usize = 0,
    uses_temp_file: bool = false,

    fn deinit(self: *const CurlBodyArg, allocator: std.mem.Allocator) void {
        if (!self.uses_temp_file) return;
        std.fs.deleteFileAbsolute(self.temp_path_buf[0..self.temp_path_len]) catch {};
        allocator.free(self.arg);
    }
};

fn prepareCurlBodyArg(
    allocator: std.mem.Allocator,
    body: []const u8,
    log_enabled: bool,
) !CurlBodyArg {
    if (builtin.os.tag != .windows) {
        return .{ .arg = body };
    }

    const debug_log = std.log.scoped(.sse);
    var prepared: CurlBodyArg = .{ .arg = body };

    const tmp_dir_path = platform.getTempDir(allocator) catch
        return error.TempDirNotFound;
    defer allocator.free(tmp_dir_path);

    // Try to open existing temp directory, create if it doesn't exist
    var tmp_dir: std.fs.Dir = undefined;
    tmp_dir = std.fs.openDirAbsolute(tmp_dir_path) catch |err| {
        if (err == error.FileNotFound) {
            // Directory doesn't exist, try to create it
            std.fs.makeDirAbsolute(tmp_dir_path) catch
                return error.TempDirNotFound;
            tmp_dir = std.fs.openDirAbsolute(tmp_dir_path) catch
                return error.TempDirNotFound;
        } else {
            return error.TempDirNotFound;
        }
    };
    defer tmp_dir.close();

    const body_path = std.fmt.bufPrint(
        &prepared.temp_path_buf,
        "{s}{s}sse_body_{d}.tmp",
        .{ tmp_dir_path, std.fs.path.sep_str, std.time.timestamp() },
    ) catch return error.PathTooLong;
    prepared.temp_path_len = body_path.len;
    errdefer std.fs.deleteFileAbsolute(prepared.temp_path_buf[0..prepared.temp_path_len]) catch {};

    var tmp_file = tmp_dir.createFile(
        body_path[tmp_dir_path.len + 1 ..],
        .{ .truncate = true, .exclusive = false },
    ) catch return error.TempFileCreateFailed;

    tmp_file.writeAll(body) catch {
        tmp_file.close();
        return error.TempFileWriteFailed;
    };
    tmp_file.close();

    if (log_enabled) {
        debug_log.info("Using temp file for curl body: {s}, body_len={d}", .{ body_path, body.len });
    }

    const verify_file = std.fs.openFileAbsolute(body_path, .{}) catch return error.TempFileCreateFailed;
    defer verify_file.close();
    const verify_stat = verify_file.stat() catch return error.TempFileCreateFailed;
    if (log_enabled) {
        debug_log.info("Temp body file size: {d} bytes", .{verify_stat.size});
    }

    for (prepared.temp_path_buf[0..prepared.temp_path_len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    prepared.arg = try std.fmt.allocPrint(allocator, "@{s}", .{prepared.temp_path_buf[0..prepared.temp_path_len]});
    errdefer allocator.free(prepared.arg);
    prepared.uses_temp_file = true;
    return prepared;
}

/// Result of parsing a single SSE line.
pub const SseLineResult = union(enum) {
    /// Text delta content (owned, caller frees).
    delta: []const u8,
    /// Stream is complete ([DONE] sentinel).
    done: void,
    /// Line should be skipped (empty, comment, or no content).
    skip: void,
};

/// Parse a single SSE line in OpenAI streaming format.
///
/// Handles:
/// - `data: [DONE]` → `.done`
/// - `data: {JSON}` → extracts `choices[0].delta.content` → `.delta`
/// - Empty lines, comments (`:`) → `.skip`
pub fn parseSseLine(allocator: std.mem.Allocator, line: []const u8) !SseLineResult {
    const trimmed = std.mem.trimRight(u8, line, "\r");

    if (trimmed.len == 0) return .skip;
    if (trimmed[0] == ':') return .skip;

    const prefix = "data: ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return .skip;

    const data = trimmed[prefix.len..];

    if (std.mem.eql(u8, data, "[DONE]")) return .done;

    const content = try extractDeltaContent(allocator, data) orelse return .skip;
    return .{ .delta = content };
}

/// Extract `choices[0].delta.content` from an SSE JSON payload.
/// Returns owned slice or null if no content found.
pub fn extractDeltaContent(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const choices = obj.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;

    const first = choices.array.items[0];
    if (first != .object) return null;

    const delta = first.object.get("delta") orelse return null;
    if (delta != .object) return null;

    const content = delta.object.get("content") orelse return null;
    if (content != .string) return null;
    if (content.string.len == 0) return null;

    return try allocator.dupe(u8, content.string);
}

/// SSE streaming via native std.http.Client (OpenAI format).
///
/// Used when `--http-backend native` is set and no proxy is configured.
/// Fetches the full response body via `client.fetch()`, then parses
/// SSE lines and fires the streaming callback for each delta.
fn nativeStream(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: ?[]const u8,
    extra_headers: []const []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var headers_buf: [20]std.http.Header = undefined;
    var n_headers: usize = 0;

    headers_buf[n_headers] = .{ .name = "Content-Type", .value = "application/json" };
    n_headers += 1;

    if (auth_header) |auth| {
        if (http_util.parseHeaderString(auth)) |h| {
            headers_buf[n_headers] = h;
            n_headers += 1;
        }
    }

    for (extra_headers) |hdr| {
        if (n_headers >= headers_buf.len) break;
        if (http_util.parseHeaderString(hdr)) |h| {
            headers_buf[n_headers] = h;
            n_headers += 1;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers_buf[0..n_headers],
        .keep_alive = false,
        .response_writer = &aw.writer,
    }) catch |err| {
        log.err("nativeStream: fetch failed for {s}: {}", .{ url, err });
        return error.CurlFailed;
    };

    const status_int = @intFromEnum(result.status);
    const response_body = aw.writer.buffer[0..aw.writer.end];

    if (status_int >= 400) {
        log.err("nativeStream: HTTP {d} from {s}", .{ status_int, url });
        // Try to classify the error from response body
        if (response_body.len > 0 and response_body[0] == '{') {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (error_classify.classifyKnownApiError(p.value.object)) |kind| {
                    return error_classify.kindToError(kind);
                }
            }
        }
        return error.ServerError;
    }

    // Parse SSE lines from the response body and fire callbacks
    return parseSseResponseBody(allocator, response_body, callback, ctx);
}

/// Parse a buffered SSE response body (OpenAI format) line by line,
/// firing the streaming callback for each delta.
fn parseSseResponseBody(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    var saw_done = false;

    for (response_body) |byte| {
        if (byte == '\n') {
            const sse_result = parseSseLine(allocator, line_buf.items) catch {
                line_buf.clearRetainingCapacity();
                continue;
            };
            line_buf.clearRetainingCapacity();
            switch (sse_result) {
                .delta => |text| {
                    defer allocator.free(text);
                    try accumulated.appendSlice(allocator, text);
                    callback(ctx, root.StreamChunk.textDelta(text));
                },
                .done => {
                    saw_done = true;
                    break;
                },
                .skip => {},
            }
        } else {
            try line_buf.append(allocator, byte);
        }
    }

    // Handle trailing line without final newline
    if (!saw_done and line_buf.items.len > 0) {
        const trailing = parseSseLine(allocator, line_buf.items) catch null;
        line_buf.clearRetainingCapacity();
        if (trailing) |trail_result| {
            switch (trail_result) {
                .delta => |text| {
                    defer allocator.free(text);
                    try accumulated.appendSlice(allocator, text);
                    callback(ctx, root.StreamChunk.textDelta(text));
                },
                .done => {},
                .skip => {},
            }
        }
    }

    callback(ctx, root.StreamChunk.finalChunk());
    return finalizeStreamResult(allocator, accumulated.items, null);
}

/// Run SSE streaming and parse output line by line (OpenAI format).
///
/// Uses libcurl for streaming with proxy/timeout support.
pub fn curlStream(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    auth_header: ?[]const u8,
    extra_headers: []const []const u8,
    timeout_secs: u64,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    // Build headers list with auth if provided
    var all_headers = std.ArrayListUnmanaged([]const u8).empty;
    errdefer all_headers.deinit(allocator);

    if (auth_header) |auth| {
        try all_headers.append(allocator, auth);
    }
    try all_headers.appendSlice(allocator, extra_headers);

    // Prepare timeout string
    var timeout_buf: [32]u8 = undefined;
    const timeout_str = if (timeout_secs > 0)
        std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_secs}) catch ""
    else
        "";

    // Use curlPostStream which uses libcurl (not curl subprocess)
    // Note: http_util.getProxyFromEnv reads from environment variables (HTTPS_PROXY, HTTP_PROXY, etc.)
    const response = http_util.curlPostStream(
        allocator,
        url,
        body,
        all_headers.items,
        timeout_str,
    ) catch |err| {
        log.err("curlStream failed: {}", .{err});
        return error.CurlFailed;
    };
    defer allocator.free(response);

    // Check if response is JSON error
    if (response.len > 0 and response[0] == '{') {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (error_classify.classifyKnownApiError(p.value.object)) |kind| {
                return error_classify.kindToError(kind);
            }
        }
        return error.ServerError;
    }

    // Parse SSE response
    return parseSseResponseBody(allocator, response, callback, ctx);
}

// ════════════════════════════════════════════════════════════════════════════
// Anthropic SSE Parsing
// ════════════════════════════════════════════════════════════════════════════

/// Result of parsing a single Anthropic SSE line.
pub const AnthropicSseResult = union(enum) {
    /// Remember this event type (caller tracks state).
    event: []const u8,
    /// Text delta content (owned, caller frees).
    delta: []const u8,
    /// Output token count from message_delta usage.
    usage: u32,
    /// Stream is complete (message_stop).
    done: void,
    /// Line should be skipped (empty, comment, or uninteresting event).
    skip: void,
};

/// Parse a single SSE line in Anthropic streaming format.
///
/// Anthropic SSE is stateful: `event:` lines set the context for subsequent `data:` lines.
/// The caller must track `current_event` across calls.
///
/// - `event: X` → `.event` (caller remembers X)
/// - `data: {JSON}` + current_event=="content_block_delta" → extracts `delta.text` → `.delta`
/// - `data: {JSON}` + current_event=="message_delta" → extracts `usage.output_tokens` → `.usage`
/// - `data: {JSON}` + current_event=="message_stop" → `.done`
/// - Everything else → `.skip`
pub fn parseAnthropicSseLine(allocator: std.mem.Allocator, line: []const u8, current_event: []const u8) !AnthropicSseResult {
    const trimmed = std.mem.trimRight(u8, line, "\r");

    if (trimmed.len == 0) return .skip;
    if (trimmed[0] == ':') return .skip;

    // Handle "event: TYPE" lines
    const event_prefix = "event: ";
    if (std.mem.startsWith(u8, trimmed, event_prefix)) {
        return .{ .event = trimmed[event_prefix.len..] };
    }

    // Handle "data: {JSON}" lines
    const data_prefix = "data: ";
    if (!std.mem.startsWith(u8, trimmed, data_prefix)) return .skip;

    const data = trimmed[data_prefix.len..];

    if (std.mem.eql(u8, current_event, "message_stop")) return .done;

    if (std.mem.eql(u8, current_event, "content_block_delta")) {
        const text = try extractAnthropicDelta(allocator, data) orelse return .skip;
        return .{ .delta = text };
    }

    if (std.mem.eql(u8, current_event, "message_delta")) {
        const tokens = try extractAnthropicUsage(data) orelse return .skip;
        return .{ .usage = tokens };
    }

    return .skip;
}

/// Extract `delta.text` from an Anthropic content_block_delta JSON payload.
/// Returns owned slice or null if not a text_delta.
pub fn extractAnthropicDelta(allocator: std.mem.Allocator, json_str: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const delta = obj.get("delta") orelse return null;
    if (delta != .object) return null;

    const dtype = delta.object.get("type") orelse return null;
    if (dtype != .string or !std.mem.eql(u8, dtype.string, "text_delta")) return null;

    const text = delta.object.get("text") orelse return null;
    if (text != .string) return null;
    if (text.string.len == 0) return null;

    return try allocator.dupe(u8, text.string);
}

/// Extract `usage.output_tokens` from an Anthropic message_delta JSON payload.
/// Returns token count or null if not present.
pub fn extractAnthropicUsage(json_str: []const u8) !?u32 {
    // Use a stack buffer for parsing to avoid needing an allocator
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.InvalidSseJson;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const usage = obj.get("usage") orelse return null;
    if (usage != .object) return null;

    const output_tokens = usage.object.get("output_tokens") orelse return null;
    if (output_tokens != .integer) return null;

    return @intCast(output_tokens.integer);
}

/// SSE streaming via native std.http.Client (Anthropic format).
///
/// Used when `--http-backend native` is set and no proxy is configured.
/// Fetches the full response body via `client.fetch()`, then parses
/// Anthropic SSE events and fires the streaming callback for each delta.
fn nativeStreamAnthropic(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var headers_buf: [20]std.http.Header = undefined;
    var n_headers: usize = 0;

    headers_buf[n_headers] = .{ .name = "Content-Type", .value = "application/json" };
    n_headers += 1;

    for (headers) |hdr| {
        if (n_headers >= headers_buf.len) break;
        if (http_util.parseHeaderString(hdr)) |h| {
            headers_buf[n_headers] = h;
            n_headers += 1;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers_buf[0..n_headers],
        .keep_alive = false,
        .response_writer = &aw.writer,
    }) catch |err| {
        log.err("nativeStreamAnthropic: fetch failed for {s}: {}", .{ url, err });
        return error.CurlFailed;
    };

    const status_int = @intFromEnum(result.status);
    const response_body = aw.writer.buffer[0..aw.writer.end];

    if (status_int >= 400) {
        log.err("nativeStreamAnthropic: HTTP {d} from {s}", .{ status_int, url });
        return error.ServerError;
    }

    // Parse Anthropic SSE lines from the response body
    return parseAnthropicSseResponseBody(allocator, response_body, callback, ctx);
}

/// Parse a buffered SSE response body (Anthropic format) line by line,
/// firing the streaming callback for each delta.
fn parseAnthropicSseResponseBody(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    var accumulated: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated.deinit(allocator);

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    var current_event: []const u8 = "";
    var output_tokens: u32 = 0;

    for (response_body) |byte| {
        if (byte == '\n') {
            const sse_result = parseAnthropicSseLine(allocator, line_buf.items, current_event) catch {
                line_buf.clearRetainingCapacity();
                continue;
            };
            switch (sse_result) {
                .event => |ev| {
                    if (current_event.len > 0) allocator.free(@constCast(current_event));
                    current_event = allocator.dupe(u8, ev) catch "";
                },
                .delta => |text| {
                    defer allocator.free(text);
                    try accumulated.appendSlice(allocator, text);
                    callback(ctx, root.StreamChunk.textDelta(text));
                },
                .usage => |tokens| output_tokens = tokens,
                .done => {
                    line_buf.clearRetainingCapacity();
                    break;
                },
                .skip => {},
            }
            line_buf.clearRetainingCapacity();
        } else {
            try line_buf.append(allocator, byte);
        }
    }

    // Free owned event string
    if (current_event.len > 0) allocator.free(@constCast(current_event));

    callback(ctx, root.StreamChunk.finalChunk());
    return finalizeStreamResult(allocator, accumulated.items, output_tokens);
}

/// Run SSE streaming for Anthropic and parse output line by line.
///
/// Uses libcurl for streaming with proxy support.
pub fn curlStreamAnthropic(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
    callback: root.StreamCallback,
    ctx: *anyopaque,
) !root.StreamChatResult {
    // Use curlPostStream which uses libcurl (not curl subprocess)
    const response = http_util.curlPostStream(
        allocator,
        url,
        body,
        headers,
        "",
    ) catch |err| {
        log.err("curlStreamAnthropic failed: {}", .{err});
        return error.CurlFailed;
    };
    defer allocator.free(response);

    // Parse Anthropic SSE response
    return parseAnthropicSseResponseBody(allocator, response, callback, ctx);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "parseSseLine valid delta" {
    const allocator = std.testing.allocator;
    const result = try parseSseLine(allocator, "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}");
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "prepareCurlBodyArg uses temp file only on Windows" {
    const allocator = std.testing.allocator;
    const body = [_]u8{'x'} ** 4096;
    var prepared = try prepareCurlBodyArg(allocator, body[0..], false);
    defer prepared.deinit(allocator);

    if (builtin.os.tag == .windows) {
        try std.testing.expect(prepared.uses_temp_file);
        try std.testing.expect(std.mem.startsWith(u8, prepared.arg, "@"));
    } else {
        try std.testing.expect(!prepared.uses_temp_file);
        try std.testing.expectEqualStrings(body[0..], prepared.arg);
    }
}

test "parseSseLine DONE sentinel" {
    const result = try parseSseLine(std.testing.allocator, "data: [DONE]");
    try std.testing.expect(result == .done);
}

test "parseSseLine empty line" {
    const result = try parseSseLine(std.testing.allocator, "");
    try std.testing.expect(result == .skip);
}

test "parseSseLine comment" {
    const result = try parseSseLine(std.testing.allocator, ":keep-alive");
    try std.testing.expect(result == .skip);
}

test "parseSseLine delta without content" {
    const result = try parseSseLine(std.testing.allocator, "data: {\"choices\":[{\"delta\":{}}]}");
    try std.testing.expect(result == .skip);
}

test "parseSseLine empty choices" {
    const result = try parseSseLine(std.testing.allocator, "data: {\"choices\":[]}");
    try std.testing.expect(result == .skip);
}

test "parseSseLine invalid JSON" {
    try std.testing.expectError(error.InvalidSseJson, parseSseLine(std.testing.allocator, "data: not-json{{{"));
}

test "extractDeltaContent with content" {
    const allocator = std.testing.allocator;
    const result = (try extractDeltaContent(allocator, "{\"choices\":[{\"delta\":{\"content\":\"world\"}}]}")).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "extractDeltaContent without content" {
    const result = try extractDeltaContent(std.testing.allocator, "{\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}");
    try std.testing.expect(result == null);
}

test "extractDeltaContent empty content" {
    const result = try extractDeltaContent(std.testing.allocator, "{\"choices\":[{\"delta\":{\"content\":\"\"}}]}");
    try std.testing.expect(result == null);
}

test "StreamChunk textDelta token estimate" {
    const chunk = root.StreamChunk.textDelta("12345678");
    try std.testing.expect(chunk.token_count == 2);
    try std.testing.expect(!chunk.is_final);
    try std.testing.expectEqualStrings("12345678", chunk.delta);
}

test "StreamChunk finalChunk" {
    const chunk = root.StreamChunk.finalChunk();
    try std.testing.expect(chunk.is_final);
    try std.testing.expectEqualStrings("", chunk.delta);
    try std.testing.expect(chunk.token_count == 0);
}

// ── Anthropic SSE Tests ─────────────────────────────────────────

test "parseAnthropicSseLine event line returns event" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "event: content_block_delta", "");
    switch (result) {
        .event => |ev| try std.testing.expectEqualStrings("content_block_delta", ev),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with content_block_delta returns delta" {
    const allocator = std.testing.allocator;
    const json = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}";
    const result = try parseAnthropicSseLine(allocator, json, "content_block_delta");
    switch (result) {
        .delta => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("Hello", text);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with message_delta returns usage" {
    const json = "data: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"output_tokens\":42}}";
    const result = try parseAnthropicSseLine(std.testing.allocator, json, "message_delta");
    switch (result) {
        .usage => |tokens| try std.testing.expect(tokens == 42),
        else => return error.TestUnexpectedResult,
    }
}

test "parseAnthropicSseLine data with message_stop returns done" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "data: {\"type\":\"message_stop\"}", "message_stop");
    try std.testing.expect(result == .done);
}

test "parseAnthropicSseLine empty line returns skip" {
    const result = try parseAnthropicSseLine(std.testing.allocator, "", "");
    try std.testing.expect(result == .skip);
}

test "parseAnthropicSseLine comment returns skip" {
    const result = try parseAnthropicSseLine(std.testing.allocator, ":keep-alive", "");
    try std.testing.expect(result == .skip);
}

test "parseAnthropicSseLine data with unknown event returns skip" {
    const json = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_123\"}}";
    const result = try parseAnthropicSseLine(std.testing.allocator, json, "message_start");
    try std.testing.expect(result == .skip);
}

test "extractAnthropicDelta correct JSON returns text" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}";
    const result = (try extractAnthropicDelta(allocator, json)).?;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("world", result);
}

test "extractAnthropicDelta without text returns null" {
    const json = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}";
    const result = try extractAnthropicDelta(std.testing.allocator, json);
    try std.testing.expect(result == null);
}

test "extractAnthropicUsage correct JSON returns token count" {
    const json = "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":57}}";
    const result = (try extractAnthropicUsage(json)).?;
    try std.testing.expect(result == 57);
}

test "drainStderr with null pipe returns empty" {
    const result = drainStderr(std.testing.allocator, null);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "logCurlStderr compiles and is callable" {
    // Verify the function signature is correct.  We cannot call it in tests
    // because it logs at error level, which Zig's test runner treats as a
    // test failure.
    _ = &logCurlStderr;
}

// ── Native streaming response body parser tests ─────────────────────

fn testNoopCallback(_: *anyopaque, _: root.StreamChunk) void {}

test "parseSseResponseBody parses OpenAI SSE with delta and done" {
    const allocator = std.testing.allocator;
    const body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\ndata: [DONE]\n";
    var dummy_ctx: usize = 0;
    const result = try parseSseResponseBody(allocator, body, testNoopCallback, @ptrCast(&dummy_ctx));
    defer if (result.content) |c| allocator.free(c);
    try std.testing.expect(result.content != null);
    try std.testing.expectEqualStrings("Hello world", result.content.?);
}

test "parseSseResponseBody handles empty body" {
    const allocator = std.testing.allocator;
    var dummy_ctx: usize = 0;
    const result = try parseSseResponseBody(allocator, "", testNoopCallback, @ptrCast(&dummy_ctx));
    defer if (result.content) |c| allocator.free(c);
    try std.testing.expect(result.content == null);
}

test "parseSseResponseBody skips comment and empty lines" {
    const allocator = std.testing.allocator;
    const body = ":keep-alive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n";
    var dummy_ctx: usize = 0;
    const result = try parseSseResponseBody(allocator, body, testNoopCallback, @ptrCast(&dummy_ctx));
    defer if (result.content) |c| allocator.free(c);
    try std.testing.expect(result.content != null);
    try std.testing.expectEqualStrings("ok", result.content.?);
}

test "parseAnthropicSseResponseBody parses Anthropic SSE deltas" {
    const allocator = std.testing.allocator;
    const body = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n";
    var dummy_ctx: usize = 0;
    const result = try parseAnthropicSseResponseBody(allocator, body, testNoopCallback, @ptrCast(&dummy_ctx));
    defer if (result.content) |c| allocator.free(c);
    try std.testing.expect(result.content != null);
    try std.testing.expectEqualStrings("Hi", result.content.?);
}

test "parseAnthropicSseResponseBody handles empty body" {
    const allocator = std.testing.allocator;
    var dummy_ctx: usize = 0;
    const result = try parseAnthropicSseResponseBody(allocator, "", testNoopCallback, @ptrCast(&dummy_ctx));
    defer if (result.content) |c| allocator.free(c);
    try std.testing.expect(result.content == null);
}

test "curlStream compiles and is callable" {
    _ = curlStream;
}

test "curlStreamAnthropic compiles and is callable" {
    _ = curlStreamAnthropic;
}
