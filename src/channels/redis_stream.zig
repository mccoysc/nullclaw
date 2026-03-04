const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");

const log = std.log.scoped(.redis_stream);

/// Redis Stream channel — publish/subscribe messaging over Redis Streams.
///
/// Each endpoint represents a connection to a single Redis server + stream key pair.
/// Inbound messages are verified against the peer's P256 public key;
/// outbound messages are signed with the local P256 private key.
///
/// Wire format (JSON fields in the stream entry):
///   pubkey: <hex>   sig: <hex>   body: <base64>
///
/// When listen_topic == reply_topic (single-topic mode), the channel
/// filters out messages whose `pubkey` matches our own local_pubkey.
///
/// Uses XREADGROUP for consuming and XADD for publishing.
pub const RedisStreamChannel = struct {
    allocator: std.mem.Allocator,
    config: config_types.RedisStreamConfig,

    pub fn init(allocator: std.mem.Allocator, config: config_types.RedisStreamConfig) RedisStreamChannel {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.RedisStreamConfig) RedisStreamChannel {
        return init(allocator, cfg);
    }

    pub fn channelName(_: *RedisStreamChannel) []const u8 {
        return "redis_stream";
    }

    pub fn healthCheck(_: *RedisStreamChannel) bool {
        return true;
    }

    // ── Channel vtable ──────────────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        _ = ptr;
        // TODO: Connect to Redis, create consumer group (XGROUP CREATE),
        // spawn reader thread using XREADGROUP with BLOCK.
        log.info("Redis Stream channel start (not yet connected — pending implementation)", .{});
    }

    fn vtableStop(ptr: *anyopaque) void {
        _ = ptr;
        log.info("Redis Stream channel stopped", .{});
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *RedisStreamChannel = @ptrCast(@alignCast(ptr));
        _ = self;
        // TODO: XADD signed message to reply_topic (or listen_topic if reply_topic is null).
        log.info("Redis Stream send to {s}: {d} bytes (pending implementation)", .{ target, message.len });
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *RedisStreamChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *RedisStreamChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *RedisStreamChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "RedisStreamChannel basic init" {
    const cfg = config_types.RedisStreamConfig{};
    var ch = RedisStreamChannel.init(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("redis_stream", ch.channelName());
    try std.testing.expect(ch.healthCheck());
}
