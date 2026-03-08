const std = @import("std");

/// Find the position of a JSON key in a JSON blob, ensuring it is followed by
/// a colon separator (i.e. it is actually a key, not a value).
/// Returns the position just after the closing quote of the key, or null.
fn findKeyPos(json: []const u8, quoted_key: []const u8) ?usize {
    var search_from: usize = 0;
    var in_string = false;
    var escaped = false;
    
    // First pass: find a valid key position (not inside a string value)
    for (json, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        
        if (c == '\\') {
            escaped = true;
            continue;
        }
        
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        
        // Only look for keys when not inside a string value
        if (!in_string and i >= search_from) {
            if (i + quoted_key.len <= json.len and std.mem.eql(u8, json[i..i+quoted_key.len], quoted_key)) {
                // Found potential key, verify it's followed by colon
                const after = json[i + quoted_key.len..];
                var j: usize = 0;
                while (j < after.len and (after[j] == ' ' or after[j] == '\t' or after[j] == '\n' or after[j] == '\r')) : (j += 1) {}
                if (j < after.len and after[j] == ':') {
                    return i + quoted_key.len;
                }
                // Not a valid key-value pair, continue searching
                search_from = i + quoted_key.len;
            }
        }
    }
    return null;
}

/// Extract a string field value from a JSON blob (minimal parser — no allocations).
pub fn parseStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const after_key_start = findKeyPos(json, quoted_key) orelse return null;
    const after_key = json[after_key_start..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1;

    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1;
            continue;
        }
        if (after_key[i] == '"') return after_key[start..i];
    }
    return null;
}

/// Extract a boolean field value from a JSON blob.
pub fn parseBoolField(json: []const u8, key: []const u8) ?bool {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const after_key_start = findKeyPos(json, quoted_key) orelse return null;
    const after_key = json[after_key_start..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    // Check for boolean literals
    if (i + 4 <= after_key.len and std.mem.eql(u8, after_key[i..][0..4], "true")) return true;
    if (i + 5 <= after_key.len and std.mem.eql(u8, after_key[i..][0..5], "false")) return false;
    
    // Reject numeric values that might be silently truncated
    if (i < after_key.len and (after_key[i] == '-' or (after_key[i] >= '0' and after_key[i] <= '9'))) return null;
    return null;
}

/// Extract an integer field value from a JSON blob.
/// Returns null for non-integer numbers (e.g. 3.14) rather than silently truncating.
pub fn parseIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const after_key_start = findKeyPos(json, quoted_key) orelse return null;
    const after_key = json[after_key_start..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    const start = i;
    if (i < after_key.len and after_key[i] == '-') i += 1;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    // Reject non-integer numbers (floats like 3.14 or 1e5) — do not silently truncate.
    if (i < after_key.len and (after_key[i] == '.' or after_key[i] == 'e' or after_key[i] == 'E')) return null;

    return std.fmt.parseInt(i64, after_key[start..i], 10) catch null;
}

/// Extract an unsigned integer field value from a JSON blob.
/// Returns null for non-integer numbers (e.g. 3.14) rather than silently truncating.
pub fn parseUintField(json: []const u8, key: []const u8) ?u64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const after_key_start = findKeyPos(json, quoted_key) orelse return null;
    const after_key = json[after_key_start..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}

    const start = i;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    // Reject non-integer numbers (floats like 3.14 or 1e5) — do not silently truncate.
    if (i < after_key.len and (after_key[i] == '.' or after_key[i] == 'e' or after_key[i] == 'E')) return null;

    return std.fmt.parseInt(u64, after_key[start..i], 10) catch null;
}

test "json_miniparse parseStringField basic" {
    const json = "{\"command\": \"echo hello\", \"other\": \"val\"}";
    const val = parseStringField(json, "command");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("echo hello", val.?);
}

test "json_miniparse parseBoolField values" {
    try std.testing.expectEqual(true, parseBoolField("{\"enabled\": true}", "enabled").?);
    try std.testing.expectEqual(false, parseBoolField("{\"enabled\": false}", "enabled").?);
}

test "json_miniparse parseIntField supports signed numbers" {
    try std.testing.expectEqual(@as(i64, 42), parseIntField("{\"n\": 42}", "n").?);
    try std.testing.expectEqual(@as(i64, -7), parseIntField("{\"n\": -7}", "n").?);
}

test "json_miniparse parseUintField supports positive numbers" {
    try std.testing.expectEqual(@as(u64, 42), parseUintField("{\"n\": 42}", "n").?);
}

test "json_miniparse missing fields return null" {
    try std.testing.expect(parseStringField("{\"x\":1}", "name") == null);
    try std.testing.expect(parseBoolField("{\"x\":1}", "enabled") == null);
    try std.testing.expect(parseIntField("{\"x\":1}", "n") == null);
    try std.testing.expect(parseUintField("{\"x\":1}", "n") == null);
}

test "json_miniparse key not matched inside value string" {
    // "name" appears as a value, not a key — must not be matched
    const json = "{\"value\": \"name\", \"name\": \"alice\"}";
    const val = parseStringField(json, "name");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("alice", val.?);
}

test "json_miniparse parseIntField rejects float" {
    // 3.14 is not an integer — must return null, not silently truncate to 3
    try std.testing.expect(parseIntField("{\"n\": 3.14}", "n") == null);
    try std.testing.expect(parseIntField("{\"n\": 1e5}", "n") == null);
}

test "json_miniparse parseUintField rejects float" {
    try std.testing.expect(parseUintField("{\"n\": 3.14}", "n") == null);
    try std.testing.expect(parseUintField("{\"n\": 1E10}", "n") == null);
}
