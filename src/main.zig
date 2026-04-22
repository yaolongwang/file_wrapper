const std = @import("std");
const build_options = @import("build_options");

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

    // 强制 -m 指向缓存中的 magic.mgc，摆脱对 MAGIC 环境变量的依赖。
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, file_real_path);
    try argv.append(arena, "-m");
    try argv.append(arena, magic_mgc_path);
    if (args.len > 1) for (args[1..]) |a| try argv.append(arena, a);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("file_wrapper: spawn {s}: {t}\n", .{ file_real_path, err });
        return 127;
    };

    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => 1,
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
