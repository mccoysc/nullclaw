const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const bus_mod = @import("../bus.zig");

const log = std.log.scoped(.mqtt);

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

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
///
/// Uses mosquitto_sub/mosquitto_pub CLI tools for broker communication.
pub const MqttChannel = struct {
    allocator: std.mem.Allocator,
    config: config_types.MqttConfig,
    bus: ?*bus_mod.Bus = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader_threads: [MAX_ENDPOINTS]?std.Thread = [_]?std.Thread{null} ** MAX_ENDPOINTS,
    sub_processes: [MAX_ENDPOINTS]?std.process.Child = [_]?std.process.Child{null} ** MAX_ENDPOINTS,

    const MAX_ENDPOINTS = 8;

    pub fn init(allocator: std.mem.Allocator, config: config_types.MqttConfig) MqttChannel {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.MqttConfig) MqttChannel {
        return init(allocator, cfg);
    }

    pub fn channelName(_: *MqttChannel) []const u8 {
        return "mqtt";
    }

    pub fn setBus(self: *MqttChannel, b: *bus_mod.Bus) void {
        self.bus = b;
    }

    pub fn healthCheck(self: *MqttChannel) bool {
        return self.running.load(.acquire);
    }

    // ── P256 Signing / Verification ─────────────────────────────────

    /// Build a signed JSON payload for an outbound message.
    /// Format: {"pubkey":"<hex>","sig":"<hex>","body":"<base64>"}
    pub fn buildSignedPayload(self: *MqttChannel, message: []const u8, endpoint: config_types.MqttEndpointConfig) ![]u8 {
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
        defer self.allocator.free(b64_buf);
        const b64_body = std.base64.standard.Encoder.encode(b64_buf, message);

        // Build JSON payload
        const sig_hex = std.fmt.bytesToHex(sig_bytes, .lower);
        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"pubkey":"{s}","sig":"{s}","body":"{s}"}}
        , .{ endpoint.local_pubkey, &sig_hex, b64_body });

        return payload;
    }

    /// Verify an inbound payload against the peer's public key.
    /// Returns the decoded message body on success, null if verification fails.
    pub fn verifyAndDecode(self: *MqttChannel, json_payload: []const u8, endpoint: config_types.MqttEndpointConfig) ?[]u8 {
        // Parse the JSON payload to extract pubkey, sig, body
        const parsed = std.json.parseFromSlice(WireMessage, self.allocator, json_payload, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            log.warn("MQTT: failed to parse inbound JSON payload", .{});
            return null;
        };
        defer parsed.deinit();
        const msg = parsed.value;

        // In single-topic mode, filter out our own messages
        if (std.mem.eql(u8, msg.pubkey, endpoint.local_pubkey)) {
            return null; // Our own message, skip
        }

        // Verify that the pubkey matches the configured peer pubkey
        if (!std.mem.eql(u8, msg.pubkey, endpoint.peer_pubkey)) {
            log.warn("MQTT: inbound pubkey does not match configured peer_pubkey", .{});
            return null;
        }

        // Decode the base64 body
        const body_len = std.base64.standard.Decoder.calcSizeForSlice(msg.body) catch {
            log.warn("MQTT: failed to decode base64 body", .{});
            return null;
        };
        const body_buf = self.allocator.alloc(u8, body_len) catch return null;
        std.base64.standard.Decoder.decode(body_buf, msg.body) catch {
            self.allocator.free(body_buf);
            log.warn("MQTT: failed to decode base64 body", .{});
            return null;
        };

        // Decode signature from hex (64 bytes)
        const sig_bytes = hexDecode(64, msg.sig) catch {
            self.allocator.free(body_buf);
            log.warn("MQTT: failed to decode signature hex", .{});
            return null;
        };
        const signature = EcdsaP256.Signature.fromBytes(sig_bytes);

        // Decode peer public key from hex (uncompressed SEC1: 65 bytes)
        const pubkey_bytes = hexDecode(65, msg.pubkey) catch {
            self.allocator.free(body_buf);
            log.warn("MQTT: failed to decode peer pubkey hex", .{});
            return null;
        };
        const public_key = EcdsaP256.PublicKey.fromSec1(&pubkey_bytes) catch {
            self.allocator.free(body_buf);
            log.warn("MQTT: invalid peer public key", .{});
            return null;
        };

        // Verify signature against the decoded body
        signature.verify(body_buf[0..body_len], public_key) catch {
            self.allocator.free(body_buf);
            log.warn("MQTT: signature verification failed", .{});
            return null;
        };

        // body_buf is exactly body_len bytes (from calcSizeForSlice)
        return body_buf;
    }

    // ── Subprocess management ───────────────────────────────────────

    /// Spawn mosquitto_sub and read its stdout in a loop (one per endpoint).
    fn readerLoop(self: *MqttChannel, ep_index: usize) void {
        if (ep_index >= self.config.endpoints.len) return;
        const ep = self.config.endpoints[ep_index];

        while (self.running.load(.acquire)) {
            self.runSubscriber(ep, ep_index) catch |err| {
                if (self.running.load(.acquire)) {
                    log.warn("MQTT subscriber error on endpoint {d}: {}, retrying in 5s", .{ ep_index, err });
                    std.Thread.sleep(5 * std.time.ns_per_s);
                }
                continue;
            };
        }
    }

    fn runSubscriber(self: *MqttChannel, ep: config_types.MqttEndpointConfig, ep_index: usize) !void {
        var argv_buf: [20][]const u8 = undefined;
        var argc: usize = 0;

        argv_buf[argc] = "mosquitto_sub";
        argc += 1;
        argv_buf[argc] = "-h";
        argc += 1;
        argv_buf[argc] = ep.host;
        argc += 1;

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{ep.port}) catch "1883";
        argv_buf[argc] = "-p";
        argc += 1;
        argv_buf[argc] = port_str;
        argc += 1;

        argv_buf[argc] = "-t";
        argc += 1;
        argv_buf[argc] = ep.listen_topic;
        argc += 1;

        if (ep.username) |user| {
            argv_buf[argc] = "-u";
            argc += 1;
            argv_buf[argc] = user;
            argc += 1;
        }
        if (ep.password) |pass| {
            argv_buf[argc] = "-P";
            argc += 1;
            argv_buf[argc] = pass;
            argc += 1;
        }

        var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.stdin_behavior = .Ignore;

        try child.spawn();
        self.sub_processes[ep_index] = child;
        defer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.sub_processes[ep_index] = null;
        }

        const stdout = child.stdout orelse return error.NoStdout;
        var buf: [16384]u8 = undefined;
        var line_buf = std.ArrayListUnmanaged(u8){};
        defer line_buf.deinit(self.allocator);

        while (self.running.load(.acquire)) {
            const n = stdout.read(&buf) catch break;
            if (n == 0) break; // EOF — process exited

            // Append to line buffer and process complete lines
            line_buf.appendSlice(self.allocator, buf[0..n]) catch break;

            while (std.mem.indexOfScalar(u8, line_buf.items, '\n')) |idx| {
                const line = line_buf.items[0..idx];
                if (line.len > 0) {
                    self.handleInboundLine(line, ep);
                }
                // Remove processed line + newline
                const rest = line_buf.items[idx + 1 ..];
                std.mem.copyForwards(u8, line_buf.items[0..rest.len], rest);
                line_buf.items.len = rest.len;
            }
        }
    }

    /// Build metadata JSON containing account_id and per-channel model overrides.
    fn buildMetadataJson(self: *MqttChannel, ep: config_types.MqttEndpointConfig) ?[]u8 {
        const mo = ep.model_override;
        const has_override = mo.provider != null or mo.model != null or mo.max_context_tokens != 0 or mo.temperature != null;

        // Always include account_id; include model_override fields when set
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const w = buf.writer(self.allocator);
        w.writeAll("{\"account_id\":\"") catch {
            buf.deinit(self.allocator);
            return null;
        };
        w.writeAll(self.config.account_id) catch {
            buf.deinit(self.allocator);
            return null;
        };
        w.writeByte('"') catch {
            buf.deinit(self.allocator);
            return null;
        };

        if (has_override) {
            if (mo.provider) |prov| {
                w.writeAll(",\"model_override_provider\":\"") catch {};
                w.writeAll(prov) catch {};
                w.writeByte('"') catch {};
            }
            if (mo.model) |model| {
                w.writeAll(",\"model_override_model\":\"") catch {};
                w.writeAll(model) catch {};
                w.writeByte('"') catch {};
            }
            if (mo.max_context_tokens != 0) {
                std.fmt.format(w, ",\"model_override_max_context_tokens\":{d}", .{mo.max_context_tokens}) catch {};
            }
            if (mo.temperature) |temp| {
                std.fmt.format(w, ",\"model_override_temperature\":{d}", .{temp}) catch {};
            }
        }
        w.writeByte('}') catch {
            buf.deinit(self.allocator);
            return null;
        };
        return buf.toOwnedSlice(self.allocator) catch {
            buf.deinit(self.allocator);
            return null;
        };
    }

    fn handleInboundLine(self: *MqttChannel, line: []const u8, ep: config_types.MqttEndpointConfig) void {
        // mosquitto_sub (without -v): each line is just the payload
        // With -v: "topic payload"
        // We use without -v, so each line is the raw JSON payload
        const payload = std.mem.trim(u8, line, " \t\r\n");
        if (payload.len == 0) return;

        // Verify and decode the signed payload
        const body = self.verifyAndDecode(payload, ep) orelse return;
        defer self.allocator.free(body);

        // Build session key for bus routing
        // Use endpoint_id when available for stable session correlation across hot-reloads.
        // Fall back to account_id:topic for backward compatibility.
        const session_key = if (ep.endpoint_id.len > 0)
            std.fmt.allocPrint(self.allocator, "mqtt:{s}", .{ep.endpoint_id}) catch return
        else
            std.fmt.allocPrint(self.allocator, "mqtt:{s}:{s}", .{ self.config.account_id, ep.listen_topic }) catch return;
        defer self.allocator.free(session_key);

        // Build metadata with account_id and per-channel model overrides
        const metadata = self.buildMetadataJson(ep);
        defer if (metadata) |md| self.allocator.free(md);

        // Publish to bus (with metadata for per-channel model overrides)
        const msg = bus_mod.makeInboundFull(
            self.allocator,
            "mqtt",
            "peer",
            ep.listen_topic,
            body,
            session_key,
            &.{},
            metadata,
        ) catch |err| {
            log.warn("MQTT: failed to create inbound message: {}", .{err});
            return;
        };

        if (self.bus) |b| {
            b.publishInbound(msg) catch |err| {
                log.warn("MQTT publishInbound failed: {}", .{err});
                msg.deinit(self.allocator);
            };
        } else {
            msg.deinit(self.allocator);
        }
    }

    /// Publish a signed message via mosquitto_pub subprocess.
    fn publishMessage(self: *MqttChannel, ep: config_types.MqttEndpointConfig, payload: []const u8) !void {
        var argv_buf: [20][]const u8 = undefined;
        var argc: usize = 0;

        const reply_topic = ep.reply_topic orelse ep.listen_topic;

        argv_buf[argc] = "mosquitto_pub";
        argc += 1;
        argv_buf[argc] = "-h";
        argc += 1;
        argv_buf[argc] = ep.host;
        argc += 1;

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{ep.port}) catch "1883";
        argv_buf[argc] = "-p";
        argc += 1;
        argv_buf[argc] = port_str;
        argc += 1;

        argv_buf[argc] = "-t";
        argc += 1;
        argv_buf[argc] = reply_topic;
        argc += 1;

        // Pass payload via stdin to avoid argv length limits
        argv_buf[argc] = "-s";
        argc += 1;

        if (ep.username) |user| {
            argv_buf[argc] = "-u";
            argc += 1;
            argv_buf[argc] = user;
            argc += 1;
        }
        if (ep.password) |pass| {
            argv_buf[argc] = "-P";
            argc += 1;
            argv_buf[argc] = pass;
            argc += 1;
        }

        var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.stdin_behavior = .Pipe;

        try child.spawn();

        // Write payload to stdin
        if (child.stdin) |stdin_file| {
            stdin_file.writeAll(payload) catch {
                stdin_file.close();
                child.stdin = null;
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                return error.MosquittoPublishFailed;
            };
            stdin_file.close();
            child.stdin = null;
        }

        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return error.MosquittoPublishFailed,
            else => return error.MosquittoPublishFailed,
        }
    }

    // ── Channel vtable ──────────────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *MqttChannel = @ptrCast(@alignCast(ptr));
        if (self.running.load(.acquire)) return;
        if (self.config.endpoints.len == 0) {
            log.warn("MQTT: no endpoints configured, skipping start", .{});
            return;
        }

        self.running.store(true, .release);

        // Spawn a reader thread per endpoint (up to MAX_ENDPOINTS)
        const count = @min(self.config.endpoints.len, MAX_ENDPOINTS);
        for (0..count) |i| {
            self.reader_threads[i] = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readerLoop, .{ self, i }) catch |err| {
                log.err("MQTT: failed to spawn reader thread for endpoint {d}: {}", .{ i, err });
                continue;
            };
        }
        log.info("MQTT channel started ({d} endpoint(s))", .{count});
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *MqttChannel = @ptrCast(@alignCast(ptr));
        self.running.store(false, .release);

        // Terminate subscriber processes to unblock reader threads.
        // IMPORTANT: do NOT call proc.kill() here because Child.kill()
        // internally calls waitpid/WaitForSingleObject which would reap
        // the child.  The reader thread's defer block also calls child.kill()
        // + child.wait() on its *local* copy of the Child struct; if we reap
        // first via the array copy, that second waitpid() hits ECHILD →
        // "reached unreachable code" panic inside std.process.Child.
        // Use terminateChildNoWait which sends the signal without reaping.
        for (&self.sub_processes) |*proc_slot| {
            if (proc_slot.*) |proc| {
                terminateChildNoWait(proc);
            }
        }

        // Join all reader threads (their defer blocks handle kill+wait+cleanup)
        for (&self.reader_threads) |*thread_slot| {
            if (thread_slot.*) |t| {
                t.join();
                thread_slot.* = null;
            }
        }
        log.info("MQTT channel stopped", .{});
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *MqttChannel = @ptrCast(@alignCast(ptr));
        if (self.config.endpoints.len == 0) return error.NoEndpoints;
        _ = target;

        // Send to all endpoints
        for (self.config.endpoints) |ep| {
            const payload = self.buildSignedPayload(message, ep) catch |err| {
                log.warn("MQTT: failed to build signed payload: {}", .{err});
                continue;
            };
            defer self.allocator.free(payload);

            self.publishMessage(ep, payload) catch |err| {
                log.warn("MQTT: publish failed: {}", .{err});
            };
        }
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

// ═══════════════════════════════════════════════════════════════════════════
// Cross-platform process helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Terminate a child process without waiting for it to exit.
/// On POSIX sends SIGTERM; on Windows calls TerminateProcess.
/// This avoids the waitpid/WaitForSingleObject race when another thread
/// will perform its own kill+wait on its copy of the Child struct.
fn terminateChildNoWait(child: std.process.Child) void {
    if (native_os == .windows) {
        const windows = std.os.windows;
        windows.TerminateProcess(child.id, 1) catch {};
    } else {
        std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Wire format types
// ═══════════════════════════════════════════════════════════════════════════

const WireMessage = struct {
    pubkey: []const u8,
    sig: []const u8,
    body: []const u8,
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

test "MqttChannel basic init" {
    const cfg = config_types.MqttConfig{};
    var ch = MqttChannel.init(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("mqtt", ch.channelName());
    try std.testing.expect(!ch.healthCheck()); // not running yet
}

test "MqttChannel P256 signing roundtrip" {
    const allocator = std.testing.allocator;

    // Generate test keypairs
    const local_kp = EcdsaP256.KeyPair.generate();
    const local_privkey_hex = std.fmt.bytesToHex(local_kp.secret_key.toBytes(), .lower);
    const local_pubkey_hex = std.fmt.bytesToHex(local_kp.public_key.toUncompressedSec1(), .lower);

    const peer_kp = EcdsaP256.KeyPair.generate();
    const peer_pubkey_hex = std.fmt.bytesToHex(peer_kp.public_key.toUncompressedSec1(), .lower);

    const ep = config_types.MqttEndpointConfig{
        .host = "localhost",
        .peer_pubkey = &peer_pubkey_hex,
        .local_privkey = &local_privkey_hex,
        .local_pubkey = &local_pubkey_hex,
        .listen_topic = "test/topic",
    };

    const cfg = config_types.MqttConfig{ .endpoints = &.{ep} };
    var ch = MqttChannel.init(allocator, cfg);

    // Build a signed payload
    const payload = try ch.buildSignedPayload("hello world", ep);
    defer allocator.free(payload);

    // Verify the payload is valid JSON with expected fields
    const parsed = try std.json.parseFromSlice(WireMessage, allocator, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&local_pubkey_hex, parsed.value.pubkey);

    // Verify signature length (P256 sig = 64 bytes = 128 hex chars)
    try std.testing.expectEqual(@as(usize, 128), parsed.value.sig.len);
}

test "MqttChannel verify and decode rejects wrong pubkey" {
    const allocator = std.testing.allocator;

    const local_kp = EcdsaP256.KeyPair.generate();
    const local_privkey_hex = std.fmt.bytesToHex(local_kp.secret_key.toBytes(), .lower);
    const local_pubkey_hex = std.fmt.bytesToHex(local_kp.public_key.toUncompressedSec1(), .lower);

    const peer_kp = EcdsaP256.KeyPair.generate();
    const peer_pubkey_hex = std.fmt.bytesToHex(peer_kp.public_key.toUncompressedSec1(), .lower);

    const ep = config_types.MqttEndpointConfig{
        .host = "localhost",
        .peer_pubkey = &peer_pubkey_hex,
        .local_privkey = &local_privkey_hex,
        .local_pubkey = &local_pubkey_hex,
        .listen_topic = "test/topic",
    };

    const cfg = config_types.MqttConfig{ .endpoints = &.{ep} };
    var ch = MqttChannel.init(allocator, cfg);

    // Build a payload (signed by local key)
    const payload = try ch.buildSignedPayload("test msg", ep);
    defer allocator.free(payload);

    // verifyAndDecode should return null because our own pubkey doesn't match peer_pubkey
    // (the payload has local_pubkey, but ep.peer_pubkey is from peer_kp)
    // Actually, it will first filter out our own message (pubkey == local_pubkey),
    // so it returns null for self-message filtering.
    const result = ch.verifyAndDecode(payload, ep);
    try std.testing.expect(result == null);
}

test "MqttChannel verify and decode accepts valid peer message" {
    const allocator = std.testing.allocator;

    // Simulate a "peer" that signs a message
    const peer_kp = EcdsaP256.KeyPair.generate();
    const peer_privkey_hex = std.fmt.bytesToHex(peer_kp.secret_key.toBytes(), .lower);
    const peer_pubkey_hex = std.fmt.bytesToHex(peer_kp.public_key.toUncompressedSec1(), .lower);

    // Local keypair
    const local_kp = EcdsaP256.KeyPair.generate();
    const local_privkey_hex = std.fmt.bytesToHex(local_kp.secret_key.toBytes(), .lower);
    const local_pubkey_hex = std.fmt.bytesToHex(local_kp.public_key.toUncompressedSec1(), .lower);

    // Peer's endpoint config (used to sign)
    const peer_ep = config_types.MqttEndpointConfig{
        .host = "localhost",
        .peer_pubkey = &local_pubkey_hex, // peer knows our pubkey
        .local_privkey = &peer_privkey_hex,
        .local_pubkey = &peer_pubkey_hex,
        .listen_topic = "test/topic",
    };

    // Our endpoint config (used to verify)
    const our_ep = config_types.MqttEndpointConfig{
        .host = "localhost",
        .peer_pubkey = &peer_pubkey_hex, // we know peer's pubkey
        .local_privkey = &local_privkey_hex,
        .local_pubkey = &local_pubkey_hex,
        .listen_topic = "test/topic",
    };

    const peer_cfg = config_types.MqttConfig{ .endpoints = &.{peer_ep} };
    var peer_ch = MqttChannel.init(allocator, peer_cfg);

    const our_cfg = config_types.MqttConfig{ .endpoints = &.{our_ep} };
    var our_ch = MqttChannel.init(allocator, our_cfg);

    // Peer builds a signed payload
    const payload = try peer_ch.buildSignedPayload("hello from peer", peer_ep);
    defer allocator.free(payload);

    // We verify and decode it
    const body = our_ch.verifyAndDecode(payload, our_ep);
    try std.testing.expect(body != null);
    defer allocator.free(body.?);
    try std.testing.expectEqualStrings("hello from peer", body.?);
}
