const std = @import("std");
const build_options = @import("build_options");
const windows = std.os.windows;

const MB_ERR_INVALID_CHARS: windows.DWORD = 0x00000008;

extern "kernel32" fn MultiByteToWideChar(
    code_page: windows.UINT,
    flags: windows.DWORD,
    src: ?[*]const u8,
    src_len: c_int,
    dst: ?[*]u16,
    dst_len: c_int,
) callconv(.winapi) c_int;

extern "kernel32" fn GetACP() callconv(.winapi) windows.UINT;

const PayloadEntry = struct {
    name: []const u8,
    bytes: []const u8,
    size: u64,
};

const payload: [5]PayloadEntry = .{
    .{ .name = "file-real.exe", .bytes = @embedFile("file_real_exe"), .size = build_options.size_file_real_exe },
    .{ .name = "libmagic-1.dll", .bytes = @embedFile("libmagic_1_dll"), .size = build_options.size_libmagic_1_dll },
    .{ .name = "libsystre-0.dll", .bytes = @embedFile("libsystre_0_dll"), .size = build_options.size_libsystre_0_dll },
    .{ .name = "libtre-5.dll", .bytes = @embedFile("libtre_5_dll"), .size = build_options.size_libtre_5_dll },
    .{ .name = "magic.mgc", .bytes = @embedFile("magic_mgc"), .size = build_options.size_magic_mgc },
};

const payload_hash_hex: []const u8 = build_options.payload_hash_hex;
const cache_dir_name: []const u8 = "payload-" ++ payload_hash_hex;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    const localappdata = init.environ_map.get("LOCALAPPDATA") orelse {
        std.debug.print("file_wrapper: LOCALAPPDATA not set\n", .{});
        return 2;
    };

    const cache_dir = try std.fs.path.join(arena, &.{ localappdata, "file_wrapper", cache_dir_name });
    try ensurePayloadExtracted(io, arena, cache_dir);

    const file_real_path = try std.fs.path.join(arena, &.{ cache_dir, "file-real.exe" });
    const magic_mgc_path = try std.fs.path.join(arena, &.{ cache_dir, "magic.mgc" });

    const args = try init.minimal.args.toSlice(arena);
    // yazi on Windows uses `file -bL --mime-type -f -` and writes paths via stdin.
    // This payload mishandles both `-f -` and `-L`, so normalize them here.
    const stdin_paths = if (usesFilesFromStdin(args))
        try readFilesFromStdinPaths(arena, io)
    else
        &.{};

    // 强制 -r 保留原始文件名输出，并让 -m 指向缓存中的 magic.mgc。
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, file_real_path);
    try argv.append(arena, "-r");
    try argv.append(arena, "-m");
    try argv.append(arena, magic_mgc_path);
    try appendForwardedArgs(arena, &argv, args);
    try argv.appendSlice(arena, stdin_paths);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        std.debug.print("file_wrapper: spawn {s}: {t}\n", .{ file_real_path, err });
        return 127;
    };
    defer child.kill(io);

    var stdout_task = try io.concurrent(readStreamAlloc, .{ arena, io, child.stdout.?, .unlimited });
    var stderr_task = try io.concurrent(readStreamAlloc, .{ arena, io, child.stderr.?, .unlimited });

    const stdout_bytes = try stdout_task.await(io);
    const stderr_bytes = try stderr_task.await(io);

    try writeChildOutput(io, arena, std.Io.File.stdout(), stdout_bytes);
    try writeChildOutput(io, arena, std.Io.File.stderr(), stderr_bytes);

    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => 1,
    };
}

fn writeChildOutput(io: std.Io, arena: std.mem.Allocator, out_file: std.Io.File, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const utf8 = try normalizeChildOutputAlloc(arena, bytes);
    try out_file.writeStreamingAll(io, utf8);
}

fn normalizeChildOutputAlloc(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len == 0 or std.unicode.utf8ValidateSlice(bytes)) return bytes;
    return windowsAcpToUtf8Alloc(arena, bytes);
}

fn appendForwardedArgs(
    arena: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    args: []const []const u8,
) !void {
    var i: usize = 1;
    var literal_args = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (literal_args) {
            try argv.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            literal_args = true;
            try argv.append(arena, arg);
            continue;
        }
        if (isFilesFromStdinPair(arg, if (i + 1 < args.len) args[i + 1] else null)) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--files-from")) {
            if (i + 1 < args.len) {
                try argv.append(arena, arg);
                i += 1;
                try argv.append(arena, args[i]);
                continue;
            }
            continue;
        }
        if (isFilesFromStdinInline(arg)) continue;
        if (normalizeForwardedArg(arg)) |sanitized| {
            try argv.append(arena, sanitized);
        }
    }
}

// This Windows payload errors out on `-L`, while yazi's preset plugins add it by
// default. Dropping it is more compatible than letting the whole invocation fail.
fn normalizeForwardedArg(arg: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, "-L")) return null;
    if (std.mem.eql(u8, arg, "--dereference")) return null;
    if (std.mem.eql(u8, arg, "-bL") or std.mem.eql(u8, arg, "-Lb")) return "-b";
    return arg;
}

fn windowsAcpToUtf8Alloc(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (bytes.len == 0) return "";

    const acp = GetACP();
    const src_len = std.math.cast(c_int, bytes.len) orelse return error.InputTooLong;
    const utf16_len = MultiByteToWideChar(acp, MB_ERR_INVALID_CHARS, bytes.ptr, src_len, null, 0);
    if (utf16_len == 0) return windows.unexpectedError(windows.GetLastError());

    const utf16 = try arena.alloc(u16, @intCast(utf16_len));
    const written = MultiByteToWideChar(acp, MB_ERR_INVALID_CHARS, bytes.ptr, src_len, utf16.ptr, utf16_len);
    if (written == 0) return windows.unexpectedError(windows.GetLastError());

    return std.unicode.utf16LeToUtf8Alloc(arena, utf16[0..@intCast(written)]);
}

fn readFilesFromStdinPaths(arena: std.mem.Allocator, io: std.Io) ![][]const u8 {
    const stdin_bytes = try readStreamAlloc(arena, io, std.Io.File.stdin(), .unlimited);
    const utf8 = if (stdin_bytes.len == 0 or std.unicode.utf8ValidateSlice(stdin_bytes))
        stdin_bytes
    else
        try windowsAcpToUtf8Alloc(arena, stdin_bytes);

    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, utf8, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len == 0) continue;
        try paths.append(arena, trimmed);
    }
    return paths.toOwnedSlice(arena);
}

fn usesFilesFromStdin(args: []const []const u8) bool {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (isFilesFromStdinPair(arg, if (i + 1 < args.len) args[i + 1] else null)) return true;
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--files-from")) {
            i += 1;
            continue;
        }
        if (isFilesFromStdinInline(arg)) return true;
    }
    return false;
}

fn isFilesFromStdinPair(arg: []const u8, next: ?[]const u8) bool {
    return (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--files-from")) and
        next != null and std.mem.eql(u8, next.?, "-");
}

fn isFilesFromStdinInline(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-f-") or std.mem.eql(u8, arg, "--files-from=-");
}

fn readStreamAlloc(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, limit: std.Io.Limit) ![]u8 {
    var file_reader: std.Io.File.Reader = .initStreaming(file, io, &.{});
    return file_reader.interface.allocRemaining(gpa, limit) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
        else => |e| return e,
    };
}

fn ensurePayloadExtracted(io: std.Io, arena: std.mem.Allocator, cache_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const marker_path = try std.fs.path.join(arena, &.{ cache_dir, ".ready" });

    if (markerOk(io, cwd, marker_path) and try allFilesPresent(io, cwd, arena, cache_dir)) return;

    try cwd.createDirPath(io, cache_dir);

    for (payload) |entry| {
        const final_path = try std.fs.path.join(arena, &.{ cache_dir, entry.name });
        if (try fileMatchesSize(io, cwd, final_path, entry.bytes.len)) continue;

        var f = try cwd.createFile(io, final_path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, entry.bytes);
    }

    // marker 最后写：它的存在即"全部就绪"。
    var mf = try cwd.createFile(io, marker_path, .{ .truncate = true });
    defer mf.close(io);
    try mf.writeStreamingAll(io, payload_hash_hex);
}

fn markerOk(io: std.Io, cwd: std.Io.Dir, marker_path: []const u8) bool {
    var f = cwd.openFile(io, marker_path, .{}) catch return false;
    defer f.close(io);
    var buf: [64]u8 = undefined;
    var reader = f.reader(io, &.{});
    const n = reader.interface.readSliceShort(&buf) catch return false;
    return std.mem.eql(u8, buf[0..n], payload_hash_hex);
}

fn allFilesPresent(io: std.Io, cwd: std.Io.Dir, arena: std.mem.Allocator, cache_dir: []const u8) !bool {
    for (payload) |entry| {
        const p = try std.fs.path.join(arena, &.{ cache_dir, entry.name });
        if (!try fileMatchesSize(io, cwd, p, entry.bytes.len)) return false;
    }
    return true;
}

fn fileMatchesSize(io: std.Io, cwd: std.Io.Dir, path: []const u8, expected: usize) !bool {
    var f = cwd.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer f.close(io);
    const st = f.stat(io) catch return false;
    return st.size == expected;
}
