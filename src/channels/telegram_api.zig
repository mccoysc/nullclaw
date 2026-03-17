const std = @import("std");
const root = @import("root.zig");
const log = std.log.scoped(.telegram_api);

pub const SentMessageMeta = struct {
    message_id: ?i64 = null,
};

pub const BotIdentity = struct {
    user_id: ?i64 = null,
    username: ?[]u8 = null,

    pub fn deinit(self: *const BotIdentity, allocator: std.mem.Allocator) void {
        if (self.username) |name| allocator.free(name);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    proxy: ?[]const u8,

    pub fn apiUrl(self: Client, buf: []u8, method: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        try fbs.writer().print("https://api.telegram.org/bot{s}/{s}", .{ self.bot_token, method });
        return fbs.getWritten();
    }

    pub fn getMe(self: Client, allocator: std.mem.Allocator) ![]u8 {
        return self.post(allocator, "getMe", "{}", "10");
    }

    pub fn getMeOk(self: Client) bool {
        const resp = self.getMe(self.allocator) catch return false;
        defer self.allocator.free(resp);
        return std.mem.indexOf(u8, resp, "\"ok\":true") != null;
    }

    pub fn fetchBotIdentity(self: Client, allocator: std.mem.Allocator) ?BotIdentity {
        const resp = self.getMe(allocator) catch return null;
        defer allocator.free(resp);
        return parseBotIdentity(allocator, resp);
    }

    pub fn setMyCommands(self: Client, commands_json: []const u8) !void {
        const resp = try self.post(self.allocator, "setMyCommands", commands_json, "10");
        self.allocator.free(resp);
    }

    pub fn deleteWebhookKeepPending(self: Client) !void {
        const resp = try self.post(self.allocator, "deleteWebhook", "{\"drop_pending_updates\":false}", "10");
        self.allocator.free(resp);
    }

    pub fn latestUpdateNextOffset(self: Client, allocator: std.mem.Allocator) ?i64 {
        const resp = self.post(allocator, "getUpdates", "{\"offset\":-1,\"timeout\":0}", "10") catch return null;
        defer allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;

        const result_val = parsed.value.object.get("result") orelse return null;
        if (result_val != .array) return null;

        var next_offset: ?i64 = null;
        for (result_val.array.items) |update| {
            if (update != .object) continue;
            const uid = update.object.get("update_id") orelse continue;
            if (uid != .integer) continue;
            next_offset = uid.integer + 1;
        }
        return next_offset;
    }

    pub fn sendTypingIndicator(self: Client, chat_id: []const u8) !void {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"chat_id\":");
        try body.appendSlice(self.allocator, chat_id);
        try body.appendSlice(self.allocator, ",\"action\":\"typing\"}");

        const resp = try self.post(self.allocator, "sendChatAction", body.items, "10");
        self.allocator.free(resp);
    }

    pub fn answerCallbackQuery(self: Client, callback_query_id: []const u8, text: ?[]const u8) !void {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"callback_query_id\":");
        try root.json_util.appendJsonString(&body, self.allocator, callback_query_id);
        if (text) |t| {
            try body.appendSlice(self.allocator, ",\"text\":");
            try root.json_util.appendJsonString(&body, self.allocator, t);
        }
        try body.appendSlice(self.allocator, "}");

        const resp = try self.post(self.allocator, "answerCallbackQuery", body.items, "10");
        self.allocator.free(resp);
    }

    pub fn clearReplyMarkup(self: Client, chat_id: []const u8, message_id: i64) !void {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(self.allocator);

        try body.appendSlice(self.allocator, "{\"chat_id\":");
        try body.appendSlice(self.allocator, chat_id);

        var msg_id_buf: [32]u8 = undefined;
        const msg_id_str = try std.fmt.bufPrint(&msg_id_buf, "{d}", .{message_id});
        try body.appendSlice(self.allocator, ",\"message_id\":");
        try body.appendSlice(self.allocator, msg_id_str);
        try body.appendSlice(self.allocator, ",\"reply_markup\":{\"inline_keyboard\":[]}}");

        const resp = try self.post(self.allocator, "editMessageReplyMarkup", body.items, "10");
        self.allocator.free(resp);
    }

    pub fn sendMessage(self: Client, allocator: std.mem.Allocator, body: []const u8, timeout: []const u8) ![]u8 {
        return self.post(allocator, "sendMessage", body, timeout);
    }

    pub fn getUpdates(self: Client, allocator: std.mem.Allocator, body: []const u8, timeout: []const u8) ![]u8 {
        return self.post(allocator, "getUpdates", body, timeout);
    }

    pub fn editMessageText(
        self: Client,
        allocator: std.mem.Allocator,
        chat_id: []const u8,
        message_id: i64,
        text: []const u8,
    ) ![]u8 {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);

        try body.appendSlice(allocator, "{\"chat_id\":");
        try body.appendSlice(allocator, chat_id);
        try body.appendSlice(allocator, ",\"message_id\":");
        var msg_id_buf: [32]u8 = undefined;
        const msg_id_str = try std.fmt.bufPrint(&msg_id_buf, "{d}", .{message_id});
        try body.appendSlice(allocator, msg_id_str);
        try body.appendSlice(allocator, ",\"text\":");
        try root.json_util.appendJsonString(&body, allocator, text);
        try body.appendSlice(allocator, "}");

        return self.post(allocator, "editMessageText", body.items, "10");
    }

    /// Edit a message with HTML parse_mode enabled.
    pub fn editMessageTextHtml(
        self: Client,
        allocator: std.mem.Allocator,
        chat_id: []const u8,
        message_id: i64,
        html_text: []const u8,
    ) ![]u8 {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);

        try body.appendSlice(allocator, "{\"chat_id\":");
        try body.appendSlice(allocator, chat_id);
        try body.appendSlice(allocator, ",\"message_id\":");
        var msg_id_buf: [32]u8 = undefined;
        const msg_id_str = try std.fmt.bufPrint(&msg_id_buf, "{d}", .{message_id});
        try body.appendSlice(allocator, msg_id_str);
        try body.appendSlice(allocator, ",\"text\":");
        try root.json_util.appendJsonString(&body, allocator, html_text);
        try body.appendSlice(allocator, ",\"parse_mode\":\"HTML\"");
        try body.appendSlice(allocator, "}");

        return self.post(allocator, "editMessageText", body.items, "10");
    }

    /// Delete a message from a chat.
    pub fn deleteMessage(
        self: Client,
        allocator: std.mem.Allocator,
        chat_id: []const u8,
        message_id: i64,
    ) ![]u8 {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);

        try body.appendSlice(allocator, "{\"chat_id\":");
        try body.appendSlice(allocator, chat_id);
        try body.appendSlice(allocator, ",\"message_id\":");
        var msg_id_buf: [32]u8 = undefined;
        const msg_id_str = try std.fmt.bufPrint(&msg_id_buf, "{d}", .{message_id});
        try body.appendSlice(allocator, msg_id_str);
        try body.appendSlice(allocator, "}");

        return self.post(allocator, "deleteMessage", body.items, "10");
    }

    pub fn getFilePath(self: Client, allocator: std.mem.Allocator, file_id: []const u8) ![]u8 {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(allocator);
        try body.appendSlice(allocator, "{\"file_id\":");
        try root.json_util.appendJsonString(&body, allocator, file_id);
        try body.appendSlice(allocator, "}");

        const resp = try self.post(allocator, "getFile", body.items, "15");
        defer allocator.free(resp);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch |err| {
            return switch (err) {
                else => error.InvalidResponse,
            };
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;

        const result_obj = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result_obj != .object) return error.InvalidResponse;

        const fp_val = result_obj.object.get("file_path") orelse return error.InvalidResponse;
        if (fp_val != .string) return error.InvalidResponse;

        return allocator.dupe(u8, fp_val.string);
    }

    pub fn downloadFile(self: Client, allocator: std.mem.Allocator, file_path: []const u8, timeout: []const u8) ![]u8 {
        var url_buf: [1024]u8 = undefined;
        const url = try self.fileUrl(&url_buf, file_path);
        return root.http_util.curlGetWithProxy(allocator, url, &.{}, timeout, self.proxy);
    }

    pub fn postMultipart(
        self: Client,
        allocator: std.mem.Allocator,
        method: []const u8,
        chat_id: []const u8,
        field_name: []const u8,
        media_path: []const u8,
        caption: ?[]const u8,
    ) !void {
        var url_buf: [512]u8 = undefined;
        const url = try self.apiUrl(&url_buf, method);

        // Build multipart form data manually
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(allocator);

        // Add chat_id field
        try body.appendSlice(allocator, "--boundary\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n");
        try body.appendSlice(allocator, chat_id);
        try body.appendSlice(allocator, "\r\n");

        // Add media field (either file reference or URL)
        try body.appendSlice(allocator, "--boundary\r\nContent-Disposition: form-data; name=\"");
        try body.appendSlice(allocator, field_name);
        try body.appendSlice(allocator, "\"");
        if (std.mem.startsWith(u8, media_path, "http://") or
            std.mem.startsWith(u8, media_path, "https://"))
        {
            try body.appendSlice(allocator, "; filename=\"attachment\"\r\nContent-Type: application/octet-stream\r\n\r\n");
            try body.appendSlice(allocator, media_path);
        } else {
            try body.appendSlice(allocator, "; filename=\"file\"\r\nContent-Type: application/octet-stream\r\n\r\n");
            // Read file content
            const file_content = std.fs.cwd().readFileAlloc(allocator, media_path, 10 * 1024 * 1024) catch
                return error.FileReadError;
            defer allocator.free(file_content);
            try body.appendSlice(allocator, file_content);
        }
        try body.appendSlice(allocator, "\r\n");

        // Add caption if present
        if (caption) |cap| {
            try body.appendSlice(allocator, "--boundary\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n");
            try body.appendSlice(allocator, cap);
            try body.appendSlice(allocator, "\r\n");
        }

        // Close boundary
        try body.appendSlice(allocator, "--boundary--\r\n");

        // Build headers
        var headers = std.ArrayListUnmanaged([]const u8).empty;
        defer headers.deinit(allocator);
        try headers.append(allocator, "Content-Type: multipart/form-data; boundary=boundary");

        // Use libcurl to POST the multipart data
        const http_util = @import("../http_util.zig");
        const response = http_util.curlPostWithProxy(
            allocator,
            url,
            body.items,
            headers.items,
            self.proxy,
            "120",
        ) catch |err| {
            log.err("multipart post failed: {}", .{err});
            return error.CurlFailed;
        };
        defer allocator.free(response);

        // Check for Telegram errors
        if (response.len > 0 and response[0] == '{') {
            if (std.mem.indexOf(u8, response, "\"ok\":false") != null) {
                log.err("Telegram API error: {s}", .{response});
                return error.CurlFailed;
            }
        }
    }

    fn post(self: Client, allocator: std.mem.Allocator, method: []const u8, body: []const u8, timeout: []const u8) ![]u8 {
        var url_buf: [512]u8 = undefined;
        const url = try self.apiUrl(&url_buf, method);
        return root.http_util.curlPostWithProxy(allocator, url, body, &.{}, self.proxy, timeout);
    }

    fn fileUrl(self: Client, buf: []u8, file_path: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        try fbs.writer().print("https://api.telegram.org/file/bot{s}/{s}", .{ self.bot_token, file_path });
        return fbs.getWritten();
    }
};

pub fn appendReplyTo(body: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, reply_to: ?i64) !void {
    if (reply_to) |rid| {
        var rid_buf: [32]u8 = undefined;
        const rid_str = std.fmt.bufPrint(&rid_buf, "{d}", .{rid}) catch unreachable;
        try body.appendSlice(allocator, ",\"reply_parameters\":{\"message_id\":");
        try body.appendSlice(allocator, rid_str);
        try body.appendSlice(allocator, "}");
    }
}

pub fn appendRawReplyMarkup(body: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, reply_markup_json: ?[]const u8) !void {
    if (reply_markup_json) |rm| {
        try body.appendSlice(allocator, ",\"reply_markup\":");
        try body.appendSlice(allocator, rm);
    }
}

pub fn responseHasTelegramError(resp: []const u8) bool {
    return std.mem.indexOf(u8, resp, "\"error_code\"") != null or
        std.mem.indexOf(u8, resp, "\"ok\":false") != null;
}

pub fn parseSentMessageMeta(allocator: std.mem.Allocator, resp: []const u8) ?SentMessageMeta {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const ok_val = parsed.value.object.get("ok") orelse return null;
    if (ok_val != .bool or !ok_val.bool) return null;

    const result_val = parsed.value.object.get("result") orelse return null;
    if (result_val != .object) return null;

    const msg_id_val = result_val.object.get("message_id") orelse return .{};
    if (msg_id_val != .integer) return .{};
    return .{ .message_id = msg_id_val.integer };
}

fn parseBotIdentity(allocator: std.mem.Allocator, resp: []const u8) ?BotIdentity {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const result_val = parsed.value.object.get("result") orelse return null;
    if (result_val != .object) return null;

    const id_val = result_val.object.get("id");
    const username_val = result_val.object.get("username");

    return .{
        .user_id = if (id_val) |value| (if (value == .integer) value.integer else null) else null,
        .username = if (username_val) |value|
            (if (value == .string) (allocator.dupe(u8, value.string) catch null) else null)
        else
            null,
    };
}

test "telegram api client builds method url" {
    const client = Client{
        .allocator = std.testing.allocator,
        .bot_token = "123:ABC",
        .proxy = null,
    };
    var buf: [256]u8 = undefined;
    const url = try client.apiUrl(&buf, "getUpdates");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot123:ABC/getUpdates", url);
}

test "telegram api responseHasTelegramError matches error payloads" {
    try std.testing.expect(responseHasTelegramError("{\"ok\":false,\"error_code\":400}"));
    try std.testing.expect(!responseHasTelegramError("{\"ok\":true,\"result\":{}}"));
}

test "telegram api parseSentMessageMeta extracts message id" {
    const meta = parseSentMessageMeta(
        std.testing.allocator,
        "{\"ok\":true,\"result\":{\"message_id\":42}}",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?i64, 42), meta.message_id);
}

test "editMessageText builds valid JSON body" {
    // Verify that editMessageText produces well-formed JSON (no stray quotes
    // between fields).  We can't call editMessageText directly because it
    // invokes curlPostWithProxy, so we replicate the body-building logic and
    // validate the output.
    const allocator = std.testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    const chat_id = "12345678";
    const message_id: i64 = 42;
    const text = "hello world";

    try body.appendSlice(allocator, "{\"chat_id\":");
    try body.appendSlice(allocator, chat_id);
    try body.appendSlice(allocator, ",\"message_id\":");
    var msg_id_buf: [32]u8 = undefined;
    const msg_id_str = try std.fmt.bufPrint(&msg_id_buf, "{d}", .{message_id});
    try body.appendSlice(allocator, msg_id_str);
    try body.appendSlice(allocator, ",\"text\":");
    try root.json_util.appendJsonString(&body, allocator, text);
    try body.appendSlice(allocator, "}");

    // The body must be valid JSON that std.json can parse.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.items, .{});
    defer parsed.deinit();

    // Verify fields
    const obj = parsed.value.object;
    const cid = obj.get("chat_id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 12345678), cid.integer);
    const mid = obj.get("message_id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 42), mid.integer);
    const txt = obj.get("text") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello world", txt.string);
}

test "editMessageTextHtml builds valid JSON body with parse_mode" {
    const allocator = std.testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    const chat_id = "12345678";
    const message_id: i64 = 99;
    const html_text = "<b>bold</b> text";

    try body.appendSlice(allocator, "{\"chat_id\":");
    try body.appendSlice(allocator, chat_id);
    try body.appendSlice(allocator, ",\"message_id\":");
    var msg_id_buf: [32]u8 = undefined;
    const msg_id_str = try std.fmt.bufPrint(&msg_id_buf, "{d}", .{message_id});
    try body.appendSlice(allocator, msg_id_str);
    try body.appendSlice(allocator, ",\"text\":");
    try root.json_util.appendJsonString(&body, allocator, html_text);
    try body.appendSlice(allocator, ",\"parse_mode\":\"HTML\"");
    try body.appendSlice(allocator, "}");

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.items, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const cid = obj.get("chat_id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 12345678), cid.integer);
    const mid = obj.get("message_id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 99), mid.integer);
    const txt = obj.get("text") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("<b>bold</b> text", txt.string);
    const pm = obj.get("parse_mode") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("HTML", pm.string);
}

test "deleteMessage builds valid JSON body" {
    const allocator = std.testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    const chat_id = "12345678";
    const message_id: i64 = 55;

    try body.appendSlice(allocator, "{\"chat_id\":");
    try body.appendSlice(allocator, chat_id);
    try body.appendSlice(allocator, ",\"message_id\":");
    var msg_id_buf: [32]u8 = undefined;
    const msg_id_str = try std.fmt.bufPrint(&msg_id_buf, "{d}", .{message_id});
    try body.appendSlice(allocator, msg_id_str);
    try body.appendSlice(allocator, "}");

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.items, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const cid = obj.get("chat_id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 12345678), cid.integer);
    const mid = obj.get("message_id") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 55), mid.integer);
}
