//! `io.zig`'s two disks, on the host: two FAT16 disks in memory
//! (`test_disk.zig`), the site's and the data volume, and the routing between
//! them that `keepData` sets up — which disk a path goes to, which writes are
//! refused, and that a refusal is logged.
//!
//! Each test sets io's routing itself (`mount`, then `keepData`), because it
//! is module state that outlives a test. What is not tested here:
//! `Dir.fromRoot`'s panic, which would take the test runner down with it.

const std = @import("std");
const io_mod = @import("io.zig");
const serial = @import("serial.zig");
const test_disk = @import("test_disk.zig");
const fat16 = @import("fat16.zig");

const testing = std.testing;
const Disk = test_disk.Disk;
const io = io_mod.io();
const cwd = io_mod.Dir.cwd();
const data_dirs = [_][]const u8{ "data", "auth" };

/// A site disk and a data volume, with io routing between them. With
/// `with_volume` false, the data directories are on the site's disk.
const Two = struct {
    site: *Disk,
    volume: *Disk,

    fn make(with_volume: bool) !Two {
        const site = try Disk.make("io-site", test_disk.small, false);
        errdefer site.deinit();
        const volume = try Disk.make("io-volume", test_disk.small, false);
        io_mod.mount(site.vol);
        io_mod.keepData(&data_dirs, if (with_volume) volume.vol else null);
        serial.clearCaptured();
        return .{ .site = site, .volume = volume };
    }

    /// After a test writes to a disk directly, through its own copy of the
    /// volume: io's copies take it, so that one copy, io's, is again the one
    /// that writes and keeps the free count (see `deinit`).
    fn resync(t: Two, with_volume: bool) void {
        io_mod.mount(t.site.vol);
        io_mod.keepData(&data_dirs, if (with_volume) t.volume.vol else null);
    }

    /// io holds its own copies of the volumes (io.mount and io.keepData take
    /// them by value), and those are the ones the writes moved: the kept free
    /// count among them. They come back before the disks are checked.
    fn deinit(t: Two) void {
        if (io_mod.siteVolume()) |v| t.site.vol = v.*;
        if (io_mod.dataVolume()) |v| t.volume.vol = v.*;
        t.site.deinit();
        t.volume.deinit();
    }
};

fn expectAbsent(d: *Disk, path: []const u8) !void {
    try testing.expectError(fat16.Error.NotFound, d.vol.open(path));
}

fn logged(what: []const u8) bool {
    return std.mem.indexOf(u8, serial.captured(), what) != null;
}

test "a write under data/ or auth/ lands on the volume, and nothing of it on the site's disk" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.createDirPath(io, "data/chat");
    try cwd.writeFile(io, .{ .sub_path = "data/chat/plan.md", .data = "on the volume" });
    try cwd.writeFile(io, .{ .sub_path = "auth/7/password", .data = "hash" });
    try t.volume.expectFile("data/chat/plan.md", "on the volume");
    try t.volume.expectFile("auth/7/password", "hash");
    try expectAbsent(t.site, "data");
    try expectAbsent(t.site, "auth");

    const got = try cwd.readFileAlloc(io, "data/chat/plan.md", testing.allocator, .limited(100));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("on the volume", got);
    try testing.expectEqualStrings("", serial.captured());
}

test "a write outside the data directories is refused and logged, and changes neither disk" {
    const t = try Two.make(true);
    defer t.deinit();
    const site_free = t.site.free();
    const volume_free = t.volume.free();
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "index.html", .data = "x" }));
    try testing.expect(logged("refused: a write outside the data directories: index.html"));
    // Each way of changing the disk, not only writeFile.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.createDirPath(io, "static/new"));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.createFile(io, "notes.txt", .{ .truncate = false }));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteFile(io, "index.html"));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteTree(io, "static"));
    // A name that only begins like a data directory is not one.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "database/x", .data = "x" }));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "dat/x", .data = "x" }));
    try testing.expectEqual(site_free, t.site.free());
    try testing.expectEqual(volume_free, t.volume.free());
}

test "a path with . or .. is refused for writes and not found for reads, on either side" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/keep", .data = "kept" });
    const volume_free = t.volume.free();
    const bad = [_][]const u8{ "data/../x", "./data/x", "data/./x", "data/chat/../../x", "..", "data/.." };
    for (bad) |p| {
        serial.clearCaptured();
        try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = p, .data = "x" }));
        try testing.expect(logged("refused: a write to a path with . or ..: "));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.readFileAlloc(io, p, testing.allocator, .limited(100)));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.statFile(io, p, .{}));
        try testing.expectError(io_mod.Error.FileNotFound, cwd.openDir(io, p, .{}));
    }
    // **THE ONE THAT WOULD HURT:** `data/..` resolves, on the volume, to its
    // root, and removing that tree would empty the volume.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteTree(io, "data/.."));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.deleteTree(io, "data/chat/../.."));
    try testing.expectEqual(volume_free, t.volume.free());
    try t.volume.expectFile("data/keep", "kept");
    try expectAbsent(t.volume, "x");
    try expectAbsent(t.site, "x");
}

test "the first directory is matched without case, as FAT matches it" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "Data/x", .data = "upper" });
    try cwd.writeFile(io, .{ .sub_path = "AUTH/y", .data = "all upper" });
    try t.volume.expectFile("data/x", "upper");
    try t.volume.expectFile("auth/y", "all upper");
    try expectAbsent(t.site, "data");
    try expectAbsent(t.site, "auth");
    try testing.expectEqualStrings("", serial.captured());
}

test "with a volume attached, data/ is read from it, never from the site's disk" {
    const t = try Two.make(true);
    defer t.deinit();
    // The boot disk carries a stale data/ of its own (an image built before
    // the volume, say) and the site's files.
    try t.site.vol.writeFile("data/x", "stale, on the boot disk");
    try t.site.vol.writeFile("data/only-here", "stale");
    try t.site.vol.writeFile("index.html", "<p>site</p>");
    try t.volume.vol.writeFile("data/x", "current, on the volume");
    t.resync(true);

    const x = try cwd.readFileAlloc(io, "data/x", testing.allocator, .limited(100));
    defer testing.allocator.free(x);
    try testing.expectEqualStrings("current, on the volume", x);
    try testing.expectError(io_mod.Error.FileNotFound, cwd.readFileAlloc(io, "data/only-here", testing.allocator, .limited(100)));
    const page = try cwd.readFileAlloc(io, "index.html", testing.allocator, .limited(100));
    defer testing.allocator.free(page);
    try testing.expectEqualStrings("<p>site</p>", page);
    // And the site's file is not on the volume to be read instead.
    try expectAbsent(t.volume, "index.html");
}

test "with no volume, data/ is on the site's disk, and writes outside it are still refused" {
    const t = try Two.make(false);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/x", .data = "one disk" });
    try t.site.expectFile("data/x", "one disk");
    try expectAbsent(t.volume, "data");
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "index.html", .data = "x" }));
    try testing.expect(logged("refused: a write outside the data directories"));
    try testing.expectError(io_mod.Error.WriteFailed, cwd.writeFile(io, .{ .sub_path = "data/../index.html", .data = "x" }));
    try expectAbsent(t.site, "index.html");
}

test "an append through a File goes to the disk its path names" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.createDirPath(io, "data/chat/1_2/sessions");
    const path = "data/chat/1_2/sessions/plan.md";
    // The application's append, spelled as it spells it.
    for ([_][]const u8{ "one\n", "two\n", "three\n" }) |line| {
        var file = try cwd.createFile(io, path, .{ .truncate = false });
        defer file.close(io);
        const st = try file.stat(io);
        try file.writePositionalAll(io, line, st.size);
    }
    try t.volume.expectFile(path, "one\ntwo\nthree\n");
    try expectAbsent(t.site, "data");

    var file = try cwd.openFile(io, path, .{});
    var buf: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try file.readPositionalAll(io, &buf, 4));
    try testing.expectEqualStrings("two\nt", &buf);
}

test "a directory opened under data/ lists the volume's entries, and deleting a tree there frees the volume" {
    const t = try Two.make(true);
    defer t.deinit();
    const empty = t.volume.free();
    try t.site.vol.writeFile("data/players/stale", "x");
    t.resync(true);
    try cwd.writeFile(io, .{ .sub_path = "data/players/p1/name", .data = "Ada" });
    try cwd.writeFile(io, .{ .sub_path = "data/players/p2/name", .data = "Lin" });

    var dir = try cwd.openDir(io, "data/players", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var seen: [2][]const u8 = undefined;
    var n: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expect(n < 2);
        try testing.expectEqual(io_mod.Kind.directory, e.kind);
        seen[n] = e.name;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("p1", seen[0]);
    try testing.expectEqualStrings("p2", seen[1]);

    try cwd.deleteTree(io, "data/players");
    try testing.expectError(io_mod.Error.FileNotFound, cwd.statFile(io, "data/players/p1/name", .{}));
    // Only `data` itself is left on the volume: one cluster.
    try testing.expectEqual(empty - 1, t.volume.free());
    // The boot disk's stale copy was not the one removed.
    try t.site.expectFile("data/players/stale", "x");
}

test "rename replaces a file on the volume, as std.Io spells it, and refuses what fat16.rename does" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/sessions/topic.count", .data = "4\n" });
    try cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/sessions/~0a1b2c3d.tmp", .data = "5\n" });
    try cwd.rename("data/chat/1_2/sessions/~0a1b2c3d.tmp", cwd, "data/chat/1_2/sessions/topic.count", io);
    try t.volume.expectFile("data/chat/1_2/sessions/topic.count", "5\n");
    try expectAbsent(t.volume, "data/chat/1_2/sessions/~0a1b2c3d.tmp");

    try testing.expectError(io_mod.Error.FileNotFound, cwd.rename("data/chat/nothing", cwd, "data/chat/x", io));
    // Across directories: fat16.rename moves within one only.
    try testing.expectError(io_mod.Error.NameTooLong, cwd.rename("data/chat/1_2/sessions/topic.count", cwd, "data/topic.count", io));
    // Off the volume, or onto the site: refused as every write there is.
    try testing.expectError(io_mod.Error.WriteFailed, cwd.rename("data/chat/1_2/sessions/topic.count", cwd, "index.html", io));
    try t.volume.expectFile("data/chat/1_2/sessions/topic.count", "5\n");
}
