//! WebSocket client abstraction using libcurl.
//!
//! This module provides WebSocket functionality using libcurl's native WebSocket
//! support (available in curl 7.86+). Both text and binary frames are supported.

const std = @import("std");
const http_util = @import("http_util.zig");

const log = std.log.scoped(.ws_util);

// ===================================================================
// Unified WebSocket connection
// ===================================================================

/// Unified WebSocket connection using libcurl
pub const WsConnection = http_util.WsConnection;

/// WebSocket message structure
pub const WsMessage = http_util.WsMessage;

/// WebSocket frame type
pub const WsFrameType = http_util.WsFrameType;

// ===================================================================
// Public API
// ===================================================================

/// Connect to a WebSocket server using libcurl.
pub fn wsConnect(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const []const u8,
) !*WsConnection {
    return http_util.wsConnect(allocator, url, extra_headers);
}

/// Send a text message over WebSocket.
pub fn wsSend(conn: *WsConnection, message: []const u8) !void {
    try http_util.wsSendText(conn, message);
}

/// Send a binary message over WebSocket.
pub fn wsSendBinary(conn: *WsConnection, data: []const u8) !void {
    try http_util.wsSendBinary(conn, data);
}

/// Check if WebSocket connection is still alive.
pub fn wsIsConnected(conn: *WsConnection) bool {
    return http_util.wsIsConnected(conn);
}

/// Read a message from WebSocket.
/// Returns null if connection closed.
pub fn wsRecv(conn: *WsConnection, timeout_ms: u32) !?WsMessage {
    return http_util.wsRecv(conn, timeout_ms);
}

/// Close the WebSocket connection and free the handle.
pub fn wsClose(conn: *WsConnection) void {
    http_util.wsDestroy(conn);
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
