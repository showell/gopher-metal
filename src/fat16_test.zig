//! `fat16.zig` on a disk in memory (`virtio.Block.inMemory`): mount, write,
//! read back, append, remove, fill the disk, and damage it on purpose, all
//! on the host.
//!
//! **THE VOLUMES ARE MADE FROM THE SPEC**, by `test_disk.zig`, not by
//! `fat16.zig` (Microsoft's FAT specification: the BPB, two FATs, a fixed
//! root). And the checks read the disk's bytes directly where they can: the
//! free clusters are counted in the FAT as it sits on the disk, and the two
//! FAT copies are compared byte for byte. So a test does not ask `fat16.zig` to vouch for
//! itself.
//!
//! An independent reader of the images, written from the spec in Python, is
//! QUEUE.md item 4; the images these tests make are what it reads.

const std = @import("std");
const fat16 = @import("fat16.zig");
const options = @import("fat16_test_options");
const virtio = @import("virtio.zig");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Shape = test_disk.Shape;
const Layout = test_disk.Layout;
const small = test_disk.small;

/// `test_disk.Disk`, kept as an image when the tests are asked to keep them
/// (-Dfat16-images).
const Disk = struct {
    fn make(label: []const u8, shape: Shape, cached: bool) !*test_disk.Disk {
        const d = try test_disk.Disk.make(label, shape, cached);
        d.images_dir = options.images_dir;
        return d;
    }
};

fn pattern(buf: []u8, seed: u8) []u8 {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
    return buf;
}

// Every test runs with the FAT on the disk and with it held in memory: the
// two paths through `fatGet` and `fatSet` must agree.
const both = [_]bool{ false, true };

test "a volume formatted from the spec mounts, and its root is empty" {
    for (both) |cached| {
        const d = try Disk.make("fresh", small, cached);
        defer d.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("", try d.names(0, &buf));
        try testing.expect(d.free() > 4085);
    }
}

test "a file is read back exactly, at every size around a sector and a cluster" {
    for (both) |cached| {
        const d = try Disk.make("sizes", small, cached);
        defer d.deinit();
        const sizes = [_]usize{ 0, 1, 511, 512, 513, 1023, 1024, 1025, 4096, 70_000 };
        var data: [70_000]u8 = undefined;
        for (sizes, 0..) |size, k| {
            var name: [16]u8 = undefined;
            const path = try std.fmt.bufPrint(&name, "f{d}.bin", .{k});
            try d.vol.writeFile(path, pattern(data[0..size], @intCast(k)));
            try d.expectFile(path, data[0..size]);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a path makes its directories, and names of every length up to max_name read back by name" {
    for (both) |cached| {
        const d = try Disk.make("names", small, cached);
        defer d.deinit();
        var name: [fat16.max_name]u8 = undefined;
        var path: [128]u8 = undefined;
        for (1..fat16.max_name + 1) |len| {
            for (name[0..len], 0..) |*c, i| c.* = "abcdefghijklmnopqrstuvwxyz0123456789-"[i % 37];
            const p = try std.fmt.bufPrint(&path, "data/chat/{s}", .{name[0..len]});
            try d.vol.writeFile(p, name[0..len]);
            try d.expectFile(p, name[0..len]);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a name longer than max_name is refused, not truncated" {
    const d = try Disk.make("toolong", small, true);
    defer d.deinit();
    const long = "a" ** (fat16.max_name + 1);
    try testing.expectError(fat16.Error.BadName, d.vol.writeFile(long, "x"));
}

test "a replaced file gives back what it held" {
    for (both) |cached| {
        const d = try Disk.make("replaced", small, cached);
        defer d.deinit();
        var data: [20_000]u8 = undefined;
        try d.vol.writeFile("data/x", pattern(&data, 1));
        const after_big = d.free();
        try d.vol.writeFile("data/x", "small");
        // 20,000 bytes took 40 clusters; "small" takes one.
        try testing.expectEqual(after_big + 39, d.free());
        try d.expectFile("data/x", "small");
        try testing.expect(d.fatsAgree());
    }
}

test "appends cross cluster boundaries and read back whole" {
    for (both) |cached| {
        const d = try Disk.make("appends", small, cached);
        defer d.deinit();
        try d.vol.writeFile("data/log", "");
        var whole: [3000]u8 = undefined;
        _ = pattern(&whole, 7);
        var at: usize = 0;
        // Pieces of awkward sizes, so that writes start and end everywhere in
        // a cluster.
        const pieces = [_]usize{ 1, 510, 2, 513, 300, 700, 974 };
        for (pieces) |n| {
            try d.vol.writeInto("data/log", @intCast(at), whole[at..][0..n]);
            at += n;
            try d.expectFile("data/log", whole[0..at]);
        }
        try testing.expectEqual(whole.len, at);
        // An overwrite in the middle, and a write past the end refused.
        try d.vol.writeInto("data/log", 100, "OVERWRITTEN");
        @memcpy(whole[100..][0..11], "OVERWRITTEN");
        try d.expectFile("data/log", &whole);
        try testing.expectError(fat16.Error.BadChain, d.vol.writeInto("data/log", whole.len + 1, "hole"));
        try testing.expect(d.fatsAgree());
    }
}

test "removing a tree gives back every cluster, directories included" {
    for (both) |cached| {
        const d = try Disk.make("removetree", small, cached);
        defer d.deinit();
        const empty = d.free();
        var data: [4000]u8 = undefined;
        var path: [64]u8 = undefined;
        for (0..40) |k| {
            const p = try std.fmt.bufPrint(&path, "data/chat/{d}_{d}/sessions/topic-{d}.md", .{ k % 5, k % 3, k });
            try d.vol.writeFile(p, pattern(data[0 .. 100 * k], @intCast(k)));
        }
        try testing.expect(d.free() < empty);
        try d.vol.removeTree("data");
        try testing.expectEqual(empty, d.free());
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("", try d.names(0, &buf));
        try testing.expect(d.fatsAgree());
    }
}

test "a directory grows past its first cluster, and every name in it is found" {
    for (both) |cached| {
        const d = try Disk.make("growth", small, cached);
        defer d.deinit();
        // Each name takes three entries; a 512-byte cluster holds sixteen.
        var path: [64]u8 = undefined;
        for (0..200) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.vol.writeFile(p, p);
        }
        for (0..200) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.expectFile(p, p);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a full disk refuses the write, and the refused write leaves nothing behind" {
    for (both) |cached| {
        // The smallest FAT16 there is: 4,085 clusters of 512 bytes.
        const d = try Disk.make("full", .{ .sectors = 4085 + 1 + 2 * 17 + 32 }, cached);
        defer d.deinit();
        const big = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(big);
        _ = pattern(big, 3);
        try d.vol.writeFile("one", big); // 2,048 clusters
        const before = d.free();
        try testing.expect(before < 2048);
        try testing.expectError(fat16.Error.Full, d.vol.writeFile("two", big));
        try testing.expectEqual(before, d.free());
        try testing.expectError(fat16.Error.NotFound, d.vol.open("two"));
        // What fits still fits, and the first file is untouched.
        try d.vol.writeFile("three", big[0..1000]);
        try d.expectFile("one", big);
        try testing.expect(d.fatsAgree());
    }
}

test "a chain that runs into a free cluster is a broken chain, not a short file" {
    for (both) |cached| {
        const d = try Disk.make("damaged-chain", small, cached);
        defer d.deinit();
        var data: [2000]u8 = undefined;
        try d.vol.writeFile("broken", pattern(&data, 9));
        const e = try d.vol.open("broken");
        // Its second cluster is marked free in both copies of the FAT.
        const l = Layout.of(d.bytes);
        for (0..2) |copy| {
            std.mem.writeInt(u16, d.bytes[l.fat_start + copy * l.fat_bytes + @as(usize, e.first_cluster) * 2 ..][0..2], 0, .little);
        }
        try d.mount(cached); // so a held FAT sees the damage too
        var out: [2000]u8 = undefined;
        try testing.expectError(fat16.Error.BadChain, d.vol.readFile(e, &out));
    }
}

test "a disk that stops answering is an error, not a hang or a wrong answer" {
    const d = try Disk.make("io-failure", small, false);
    defer d.deinit();
    try d.vol.writeFile("data/x", "before");
    d.blk.fail_after = d.blk.requests;
    try testing.expectError(fat16.Error.ReadFailed, d.vol.open("data/x"));
    try testing.expect(std.meta.isError(d.vol.writeFile("data/y", "after")));
}

/// Sets `cluster`'s entry in both copies of the FAT on the disk, then mounts
/// again so that a held FAT sees it too.
fn damageFat(d: *test_disk.Disk, cached: bool, cluster: u16, value: u16) !void {
    const l = Layout.of(d.bytes);
    for (0..2) |copy| {
        std.mem.writeInt(u16, d.bytes[l.fat_start + copy * l.fat_bytes + @as(usize, cluster) * 2 ..][0..2], value, .little);
    }
    try d.mount(cached);
}

/// The clusters of a chain, in order, read from the first FAT on the disk.
fn chainOf(d: *const test_disk.Disk, first: u16, out: []u16) []u16 {
    const l = Layout.of(d.bytes);
    var n: usize = 0;
    var c = first;
    while (c >= 2 and c < 0xFFF8 and n < out.len) {
        out[n] = c;
        n += 1;
        c = std.mem.readInt(u16, d.bytes[l.fat_start + @as(usize, c) * 2 ..][0..2], .little);
    }
    return out[0..n];
}

// **A LOOP IN THE FAT MUST END A WALK WITH AN ERROR.** Before the walks were
// bounded, each of these hung: the test did not fail, it never finished.

test "a file whose chain loops back is a broken chain to append to, not a hang" {
    for (both) |cached| {
        const d = try Disk.make("damaged-loop-file", small, cached);
        defer d.deinit();
        var data: [1536]u8 = undefined; // three clusters, full, so an append needs a fourth
        try d.vol.writeFile("data/log", pattern(&data, 4));
        const e = try d.vol.open("data/log");
        var chain: [8]u16 = undefined;
        const c = chainOf(d, e.first_cluster, &chain);
        try testing.expectEqual(@as(usize, 3), c.len);
        try damageFat(d, cached, c[2], c[0]);
        // A read stops at the file's size, so it never reaches the loop.
        try d.expectFile("data/log", &data);
        // An append looks for the chain's end, which a loop does not have.
        try testing.expectError(fat16.Error.BadChain, d.vol.writeInto("data/log", data.len, "more"));
        try testing.expectError(fat16.Error.BadChain, d.vol.layout(try d.vol.open("data/log")));
    }
}

test "a directory whose chain loops back is a broken chain to list, search or grow, not a hang" {
    for (both) |cached| {
        const d = try Disk.make("damaged-loop-dir", small, cached);
        defer d.deinit();
        // Every cluster of it full, so no end-of-directory entry stops a walk:
        // "." and "..", and three entries a name, are 32, two clusters.
        var path: [64]u8 = undefined;
        for (0..10) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.vol.writeFile(p, "x");
        }
        const dir = try d.vol.open("data/sessions");
        var chain: [64]u16 = undefined;
        const c = chainOf(d, dir.first_cluster, &chain);
        try testing.expectEqual(@as(usize, 2), c.len);
        try damageFat(d, cached, c[c.len - 1], c[0]);

        var buf: [4096]u8 = undefined;
        try testing.expectError(fat16.Error.BadChain, d.names(dir.first_cluster, &buf));
        try testing.expect(std.meta.isError(d.vol.open("data/sessions/nothing-by-this-name")));
        try testing.expect(std.meta.isError(d.vol.writeFile("data/sessions/one-more-session.md", "x")));
    }
}

test "a link past the last cluster, or to the bad-cluster mark, is a broken chain" {
    for (both) |cached| {
        const d = try Disk.make("damaged-past-end", small, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined;
        try d.vol.writeFile("f", pattern(&data, 5));
        const e = try d.vol.open("f");
        const past: u16 = @intCast(Layout.of(d.bytes).clusters + 2);
        for ([_]u16{ past, 0xFFF0, 0xFFF7 }) |link| {
            try damageFat(d, cached, e.first_cluster, link);
            var out: [1500]u8 = undefined;
            try testing.expectError(fat16.Error.BadChain, d.vol.readFile(e, &out));
            try testing.expectError(fat16.Error.BadChain, d.vol.writeInto("f", 1000, "x"));
            try testing.expectError(fat16.Error.BadChain, d.vol.layout(e));
        }
    }
}

test "an entry whose first cluster is past the volume is a broken chain, and removing it frees nothing" {
    for (both) |cached| {
        const d = try Disk.make("damaged-first-cluster", small, cached);
        defer d.deinit();
        try d.vol.writeFile("f", "some bytes");
        try d.vol.writeFile("data/x", "a directory's worth");
        const e = try d.vol.open("f");
        const dir = try d.vol.open("data");
        const past: u16 = @intCast(Layout.of(d.bytes).clusters + 2);
        // The first cluster is two bytes at offset 26 of the entry.
        std.mem.writeInt(u16, d.bytes[e.lba * test_disk.sector + e.slot + 26 ..][0..2], past, .little);
        std.mem.writeInt(u16, d.bytes[dir.lba * test_disk.sector + dir.slot + 26 ..][0..2], 0xFF00, .little);
        try d.mount(cached);
        const free = d.free();

        var out: [64]u8 = undefined;
        try testing.expectError(fat16.Error.BadChain, d.vol.readFile(try d.vol.open("f"), &out));
        try testing.expectError(fat16.Error.BadChain, d.vol.writeInto("f", 2, "x"));
        try testing.expectError(fat16.Error.BadChain, d.vol.open("data/x"));
        var buf: [64]u8 = undefined;
        try testing.expectError(fat16.Error.BadChain, d.names(0xFF00, &buf));
        try d.vol.remove("f");
        try testing.expectEqual(free, d.free());
        try testing.expect(d.fatsAgree());
    }
}

test "a FAT too short for the clusters it describes is refused at mount" {
    const bytes = try testing.allocator.alloc(u8, small.sectors * test_disk.sector);
    defer testing.allocator.free(bytes);
    test_disk.format(bytes, small);
    std.mem.writeInt(u16, bytes[22..24], 2, .little); // room for 510 clusters of ~8,000
    var blk = @import("virtio.zig").Block.inMemory(bytes);
    var scratch: [test_disk.sector]u8 align(16) = undefined;
    try testing.expectError(fat16.Error.BadBootSector, fat16.Volume.mount(&blk, &scratch, 0));
}

// ---- the boot-time check (QUEUE item 5) ------------------------------------
//
// Every disk a test above left healthy is checked when it is torn down, and
// must check clean (test_disk.Disk.deinit). These break a disk on purpose, one
// way each, and expect exactly what the check should say. `Disk.check` also
// requires that the check changed nothing on the disk.

/// Writes a file's entry fields on the disk directly: its size, or its first
/// cluster.
fn setEntry(d: *test_disk.Disk, e: fat16.Entry, comptime field: enum { size, first_cluster }, value: u32) void {
    const at = e.lba * test_disk.sector + e.slot;
    switch (field) {
        .size => std.mem.writeInt(u32, d.bytes[at + 28 ..][0..4], value, .little),
        .first_cluster => std.mem.writeInt(u16, d.bytes[at + 26 ..][0..2], @intCast(value), .little),
    }
}

test "the check counts what a healthy volume holds" {
    for (both) |cached| {
        const d = try Disk.make("check-healthy", small, cached);
        defer d.deinit();
        const empty = d.free();
        var data: [3000]u8 = undefined;
        try d.vol.writeFile("data/chat/a.md", pattern(&data, 1)); // 6 clusters
        try d.vol.writeFile("data/chat/b.md", ""); // none
        try d.vol.writeFile("auth/7/password", "hash"); // 1
        try d.vol.writeFile("data/gone", "x");
        try d.vol.remove("data/gone");
        const r = try d.check();
        try r.expect(&.{});
        try testing.expectEqual(@as(u32, 3), r.health.files);
        try testing.expectEqual(@as(u32, 4), r.health.directories); // data, data/chat, auth, auth/7
        try testing.expectEqual(@as(u32, @intCast(empty - d.free())), r.health.used);
        try testing.expectEqual(@as(u32, 0), r.health.leaked);
    }
}

test "the check finds clusters in use that nothing holds" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-leaked", small, cached);
        defer d.deinit();
        try d.vol.writeFile("data/x", "kept");
        const last: u16 = @intCast(Layout.of(d.bytes).clusters + 1);
        // One cluster alone, and a run of three linked ones, as a write that
        // stopped before its entry was written leaves them.
        try damageFat(d, cached, last - 10, 0xFFFF);
        try damageFat(d, cached, last - 5, last - 4);
        try damageFat(d, cached, last - 4, last - 3);
        try damageFat(d, cached, last - 3, 0xFFFF);
        // A cluster marked bad is in use by nothing, and is not a leak.
        try damageFat(d, cached, last - 1, 0xFFF7);
        // And the volume's very last cluster, where the FAT's scan ends.
        try damageFat(d, cached, last, 0xFFFF);
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .leaked, .cluster = last - 10, .count = 1 },
            .{ .problem = .leaked, .cluster = last - 5, .count = 3 },
            .{ .problem = .leaked, .cluster = last, .count = 1 },
        });
        try testing.expectEqual(@as(u32, 5), r.health.leaked);
    }
}

test "the check finds a chain that runs into a free cluster, past the volume, or into a bad one" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-broken", small, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined; // three clusters
        try d.vol.writeFile("data/f", pattern(&data, 2));
        const e = try d.vol.open("data/f");
        const past: u16 = @intCast(Layout.of(d.bytes).clusters + 2);
        for ([_]u16{ 0, past, 0xFFF7 }) |link| {
            try damageFat(d, cached, e.first_cluster, link);
            const r = try d.check();
            // The rest of the chain is then held by nothing.
            try r.expect(&.{
                .{ .problem = .broken, .path = "/data/f", .cluster = e.first_cluster },
                .{ .problem = .leaked, .cluster = e.first_cluster + 1, .count = 2 },
            });
        }
    }
}

test "the check finds a first cluster past the volume, and a directory with no chain" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-first", small, cached);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        try d.vol.writeFile("auth/7/password", "x");
        const f = try d.vol.open("data/f");
        const dir = try d.vol.open("auth/7");
        const past: u16 = @intCast(Layout.of(d.bytes).clusters + 2);
        setEntry(d, f, .first_cluster, past);
        setEntry(d, dir, .first_cluster, 0);
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .broken, .path = "/data/f", .cluster = past },
            .{ .problem = .broken, .path = "/auth/7", .cluster = 0 },
            .{ .problem = .leaked, .cluster = f.first_cluster, .count = 1 },
            .{ .problem = .leaked, .cluster = dir.first_cluster, .count = 2 }, // auth/7 and its password
        });
    }
}

test "the check finds two files sharing clusters, and a file that loops" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-crossed", small, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined;
        try d.vol.writeFile("a", pattern(&data, 3));
        try d.vol.writeFile("b", pattern(&data, 4));
        try d.vol.writeFile("c", pattern(&data, 5));
        var chain: [8]u16 = undefined;
        const a = chainOf(d, (try d.vol.open("a")).first_cluster, &chain)[0..3].*;
        const b = chainOf(d, (try d.vol.open("b")).first_cluster, &chain)[0..3].*;
        const c = chainOf(d, (try d.vol.open("c")).first_cluster, &chain)[0..3].*;
        try damageFat(d, cached, a[2], b[1]); // a runs on into b's tail
        try damageFat(d, cached, c[2], c[0]); // c comes back to its start
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .long, .path = "/a", .cluster = a[0], .count = 5 },
            .{ .problem = .crossed, .path = "/b", .cluster = b[1] },
            .{ .problem = .crossed, .path = "/c", .cluster = c[0] },
        });
    }
}

test "the check finds a directory that loops, and one that points at its own parent" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-dirs", small, cached);
        defer d.deinit();
        // Two full clusters, as in the loop test above.
        var path: [64]u8 = undefined;
        for (0..10) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.vol.writeFile(p, "x");
        }
        try d.vol.writeFile("data/up/x", "x");
        const data_dir = try d.vol.open("data");
        const sessions = try d.vol.open("data/sessions");
        const up = try d.vol.open("data/up");
        var chain: [8]u16 = undefined;
        const s = chainOf(d, sessions.first_cluster, &chain)[0..2].*;
        try damageFat(d, cached, s[1], s[0]);
        setEntry(d, up, .first_cluster, data_dir.first_cluster);
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{
            // The loop is found, and the sessions are all still checked.
            .{ .problem = .crossed, .path = "/data/sessions", .cluster = s[0] },
            // A directory that is its own parent is reported, not walked
            // for ever, and what it used to hold is held by nothing.
            .{ .problem = .crossed, .path = "/data/up", .cluster = data_dir.first_cluster },
            .{ .problem = .leaked, .cluster = up.first_cluster, .count = 2 },
        });
        try testing.expectEqual(@as(u32, 10), r.health.files);
    }
}

test "the check finds a file whose size and chain disagree" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-size", small, cached);
        defer d.deinit();
        try d.vol.writeFile("short", "x" ** 1000); // two clusters
        try d.vol.writeFile("long", "x" ** 1000);
        try d.vol.writeFile("empty", "x" ** 1000);
        const short = try d.vol.open("short");
        const long = try d.vol.open("long");
        const empty = try d.vol.open("empty");
        setEntry(d, short, .size, 5000);
        setEntry(d, long, .size, 10);
        setEntry(d, empty, .size, 0);
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .short, .path = "/short", .cluster = short.first_cluster, .count = 2 },
            .{ .problem = .long, .path = "/long", .cluster = long.first_cluster, .count = 2 },
            .{ .problem = .long, .path = "/empty", .cluster = empty.first_cluster, .count = 2 },
        });
    }
}

test "the check finds FAT copies that differ" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-fats", small, cached);
        defer d.deinit();
        try d.vol.writeFile("f", "x");
        // The second copy only, and not mounted again: a held FAT would refuse
        // the volume, which is cacheFat's business, not the check's.
        const l = Layout.of(d.bytes);
        std.mem.writeInt(u16, d.bytes[l.fat_start + l.fat_bytes + 300 * 2 ..][0..2], 0xFFFF, .little);
        std.mem.writeInt(u16, d.bytes[l.fat_start + l.fat_bytes + 1000 * 2 ..][0..2], 0xFFFF, .little);
        const r = try d.check();
        try r.expect(&.{.{ .problem = .fats_differ, .cluster = 300, .count = 2 }});
    }
}

test "the check finds a . or .. that points elsewhere" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-dots", small, cached);
        defer d.deinit();
        try d.vol.writeFile("data/chat/x", "x");
        const chat = try d.vol.open("data/chat");
        const at = @as(usize, chat.first_cluster - 2 + Layout.of(d.bytes).data_sector) * test_disk.sector;
        // "." is the first entry of a directory, ".." the second.
        std.mem.writeInt(u16, d.bytes[at + 26 ..][0..2], 77, .little);
        std.mem.writeInt(u16, d.bytes[at + 32 + 26 ..][0..2], 78, .little);
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .bad_dot, .path = "/data/chat/.", .cluster = 77 },
            .{ .problem = .bad_dot, .path = "/data/chat/..", .cluster = 78 },
        });
    }
}

test "the check says where it stopped going deeper, and does not call what is below leaked" {
    for (both) |cached| {
        // A healthy volume (tools/fat16_read.py checks it clean), deeper than
        // the check walks.
        const d = try Disk.make("limit-check-deep", small, cached);
        defer d.deinit();
        const deep = "d/" ** 16 ++ "f";
        try d.vol.writeFile(deep, "x");
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .too_deep, .path = "/d" ** 16, .cluster = (try d.vol.open("d/" ** 15 ++ "d")).first_cluster },
        });
        try testing.expectEqual(@as(u32, 0), r.health.leaked);
    }
}

test "the check refuses a bitmap too short, and a disk that stops answering is an error" {
    const d = try Disk.make("io-failure-check", small, false);
    defer d.deinit();
    try d.vol.writeFile("data/x", "x");
    var short: [8]u8 = undefined;
    const Ignore = struct {
        fn each(_: void, _: fat16.Finding) void {}
    };
    try testing.expectError(fat16.Error.TooBig, d.vol.check(&short, {}, Ignore.each));
    d.blk.fail_after = d.blk.requests;
    try testing.expectError(fat16.Error.ReadFailed, d.check());
}

// **VOLUMES ANOTHER PROGRAM MADE.** Every volume above was formatted by
// test_disk.zig and written by fat16.zig itself; the volumes this machine
// meets in service were made by mkfs.vfat and written by Linux. So
// tools/check_fat16_images.sh has tools/fat16_read.py make some with
// mkfs.vfat and mtools (`make-foreign`), healthy and damaged each way its own
// self-test damages them, and passes the directory as -Dfat16-foreign. The
// verdict here must be the oracle's: healthy-* clean, damaged-* not. What was
// judged is written to judged.txt there, and the script requires every image
// in it: an option left unset makes this test do nothing, and the script is
// what says so.
test "a volume mkfs.vfat and mtools made: the check's verdict is the oracle's" {
    if (options.foreign_dir.len == 0) return;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, options.foreign_dir, .{ .iterate = true });
    defer dir.close(io);
    var judged: std.ArrayList(u8) = .empty;
    defer judged.deinit(testing.allocator);

    var it = dir.iterate();
    while (try it.next(io)) |file| {
        if (!std.mem.endsWith(u8, file.name, ".img")) continue;
        const bytes = try dir.readFileAlloc(io, file.name, testing.allocator, .limited(64 << 20));
        defer testing.allocator.free(bytes);
        var blk = virtio.Block.inMemory(bytes);
        var scratch: [test_disk.sector]u8 align(16) = undefined;
        var vol = try fat16.Volume.mount(&blk, &scratch, 0);
        const seen = try testing.allocator.alloc(u8, vol.checkBytes());
        defer testing.allocator.free(seen);
        var r = test_disk.Report{};
        r.health = try vol.check(seen, &r, test_disk.Report.each);

        const healthy = std.mem.startsWith(u8, file.name, "healthy-");
        try judged.print(testing.allocator, "{s}: {s}", .{ file.name, if (r.health.clean()) "clean" else "damaged" });
        for (r.found[0..r.len]) |f| try judged.print(testing.allocator, "; {s} at '{s}' cluster {d}", .{ @tagName(f.problem), f.text(), f.cluster });
        try judged.append(testing.allocator, '\n');
        if (healthy != r.health.clean()) {
            std.debug.print("{s}", .{judged.items});
            return error.TestUnexpectedResult;
        }
        if (healthy) try testing.expect(r.health.files > 0);
    }
    try dir.writeFile(io, .{ .sub_path = "judged.txt", .data = judged.items });
}

// ---- a directory at FAT's limit (QUEUE item 9) -----------------------------

/// Makes `path` a directory of `clusters` clusters with every entry in use:
/// "." and "..", then empty files F0000000, F0000001, ..., one 8.3 entry
/// each. Laid straight onto the disk, in both FATs: writing 65,536 names
/// through fat16.zig would scan the directory from its start for each one.
fn fullDirectory(d: *test_disk.Disk, cached: bool, path: []const u8, clusters: usize) !void {
    const first = try d.vol.makePath(path);
    const l = Layout.of(d.bytes);
    try testing.expectEqual(@as(u8, 1), d.bytes[13]); // one sector a cluster, below
    const fat = struct {
        fn get(bytes: []const u8, at: Layout, c: usize) u16 {
            return std.mem.readInt(u16, bytes[at.fat_start + c * 2 ..][0..2], .little);
        }
        fn set(bytes: []u8, at: Layout, c: usize, v: u16) void {
            for (0..2) |copy| std.mem.writeInt(u16, bytes[at.fat_start + copy * at.fat_bytes + c * 2 ..][0..2], v, .little);
        }
    };
    var last: usize = first;
    var candidate: usize = 2;
    for (1..clusters) |_| {
        while (fat.get(d.bytes, l, candidate) != 0) candidate += 1;
        fat.set(d.bytes, l, last, @intCast(candidate));
        fat.set(d.bytes, l, candidate, 0xFFFF);
        last = candidate;
    }
    var name: u32 = 0;
    var c: usize = first;
    for (0..clusters) |k| {
        const sector = d.bytes[(l.data_sector + c - 2) * test_disk.sector ..][0..test_disk.sector];
        for (0..test_disk.sector / 32) |slot| {
            if (k == 0 and slot < 2) continue; // "." and ".."
            const e = sector[slot * 32 ..][0..32];
            @memset(e, 0);
            _ = std.fmt.bufPrint(e[0..8], "F{X:0>7}", .{name}) catch unreachable;
            @memset(e[8..11], ' ');
            e[11] = 0x20; // an archive bit: a plain file
            name += 1;
        }
        c = fat.get(d.bytes, l, c);
    }
    try d.mount(cached);
}

test "a directory grows to FAT's limit of 65,536 entries, and no further" {
    for (both) |cached| {
        const d = try Disk.make("dirlimit", small, cached);
        defer d.deinit();
        const per_cluster = test_disk.sector / 32;
        const limit = fat16.Volume.max_dir_entries / per_cluster; // 4,096 clusters
        // One cluster short of the limit, and full: the next name grows it
        // to exactly the limit.
        try fullDirectory(d, cached, "data/big", limit - 1);
        try d.vol.writeFile("data/big/one-more.md", "fits");
        try d.expectFile("data/big/one-more.md", "fits");
        var chain: [4200]u16 = undefined;
        try testing.expectEqual(limit, chainOf(d, (try d.vol.open("data/big")).first_cluster, &chain).len);
        // "one-more.md" took two of the new cluster's sixteen entries (a long
        // part and the short entry); seven more such names take the other
        // fourteen, and then the directory is full.
        var path: [64]u8 = undefined;
        for (0..7) |k| try d.vol.writeFile(try std.fmt.bufPrint(&path, "data/big/more-{d}.md", .{k}), "x");
        const before = d.free();
        try testing.expectError(fat16.Error.DirectoryFull, d.vol.writeFile("data/big/past-the-limit.md", "x"));
        try testing.expectEqual(before, d.free());
        try testing.expectEqual(limit, chainOf(d, (try d.vol.open("data/big")).first_cluster, &chain).len);
        // Every name in it is still found, the first laid down and the last.
        _ = try d.vol.open("data/big/F0000000");
        _ = try d.vol.open("data/big/more-6.md");
        // Other directories still grow.
        try d.vol.writeFile("data/small/x", "x");
    }
}

// ---- the NT case bits (QUEUE item 12) ---------------------------------------

test "a short name with the NT lower-case bits lists in lower case, and is found either way" {
    for (both) |cached| {
        const d = try Disk.make("ntcase", small, cached);
        defer d.deinit();
        // Upper-case 8.3 names: one short entry each, no long name.
        try d.vol.writeFile("data/TOPIC.MD", "both");
        try d.vol.writeFile("data/NOTES.TXT", "base");
        try d.vol.writeFile("data/README.MD", "ext");
        try d.vol.writeFile("data/KEEP.MD", "neither");
        const data_dir = try d.vol.open("data");
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("TOPIC.MD NOTES.TXT README.MD KEEP.MD", try d.names(data_dir.first_cluster, &buf));
        // As Windows or mtools would have written them.
        for ([_]struct { []const u8, u8 }{ .{ "data/TOPIC.MD", 0x18 }, .{ "data/NOTES.TXT", 0x08 }, .{ "data/README.MD", 0x10 } }) |set| {
            const e = try d.vol.open(set[0]);
            d.bytes[e.lba * test_disk.sector + e.slot + 12] = set[1];
        }
        try d.mount(cached);
        try testing.expectEqualStrings("topic.md notes.TXT README.md KEEP.MD", try d.names(data_dir.first_cluster, &buf));
        // Found by any case, as every name is; the alias is still the alias.
        try d.expectFile("data/topic.md", "both");
        try d.expectFile("data/TOPIC.MD", "both");
        const e = try d.vol.open("data/Topic.Md");
        try testing.expectEqualStrings("TOPIC.MD", e.alias());
        try testing.expectEqualStrings("topic.md", e.text());
    }
}

// ---- the kept free count (QUEUE item 14) -------------------------------------

test "the kept free count follows every operation, the refused and failed ones included" {
    for (both) |cached| {
        const d = try Disk.make("keptfree", .{ .sectors = 4085 + 1 + 2 * 17 + 32 }, cached);
        defer d.deinit();
        try d.expectKept();
        var data: [20_000]u8 = undefined;
        _ = pattern(&data, 6);
        try d.vol.writeFile("data/a", &data);
        try d.expectKept();
        try d.vol.writeFile("data/a", data[0..100]); // replaced, smaller
        try d.expectKept();
        try d.vol.writeFile("data/b", "");
        try d.expectKept();
        try d.vol.writeInto("data/b", 0, data[0..3000]); // an append that allocates
        try d.expectKept();
        try d.vol.writeInto("data/b", 100, "overwrite"); // inside: allocates nothing
        try d.expectKept();
        try testing.expectError(fat16.Error.BadChain, d.vol.writeInto("data/b", 5000, "hole"));
        try d.expectKept();
        try testing.expectError(fat16.Error.BadName, d.vol.writeFile("x" ** (fat16.max_name + 1), "x"));
        try d.expectKept();
        _ = try d.vol.makePath("data/deep/er/still");
        try d.expectKept();
        // Fill the disk: the write that does not fit takes clusters, then
        // gives them all back.
        const big = try testing.allocator.alloc(u8, 3 << 20);
        defer testing.allocator.free(big);
        try testing.expectError(fat16.Error.Full, d.vol.writeFile("data/too-big", big));
        try d.expectKept();
        try d.vol.writeFile("data/fits", big[0 .. 1 << 20]);
        try d.expectKept();
        try testing.expectError(fat16.Error.Full, d.vol.writeInto("data/fits", 1 << 20, big[0 .. 2 << 20]));
        try d.expectKept();
        try d.vol.remove("data/a");
        try d.expectKept();
        try d.vol.removeTree("data");
        try d.expectKept();
        // A fresh mount counts it again, to the same number.
        const kept = d.vol.free_clusters;
        try d.mount(cached);
        try testing.expectEqual(kept, d.vol.free_clusters);
        const sp = try d.vol.space();
        try testing.expectEqual(@as(u64, kept) * 512, sp.free);
    }
}
