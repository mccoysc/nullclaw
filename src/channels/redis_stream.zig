const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const bus_mod = @import("../bus.zig");

const log = std.log.scoped(.redis_stream);

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// Redis Stream channel — publish/subscribe messaging over Redis Streams.
///
/// Each endpoint represents a connection to a single Redis server + stream key pair.
/// Inbound messages are verified against the peer's P256 public key;
/// outbound messages are signed with the local P256 private key.
///
/// Wire format: The stream entry has three fields:
///   pubkey <hex>  sig <hex>  body <base64>
///
/// When listen_topic == reply_topic (single-topic mode), the channel
/// filters out messages whose `pubkey` matches our own local_pubkey.
///
/// Uses redis-cli subprocess for XREADGROUP (consume) and XADD (publish).
pub const RedisStreamChannel = struct {
    allocator: std.mem.Allocator,
    config: config_types.RedisStreamConfig,
    bus: ?*bus_mod.Bus = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader_threads: [MAX_ENDPOINTS]?std.Thread = [_]?std.Thread{null} ** MAX_ENDPOINTS,

    const MAX_ENDPOINTS = 8;

    pub fn init(allocator: std.mem.Allocator, config: config_types.RedisStreamConfig) RedisStreamChannel {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.RedisStreamConfig) RedisStreamChannel {
        return init(allocator, cfg);
    }

    pub fn channelName(_: *RedisStreamChannel) []const u8 {
        return "redis_stream";
    }

    pub fn setBus(self: *RedisStreamChannel, b: *bus_mod.Bus) void {
        self.bus = b;
    }

    pub fn healthCheck(self: *RedisStreamChannel) bool {
        return self.running.load(.acquire);
    }

    // ── P256 Signing / Verification ─────────────────────────────────

    /// Build a signed wire message for XADD.
    /// Returns the three field-value pairs as a JSON string for passing to redis-cli.
    pub fn buildSignedFields(self: *RedisStreamChannel, message: []const u8, endpoint: config_types.RedisStreamEndpointConfig) !struct { pubkey: []const u8, sig_hex: [128]u8, b64_body: []u8 } {
        // Decode private key from hex (32 bytes)
        const privkey_bytes = hexDecode(32, endpoint.local_privkey) catch return error.InvalidPrivateKey;
        const secret_key = EcdsaP256.SecretKey.fromBytes(privkey_bytes) catch return error.InvalidPrivateKey;
        const key_pair = EcdsaP256.KeyPair.fromSecretKey(secret_key) catch return error.InvalidPrivateKey;

        // Sign the raw message bytes
        const sig = key_pair.sign(message, null) catch return error.SigningFailed;
        const sig_bytes = sig.toBytes();

        // Base64 encode the message body
        const b64_len = std.base64.standard.Encoder.calcSize(message.len);
        const b64_buf = try self.allocator.alloc(u8, b64_len);
        _ = std.base64.standard.Encoder.encode(b64_buf, message);

        return .{
            .pubkey = endpoint.local_pubkey,
            .sig_hex = std.fmt.bytesToHex(sig_bytes, .lower),
            .b64_body = b64_buf,
        };
    }

    /// Verify inbound stream entry fields against the peer's public key.
    /// Returns the decoded message body on success, null on failure.
    pub fn verifyAndDecode(self: *RedisStreamChannel, pubkey_hex: []const u8, sig_hex_str: []const u8, b64_body: []const u8, endpoint: config_types.RedisStreamEndpointConfig) ?[]u8 {
        // In single-topic mode, filter out our own messages
        if (std.mem.eql(u8, pubkey_hex, endpoint.local_pubkey)) {
            return null; // Our own message, skip
        }

        // Verify that the pubkey matches the configured peer pubkey
        if (!std.mem.eql(u8, pubkey_hex, endpoint.peer_pubkey)) {
            log.warn("Redis Stream: inbound pubkey does not match configured peer_pubkey", .{});
            return null;
        }

        // Decode the base64 body
        const body_len = std.base64.standard.Decoder.calcSizeForSlice(b64_body) catch {
            log.warn("Redis Stream: failed to decode base64 body", .{});
            return null;
        };
        const body_buf = self.allocator.alloc(u8, body_len) catch return null;
        std.base64.standard.Decoder.decode(body_buf, b64_body) catch {
            self.allocator.free(body_buf);
            log.warn("Redis Stream: failed to decode base64 body", .{});
            return null;
        };

        // Decode signature from hex (64 bytes)
        const sig_bytes = hexDecode(64, sig_hex_str) catch {
            self.allocator.free(body_buf);
            log.warn("Redis Stream: failed to decode signature hex", .{});
            return null;
        };
        const signature = EcdsaP256.Signature.fromBytes(sig_bytes);

        // Decode peer public key from hex (uncompressed SEC1: 65 bytes)
        const pubkey_bytes = hexDecode(65, pubkey_hex) catch {
            self.allocator.free(body_buf);
            log.warn("Redis Stream: failed to decode peer pubkey hex", .{});
            return null;
        };
        const public_key = EcdsaP256.PublicKey.fromSec1(&pubkey_bytes) catch {
            self.allocator.free(body_buf);
            log.warn("Redis Stream: invalid peer public key", .{});
            return null;
        };

        // Verify signature against the decoded body
        signature.verify(body_buf[0..body_len], public_key) catch {
            self.allocator.free(body_buf);
            log.warn("Redis Stream: signature verification failed", .{});
            return null;
        };

        // body_buf is exactly body_len bytes (from calcSizeForSlice)
        return body_buf;
    }

    // ── Redis CLI helpers ───────────────────────────────────────────

    /// Build base redis-cli arguments (host, port, password, db).
    fn buildRedisBaseArgs(ep: config_types.RedisStreamEndpointConfig, port_buf: *[8]u8, db_buf: *[8]u8) struct { args: [12][]const u8, count: usize } {
        var args: [12][]const u8 = undefined;
        var argc: usize = 0;

        args[argc] = "redis-cli";
        argc += 1;
        args[argc] = "-h";
        argc += 1;
        args[argc] = ep.host;
        argc += 1;

        const port_str = std.fmt.bufPrint(port_buf, "{d}", .{ep.port}) catch "6379";
        args[argc] = "-p";
        argc += 1;
        args[argc] = port_str;
        argc += 1;

        if (ep.db != 0) {
            const db_str = std.fmt.bufPrint(db_buf, "{d}", .{ep.db}) catch "0";
            args[argc] = "-n";
            argc += 1;
            args[argc] = db_str;
            argc += 1;
        }

        if (ep.password) |pass| {
            args[argc] = "-a";
            argc += 1;
            args[argc] = pass;
            argc += 1;
        }

        if (ep.username) |user| {
            args[argc] = "--user";
            argc += 1;
            args[argc] = user;
            argc += 1;
        }

        return .{ .args = args, .count = argc };
    }

    /// Run a redis-cli command and return its stdout.
    fn runRedisCommand(self: *RedisStreamChannel, base_args: []const []const u8, extra_args: []const []const u8) ![]u8 {
        var argv_buf: [30][]const u8 = undefined;
        var argc: usize = 0;

        for (base_args) |arg| {
            argv_buf[argc] = arg;
            argc += 1;
        }
        for (extra_args) |arg| {
            argv_buf[argc] = arg;
            argc += 1;
        }

        var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.stdin_behavior = .Ignore;

        try child.spawn();

        const stdout = child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.RedisReadError;
        };

        const term = child.wait() catch {
            self.allocator.free(stdout);
            return error.RedisWaitError;
        };
        switch (term) {
            .Exited => |code| if (code != 0) {
                self.allocator.free(stdout);
                return error.RedisFailed;
            },
            else => {
                self.allocator.free(stdout);
                return error.RedisFailed;
            },
        }

        return stdout;
    }

    /// Ensure the consumer group exists (XGROUP CREATE ... MKSTREAM).
    fn ensureConsumerGroup(self: *RedisStreamChannel, ep: config_types.RedisStreamEndpointConfig) void {
        var port_buf: [8]u8 = undefined;
        var db_buf: [8]u8 = undefined;
        const base = buildRedisBaseArgs(ep, &port_buf, &db_buf);

        const result = self.runRedisCommand(base.args[0..base.count], &.{
            "XGROUP",    "CREATE",
            ep.listen_topic, ep.consumer_group,
            "$",         "MKSTREAM",
        }) catch {
            // Group may already exist, which is fine
            return;
        };
        self.allocator.free(result);
    }

    // ── Reader loop ─────────────────────────────────────────────────

    fn readerLoop(self: *RedisStreamChannel, ep_index: usize) void {
        if (ep_index >= self.config.endpoints.len) return;
        const ep = self.config.endpoints[ep_index];

        // Ensure consumer group exists
        self.ensureConsumerGroup(ep);

        while (self.running.load(.acquire)) {
            self.pollOnce(ep) catch |err| {
                if (self.running.load(.acquire)) {
                    log.warn("Redis Stream poll error on endpoint {d}: {}, retrying in 2s", .{ ep_index, err });
                    std.Thread.sleep(2 * std.time.ns_per_s);
                }
                continue;
            };
            // Small sleep between polls to avoid busy-waiting
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
    }

    fn pollOnce(self: *RedisStreamChannel, ep: config_types.RedisStreamEndpointConfig) !void {
        var port_buf: [8]u8 = undefined;
        var db_buf: [8]u8 = undefined;
        const base = buildRedisBaseArgs(ep, &port_buf, &db_buf);

        // XREADGROUP GROUP <group> <consumer> COUNT 10 BLOCK 1000 STREAMS <stream> >
        const output = try self.runRedisCommand(base.args[0..base.count], &.{
            "XREADGROUP", "GROUP",
            ep.consumer_group, ep.consumer_name,
            "COUNT",      "10",
            "STREAMS",    ep.listen_topic,
            ">",
        });
        defer self.allocator.free(output);

        // Parse redis-cli XREADGROUP output
        // Format varies, but typically each entry shows fields line by line
        self.parseXreadOutput(output, ep);
    }

    /// Parse the redis-cli XREADGROUP output to extract stream entries.
    /// The output format from redis-cli is line-based with indentation.
    /// We look for sequences: pubkey value, sig value, body value.
    fn parseXreadOutput(self: *RedisStreamChannel, output: []const u8, ep: config_types.RedisStreamEndpointConfig) void {
        var lines = std.mem.splitScalar(u8, output, '\n');
        var pubkey_val: ?[]const u8 = null;
        var sig_val: ?[]const u8 = null;

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n\"");
            if (line.len == 0) continue;

            // Look for field-value pattern in redis-cli output
            if (std.mem.eql(u8, line, "pubkey")) {
                if (lines.next()) |val_line| {
                    pubkey_val = std.mem.trim(u8, val_line, " \t\r\n\"");
                }
                continue;
            }
            if (std.mem.eql(u8, line, "sig")) {
                if (lines.next()) |val_line| {
                    sig_val = std.mem.trim(u8, val_line, " \t\r\n\"");
                }
                continue;
            }
            if (std.mem.eql(u8, line, "body")) {
                if (lines.next()) |val_line| {
                    const body_b64 = std.mem.trim(u8, val_line, " \t\r\n\"");
                    if (pubkey_val != null and sig_val != null and body_b64.len > 0) {
                        self.handleStreamEntry(pubkey_val.?, sig_val.?, body_b64, ep);
                    }
                }
                // Reset for next entry
                pubkey_val = null;
                sig_val = null;
                continue;
            }
        }
    }

    fn handleStreamEntry(self: *RedisStreamChannel, pubkey_hex: []const u8, sig_hex_str: []const u8, b64_body: []const u8, ep: config_types.RedisStreamEndpointConfig) void {
        // Verify and decode
        const body = self.verifyAndDecode(pubkey_hex, sig_hex_str, b64_body, ep) orelse return;
        defer self.allocator.free(body);

        // Build session key
        const session_key = std.fmt.allocPrint(self.allocator, "redis_stream:{s}:{s}", .{ self.config.account_id, ep.listen_topic }) catch return;
        defer self.allocator.free(session_key);

        // Publish to bus
        const msg = bus_mod.makeInbound(
            self.allocator,
            "redis_stream",
            "peer",
            ep.listen_topic,
            body,
            session_key,
        ) catch |err| {
            log.warn("Redis Stream: failed to create inbound message: {}", .{err});
            return;
        };

        if (self.bus) |b| {
            b.publishInbound(msg) catch |err| {
                log.warn("Redis Stream publishInbound failed: {}", .{err});
                msg.deinit(self.allocator);
            };
        } else {
            msg.deinit(self.allocator);
        }
    }

    /// Publish a signed message via redis-cli XADD.
    fn publishMessage(self: *RedisStreamChannel, ep: config_types.RedisStreamEndpointConfig, message: []const u8) !void {
        const fields = try self.buildSignedFields(message, ep);
        defer self.allocator.free(fields.b64_body);

        var port_buf: [8]u8 = undefined;
        var db_buf: [8]u8 = undefined;
        const base = buildRedisBaseArgs(ep, &port_buf, &db_buf);

        const reply_stream = ep.reply_topic orelse ep.listen_topic;

        // XADD <stream> * pubkey <hex> sig <hex> body <base64>
        const result = try self.runRedisCommand(base.args[0..base.count], &.{
            "XADD",       reply_stream,
            "*",          "pubkey",
            fields.pubkey, "sig",
            &fields.sig_hex, "body",
            fields.b64_body,
        });
        self.allocator.free(result);
    }

    // ── Channel vtable ──────────────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *RedisStreamChannel = @ptrCast(@alignCast(ptr));
        if (self.running.load(.acquire)) return;
        if (self.config.endpoints.len == 0) {
            log.warn("Redis Stream: no endpoints configured, skipping start", .{});
            return;
        }

        self.running.store(true, .release);

        // Spawn a reader thread per endpoint (up to MAX_ENDPOINTS)
        const count = @min(self.config.endpoints.len, MAX_ENDPOINTS);
        for (0..count) |i| {
            self.reader_threads[i] = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readerLoop, .{ self, i }) catch |err| {
                log.err("Redis Stream: failed to spawn reader thread for endpoint {d}: {}", .{ i, err });
                continue;
            };
        }
        log.info("Redis Stream channel started ({d} endpoint(s))", .{count});
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *RedisStreamChannel = @ptrCast(@alignCast(ptr));
        self.running.store(false, .release);

        // Join all reader threads
        for (&self.reader_threads) |*thread_slot| {
            if (thread_slot.*) |t| {
                t.join();
                thread_slot.* = null;
            }
        }
        log.info("Redis Stream channel stopped", .{});
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *RedisStreamChannel = @ptrCast(@alignCast(ptr));
        if (self.config.endpoints.len == 0) return error.NoEndpoints;
        _ = target;

        // Send to all endpoints
        for (self.config.endpoints) |ep| {
            self.publishMessage(ep, message) catch |err| {
                log.warn("Redis Stream: publish failed: {}", .{err});
            };
        }
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

// ═══════════════════════════════════════════════════════════════════════════
// Hex decode helper (comptime length)
// ═══════════════════════════════════════════════════════════════════════════

fn hexDecode(comptime N: usize, hex: []const u8) ![N]u8 {
    if (hex.len != N * 2) return error.InvalidHexLength;
    var result: [N]u8 = undefined;
    for (0..N) |i| {
        result[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return error.InvalidHex;
    }
    return result;
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "RedisStreamChannel basic init" {
    const cfg = config_types.RedisStreamConfig{};
    var ch = RedisStreamChannel.init(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("redis_stream", ch.channelName());
    try std.testing.expect(!ch.healthCheck()); // not running yet
}

test "RedisStreamChannel P256 signing roundtrip" {
    const allocator = std.testing.allocator;

    // Generate test keypairs
    const local_kp = EcdsaP256.KeyPair.generate();
    const local_privkey_hex = std.fmt.bytesToHex(local_kp.secret_key.toBytes(), .lower);
    const local_pubkey_hex = std.fmt.bytesToHex(local_kp.public_key.toUncompressedSec1(), .lower);

    const peer_kp = EcdsaP256.KeyPair.generate();
    const peer_pubkey_hex = std.fmt.bytesToHex(peer_kp.public_key.toUncompressedSec1(), .lower);

    const ep = config_types.RedisStreamEndpointConfig{
        .peer_pubkey = &peer_pubkey_hex,
        .local_privkey = &local_privkey_hex,
        .local_pubkey = &local_pubkey_hex,
        .listen_topic = "test:stream",
    };

    const cfg = config_types.RedisStreamConfig{ .endpoints = &.{ep} };
    var ch = RedisStreamChannel.init(allocator, cfg);

    const fields = try ch.buildSignedFields("hello redis", ep);
    defer allocator.free(fields.b64_body);

    // Verify pubkey matches
    try std.testing.expectEqualStrings(&local_pubkey_hex, fields.pubkey);
    // Verify signature length (P256 sig = 64 bytes = 128 hex chars)
    try std.testing.expectEqual(@as(usize, 128), fields.sig_hex.len);
}

test "RedisStreamChannel verify rejects self-message" {
    const allocator = std.testing.allocator;

    const local_kp = EcdsaP256.KeyPair.generate();
    const local_privkey_hex = std.fmt.bytesToHex(local_kp.secret_key.toBytes(), .lower);
    const local_pubkey_hex = std.fmt.bytesToHex(local_kp.public_key.toUncompressedSec1(), .lower);

    const peer_kp = EcdsaP256.KeyPair.generate();
    const peer_pubkey_hex = std.fmt.bytesToHex(peer_kp.public_key.toUncompressedSec1(), .lower);

    const ep = config_types.RedisStreamEndpointConfig{
        .peer_pubkey = &peer_pubkey_hex,
        .local_privkey = &local_privkey_hex,
        .local_pubkey = &local_pubkey_hex,
        .listen_topic = "test:stream",
    };

    const cfg = config_types.RedisStreamConfig{ .endpoints = &.{ep} };
    var ch = RedisStreamChannel.init(allocator, cfg);

    const fields = try ch.buildSignedFields("test msg", ep);
    defer allocator.free(fields.b64_body);

    // verifyAndDecode should return null (self-message: pubkey == local_pubkey)
    const result = ch.verifyAndDecode(&local_pubkey_hex, &fields.sig_hex, fields.b64_body, ep);
    try std.testing.expect(result == null);
}

test "RedisStreamChannel verify accepts valid peer message" {
    const allocator = std.testing.allocator;

    // Simulate a "peer" that signs
    const peer_kp = EcdsaP256.KeyPair.generate();
    const peer_privkey_hex = std.fmt.bytesToHex(peer_kp.secret_key.toBytes(), .lower);
    const peer_pubkey_hex = std.fmt.bytesToHex(peer_kp.public_key.toUncompressedSec1(), .lower);

    // Local keypair
    const local_kp = EcdsaP256.KeyPair.generate();
    const local_privkey_hex = std.fmt.bytesToHex(local_kp.secret_key.toBytes(), .lower);
    const local_pubkey_hex = std.fmt.bytesToHex(local_kp.public_key.toUncompressedSec1(), .lower);

    // Peer's endpoint config (used to sign)
    const peer_ep = config_types.RedisStreamEndpointConfig{
        .peer_pubkey = &local_pubkey_hex,
        .local_privkey = &peer_privkey_hex,
        .local_pubkey = &peer_pubkey_hex,
        .listen_topic = "test:stream",
    };

    // Our endpoint config (used to verify)
    const our_ep = config_types.RedisStreamEndpointConfig{
        .peer_pubkey = &peer_pubkey_hex,
        .local_privkey = &local_privkey_hex,
        .local_pubkey = &local_pubkey_hex,
        .listen_topic = "test:stream",
    };

    const peer_cfg = config_types.RedisStreamConfig{ .endpoints = &.{peer_ep} };
    var peer_ch = RedisStreamChannel.init(allocator, peer_cfg);

    const our_cfg = config_types.RedisStreamConfig{ .endpoints = &.{our_ep} };
    var our_ch = RedisStreamChannel.init(allocator, our_cfg);

    // Peer builds signed fields
    const fields = try peer_ch.buildSignedFields("hello from peer", peer_ep);
    defer allocator.free(fields.b64_body);

    // We verify and decode
    const body = our_ch.verifyAndDecode(&peer_pubkey_hex, &fields.sig_hex, fields.b64_body, our_ep);
    try std.testing.expect(body != null);
    defer allocator.free(body.?);
    try std.testing.expectEqualStrings("hello from peer", body.?);
}
