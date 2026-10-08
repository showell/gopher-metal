//! **A SCRATCH DIRECTORY FROM ANY `Io`** (metal-vmm QUEUE 106): what
//! `std.testing.tmpDir` makes, `.zig-cache/tmp/<random>`, made through the
//! `Io` a caller passes, so a simulator run as a program (the explorer's
//! bench and soak) has one too; `std.testing`'s exists only in a test.

const std = @import("std");
const Io = std.Io;

pub const ScratchDir = struct {
    io: Io,
    dir: Io.Dir,
    parent_dir: Io.Dir,
    sub_path: [sub_path_len]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    pub fn make(io: Io, opts: Io.Dir.OpenOptions) !ScratchDir {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);
        var cache_dir = try Io.Dir.cwd().createDirPathOpen(io, ".zig-cache", .{});
        defer cache_dir.close(io);
        var parent_dir = try cache_dir.createDirPathOpen(io, "tmp", .{});
        errdefer parent_dir.close(io);
        const dir = try parent_dir.createDirPathOpen(io, &sub_path, .{ .open_options = opts });
        return .{ .io = io, .dir = dir, .parent_dir = parent_dir, .sub_path = sub_path };
    }

    pub fn cleanup(self: *ScratchDir) void {
        self.dir.close(self.io);
        self.parent_dir.deleteTree(self.io, &self.sub_path) catch {};
        self.parent_dir.close(self.io);
        self.* = undefined;
    }
};

test "a scratch directory is made, written in, and gone after" {
    const io = std.testing.io;
    var s = try ScratchDir.make(io, .{ .iterate = true });
    const name = s.sub_path;
    try s.dir.writeFile(io, .{ .sub_path = "x", .data = "y" });
    var parent = try Io.Dir.cwd().openDir(io, ".zig-cache/tmp", .{});
    defer parent.close(io);
    s.cleanup();
    try std.testing.expectError(error.FileNotFound, parent.openDir(io, &name, .{}));
}
