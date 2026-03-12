//! Minimal protobuf encoder/decoder for Lark WebSocket binary frames.
//!
//! Implements just enough of the protobuf wire format to handle the
//! `pbbp2.Frame` and `pbbp2.Header` messages used by Lark's long-connection
//! WebSocket protocol.
//!
//! Wire format reference (from larksuite/node-sdk ws-client/proto-buf/pbbp2.js):
//!
//!   message Header {
//!     required string key   = 1;
//!     required string value = 2;
//!   }
//!
//!   message Frame {
//!     required uint64 SeqID           = 1;
//!     required uint64 LogID           = 2;
//!     required int32  service         = 3;
//!     required int32  method          = 4;
//!     repeated Header headers         = 5;
//!     optional string payloadEncoding = 6;
//!     optional string payloadType     = 7;
//!     optional bytes  payload         = 8;
//!     optional string LogIDNew        = 9;
//!   }

const std = @import("std");

const log = std.log.scoped(.lark_proto);

// ── Frame method constants ──────────────────────────────────────────
pub const METHOD_CONTROL: i32 = 0;
pub const METHOD_DATA: i32 = 1;

// ── Header key constants ────────────────────────────────────────────
pub const HEADER_TYPE = "type";
pub const HEADER_MESSAGE_ID = "message_id";
pub const HEADER_SUM = "sum";
pub const HEADER_SEQ = "seq";
pub const HEADER_TRACE_ID = "trace_id";
pub const HEADER_BIZ_RT = "biz_rt";
pub const HEADER_HANDSHAKE_STATUS = "handshake-status";
pub const HEADER_HANDSHAKE_MSG = "handshake-msg";

// ── Message type constants ──────────────────────────────────────────
pub const MSG_PING = "ping";
pub const MSG_PONG = "pong";
pub const MSG_EVENT = "event";
pub const MSG_CARD = "card";

// ── Data structures ─────────────────────────────────────────────────

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub const Frame = struct {
    seq_id: u64 = 0,
    log_id: u64 = 0,
    service: i32 = 0,
    method: i32 = 0,
    headers: []const Header = &.{},
    payload_encoding: []const u8 = "",
    payload_type: []const u8 = "",
    payload: []const u8 = "",
    log_id_new: []const u8 = "",

    /// Find a header value by key.
    pub fn getHeader(self: *const Frame, key: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.mem.eql(u8, h.key, key)) return h.value;
        }
        return null;
    }
};

/// Result of decoding a Frame. Owns the headers slice.
pub const DecodedFrame = struct {
    frame: Frame,
    /// Heap-allocated headers array (caller must free).
    headers_buf: []Header,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedFrame) void {
        self.allocator.free(self.headers_buf);
    }
};

// ── Protobuf varint encoding/decoding ───────────────────────────────

fn encodeVarint(buf: []u8, value: u64) usize {
    var v = value;
    var i: usize = 0;
    while (v > 0x7F) : (i += 1) {
        buf[i] = @as(u8, @intCast(v & 0x7F)) | 0x80;
        v >>= 7;
    }
    buf[i] = @as(u8, @intCast(v & 0x7F));
    return i + 1;
}

fn decodeVarint(data: []const u8, pos: *usize) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (pos.* + i >= data.len) return error.UnexpectedEndOfData;
        const b = data[pos.* + i];
        result |= @as(u64, b & 0x7F) << shift;
        if ((b & 0x80) == 0) {
            pos.* += i + 1;
            return result;
        }
        shift +%= 7;
    }
    return error.VarintTooLong;
}

// ── Protobuf encoding ───────────────────────────────────────────────

fn writeTag(writer: anytype, field: u32, wire_type: u3) !void {
    var buf: [5]u8 = undefined;
    const tag_val: u64 = (@as(u64, field) << 3) | wire_type;
    const n = encodeVarint(&buf, tag_val);
    try writer.writeAll(buf[0..n]);
}

fn writeVarintField(writer: anytype, field: u32, value: u64) !void {
    try writeTag(writer, field, 0); // wireType 0 = varint
    var buf: [10]u8 = undefined;
    const n = encodeVarint(&buf, value);
    try writer.writeAll(buf[0..n]);
}

fn writeSignedVarintField(writer: anytype, field: u32, value: i32) !void {
    // protobuf int32 uses standard varint encoding (sign-extended to 64 bits)
    const v: u64 = @bitCast(@as(i64, value));
    try writeVarintField(writer, field, v);
}

fn writeBytesField(writer: anytype, field: u32, data: []const u8) !void {
    try writeTag(writer, field, 2); // wireType 2 = length-delimited
    var buf: [10]u8 = undefined;
    const n = encodeVarint(&buf, data.len);
    try writer.writeAll(buf[0..n]);
    try writer.writeAll(data);
}

fn encodeHeader(writer: anytype, header: Header) !void {
    // Header is embedded as a length-delimited sub-message
    // First, calculate the encoded size of the header
    var size_buf: [256]u8 = undefined;
    var size_fbs = std.io.fixedBufferStream(&size_buf);
    const sw = size_fbs.writer();

    // field 1: key (string)
    try writeBytesField(sw, 1, header.key);
    // field 2: value (string)
    try writeBytesField(sw, 2, header.value);

    const header_bytes = size_fbs.getWritten();

    // Write tag for field 5 (headers), wireType 2
    try writeTag(writer, 5, 2);
    // Write length
    var len_buf: [10]u8 = undefined;
    const len_n = encodeVarint(&len_buf, header_bytes.len);
    try writer.writeAll(len_buf[0..len_n]);
    // Write header content
    try writer.writeAll(header_bytes);
}

/// Encode a Frame into a byte buffer. Returns the encoded bytes.
pub fn encodeFrame(buf: []u8, frame: *const Frame) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // field 1: SeqID (uint64)
    try writeVarintField(w, 1, frame.seq_id);
    // field 2: LogID (uint64)
    try writeVarintField(w, 2, frame.log_id);
    // field 3: service (int32)
    try writeSignedVarintField(w, 3, frame.service);
    // field 4: method (int32)
    try writeSignedVarintField(w, 4, frame.method);
    // field 5: headers (repeated Header)
    for (frame.headers) |h| {
        try encodeHeader(w, h);
    }
    // field 6: payloadEncoding (optional string)
    if (frame.payload_encoding.len > 0) {
        try writeBytesField(w, 6, frame.payload_encoding);
    }
    // field 7: payloadType (optional string)
    if (frame.payload_type.len > 0) {
        try writeBytesField(w, 7, frame.payload_type);
    }
    // field 8: payload (optional bytes)
    if (frame.payload.len > 0) {
        try writeBytesField(w, 8, frame.payload);
    }
    // field 9: LogIDNew (optional string)
    if (frame.log_id_new.len > 0) {
        try writeBytesField(w, 9, frame.log_id_new);
    }

    return fbs.getWritten();
}

// ── Protobuf decoding ───────────────────────────────────────────────

fn decodeHeaderMsg(data: []const u8) !Header {
    var pos: usize = 0;
    var key: []const u8 = "";
    var value: []const u8 = "";

    while (pos < data.len) {
        const tag = try decodeVarint(data, &pos);
        const field_num: u32 = @intCast(tag >> 3);
        const wire_type: u3 = @intCast(tag & 7);

        switch (field_num) {
            1 => { // key: string
                if (wire_type != 2) return error.InvalidWireType;
                const len = try decodeVarint(data, &pos);
                const end = pos + @as(usize, @intCast(len));
                if (end > data.len) return error.UnexpectedEndOfData;
                key = data[pos..end];
                pos = end;
            },
            2 => { // value: string
                if (wire_type != 2) return error.InvalidWireType;
                const len = try decodeVarint(data, &pos);
                const end = pos + @as(usize, @intCast(len));
                if (end > data.len) return error.UnexpectedEndOfData;
                value = data[pos..end];
                pos = end;
            },
            else => {
                // Skip unknown field
                try skipField(data, &pos, wire_type);
            },
        }
    }

    return .{ .key = key, .value = value };
}

fn skipField(data: []const u8, pos: *usize, wire_type: u3) !void {
    switch (wire_type) {
        0 => { // varint
            _ = try decodeVarint(data, pos);
        },
        1 => { // 64-bit
            if (pos.* + 8 > data.len) return error.UnexpectedEndOfData;
            pos.* += 8;
        },
        2 => { // length-delimited
            const len = try decodeVarint(data, pos);
            const skip_len: usize = @intCast(len);
            if (pos.* + skip_len > data.len) return error.UnexpectedEndOfData;
            pos.* += skip_len;
        },
        5 => { // 32-bit
            if (pos.* + 4 > data.len) return error.UnexpectedEndOfData;
            pos.* += 4;
        },
        else => return error.UnsupportedWireType,
    }
}

/// Decode a Frame from raw protobuf bytes. Caller must call deinit() on result.
pub fn decodeFrame(allocator: std.mem.Allocator, data: []const u8) !DecodedFrame {
    var pos: usize = 0;
    var frame: Frame = .{};
    var headers_list: std.ArrayListUnmanaged(Header) = .empty;
    errdefer headers_list.deinit(allocator);

    while (pos < data.len) {
        const tag = try decodeVarint(data, &pos);
        const field_num: u32 = @intCast(tag >> 3);
        const wire_type: u3 = @intCast(tag & 7);

        switch (field_num) {
            1 => { // SeqID: uint64
                if (wire_type != 0) return error.InvalidWireType;
                frame.seq_id = try decodeVarint(data, &pos);
            },
            2 => { // LogID: uint64
                if (wire_type != 0) return error.InvalidWireType;
                frame.log_id = try decodeVarint(data, &pos);
            },
            3 => { // service: int32
                if (wire_type != 0) return error.InvalidWireType;
                const v = try decodeVarint(data, &pos);
                frame.service = @intCast(@as(i64, @bitCast(v)));
            },
            4 => { // method: int32
                if (wire_type != 0) return error.InvalidWireType;
                const v = try decodeVarint(data, &pos);
                frame.method = @intCast(@as(i64, @bitCast(v)));
            },
            5 => { // headers: repeated Header (length-delimited sub-message)
                if (wire_type != 2) return error.InvalidWireType;
                const len = try decodeVarint(data, &pos);
                const end = pos + @as(usize, @intCast(len));
                if (end > data.len) return error.UnexpectedEndOfData;
                const header = try decodeHeaderMsg(data[pos..end]);
                try headers_list.append(allocator, header);
                pos = end;
            },
            6 => { // payloadEncoding: string
                if (wire_type != 2) return error.InvalidWireType;
                const len = try decodeVarint(data, &pos);
                const end = pos + @as(usize, @intCast(len));
                if (end > data.len) return error.UnexpectedEndOfData;
                frame.payload_encoding = data[pos..end];
                pos = end;
            },
            7 => { // payloadType: string
                if (wire_type != 2) return error.InvalidWireType;
                const len = try decodeVarint(data, &pos);
                const end = pos + @as(usize, @intCast(len));
                if (end > data.len) return error.UnexpectedEndOfData;
                frame.payload_type = data[pos..end];
                pos = end;
            },
            8 => { // payload: bytes
                if (wire_type != 2) return error.InvalidWireType;
                const len = try decodeVarint(data, &pos);
                const end = pos + @as(usize, @intCast(len));
                if (end > data.len) return error.UnexpectedEndOfData;
                frame.payload = data[pos..end];
                pos = end;
            },
            9 => { // LogIDNew: string
                if (wire_type != 2) return error.InvalidWireType;
                const len = try decodeVarint(data, &pos);
                const end = pos + @as(usize, @intCast(len));
                if (end > data.len) return error.UnexpectedEndOfData;
                frame.log_id_new = data[pos..end];
                pos = end;
            },
            else => {
                try skipField(data, &pos, wire_type);
            },
        }
    }

    const headers_buf = try headers_list.toOwnedSlice(allocator);
    frame.headers = headers_buf;

    return .{
        .frame = frame,
        .headers_buf = headers_buf,
        .allocator = allocator,
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "encodeVarint and decodeVarint round-trip small values" {
    var buf: [10]u8 = undefined;

    // 0
    var n = encodeVarint(&buf, 0);
    var pos: usize = 0;
    try std.testing.expectEqual(@as(u64, 0), try decodeVarint(&buf, &pos));
    try std.testing.expectEqual(@as(usize, n), pos);

    // 1
    n = encodeVarint(&buf, 1);
    pos = 0;
    try std.testing.expectEqual(@as(u64, 1), try decodeVarint(buf[0..n], &pos));

    // 127
    n = encodeVarint(&buf, 127);
    pos = 0;
    try std.testing.expectEqual(@as(u64, 127), try decodeVarint(buf[0..n], &pos));

    // 128
    n = encodeVarint(&buf, 128);
    pos = 0;
    try std.testing.expectEqual(@as(u64, 128), try decodeVarint(buf[0..n], &pos));

    // 300
    n = encodeVarint(&buf, 300);
    pos = 0;
    try std.testing.expectEqual(@as(u64, 300), try decodeVarint(buf[0..n], &pos));
}

test "encodeVarint and decodeVarint round-trip large values" {
    var buf: [10]u8 = undefined;

    const large: u64 = 0x7FFFFFFFFFFFFFFF;
    const n = encodeVarint(&buf, large);
    var pos: usize = 0;
    try std.testing.expectEqual(large, try decodeVarint(buf[0..n], &pos));
}

test "encodeFrame and decodeFrame round-trip ping frame" {
    const allocator = std.testing.allocator;
    const headers = [_]Header{
        .{ .key = HEADER_TYPE, .value = MSG_PING },
    };
    const frame = Frame{
        .seq_id = 0,
        .log_id = 0,
        .service = 42,
        .method = METHOD_CONTROL,
        .headers = &headers,
    };

    var buf: [512]u8 = undefined;
    const encoded = try encodeFrame(&buf, &frame);
    try std.testing.expect(encoded.len > 0);

    var decoded = try decodeFrame(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u64, 0), decoded.frame.seq_id);
    try std.testing.expectEqual(@as(i32, 42), decoded.frame.service);
    try std.testing.expectEqual(METHOD_CONTROL, decoded.frame.method);
    try std.testing.expectEqual(@as(usize, 1), decoded.frame.headers.len);
    try std.testing.expectEqualStrings(HEADER_TYPE, decoded.frame.headers[0].key);
    try std.testing.expectEqualStrings(MSG_PING, decoded.frame.headers[0].value);
}

test "encodeFrame and decodeFrame round-trip data frame with payload" {
    const allocator = std.testing.allocator;
    const payload_data = "{\"event\":\"test\"}";
    const headers = [_]Header{
        .{ .key = HEADER_TYPE, .value = MSG_EVENT },
        .{ .key = HEADER_MESSAGE_ID, .value = "msg-123" },
        .{ .key = HEADER_SUM, .value = "1" },
        .{ .key = HEADER_SEQ, .value = "0" },
    };
    const frame = Frame{
        .seq_id = 12345,
        .log_id = 67890,
        .service = 1,
        .method = METHOD_DATA,
        .headers = &headers,
        .payload = payload_data,
    };

    var buf: [1024]u8 = undefined;
    const encoded = try encodeFrame(&buf, &frame);
    try std.testing.expect(encoded.len > 0);

    var decoded = try decodeFrame(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u64, 12345), decoded.frame.seq_id);
    try std.testing.expectEqual(@as(u64, 67890), decoded.frame.log_id);
    try std.testing.expectEqual(@as(i32, 1), decoded.frame.service);
    try std.testing.expectEqual(METHOD_DATA, decoded.frame.method);
    try std.testing.expectEqual(@as(usize, 4), decoded.frame.headers.len);
    try std.testing.expectEqualStrings(payload_data, decoded.frame.payload);
}

test "Frame.getHeader finds existing header" {
    const headers = [_]Header{
        .{ .key = "type", .value = "ping" },
        .{ .key = "trace_id", .value = "abc-123" },
    };
    const frame = Frame{
        .headers = &headers,
    };
    try std.testing.expectEqualStrings("ping", frame.getHeader("type").?);
    try std.testing.expectEqualStrings("abc-123", frame.getHeader("trace_id").?);
    try std.testing.expect(frame.getHeader("missing") == null);
}

test "decodeFrame handles empty data gracefully" {
    const allocator = std.testing.allocator;
    var decoded = try decodeFrame(allocator, "");
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 0), decoded.frame.seq_id);
    try std.testing.expectEqual(@as(usize, 0), decoded.frame.headers.len);
}

test "encodeFrame minimal frame" {
    const frame = Frame{
        .seq_id = 0,
        .log_id = 0,
        .service = 0,
        .method = 0,
    };
    var buf: [64]u8 = undefined;
    const encoded = try encodeFrame(&buf, &frame);
    try std.testing.expect(encoded.len > 0);

    // Decode back
    var decoded = try decodeFrame(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u64, 0), decoded.frame.seq_id);
    try std.testing.expectEqual(@as(i32, 0), decoded.frame.method);
}

test "encodeFrame with LogIDNew and payloadEncoding" {
    const allocator = std.testing.allocator;
    const frame = Frame{
        .seq_id = 1,
        .log_id = 2,
        .service = 3,
        .method = 4,
        .payload_encoding = "gzip",
        .payload_type = "application/json",
        .log_id_new = "new-log-id-999",
    };
    var buf: [256]u8 = undefined;
    const encoded = try encodeFrame(&buf, &frame);

    var decoded = try decodeFrame(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("gzip", decoded.frame.payload_encoding);
    try std.testing.expectEqualStrings("application/json", decoded.frame.payload_type);
    try std.testing.expectEqualStrings("new-log-id-999", decoded.frame.log_id_new);
}
