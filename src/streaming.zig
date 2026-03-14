const providers = @import("providers/root.zig");

pub const OutboundStage = enum {
    chunk,
    final,
};

pub const Event = struct {
    stage: OutboundStage,
    text: []const u8 = "",
};

pub const Sink = struct {
    callback: *const fn (ctx: *anyopaque, event: Event) void,
    ctx: *anyopaque,

    pub fn emit(self: Sink, event: Event) void {
        self.callback(self.ctx, event);
    }

    pub fn emitChunk(self: Sink, text: []const u8) void {
        if (text.len == 0) return;
        self.emit(.{
            .stage = .chunk,
            .text = text,
        });
    }

    pub fn emitFinal(self: Sink) void {
        self.emit(.{ .stage = .final });
    }
};

pub fn eventFromProviderChunk(chunk: providers.StreamChunk) ?Event {
    if (chunk.is_final) return .{ .stage = .final };
    if (chunk.delta.len == 0) return null;
    return .{
        .stage = .chunk,
        .text = chunk.delta,
    };
}

pub fn forwardProviderChunk(sink: Sink, chunk: providers.StreamChunk) void {
    if (eventFromProviderChunk(chunk)) |event| {
        sink.emit(event);
    }
}

// ---------------------------------------------------------------------------
// TagFilter – state-machine that strips <tool_call>…</tool_call> (and bracket
// variants) from a stream of chunks before forwarding to an inner Sink.
// ---------------------------------------------------------------------------

pub const TagFilter = struct {
    inner: Sink,
    state: State = .passthrough,
    buf: [max_tag_len]u8 = undefined,
    buf_len: u8 = 0,

    const State = enum {
        passthrough,
        maybe_open, // buffering after '<' or '[', checking if prefix matches
        skip_to_angle_close, // prefix matched, eating until '>' (for angle brackets)
        inside_tag, // inside tag body, suppressing output
        maybe_close, // buffering after '<' or '[', checking if close tag matches
    };

    // Opening tag prefixes. After matching, skip until ']' (for bracket) or '>' (for angle).
    // Handles both `<tool_call>` and `[TOOL_CALL]` (and variants).
    const open_prefixes = [_][]const u8{
        "<tool_call",
        "<tool_result",
        "[TOOL_CALL",
        "[tool_call",
        "[TOOL_RESULT",
        "[tool_result",
    };

    // Closing tags (fixed match). Handles both XML and bracket variants.
    const close_tags = [_][]const u8{
        "</tool_call>",
        "</tool_result>",
        "[/TOOL_CALL]",
        "[/tool_call]",
        "[/TOOL_RESULT]",
        "[/tool_result]",
    };

    const max_prefix_len = 12; // "[TOOL_RESULT".len
    const max_tag_len = 14; // "[/TOOL_RESULT]".len

    pub fn init(inner: Sink) TagFilter {
        return .{ .inner = inner };
    }

    /// Return a Sink whose callback routes through this filter.
    pub fn sink(self: *TagFilter) Sink {
        return .{
            .callback = filterCallback,
            .ctx = @ptrCast(self),
        };
    }

    fn filterCallback(ctx: *anyopaque, event: Event) void {
        const self: *TagFilter = @ptrCast(@alignCast(ctx));
        if (event.stage == .final) {
            // Flush any pending buffer as-is (incomplete tag at end of stream).
            self.flushBuf();
            self.inner.emit(event);
            return;
        }
        self.process(event.text);
    }

    fn process(self: *TagFilter, text: []const u8) void {
        var clean_start: usize = 0;
        for (text, 0..) |b, i| {
            switch (self.state) {
                .passthrough => {
                    if (b == '<' or b == '[') {
                        // Flush clean text accumulated so far.
                        if (i > clean_start)
                            self.inner.emitChunk(text[clean_start..i]);
                        self.buf[0] = b;
                        self.buf_len = 1;
                        self.state = .maybe_open;
                    }
                },
                .maybe_open => {
                    self.buf[self.buf_len] = b;
                    self.buf_len += 1;
                    const prefix = self.buf[0..self.buf_len];
                    // Check if the bytes before this one match a full open prefix
                    // and this byte is a delimiter (']' closes bracket tags, '>' closes angle tags, ' ' starts attrs).
                    if (self.buf_len > 1 and (b == '>' or b == ']' or b == ' ') and
                        matchesAnyPrefix(prefix[0 .. self.buf_len - 1], &open_prefixes))
                    {
                        self.buf_len = 0;
                        if (b == '>') {
                            self.state = .inside_tag;
                        } else if (b == ']') {
                            self.state = .inside_tag;
                        } else {
                            self.state = .skip_to_angle_close;
                        }
                        clean_start = i + 1;
                        continue;
                    }
                    // Still a valid prefix of some open tag — keep buffering.
                    if (prefixOfAny(prefix, &open_prefixes)) {
                        clean_start = i + 1;
                        continue;
                    }
                    // Not a prefix of any tag — flush buffer and resume passthrough.
                    self.inner.emitChunk(self.buf[0..self.buf_len]);
                    self.buf_len = 0;
                    self.state = .passthrough;
                    clean_start = i + 1;
                },
                .skip_to_angle_close => {
                    clean_start = i + 1;
                    if (b == '>') {
                        self.state = .inside_tag;
                    }
                },
                .inside_tag => {
                    clean_start = i + 1;
                    if (b == '<') {
                        // Start of potential close tag for angle-bracket style
                        self.buf[0] = b;
                        self.buf_len = 1;
                        self.state = .maybe_close;
                    } else if (b == '[') {
                        // Start of potential close tag for bracket style
                        self.buf[0] = b;
                        self.buf_len = 1;
                        self.state = .maybe_close;
                    }
                },
                .maybe_close => {
                    clean_start = i + 1;
                    self.buf[self.buf_len] = b;
                    self.buf_len += 1;
                    const prefix = self.buf[0..self.buf_len];
                    if (matchesAny(prefix, &close_tags)) |_| {
                        // Complete close tag matched — back to passthrough.
                        self.buf_len = 0;
                        self.state = .passthrough;
                        clean_start = i + 1;
                        continue;
                    }
                    // For bracket-style close tags, also check for ']' as the closing delimiter
                    if (self.buf_len > 0 and self.buf[0] == '[') {
                        // Inside bracket-style close tag, look for ']'
                        if (b == ']') {
                            // Check if what we have so far is a valid prefix of close tags
                            if (prefixOfAny(prefix, &close_tags)) {
                                // Keep buffering
                                continue;
                            }
                        }
                    }
                    if (!prefixOfAny(prefix, &close_tags) or self.buf_len >= max_tag_len) {
                        // Not a close tag — stay inside, discard buffer.
                        self.buf_len = 0;
                        self.state = .inside_tag;
                        continue;
                    }
                    // Still a valid prefix of a close tag — keep buffering.
                },
            }
        }
        // Flush remaining clean text in passthrough mode.
        if (self.state == .passthrough and clean_start < text.len)
            self.inner.emitChunk(text[clean_start..]);
    }

    fn flushBuf(self: *TagFilter) void {
        if (self.buf_len > 0 and self.state == .maybe_open) {
            // Incomplete open tag at end of stream — not a real tag, flush it.
            self.inner.emitChunk(self.buf[0..self.buf_len]);
        }
        self.buf_len = 0;
        self.state = .passthrough;
    }

    /// Returns the index if `text` exactly matches any entry in `tags`.
    fn matchesAny(text: []const u8, tags: []const []const u8) ?usize {
        for (tags, 0..) |tag, i| {
            if (std.mem.eql(u8, text, tag)) return i;
        }
        return null;
    }

    /// Returns true if `text` exactly matches any entry in `prefixes`.
    fn matchesAnyPrefix(text: []const u8, prefixes: []const []const u8) bool {
        for (prefixes) |p| {
            if (std.mem.eql(u8, text, p)) return true;
        }
        return false;
    }

    /// Returns true if `text` is a valid prefix of at least one entry in `tags`.
    fn prefixOfAny(text: []const u8, tags: []const []const u8) bool {
        for (tags) |tag| {
            if (text.len <= tag.len and std.mem.eql(u8, text, tag[0..text.len]))
                return true;
        }
        return false;
    }
};

const std = @import("std");

// Tool call marker detection patterns (must match TagFilter's open_prefixes)
const tool_open_prefixes = [_][]const u8{
    "<tool_call",
    "<tool_result",
    "[TOOL_CALL",
    "[tool_call",
    "[TOOL_RESULT",
    "[tool_result",
};

/// Detection result from BufferingSink
pub const ToolDetection = enum {
    /// Content is ordinary text, safe to stream to user
    passthrough,
    /// Buffer contains potential tool call, needs tool call handling
    tool_candidate,
    /// Buffer overflow protection triggered
    overflow,
};

// ---------------------------------------------------------------------------
// BufferingSink — buffers streaming chunks before forwarding to detect tool calls
// ---------------------------------------------------------------------------

pub const BufferingSink = struct {
    inner: Sink,
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    threshold: usize = 256,
    max_buffer: usize = 4096,
    state: BufferState = .collecting,

    const BufferState = enum {
        collecting, // accumulating chunks in buffer
        tool_candidate, // detected potential tool call, waiting for dispatch
        passthrough, // confirmed normal text, flushing
        overflow, // buffer exceeded max size
    };

    pub fn init(allocator: std.mem.Allocator, inner: Sink) BufferingSink {
        return .{
            .inner = inner,
            .allocator = allocator,
        };
    }

    /// Return a Sink whose callback routes through this buffer
    pub fn sink(self: *BufferingSink) Sink {
        return .{
            .callback = bufferingCallback,
            .ctx = @ptrCast(self),
        };
    }

    /// Get the current buffered content
    pub fn getBuffer(self: *const BufferingSink) []const u8 {
        return self.buffer.items;
    }

    /// Clear the buffer
    pub fn clearBuffer(self: *BufferingSink) void {
        self.buffer.clearRetainingCapacity();
        self.state = .collecting;
    }

    /// Detect if buffer content contains potential tool call markers
    fn detectToolCall(text: []const u8) ToolDetection {
        // Check for tool call opening markers
        for (tool_open_prefixes) |prefix| {
            if (std.mem.indexOf(u8, text, prefix) != null) {
                return .tool_candidate;
            }
        }
        return .passthrough;
    }
    fn processChunk(self: *BufferingSink, text: []const u8) void {
        // Append to buffer
        self.buffer.appendSlice(self.allocator, text) catch {
            // On allocation failure, force flush
            self.flush();
            return;
        };

        const buf_len = self.buffer.items.len;

        // Check buffer overflow protection
        if (buf_len >= self.max_buffer) {
            self.state = .overflow;
            self.flush();
            return;
        }

        // If buffer < threshold, continue buffering
        if (buf_len < self.threshold) {
            return;
        }

        // Buffer >= threshold, check if it's a tool call candidate
        const detection = detectToolCall(self.buffer.items);
        switch (detection) {
            .tool_candidate => {
                // Mark as tool candidate but don't flush yet
                // The caller (agent loop) should check and handle tool dispatch
                self.state = .tool_candidate;
            },
            .passthrough => {
                // Safe text, flush to user
                self.flush();
            },
            .overflow => {
                self.state = .overflow;
                self.flush();
            },
        }
    }

    /// Flush buffered content to downstream sink
    fn flush(self: *BufferingSink) void {
        if (self.buffer.items.len > 0) {
            self.inner.emitChunk(self.buffer.items);
        }
        self.buffer.clearRetainingCapacity();
        self.state = .collecting;
    }

    fn bufferingCallback(ctx: *anyopaque, event: Event) void {
        const self: *BufferingSink = @ptrCast(@alignCast(ctx));

        if (event.stage == .final) {
            // On final event, process any remaining buffer
            if (self.buffer.items.len > 0) {
                // Check if it's a tool call
                const detection = detectToolCall(self.buffer.items);
                if (detection == .tool_candidate) {
                    // Keep in buffer for tool call extraction
                    // Don't flush to user - tool call should be handled by caller
                    // But also don't leak raw content
                    self.buffer.clearRetainingCapacity();
                } else {
                    // Normal text - flush to user
                    self.flush();
                }
            }
            self.inner.emitFinal();
            return;
        }

        // Regular chunk - buffer it
        self.processChunk(event.text);
    }
};

// ---------------------------------------------------------------------------
// ToolCallDetector — extracts and repairs tool calls from buffered content
// ----------------------------------------------------------------------------

const dispatcher = @import("agent/dispatcher.zig");

/// Result of detecting tool calls in buffered content
pub const DetectResult = struct {
    /// The buffered text (may be modified or empty after extraction)
    text: []const u8,
    /// Extracted tool calls (caller must free)
    calls: []dispatcher.ParsedToolCall,
    /// Whether the content was determined to be a tool call
    is_tool_call: bool,
};

/// Detect and extract tool calls from buffered content
/// This is the bridge between BufferingSink and the dispatcher
pub fn detectToolCalls(
    allocator: std.mem.Allocator,
    buffered_text: []const u8,
) !DetectResult {
    // First check if there's actual tool call markup
    if (!dispatcher.containsToolCallMarkup(buffered_text)) {
        // No tool call markers - treat as normal text
        return .{
            .text = buffered_text,
            .calls = &.{},
            .is_tool_call = false,
        };
    }

    // Try parsing as tool calls using dispatcher
    const result = try dispatcher.parseToolCalls(allocator, buffered_text);
    errdefer {
        // Free on any early return
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
            if (call.tool_call_id) |id| allocator.free(id);
        }
        allocator.free(result.calls);
    }

    if (result.calls.len > 0) {
        // Transfer ownership of text to caller - but caller must free it
        return .{
            .text = result.text,
            .calls = result.calls,
            .is_tool_call = true,
        };
    }

    // Markup detected but no valid calls extracted - might be malformed
    // Try local repair
    if (dispatcher.looksLikeMalformedToolCall(buffered_text)) {
        // Free the text as we're not returning it
        if (result.text.len > 0) allocator.free(result.text);
        allocator.free(result.calls);
        return .{
            .text = "",
            .calls = &.{},
            .is_tool_call = true, // Signal that repair might be needed
        };
    }

    // Free resources and return passthrough
    if (result.text.len > 0) allocator.free(result.text);
    allocator.free(result.calls);
    return .{
        .text = buffered_text,
        .calls = &.{},
        .is_tool_call = false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn collectChunks(comptime max: usize) type {
    return struct {
        chunks: [max][]const u8 = undefined,
        count: usize = 0,
        got_final: bool = false,

        fn callback(ctx: *anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (event.stage == .final) {
                self.got_final = true;
                return;
            }
            if (self.count < max) {
                self.chunks[self.count] = event.text;
                self.count += 1;
            }
        }

        fn joined(self: *const @This(), buf: []u8) []const u8 {
            var pos: usize = 0;
            for (self.chunks[0..self.count]) |c| {
                @memcpy(buf[pos..][0..c.len], c);
                pos += c.len;
            }
            return buf[0..pos];
        }

        fn sink(self: *@This()) Sink {
            return .{ .callback = callback, .ctx = @ptrCast(self) };
        }
    };
}

test "TagFilter passthrough without tags" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hello ");
    s.emitChunk("world!");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello world!", col.joined(&buf));
    try std.testing.expect(col.got_final);
}

test "TagFilter strips complete tool_call in single chunk" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hi <tool_call>{\"name\":\"x\",\"arguments\":{}}</tool_call> bye");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hi  bye", col.joined(&buf));
}

test "TagFilter strips tool_result with attributes" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<tool_result name=\"shell\" status=\"success\">output</tool_result>B");
    s.emitFinal();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter strips tool_result without attributes" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<tool_result>output</tool_result>B");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter tag split across chunks" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hello <tool_c");
    s.emitChunk("all>{\"name\":\"x\"}</tool_call> world");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello  world", col.joined(&buf));
}

test "TagFilter close tag split across chunks" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("<tool_call>body</tool_");
    s.emitChunk("call>after");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("after", col.joined(&buf));
}

test "TagFilter false positive angle bracket" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("a < b > c");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a < b > c", col.joined(&buf));
}

test "TagFilter multiple tool calls" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A<tool_call>1</tool_call>B<tool_call>2</tool_call>C");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ABC", col.joined(&buf));
}

test "TagFilter incomplete open tag at end flushes on final" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("end<tool_c");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("end<tool_c", col.joined(&buf));
    try std.testing.expect(col.got_final);
}

test "TagFilter strips bracket-style tool_call" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hi [TOOL_CALL]{\"name\":\"x\",\"arguments\":{}}[/TOOL_CALL] bye");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hi  bye", col.joined(&buf));
    try std.testing.expect(col.got_final);
}

test "TagFilter strips lowercase bracket tool_call" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A[tool_call]{\"name\":\"shell\"}[/tool_call]B");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter strips bracket tool_result" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("A[TOOL_RESULT]output[/TOOL_RESULT]B");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AB", col.joined(&buf));
}

test "TagFilter bracket tag split across chunks" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("Hello [TOOL_C");
    s.emitChunk("ALL]{\"name\":\"x\"}[/TOOL_CALL] world");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello  world", col.joined(&buf));
}

test "TagFilter bracket close tag split across chunks" {
    var col = collectChunks(16){};
    var filter = TagFilter.init(col.sink());
    const s = filter.sink();
    s.emitChunk("[TOOL_CALL]body[/TOOL_");
    s.emitChunk("CALL]after");
    s.emitFinal();
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("after", col.joined(&buf));
}

// ---------------------------------------------------------------------------
// BufferingSink Tests
// ----------------------------------------------------------------------------

test "BufferingSink normal text under threshold" {
    var col = collectChunks(16){};
    var buf_sink = BufferingSink.init(std.testing.allocator, col.sink());
    defer buf_sink.buffer.deinit(std.testing.allocator);
    buf_sink.threshold = 256;
    const s = buf_sink.sink();

    // Send small chunks that stay under threshold
    s.emitChunk("Hello ");
    s.emitChunk("world!");
    // Should NOT have flushed yet (still under threshold)
    try std.testing.expectEqual(@as(usize, 0), col.count);

    s.emitFinal();
    // On final, should flush
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello world!", col.joined(&buf));
    try std.testing.expect(col.got_final);
}

test "BufferingSink normal text over threshold flushes" {
    var col = collectChunks(16){};
    var buf_sink = BufferingSink.init(std.testing.allocator, col.sink());
    defer buf_sink.buffer.deinit(std.testing.allocator);
    buf_sink.threshold = 10; // Low threshold for testing
    const s = buf_sink.sink();

    // Send chunk larger than threshold
    s.emitChunk("Hello world this is a long message");
    // Should have flushed (no tool call detected)
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hello world this is a long message", col.joined(&buf));

    s.emitFinal();
    try std.testing.expect(col.got_final);
}

test "BufferingSink tool call candidate detection" {
    var col = collectChunks(16){};
    var buf_sink = BufferingSink.init(std.testing.allocator, col.sink());
    defer buf_sink.buffer.deinit(std.testing.allocator);
    buf_sink.threshold = 10;
    const s = buf_sink.sink();

    // Send content with tool call marker
    s.emitChunk("Hello <tool_call>");
    // Buffer should be in tool_candidate state, not flushed
    try std.testing.expectEqual(BufferingSink.BufferState.tool_candidate, buf_sink.state);
    // Should not have flushed to user yet
    try std.testing.expectEqual(@as(usize, 0), col.count);

    s.emitFinal();
    // On final, should NOT flush tool call content to user
    try std.testing.expectEqual(@as(usize, 0), col.count);
    try std.testing.expect(col.got_final);
}

test "BufferingSink bracket style tool call detection" {
    var col = collectChunks(16){};
    var buf_sink = BufferingSink.init(std.testing.allocator, col.sink());
    defer buf_sink.buffer.deinit(std.testing.allocator);
    buf_sink.threshold = 10;
    const s = buf_sink.sink();

    // Send content with bracket-style tool call marker
    s.emitChunk("text [TOOL_CALL]");
    try std.testing.expectEqual(BufferingSink.BufferState.tool_candidate, buf_sink.state);
    try std.testing.expectEqual(@as(usize, 0), col.count);

    s.emitFinal();
    try std.testing.expectEqual(@as(usize, 0), col.count);
}

test "BufferingSink tool_result detection" {
    var col = collectChunks(16){};
    var buf_sink = BufferingSink.init(std.testing.allocator, col.sink());
    defer buf_sink.buffer.deinit(std.testing.allocator);
    buf_sink.threshold = 10;
    const s = buf_sink.sink();

    s.emitChunk("result <tool_result>");
    try std.testing.expectEqual(BufferingSink.BufferState.tool_candidate, buf_sink.state);

    s.emitFinal();
    try std.testing.expectEqual(@as(usize, 0), col.count);
}

test "BufferingSink clearBuffer" {
    var col = collectChunks(16){};
    var buf_sink = BufferingSink.init(std.testing.allocator, col.sink());
    defer buf_sink.buffer.deinit(std.testing.allocator);
    buf_sink.threshold = 10;
    const s = buf_sink.sink();

    s.emitChunk("some text");
    try std.testing.expect(buf_sink.buffer.items.len > 0);

    buf_sink.clearBuffer();
    try std.testing.expectEqual(@as(usize, 0), buf_sink.buffer.items.len);
    try std.testing.expectEqual(BufferingSink.BufferState.collecting, buf_sink.state);
}

test "detectToolCalls with tool_call markup" {
    const allocator = std.testing.allocator;
    const buffered = "Hello <tool_call>{\"name\": \"shell\", \"arguments\": {\"command\": \"ls\"}}</tool_call> world";

    const result = try detectToolCalls(allocator, buffered);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expect(result.is_tool_call);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("shell", result.calls[0].name);
}

test "detectToolCalls without markup returns passthrough" {
    const allocator = std.testing.allocator;
    const buffered = "Hello world, this is just normal text.";

    const result = try detectToolCalls(allocator, buffered);
    defer {
        allocator.free(result.calls);
    }

    try std.testing.expect(!result.is_tool_call);
    try std.testing.expectEqual(@as(usize, 0), result.calls.len);
}

test "detectToolCalls with bracket style tool_call" {
    const allocator = std.testing.allocator;
    const buffered = "text [TOOL_CALL]{\"name\": \"search\", \"arguments\": {\"query\": \"test\"}}[/TOOL_CALL] more";

    const result = try detectToolCalls(allocator, buffered);
    defer {
        if (result.text.len > 0) allocator.free(result.text);
        for (result.calls) |call| {
            allocator.free(call.name);
            allocator.free(call.arguments_json);
        }
        allocator.free(result.calls);
    }

    try std.testing.expect(result.is_tool_call);
    try std.testing.expectEqual(@as(usize, 1), result.calls.len);
    try std.testing.expectEqualStrings("search", result.calls[0].name);
}
