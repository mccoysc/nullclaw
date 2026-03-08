const std = @import("std");

pub fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const norm_path = normalizeWindowsPrefix(path);
        const norm_prefix = normalizeWindowsPrefix(prefix);
        if (!windowsPrefixEquals(norm_path, norm_prefix)) return false;
        if (norm_path.len == norm_prefix.len) return true;
        if (norm_prefix.len > 0 and isWindowsPathSeparator(norm_prefix[norm_prefix.len - 1])) return true;
        return isWindowsPathSeparator(norm_path[norm_prefix.len]);
    }

    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    if (prefix.len > 0 and (prefix[prefix.len - 1] == '/' or prefix[prefix.len - 1] == '\\')) return true;
    const c = path[prefix.len];
    return c == '/' or c == '\\';
}

// Buffer for UNC path normalization
var unc_norm_buf: [1024]u8 = undefined;

fn normalizeWindowsPrefix(path: []const u8) []const u8 {
    // \\?\UNC\server\share  →  \\server\share  (UNC extended path)
    if (path.len >= 8 and
        path[0] == '\\' and path[1] == '\\' and path[2] == '?' and path[3] == '\\' and
        (path[4] == 'U' or path[4] == 'u') and
        (path[5] == 'N' or path[5] == 'n') and
        (path[6] == 'C' or path[6] == 'c') and
        path[7] == '\\')
    {
        // Replace \\?\UNC\ with \\ so the result is \\server\share
        // For "\\?\UNC\server\share", we want to return "\\server\share"
        if (path.len - 8 >= unc_norm_buf.len - 2) {
            // Path too long for our buffer, return original as fallback
            return path;
        }
        
        // Copy "\\" prefix
        unc_norm_buf[0] = '\\';
        unc_norm_buf[1] = '\\';
        
        // Copy the server\share part
        @memcpy(unc_norm_buf[2..][0..path.len - 8], path[8..]);
        
        return unc_norm_buf[0 .. 2 + path.len - 8];
    }
    // \\?\C:\...  →  C:\...  (local extended path)
    if (path.len >= 4 and path[0] == '\\' and path[1] == '\\' and path[2] == '?' and path[3] == '\\') {
        return path[4..];
    }
    return path;
}

fn isWindowsPathSeparator(c: u8) bool {
    return c == '\\' or c == '/';
}

fn windowsPrefixEquals(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    for (prefix, 0..) |pc, i| {
        const c = path[i];
        if (isWindowsPathSeparator(c) and isWindowsPathSeparator(pc)) continue;
        if (std.ascii.toLower(c) != std.ascii.toLower(pc)) return false;
    }
    return true;
}

test "path_prefix exact and nested match" {
    try std.testing.expect(pathStartsWith("/foo/bar", "/foo/bar"));
    try std.testing.expect(pathStartsWith("/foo/bar/baz", "/foo/bar"));
}

test "path_prefix rejects partial segment" {
    try std.testing.expect(!pathStartsWith("/foo/barbaz", "/foo/bar"));
}

test "path_prefix accepts separator-terminated roots" {
    try std.testing.expect(pathStartsWith("/tmp/workspace", "/"));
    try std.testing.expect(pathStartsWith("C:\\tmp\\workspace", "C:\\"));
}

test "path_prefix windows case-insensitive and separators" {
    if (comptime @import("builtin").os.tag != .windows) return;
    try std.testing.expect(pathStartsWith("c:\\windows\\system32\\cmd.exe", "C:\\Windows"));
    try std.testing.expect(pathStartsWith("C:/Windows/System32/cmd.exe", "C:\\Windows"));
    try std.testing.expect(pathStartsWith("\\\\?\\C:\\Windows\\System32\\cmd.exe", "C:\\Windows"));
}

test "path_prefix windows UNC extended path normalization" {
    if (comptime @import("builtin").os.tag != .windows) return;
    // \\?\UNC\server\share\file should match \\server\share
    try std.testing.expect(pathStartsWith("\\\\?\\UNC\\server\\share\\file.txt", "\\\\server\\share"));
    // Case-insensitive UNC prefix
    try std.testing.expect(pathStartsWith("\\\\?\\unc\\server\\share\\file.txt", "\\\\server\\share"));
}
