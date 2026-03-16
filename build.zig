const std = @import("std");
const builtin = @import("builtin");

// ═══════════════════════════════════════════════════════════════════════════
// Vendored libcurl — compiled via autotools (configure/make)
// ═══════════════════════════════════════════════════════════════════════════

const CURL_VENDOR_DIR = "vendor/curl";
const CURL_SOURCE_DIR = CURL_VENDOR_DIR ++ "/curl-8.12.1";

/// Check if vendored curl source is available.
fn hasCurlSource(b: *std.Build) bool {
    const check_path = b.pathFromRoot(CURL_SOURCE_DIR ++ "/configure");
    return if (std.fs.cwd().access(check_path, .{})) |_| true else |_| false;
}

/// Returns true when the target differs from the build host (OS, arch, or ABI).
fn isCrossCompiling(target: std.Build.ResolvedTarget) bool {
    if (target.result.os.tag != builtin.os.tag) return true;
    if (target.result.cpu.arch != builtin.cpu.arch) return true;
    // On Linux, glibc vs musl matters for ABI compatibility.
    if (builtin.os.tag == .linux and target.result.abi != builtin.abi) return true;
    return false;
}

/// Compute a unique install directory name for the given target.
fn getTargetInstallDirName(allocator: std.mem.Allocator, target: std.Build.ResolvedTarget) []const u8 {
    const arch = @tagName(target.result.cpu.arch);
    const os = @tagName(target.result.os.tag);
    const abi = @tagName(target.result.abi);

    if (target.result.os.tag == .linux or target.result.os.tag == .freebsd) {
        return std.fmt.allocPrint(allocator, "install-{s}-{s}-{s}", .{ os, arch, abi }) catch "install";
    }
    return std.fmt.allocPrint(allocator, "install-{s}-{s}", .{ os, arch }) catch "install";
}

/// Construct the Zig target triple string for `zig cc -target <triple>`.
fn getZigTargetTriple(allocator: std.mem.Allocator, target: std.Build.ResolvedTarget) ![]const u8 {
    const arch = @tagName(target.result.cpu.arch);
    const os = @tagName(target.result.os.tag);
    const abi = @tagName(target.result.abi);

    if (target.result.os.tag == .linux or target.result.os.tag == .freebsd) {
        return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ arch, os, abi });
    }
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch, os });
}

/// Construct a GNU-style --host triple for autotools configure.
fn getConfigureHostTriple(allocator: std.mem.Allocator, target: std.Build.ResolvedTarget) ![]const u8 {
    const arch = @tagName(target.result.cpu.arch);
    const os_tag = target.result.os.tag;

    if (os_tag == .macos) {
        return std.fmt.allocPrint(allocator, "{s}-apple-darwin", .{arch});
    } else if (os_tag == .freebsd) {
        return std.fmt.allocPrint(allocator, "{s}-unknown-freebsd", .{arch});
    } else {
        // Linux: arch-linux-abi (e.g. aarch64-linux-musl, arm-linux-gnueabihf)
        const abi = @tagName(target.result.abi);
        return std.fmt.allocPrint(allocator, "{s}-linux-{s}", .{ arch, abi });
    }
}

/// Copy files from one directory to another (used for installing curl headers).
fn copyDirFiles(src_path: []const u8, dst_path: []const u8) !void {
    std.fs.cwd().makePath(dst_path) catch |err| {
        std.log.err("failed to create directory {s}: {s}", .{ dst_path, @errorName(err) });
        return err;
    };
    var src_dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer src_dir.close();
    var dst_dir = try std.fs.cwd().openDir(dst_path, .{});
    defer dst_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file) {
            src_dir.copyFile(entry.name, dst_dir, entry.name, .{}) catch |err| {
                std.log.err("failed to copy {s}: {s}", .{ entry.name, @errorName(err) });
                return err;
            };
        }
    }
}

/// Build libcurl from vendored source using autotools (configure/make).
/// For cross-compilation, uses `zig cc` as the C compiler.
/// Returns the install directory (relative to project root).
fn buildLibcurlFromSource(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ![]const u8 {
    const allocator = b.allocator;
    const is_cross = isCrossCompiling(target);
    const target_name = getTargetInstallDirName(allocator, target);
    const install_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ CURL_VENDOR_DIR, target_name });

    // Check if already built.
    const install_abs = b.pathFromRoot(install_dir);
    const lib_check = try std.fmt.allocPrint(allocator, "{s}/lib/libcurl.a", .{install_abs});
    defer allocator.free(lib_check);
    if (std.fs.cwd().access(lib_check, .{})) |_| {
        std.log.info("libcurl already built for {s}, skipping", .{target_name});
        return install_dir;
    } else |_| {}

    std.log.info("building libcurl via autotools for {s}...", .{target_name});

    const source_abs = b.pathFromRoot(CURL_SOURCE_DIR);

    // Use out-of-tree build directory in /tmp to allow concurrent target builds.
    const build_dir = try std.fmt.allocPrint(allocator, "/tmp/curl-build-{s}", .{target_name});
    std.fs.cwd().makePath(build_dir) catch |err| {
        std.log.err("failed to create curl build dir {s}: {s}", .{ build_dir, @errorName(err) });
        return err;
    };

    // ── configure ──
    var configure_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer configure_args.deinit(allocator);

    const configure_script = try std.fmt.allocPrint(allocator, "{s}/configure", .{source_abs});
    try configure_args.append(allocator, configure_script);

    const prefix_arg = try std.fmt.allocPrint(allocator, "--prefix={s}", .{install_abs});
    try configure_args.append(allocator, prefix_arg);
    try configure_args.append(allocator, "--enable-static");
    try configure_args.append(allocator, "--disable-shared");
    try configure_args.append(allocator, "--disable-ldap");
    try configure_args.append(allocator, "--disable-ldaps");
    try configure_args.append(allocator, "--without-brotli");
    try configure_args.append(allocator, "--without-nghttp2");
    try configure_args.append(allocator, "--without-zstd");
    try configure_args.append(allocator, "--without-libpsl");
    try configure_args.append(allocator, "--without-libidn2");

    if (is_cross) {
        // Cross-compilation: use zig cc as the C compiler.
        const zig_triple = try getZigTargetTriple(allocator, target);
        const cc_val = try std.fmt.allocPrint(allocator, "CC=zig cc -target {s}", .{zig_triple});
        try configure_args.append(allocator, cc_val);

        const host_triple = try getConfigureHostTriple(allocator, target);
        const host_arg = try std.fmt.allocPrint(allocator, "--host={s}", .{host_triple});
        try configure_args.append(allocator, host_arg);
    }

    // TLS backend selection.
    if (target.result.os.tag == .macos) {
        try configure_args.append(allocator, "--with-secure-transport");
    } else if (is_cross) {
        // Cross-compilation: skip TLS (target OpenSSL headers/libs may not be available).
        // The binary uses subprocess curl for HTTPS on the target system.
        try configure_args.append(allocator, "--without-ssl");
    } else {
        try configure_args.append(allocator, "--with-openssl");
    }

    var configure_proc = std.process.Child.init(configure_args.items, allocator);
    configure_proc.cwd = build_dir;
    try configure_proc.spawn();
    const configure_term = try configure_proc.wait();
    if (configure_term != .Exited or configure_term.Exited != 0) {
        std.log.err("curl configure failed for {s}", .{target_name});
        return error.ConfigureFailed;
    }

    // ── make ──
    const make_argv = [_][]const u8{ "make", "-j4" };
    var make_proc = std.process.Child.init(&make_argv, allocator);
    make_proc.cwd = build_dir;
    try make_proc.spawn();
    const make_term = try make_proc.wait();
    if (make_term != .Exited or make_term.Exited != 0) {
        std.log.err("curl make failed for {s}", .{target_name});
        return error.MakeFailed;
    }

    // ── install headers and library ──
    const src_include = try std.fmt.allocPrint(allocator, "{s}/include/curl", .{source_abs});
    defer allocator.free(src_include);
    const dst_include = try std.fmt.allocPrint(allocator, "{s}/include/curl", .{install_abs});
    defer allocator.free(dst_include);
    try copyDirFiles(src_include, dst_include);

    const lib_install_dir = try std.fmt.allocPrint(allocator, "{s}/lib", .{install_abs});
    defer allocator.free(lib_install_dir);
    try std.fs.cwd().makePath(lib_install_dir);

    const src_lib = try std.fmt.allocPrint(allocator, "{s}/lib/.libs/libcurl.a", .{build_dir});
    defer allocator.free(src_lib);
    const dst_lib = try std.fmt.allocPrint(allocator, "{s}/libcurl.a", .{lib_install_dir});
    defer allocator.free(dst_lib);
    try std.fs.cwd().copyFile(src_lib, std.fs.cwd(), dst_lib, .{});

    std.log.info("libcurl built and installed for {s}", .{target_name});
    return install_dir;
}

/// Link curl to a compile step per platform requirements:
///   Linux / FreeBSD: static libcurl.a (autotools) + dynamic system ssl/crypto/z
///   macOS:           static libcurl.a (autotools) + Secure Transport frameworks + z
///   Windows:         dynamic system libcurl (no source build)
fn linkCurlToStep(
    step: *std.Build.Step.Compile,
    b: *std.Build,
    curl_install_dir: ?[]const u8,
    target: std.Build.ResolvedTarget,
) void {
    const target_os = target.result.os.tag;

    if (target_os == .windows) {
        // Windows: dynamic link system libcurl (no source build needed).
        // Use vendored headers if available.
        if (hasCurlSource(b)) {
            step.addIncludePath(b.path(CURL_SOURCE_DIR ++ "/include"));
        }
        // Try VCPKG_INSTALLATION_ROOT for CI environments.
        if (std.process.getEnvVarOwned(b.allocator, "VCPKG_INSTALLATION_ROOT")) |vcpkg_root| {
            defer b.allocator.free(vcpkg_root);
            if (std.fmt.allocPrint(b.allocator, "{s}/installed/x64-windows/lib", .{vcpkg_root})) |lib_path| {
                step.addLibraryPath(.{ .cwd_relative = lib_path });
            } else |_| {}
            if (std.fmt.allocPrint(b.allocator, "{s}/installed/x64-windows/include", .{vcpkg_root})) |inc_path| {
                step.addIncludePath(.{ .cwd_relative = inc_path });
            } else |_| {}
        } else |_| {}
        step.linkSystemLibrary("curl");
    } else if (curl_install_dir) |install_dir| {
        // POSIX: link static libcurl built via autotools.
        const include_path = std.fmt.allocPrint(b.allocator, "{s}/include", .{install_dir}) catch return;
        step.addIncludePath(b.path(include_path));
        const lib_path = std.fmt.allocPrint(b.allocator, "{s}/lib/libcurl.a", .{install_dir}) catch return;
        step.addObjectFile(b.path(lib_path));

        if (target_os == .macos) {
            // macOS: Secure Transport + zlib
            step.linkSystemLibrary("z");
            step.linkFramework("CoreFoundation");
            step.linkFramework("Security");
            step.linkFramework("SystemConfiguration");
        } else {
            // Linux / FreeBSD: dynamic OpenSSL + zlib
            step.linkSystemLibrary("ssl");
            step.linkSystemLibrary("crypto");
            step.linkSystemLibrary("z");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Vendored SQLite integrity verification
// ═══════════════════════════════════════════════════════════════════════════

const VendoredFileHash = struct {
    path: []const u8,
    sha256_hex: []const u8,
};

const VENDORED_SQLITE_HASHES = [_]VendoredFileHash{
    .{
        .path = "vendor/sqlite3/sqlite3.c",
        .sha256_hex = "dc58f0b5b74e8416cc29b49163a00d6b8bf08a24dd4127652beaaae307bd1839",
    },
    .{
        .path = "vendor/sqlite3/sqlite3.h",
        .sha256_hex = "05c48cbf0a0d7bda2b6d0145ac4f2d3a5e9e1cb98b5d4fa9d88ef620e1940046",
    },
    .{
        .path = "vendor/sqlite3/sqlite3ext.h",
        .sha256_hex = "ea81fb7bd05882e0e0b92c4d60f677b205f7f1fbf085f218b12f0b5b3f0b9e48",
    },
};

fn hashWithCanonicalLineEndings(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk_start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            if (i > chunk_start) hasher.update(bytes[chunk_start..i]);
            hasher.update("\n");
            i += 1;
            chunk_start = i + 1;
        }
    }
    if (chunk_start < bytes.len) hasher.update(bytes[chunk_start..]);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn verifyVendoredSqliteHashes(b: *std.Build) !void {
    const max_vendor_file_size = 16 * 1024 * 1024;
    for (VENDORED_SQLITE_HASHES) |entry| {
        const file_path = b.pathFromRoot(entry.path);
        defer b.allocator.free(file_path);

        const bytes = std.fs.cwd().readFileAlloc(b.allocator, file_path, max_vendor_file_size) catch |err| {
            std.log.err("failed to read {s}: {s}", .{ file_path, @errorName(err) });
            return err;
        };
        defer b.allocator.free(bytes);

        const digest = hashWithCanonicalLineEndings(bytes);

        const actual_hex_buf = std.fmt.bytesToHex(digest, .lower);
        const actual_hex = actual_hex_buf[0..];

        if (!std.mem.eql(u8, actual_hex, entry.sha256_hex)) {
            std.log.err("vendored sqlite checksum mismatch for {s}", .{entry.path});
            std.log.err("expected: {s}", .{entry.sha256_hex});
            std.log.err("actual:   {s}", .{actual_hex});
            return error.VendoredSqliteChecksumMismatch;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Channel / engine selection (unchanged)
// ═══════════════════════════════════════════════════════════════════════════

const ChannelSelection = struct {
    enable_channel_cli: bool = false,
    enable_channel_telegram: bool = false,
    enable_channel_discord: bool = false,
    enable_channel_slack: bool = false,
    enable_channel_whatsapp: bool = false,
    enable_channel_matrix: bool = false,
    enable_channel_mattermost: bool = false,
    enable_channel_irc: bool = false,
    enable_channel_imessage: bool = false,
    enable_channel_email: bool = false,
    enable_channel_lark: bool = false,
    enable_channel_dingtalk: bool = false,
    enable_channel_line: bool = false,
    enable_channel_onebot: bool = false,
    enable_channel_qq: bool = false,
    enable_channel_maixcam: bool = false,
    enable_channel_signal: bool = false,
    enable_channel_mqtt: bool = false,
    enable_channel_redis_stream: bool = false,
    enable_channel_nostr: bool = false,
    enable_channel_web: bool = false,

    fn enableAll(self: *ChannelSelection) void {
        self.enable_channel_cli = true;
        self.enable_channel_telegram = true;
        self.enable_channel_discord = true;
        self.enable_channel_slack = true;
        self.enable_channel_whatsapp = true;
        self.enable_channel_matrix = true;
        self.enable_channel_mattermost = true;
        self.enable_channel_irc = true;
        self.enable_channel_imessage = true;
        self.enable_channel_email = true;
        self.enable_channel_lark = true;
        self.enable_channel_dingtalk = true;
        self.enable_channel_line = true;
        self.enable_channel_onebot = true;
        self.enable_channel_qq = true;
        self.enable_channel_maixcam = true;
        self.enable_channel_signal = true;
        self.enable_channel_mqtt = true;
        self.enable_channel_redis_stream = true;
        self.enable_channel_nostr = true;
        self.enable_channel_web = true;
    }
};

fn defaultChannels() ChannelSelection {
    var selection = ChannelSelection{};
    selection.enableAll();
    return selection;
}

fn parseChannelsOption(raw: []const u8) !ChannelSelection {
    var selection = ChannelSelection{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        std.log.err("empty -Dchannels list; use e.g. -Dchannels=all or -Dchannels=telegram,slack", .{});
        return error.InvalidChannelsOption;
    }

    var saw_token = false;
    var saw_all = false;
    var saw_none = false;

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) continue;
        saw_token = true;

        if (std.mem.eql(u8, token, "all")) {
            saw_all = true;
            selection.enableAll();
        } else if (std.mem.eql(u8, token, "none")) {
            saw_none = true;
            selection = .{};
        } else if (std.mem.eql(u8, token, "cli")) {
            selection.enable_channel_cli = true;
        } else if (std.mem.eql(u8, token, "telegram")) {
            selection.enable_channel_telegram = true;
        } else if (std.mem.eql(u8, token, "discord")) {
            selection.enable_channel_discord = true;
        } else if (std.mem.eql(u8, token, "slack")) {
            selection.enable_channel_slack = true;
        } else if (std.mem.eql(u8, token, "whatsapp")) {
            selection.enable_channel_whatsapp = true;
        } else if (std.mem.eql(u8, token, "matrix")) {
            selection.enable_channel_matrix = true;
        } else if (std.mem.eql(u8, token, "mattermost")) {
            selection.enable_channel_mattermost = true;
        } else if (std.mem.eql(u8, token, "irc")) {
            selection.enable_channel_irc = true;
        } else if (std.mem.eql(u8, token, "imessage")) {
            selection.enable_channel_imessage = true;
        } else if (std.mem.eql(u8, token, "email")) {
            selection.enable_channel_email = true;
        } else if (std.mem.eql(u8, token, "lark")) {
            selection.enable_channel_lark = true;
        } else if (std.mem.eql(u8, token, "dingtalk")) {
            selection.enable_channel_dingtalk = true;
        } else if (std.mem.eql(u8, token, "line")) {
            selection.enable_channel_line = true;
        } else if (std.mem.eql(u8, token, "onebot")) {
            selection.enable_channel_onebot = true;
        } else if (std.mem.eql(u8, token, "qq")) {
            selection.enable_channel_qq = true;
        } else if (std.mem.eql(u8, token, "maixcam")) {
            selection.enable_channel_maixcam = true;
        } else if (std.mem.eql(u8, token, "signal")) {
            selection.enable_channel_signal = true;
        } else if (std.mem.eql(u8, token, "mqtt")) {
            selection.enable_channel_mqtt = true;
        } else if (std.mem.eql(u8, token, "redis_stream") or std.mem.eql(u8, token, "redis-stream")) {
            selection.enable_channel_redis_stream = true;
        } else if (std.mem.eql(u8, token, "nostr")) {
            selection.enable_channel_nostr = true;
        } else if (std.mem.eql(u8, token, "web")) {
            selection.enable_channel_web = true;
        } else {
            std.log.err("unknown channel '{s}' in -Dchannels list", .{token});
            return error.InvalidChannelsOption;
        }
    }

    if (!saw_token) {
        std.log.err("empty -Dchannels list; use e.g. -Dchannels=all or -Dchannels=telegram,slack", .{});
        return error.InvalidChannelsOption;
    }
    if (saw_all and saw_none) {
        std.log.err("ambiguous -Dchannels list: cannot combine 'all' with 'none'", .{});
        return error.InvalidChannelsOption;
    }

    return selection;
}

const EngineSelection = struct {
    // Base backends
    enable_memory_none: bool = false,
    enable_memory_markdown: bool = false,
    enable_memory_memory: bool = false,
    enable_memory_api: bool = false,

    // Optional backends
    enable_sqlite: bool = false,
    enable_memory_sqlite: bool = false,
    enable_memory_lucid: bool = false,
    enable_memory_redis: bool = false,
    enable_memory_lancedb: bool = false,
    enable_postgres: bool = false,

    fn enableBase(self: *EngineSelection) void {
        self.enable_memory_none = true;
        self.enable_memory_markdown = true;
        self.enable_memory_memory = true;
        self.enable_memory_api = true;
    }

    fn enableAllOptional(self: *EngineSelection) void {
        self.enable_memory_sqlite = true;
        self.enable_memory_lucid = true;
        self.enable_memory_redis = true;
        self.enable_memory_lancedb = true;
        self.enable_postgres = true;
    }

    fn finalize(self: *EngineSelection) void {
        // SQLite runtime is needed by sqlite/lucid/lancedb memory backends.
        self.enable_sqlite = self.enable_memory_sqlite or self.enable_memory_lucid or self.enable_memory_lancedb;
    }

    fn hasAnyBackend(self: EngineSelection) bool {
        return self.enable_memory_none or
            self.enable_memory_markdown or
            self.enable_memory_memory or
            self.enable_memory_api or
            self.enable_memory_sqlite or
            self.enable_memory_lucid or
            self.enable_memory_redis or
            self.enable_memory_lancedb or
            self.enable_postgres;
    }
};

fn defaultEngines() EngineSelection {
    var selection = EngineSelection{};
    // Default binary: practical local setup with file/memory/api plus sqlite.
    selection.enableBase();
    selection.enable_memory_sqlite = true;
    selection.finalize();
    return selection;
}

fn parseEnginesOption(raw: []const u8) !EngineSelection {
    var selection = EngineSelection{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        std.log.err("empty -Dengines list; use e.g. -Dengines=base or -Dengines=base,sqlite", .{});
        return error.InvalidEnginesOption;
    }

    var saw_token = false;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t\r\n");
        if (token.len == 0) continue;
        saw_token = true;

        if (std.mem.eql(u8, token, "base") or std.mem.eql(u8, token, "minimal")) {
            selection.enableBase();
        } else if (std.mem.eql(u8, token, "all")) {
            selection.enableBase();
            selection.enableAllOptional();
        } else if (std.mem.eql(u8, token, "none")) {
            selection.enable_memory_none = true;
        } else if (std.mem.eql(u8, token, "markdown")) {
            selection.enable_memory_markdown = true;
        } else if (std.mem.eql(u8, token, "memory")) {
            selection.enable_memory_memory = true;
        } else if (std.mem.eql(u8, token, "api")) {
            selection.enable_memory_api = true;
        } else if (std.mem.eql(u8, token, "sqlite")) {
            selection.enable_memory_sqlite = true;
        } else if (std.mem.eql(u8, token, "lucid")) {
            selection.enable_memory_lucid = true;
        } else if (std.mem.eql(u8, token, "redis")) {
            selection.enable_memory_redis = true;
        } else if (std.mem.eql(u8, token, "lancedb")) {
            selection.enable_memory_lancedb = true;
        } else if (std.mem.eql(u8, token, "postgres")) {
            selection.enable_postgres = true;
        } else {
            std.log.err("unknown engine '{s}' in -Dengines list", .{token});
            return error.InvalidEnginesOption;
        }
    }

    if (!saw_token) {
        std.log.err("empty -Dengines list; use e.g. -Dengines=base or -Dengines=base,sqlite", .{});
        return error.InvalidEnginesOption;
    }

    selection.finalize();
    if (!selection.hasAnyBackend()) {
        std.log.err("no memory backends selected; choose at least one engine (e.g. base or none)", .{});
        return error.InvalidEnginesOption;
    }

    return selection;
}

// ═══════════════════════════════════════════════════════════════════════════
// Main build function
// ═══════════════════════════════════════════════════════════════════════════

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_wasi = target.result.os.tag == .wasi;
    const is_windows = target.result.os.tag == .windows;

    // --- Curl setup ---
    // Build static libcurl via autotools for all non-Windows, non-WASI targets.
    // Windows uses dynamic system libcurl. WASI has no curl.
    const curl_source_available = !is_wasi and hasCurlSource(b);
    const curl_install_dir: ?[]const u8 = if (curl_source_available and !is_windows) blk: {
        break :blk buildLibcurlFromSource(b, target) catch |err| {
            std.log.err("failed to build libcurl: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
    } else null;

    // --- Options ---
    const app_version = b.option([]const u8, "version", "Version string embedded in the binary") orelse
        getGitVersion(b) orelse "unknown";
    const channels_raw = b.option(
        []const u8,
        "channels",
        "Channels list. Tokens: all|none|cli|telegram|discord|slack|whatsapp|matrix|mattermost|irc|imessage|email|lark|dingtalk|line|onebot|qq|maixcam|signal|mqtt|redis_stream|nostr|web (default: all)",
    );
    const channels = if (channels_raw) |raw| blk: {
        const parsed = parseChannelsOption(raw) catch {
            std.process.exit(1);
        };
        break :blk parsed;
    } else defaultChannels();

    const engines_raw = b.option(
        []const u8,
        "engines",
        "Memory engines list. Tokens: base|minimal|all|none|markdown|memory|api|sqlite|lucid|redis|lancedb|postgres (default: base,sqlite)",
    );
    const engines = if (engines_raw) |raw| blk: {
        const parsed = parseEnginesOption(raw) catch {
            std.process.exit(1);
        };
        break :blk parsed;
    } else defaultEngines();

    const enable_memory_none = engines.enable_memory_none;
    const enable_memory_markdown = engines.enable_memory_markdown;
    const enable_memory_memory = engines.enable_memory_memory;
    const enable_memory_api = engines.enable_memory_api;
    const enable_sqlite = engines.enable_sqlite;
    const enable_memory_sqlite = engines.enable_memory_sqlite;
    const enable_memory_lucid = engines.enable_memory_lucid;
    const enable_memory_redis = engines.enable_memory_redis;
    const enable_memory_lancedb = engines.enable_memory_lancedb;
    const enable_postgres = engines.enable_postgres;
    const enable_channel_cli = channels.enable_channel_cli;
    const enable_channel_telegram = channels.enable_channel_telegram;
    const enable_channel_discord = channels.enable_channel_discord;
    const enable_channel_slack = channels.enable_channel_slack;
    const enable_channel_whatsapp = channels.enable_channel_whatsapp;
    const enable_channel_matrix = channels.enable_channel_matrix;
    const enable_channel_mattermost = channels.enable_channel_mattermost;
    const enable_channel_irc = channels.enable_channel_irc;
    const enable_channel_imessage = channels.enable_channel_imessage;
    const enable_channel_email = channels.enable_channel_email;
    const enable_channel_lark = channels.enable_channel_lark;
    const enable_channel_dingtalk = channels.enable_channel_dingtalk;
    const enable_channel_line = channels.enable_channel_line;
    const enable_channel_onebot = channels.enable_channel_onebot;
    const enable_channel_qq = channels.enable_channel_qq;
    const enable_channel_maixcam = channels.enable_channel_maixcam;
    const enable_channel_signal = channels.enable_channel_signal;
    const enable_channel_mqtt = channels.enable_channel_mqtt;
    const enable_channel_redis_stream = channels.enable_channel_redis_stream;
    const enable_channel_nostr = channels.enable_channel_nostr;
    // Resolve websocket dependency when the web channel is enabled.
    // The package is vendored in vendor/websocket/ so it is always available.
    const ws_dep: ?*std.Build.Dependency = if (channels.enable_channel_web)
        b.dependency("websocket", .{ .target = target, .optimize = optimize })
    else
        null;
    const enable_channel_web = channels.enable_channel_web;

    // Force-disable C-linked backends when targeting WASI (no C library linking in wasm32-wasi).
    const effective_enable_sqlite = enable_sqlite and !is_wasi;
    const effective_enable_postgres = enable_postgres and !is_wasi;
    if (is_wasi and enable_sqlite) {
        std.log.warn("SQLite backend disabled: C linking is not supported on wasm32-wasi", .{});
    }
    if (is_wasi and enable_postgres) {
        std.log.warn("PostgreSQL backend disabled: C linking is not supported on wasm32-wasi", .{});
    }
    const effective_enable_memory_sqlite = effective_enable_sqlite and enable_memory_sqlite;
    const effective_enable_memory_lucid = effective_enable_sqlite and enable_memory_lucid;
    const effective_enable_memory_lancedb = effective_enable_sqlite and enable_memory_lancedb;

    if (effective_enable_sqlite) {
        verifyVendoredSqliteHashes(b) catch {
            std.log.err("vendored sqlite integrity check failed", .{});
            std.process.exit(1);
        };
    }

    const sqlite3 = if (effective_enable_sqlite) blk: {
        const sqlite3_dep = b.dependency("sqlite3", .{
            .target = target,
            .optimize = optimize,
        });
        const sqlite3_artifact = sqlite3_dep.artifact("sqlite3");
        sqlite3_artifact.root_module.addCMacro("SQLITE_ENABLE_FTS5", "1");
        break :blk sqlite3_artifact;
    } else null;

    var build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption(bool, "enable_memory_none", enable_memory_none);
    build_options.addOption(bool, "enable_memory_markdown", enable_memory_markdown);
    build_options.addOption(bool, "enable_memory_memory", enable_memory_memory);
    build_options.addOption(bool, "enable_memory_api", enable_memory_api);
    build_options.addOption(bool, "enable_sqlite", effective_enable_sqlite);
    build_options.addOption(bool, "enable_postgres", effective_enable_postgres);
    build_options.addOption(bool, "enable_memory_sqlite", effective_enable_memory_sqlite);
    build_options.addOption(bool, "enable_memory_lucid", effective_enable_memory_lucid);
    build_options.addOption(bool, "enable_memory_redis", enable_memory_redis);
    build_options.addOption(bool, "enable_memory_lancedb", effective_enable_memory_lancedb);
    build_options.addOption(bool, "enable_channel_cli", enable_channel_cli);
    build_options.addOption(bool, "enable_channel_telegram", enable_channel_telegram);
    build_options.addOption(bool, "enable_channel_discord", enable_channel_discord);
    build_options.addOption(bool, "enable_channel_slack", enable_channel_slack);
    build_options.addOption(bool, "enable_channel_whatsapp", enable_channel_whatsapp);
    build_options.addOption(bool, "enable_channel_matrix", enable_channel_matrix);
    build_options.addOption(bool, "enable_channel_mattermost", enable_channel_mattermost);
    build_options.addOption(bool, "enable_channel_irc", enable_channel_irc);
    build_options.addOption(bool, "enable_channel_imessage", enable_channel_imessage);
    build_options.addOption(bool, "enable_channel_email", enable_channel_email);
    build_options.addOption(bool, "enable_channel_lark", enable_channel_lark);
    build_options.addOption(bool, "enable_channel_dingtalk", enable_channel_dingtalk);
    build_options.addOption(bool, "enable_channel_line", enable_channel_line);
    build_options.addOption(bool, "enable_channel_onebot", enable_channel_onebot);
    build_options.addOption(bool, "enable_channel_qq", enable_channel_qq);
    build_options.addOption(bool, "enable_channel_maixcam", enable_channel_maixcam);
    build_options.addOption(bool, "enable_channel_signal", enable_channel_signal);
    build_options.addOption(bool, "enable_channel_mqtt", enable_channel_mqtt);
    build_options.addOption(bool, "enable_channel_redis_stream", enable_channel_redis_stream);
    build_options.addOption(bool, "enable_channel_nostr", enable_channel_nostr);
    build_options.addOption(bool, "enable_channel_web", enable_channel_web);
    const build_options_module = build_options.createModule();

    // ---------- library module (importable by consumers) ----------
    const lib_mod: ?*std.Build.Module = if (is_wasi) null else blk: {
        const module = b.addModule("nullclaw", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("build_options", build_options_module);
        if (sqlite3) |lib| {
            module.linkLibrary(lib);
        }
        if (effective_enable_postgres) {
            module.linkSystemLibrary("pq", .{});
        }
        if (enable_channel_web) {
            module.addImport("websocket", ws_dep.?.module("websocket"));
        }
        break :blk module;
    };

    // ---------- executable ----------
    const exe_imports: []const std.Build.Module.Import = if (is_wasi)
        &.{}
    else
        &.{.{ .name = "nullclaw", .module = lib_mod.? }};

    const exe_root_module = b.createModule(.{
        .root_source_file = if (is_wasi) b.path("src/main_wasi.zig") else b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = exe_imports,
    });
    const exe = b.addExecutable(.{
        .name = "nullclaw",
        .root_module = exe_root_module,
    });
    exe.root_module.addImport("build_options", build_options_module);

    // Link libc so that std.DynLib uses dlopen/dlsym for SO plugin loading.
    // Without this Zig falls back to ElfDynLib which does not perform full
    // relocation, causing data-section pointers in plugin SOs to be invalid.
    if (!is_wasi) {
        exe.linkLibC();
    }

    // Link SQLite on the compile step (not the module)
    if (!is_wasi) {
        if (sqlite3) |lib| {
            exe.linkLibrary(lib);
        }
        if (effective_enable_postgres) {
            exe.root_module.linkSystemLibrary("pq", .{});
        }

        // Link libcurl
        if (curl_source_available or is_windows) {
            linkCurlToStep(exe, b, curl_install_dir, target);
        }
    }
    exe.dead_strip_dylibs = true;

    if (optimize != .Debug) {
        exe.root_module.strip = true;
        exe.root_module.unwind_tables = .none;
        exe.root_module.omit_frame_pointer = true;
    }

    b.installArtifact(exe);

    // macOS host+target only: strip local symbols post-install.
    // Host `strip` cannot process ELF/PE during cross-builds.
    if (optimize != .Debug and builtin.os.tag == .macos and target.result.os.tag == .macos) {
        const strip_cmd = b.addSystemCommand(&.{"strip"});
        strip_cmd.addArgs(&.{"-x"});
        strip_cmd.addFileArg(exe.getEmittedBin());
        strip_cmd.step.dependOn(b.getInstallStep());
        b.default_step = &strip_cmd.step;
    }

    // ---------- run step ----------
    const run_step = b.step("run", "Run nullclaw");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ---------- tests ----------
    const test_step = b.step("test", "Run all tests");
    if (!is_wasi) {
        const lib_tests = b.addTest(.{ .root_module = lib_mod.? });
        if (sqlite3) |lib| {
            lib_tests.linkLibrary(lib);
        }
        if (effective_enable_postgres) {
            lib_tests.root_module.linkSystemLibrary("pq", .{});
        }
        if (curl_source_available or is_windows) {
            lib_tests.linkLibC();
            linkCurlToStep(lib_tests, b, curl_install_dir, target);
        }

        const exe_tests = b.addTest(.{ .root_module = exe.root_module });
        if (curl_source_available or is_windows) {
            exe_tests.linkLibC();
            linkCurlToStep(exe_tests, b, curl_install_dir, target);
        }
        test_step.dependOn(&b.addRunArtifact(lib_tests).step);
        test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    }
}

/// Attempt to derive the version string from the current git tag.
/// Returns the exact tag (e.g. "v2026.3.7.2"), preserving any "v" prefix,
/// or null when git is unavailable or HEAD is not at an exact tag.
fn getGitVersion(b: *std.Build) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "describe", "--tags", "--exact-match" },
        .max_output_bytes = 256,
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return b.allocator.dupe(u8, trimmed) catch null;
}
