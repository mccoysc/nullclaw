const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");

const log = std.log.scoped(.mqtt);

/// MQTT channel — publish/subscribe messaging over MQTT brokers.
///
/// Each endpoint represents a connection to a single broker+topic pair.
/// Inbound messages are verified against the peer's P256 public key;
/// outbound messages are signed with the local P256 private key.
///
/// Wire format (JSON on the MQTT payload):
///   { "pubkey": "<hex>", "sig": "<hex>", "body": "<base64>" }
///
/// When listen_topic == reply_topic (single-topic mode), the channel
/// filters out messages whose `pubkey` matches our own local_pubkey.
pub const MqttChannel = struct {
    allocator: std.mem.Allocator,
    config: config_types.MqttConfig,

    pub fn init(allocator: std.mem.Allocator, config: config_types.MqttConfig) MqttChannel {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.MqttConfig) MqttChannel {
        return init(allocator, cfg);
    }

    pub fn channelName(_: *MqttChannel) []const u8 {
        return "mqtt";
    }

    pub fn healthCheck(_: *MqttChannel) bool {
        return true;
    }

    /// Build a signed JSON payload for an outbound message.
    /// Format: {"pubkey":"<hex>","sig":"<hex>","body":"<base64>"}
    pub fn buildSignedPayload(self: *MqttChannel, message: []const u8, endpoint: config_types.MqttEndpointConfig) ![]u8 {
        _ = endpoint;
        _ = message;
        _ = self;
        // TODO: Implement P256 signing and base64 encoding when crypto primitives are available.
        // For now, return a placeholder that allows the channel to compile and register.
        return error.NotImplemented;
    }

    /// Verify an inbound payload against the peer's public key.
    pub fn verifyPayload(_: *MqttChannel, _: []const u8, _: config_types.MqttEndpointConfig) ![]u8 {
        // TODO: Implement P256 verification and base64 decoding.
        return error.NotImplemented;
    }

    // ── Channel vtable ──────────────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        _ = ptr;
        // TODO: Connect to MQTT broker(s), subscribe to listen_topic(s).
        // Each endpoint gets its own connection + subscriber thread.
        log.info("MQTT channel start (not yet connected — pending broker implementation)", .{});
    }

    fn vtableStop(ptr: *anyopaque) void {
        _ = ptr;
        log.info("MQTT channel stopped", .{});
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *MqttChannel = @ptrCast(@alignCast(ptr));
        _ = self;
        // TODO: Publish signed message to reply_topic (or listen_topic if reply_topic is null).
        log.info("MQTT send to {s}: {d} bytes (pending implementation)", .{ target, message.len });
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *MqttChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *MqttChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *MqttChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "MqttChannel basic init" {
    const cfg = config_types.MqttConfig{};
    var ch = MqttChannel.init(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("mqtt", ch.channelName());
    try std.testing.expect(ch.healthCheck());
}
