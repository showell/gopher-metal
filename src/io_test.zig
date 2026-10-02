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
    // A name is good until the next `next` (it is the iterator's, as std's
    // is), so each is copied out, as store.list does.
    var seen: [2][8]u8 = undefined;
    var lens: [2]usize = undefined;
    var n: usize = 0;
    while (try it.next(io)) |e| {
        try testing.expect(n < 2);
        try testing.expectEqual(io_mod.Kind.directory, e.kind);
        @memcpy(seen[n][0..e.name.len], e.name);
        lens[n] = e.name.len;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("p1", seen[0][0..lens[0]]);
    try testing.expectEqualStrings("p2", seen[1][0..lens[1]]);

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

test "a file written over a directory is IsDir, as on Linux, and the directory stays" {
    const t = try Two.make(true);
    defer t.deinit();
    try cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/sessions/topic.md", .data = "x" });
    try testing.expectError(io_mod.Error.IsDir, cwd.writeFile(io, .{ .sub_path = "data/chat/1_2/Sessions", .data = "a file" }));
    try t.volume.expectFile("data/chat/1_2/sessions/topic.md", "x");
}

// ── listings, at the sizes the application makes (QUEUE.md item 50) ──────────

/// An upload's name as chat stores it: 32 hex digits and an extension.
fn uploadName(buf: *[40]u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>32}.webp", .{n *% 0x9E3779B97F4A7C15}) catch unreachable;
}

/// What angry-gopher's store.list keeps of a listing, in the request's
/// arena: every name copied, and the entries in a growing list. Done here as
/// store.list does it, since the application is not built into these tests.
fn listLikeStore(alloc: std.mem.Allocator, path: []const u8) ![]io_mod.Entry {
    var d = try cwd.openDir(io, path, .{ .iterate = true });
    defer d.close(io);
    var out: std.ArrayList(io_mod.Entry) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        try out.append(alloc, .{ .name = try alloc.dupe(u8, e.name), .kind = e.kind });
    }
    return out.items;
}

/// An allocator that counts what is asked of it, over an arena as a request's is.
const Counting = struct {
    arena: std.heap.ArenaAllocator,
    asked: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, n: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.asked += n;
        return self.arena.allocator().rawAlloc(n, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const ok = self.arena.allocator().rawResize(m, a, n, ra);
        if (ok and n > m.len) self.asked += n - m.len;
        return ok;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.arena.allocator().rawFree(m, a, ra);
    }
};

test "prod's largest folder, 70 uploads, listed as store.list does, takes a few KiB of the request's memory" {
    const t = try Two.make(true);
    defer t.deinit();
    var buf: [40]u8 = undefined;
    var path: [80]u8 = undefined;
    for (0..70) |n| {
        const p = try std.fmt.bufPrint(&path, "data/chat/c/1_2/uploads/{s}", .{uploadName(&buf, n)});
        try cwd.writeFile(io, .{ .sub_path = p, .data = "" });
    }
    var counting = Counting{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer counting.arena.deinit();
    const got = try listLikeStore(counting.allocator(), "data/chat/c/1_2/uploads");
    try testing.expectEqual(@as(usize, 70), got.len);
    for (got, 0..) |e, i| {
        try testing.expectEqual(io_mod.Kind.file, e.kind);
        try testing.expectEqual(@as(usize, 37), e.name.len);
        for (got[0..i]) |o| try testing.expect(!std.mem.eql(u8, o.name, e.name));
    }
    // 70 names of 37 bytes is 2,590; the entries and the list's growth are
    // the rest. The request heap keeps 32 MiB (probe/gopher.zig), and grows.
    try testing.expect(counting.asked < 16 * 1024);
    // And the iterator itself, on the stack, is a sector and a name, not a
    // listing: it held 256 names of 96 bytes before.
    try testing.expect(@sizeOf(io_mod.Iterator) < 2 * 1024);
}

fn manyEntries(shape: test_disk.Shape) !void {
    const site = try Disk.make("io-many-site", test_disk.small, false);
    defer site.deinit();
    const volume = try Disk.make("io-many-volume", shape, false);
    defer volume.deinit();
    io_mod.mount(site.vol);
    io_mod.keepData(&data_dirs, volume.vol);
    defer {
        if (io_mod.siteVolume()) |v| site.vol = v.*;
        if (io_mod.dataVolume()) |v| volume.vol = v.*;
    }
    // 600 sessions: past the 256 the iterator stopped the machine at, and
    // past the 500 a player may keep (angry-gopher's game_limits.zig).
    var path: [80]u8 = undefined;
    for (1..601) |n| {
        const p = try std.fmt.bufPrint(&path, "data/lynrummy/p1/puzzle/sessions/{d}", .{n});
        try cwd.createDirPath(io, p);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try listLikeStore(arena.allocator(), "data/lynrummy/p1/puzzle/sessions");
    try testing.expectEqual(@as(usize, 600), got.len);
    var seen = [_]bool{false} ** 601;
    for (got) |e| {
        try testing.expectEqual(io_mod.Kind.directory, e.kind);
        const n = try std.fmt.parseInt(usize, e.name, 10);
        try testing.expect(!seen[n]);
        seen[n] = true;
    }
}

test "a folder of 600 sessions lists whole, on FAT16 and FAT32: the iterator stopped the machine at 257" {
    try manyEntries(test_disk.small);
    try manyEntries(test_disk.small32);
}

// ── the site's files, kept after their first read (QUEUE.md item 61) ─────────

test "a site file is read from the disk once, then from memory; a data file every time" {
    const t = try Two.make(true);
    defer t.deinit();
    try t.site.vol.writeFile("pages/home.txt", "the home page");
    t.resync(true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cache = io_mod.siteCache();
    const hits = cache.hits;

    try testing.expectEqualStrings("the home page", try cwd.readFileAlloc(io, "pages/home.txt", a, .unlimited));
    const after_first = t.site.blk.requests;
    // Again, and in another case, as FAT names match: no disk request at all.
    try testing.expectEqualStrings("the home page", try cwd.readFileAlloc(io, "pages/home.txt", a, .unlimited));
    try testing.expectEqualStrings("the home page", try cwd.readFileAlloc(io, "PAGES/Home.txt", a, .unlimited));
    try testing.expectEqual(after_first, t.site.blk.requests);
    try testing.expectEqual(hits + 2, cache.hits);
    // The limit still holds for a kept file.
    try testing.expectError(io_mod.Error.StreamTooLong, cwd.readFileAlloc(io, "pages/home.txt", a, .limited(4)));

    // A data file changes, so it is read every time.
    try cwd.writeFile(io, .{ .sub_path = "data/chat/x", .data = "one" });
    try testing.expectEqualStrings("one", try cwd.readFileAlloc(io, "data/chat/x", a, .unlimited));
    try cwd.writeFile(io, .{ .sub_path = "data/chat/x", .data = "two" });
    try testing.expectEqualStrings("two", try cwd.readFileAlloc(io, "data/chat/x", a, .unlimited));
    try testing.expectEqual(hits + 2, cache.hits);
}

test "the data on the boot disk is never kept, nor anything before the data is named" {
    // No volume: the data directories are on the site's own disk.
    const t = try Two.make(false);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try cwd.writeFile(io, .{ .sub_path = "data/n", .data = "1" });
    _ = try cwd.readFileAlloc(io, "data/n", a, .unlimited);
    try cwd.writeFile(io, .{ .sub_path = "data/n", .data = "2" });
    try testing.expectEqualStrings("2", try cwd.readFileAlloc(io, "data/n", a, .unlimited));

    // A machine that has not named its data (a probe) writes anywhere, so
    // keeps nothing.
    io_mod.keepData(&.{}, null);
    try cwd.writeFile(io, .{ .sub_path = "pages/p", .data = "a" });
    _ = try cwd.readFileAlloc(io, "pages/p", a, .unlimited);
    try cwd.writeFile(io, .{ .sub_path = "pages/p", .data = "b" });
    try testing.expectEqualStrings("b", try cwd.readFileAlloc(io, "pages/p", a, .unlimited));
    io_mod.keepData(&data_dirs, null);
}

test "a site file larger than the cache keeps is read from the disk each time, and still whole" {
    const t = try Two.make(true);
    defer t.deinit();
    const big = try testing.allocator.alloc(u8, io_mod.SiteCache.largest + 1);
    defer testing.allocator.free(big);
    for (big, 0..) |*c, i| c.* = @truncate(i);
    try t.site.vol.writeFile("gallery/big.webp", big);
    t.resync(true);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualSlices(u8, big, try cwd.readFileAlloc(io, "gallery/big.webp", a, .unlimited));
    const before = t.site.blk.requests;
    try testing.expectEqualSlices(u8, big, try cwd.readFileAlloc(io, "gallery/big.webp", a, .unlimited));
    try testing.expect(t.site.blk.requests > before);
}
