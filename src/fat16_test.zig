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
/// The tests that apply to both kinds run over both: the same operations,
/// the same expectations, on FAT16 and on FAT32.
const formats = [_]Shape{ small, test_disk.small32 };
/// Each format with the FAT on the disk and held in memory.
const configs = blk: {
    var out: [formats.len * 2]struct { shape: Shape, cached: bool } = undefined;
    for (formats, 0..) |f, i| {
        out[2 * i] = .{ .shape = f, .cached = false };
        out[2 * i + 1] = .{ .shape = f, .cached = true };
    }
    break :blk out;
};

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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("fresh", shape, cached);
        defer d.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("", try d.names(0, &buf));
        try testing.expect(d.free() > 4085);
    }
}

test "a file is read back exactly, at every size around a sector and a cluster" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("sizes", shape, cached);
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("names", shape, cached);
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("replaced", shape, cached);
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("appends", shape, cached);
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("removetree", shape, cached);
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("growth", shape, cached);
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

test "a full disk refuses a write over a file, and the old file stays whole" {
    for (both) |cached| {
        // Room for the old file's chain and not for a second one beside it:
        // the overwrite needs both at once (essay kernel-facts #1).
        const d = try Disk.make("full-overwrite", .{ .sectors = 4085 + 1 + 2 * 17 + 32 }, cached);
        defer d.deinit();
        const big = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(big);
        _ = pattern(big, 3);
        try d.vol.writeFile("one", big); // 2,048 clusters
        const before = d.free();
        _ = pattern(big, 4);
        try testing.expectError(fat16.Error.Full, d.vol.writeFile("one", big));
        try testing.expectEqual(before, d.free());
        _ = pattern(big, 3);
        try d.expectFile("one", big);
        // A smaller one fits beside it, and takes the old one's place.
        try d.vol.writeFile("one", big[0..1000]);
        try d.expectFile("one", big[0..1000]);
        try testing.expect(d.fatsAgree());
    }
}

test "a chain that runs into a free cluster is a broken chain, not a short file" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-chain", shape, cached);
        defer d.deinit();
        var data: [2000]u8 = undefined;
        try d.vol.writeFile("broken", pattern(&data, 9));
        const e = try d.vol.open("broken");
        // Its second cluster is marked free in both copies of the FAT.
        const l = Layout.of(d.bytes);
        for (0..2) |copy| {
            l.set(d.bytes, copy, e.first_cluster, 0);
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
fn damageFat(d: *test_disk.Disk, cached: bool, cluster: fat16.Cluster, value: fat16.Cluster) !void {
    const l = Layout.of(d.bytes);
    for (0..2) |copy| {
        l.set(d.bytes, copy, cluster, value);
    }
    try d.mount(cached);
}

/// The clusters of a chain, in order, read from the first FAT on the disk.
fn chainOf(d: *const test_disk.Disk, first: fat16.Cluster, out: []fat16.Cluster) []fat16.Cluster {
    const l = Layout.of(d.bytes);
    var n: usize = 0;
    var c = first;
    while (c >= 2 and !l.ends(c) and n < out.len) {
        out[n] = c;
        n += 1;
        c = l.get(d.bytes, 0, c);
    }
    return out[0..n];
}

// **A LOOP IN THE FAT MUST END A WALK WITH AN ERROR.** Before the walks were
// bounded, each of these hung: the test did not fail, it never finished.

test "a file whose chain loops back is a broken chain to append to, not a hang" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-loop-file", shape, cached);
        defer d.deinit();
        var data: [1536]u8 = undefined; // three clusters, full, so an append needs a fourth
        try d.vol.writeFile("data/log", pattern(&data, 4));
        const e = try d.vol.open("data/log");
        var chain: [8]fat16.Cluster = undefined;
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-loop-dir", shape, cached);
        defer d.deinit();
        // Every cluster of it full, so no end-of-directory entry stops a walk:
        // "." and "..", and three entries a name, are 32, two clusters.
        var path: [64]u8 = undefined;
        for (0..10) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.vol.writeFile(p, "x");
        }
        const dir = try d.vol.open("data/sessions");
        var chain: [64]fat16.Cluster = undefined;
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-past-end", shape, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined;
        try d.vol.writeFile("f", pattern(&data, 5));
        const e = try d.vol.open("f");
        const past: fat16.Cluster = @intCast(Layout.of(d.bytes).clusters + 2);
        const l = Layout.of(d.bytes);
        // Past the volume, in the reserved range, and the bad mark.
        for ([_]fat16.Cluster{ past, l.end() - 15, l.bad() }) |link| {
            try damageFat(d, cached, e.first_cluster, link);
            var out: [1500]u8 = undefined;
            try testing.expectError(fat16.Error.BadChain, d.vol.readFile(e, &out));
            try testing.expectError(fat16.Error.BadChain, d.vol.writeInto("f", 1000, "x"));
            try testing.expectError(fat16.Error.BadChain, d.vol.layout(e));
        }
    }
}

test "an entry whose first cluster is past the volume is a broken chain, and removing it frees nothing" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-first-cluster", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("f", "some bytes");
        try d.vol.writeFile("data/x", "a directory's worth");
        const e = try d.vol.open("f");
        const dir = try d.vol.open("data");
        const past: fat16.Cluster = @intCast(Layout.of(d.bytes).clusters + 2);
        // The first cluster is two bytes at offset 26 of the entry.
        setEntry(d, e, .first_cluster, past);
        setEntry(d, dir, .first_cluster, past + 1000);
        try d.mount(cached);
        const free = d.free();

        var out: [64]u8 = undefined;
        try testing.expectError(fat16.Error.BadChain, d.vol.readFile(try d.vol.open("f"), &out));
        try testing.expectError(fat16.Error.BadChain, d.vol.writeInto("f", 2, "x"));
        try testing.expectError(fat16.Error.BadChain, d.vol.open("data/x"));
        var buf: [64]u8 = undefined;
        try testing.expectError(fat16.Error.BadChain, d.names(past + 1000, &buf));
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
        .first_cluster => {
            std.mem.writeInt(u16, d.bytes[at + 26 ..][0..2], @truncate(value), .little);
            std.mem.writeInt(u16, d.bytes[at + 20 ..][0..2], @truncate(value >> 16), .little);
        },
    }
}

test "the check counts what a healthy volume holds" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("check-healthy", shape, cached);
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
        // FAT32's root is a chain in the data region, held like any
        // directory's: one cluster here, already in use when `empty` was
        // counted.
        const root: u32 = if (shape.kind == .fat32) 1 else 0;
        try testing.expectEqual(@as(u32, @intCast(empty - d.free())) + root, r.health.used);
        try testing.expectEqual(@as(u32, 0), r.health.leaked);
    }
}

test "the check finds clusters in use that nothing holds" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-leaked", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/x", "kept");
        const last: fat16.Cluster = @intCast(Layout.of(d.bytes).clusters + 1);
        // One cluster alone, and a run of three linked ones, as a write that
        // stopped before its entry was written leaves them.
        const l = Layout.of(d.bytes);
        try damageFat(d, cached, last - 10, l.end());
        try damageFat(d, cached, last - 5, last - 4);
        try damageFat(d, cached, last - 4, last - 3);
        try damageFat(d, cached, last - 3, l.end());
        // A cluster marked bad is in use by nothing, and is not a leak.
        try damageFat(d, cached, last - 1, l.bad());
        // And the volume's very last cluster, where the FAT's scan ends.
        try damageFat(d, cached, last, l.end());
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-broken", shape, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined; // three clusters
        try d.vol.writeFile("data/f", pattern(&data, 2));
        const e = try d.vol.open("data/f");
        const past: fat16.Cluster = @intCast(Layout.of(d.bytes).clusters + 2);
        for ([_]fat16.Cluster{ 0, past, Layout.of(d.bytes).bad() }) |link| {
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-first", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        try d.vol.writeFile("auth/7/password", "x");
        const f = try d.vol.open("data/f");
        const dir = try d.vol.open("auth/7");
        const past: fat16.Cluster = @intCast(Layout.of(d.bytes).clusters + 2);
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-crossed", shape, cached);
        defer d.deinit();
        var data: [1500]u8 = undefined;
        try d.vol.writeFile("a", pattern(&data, 3));
        try d.vol.writeFile("b", pattern(&data, 4));
        try d.vol.writeFile("c", pattern(&data, 5));
        var chain: [8]fat16.Cluster = undefined;
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-dirs", shape, cached);
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
        var chain: [8]fat16.Cluster = undefined;
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-size", shape, cached);
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-fats", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("f", "x");
        // The second copy only, and not mounted again: a held FAT would bring
        // the copies into line, which is cacheFat's business, not the check's.
        const l = Layout.of(d.bytes);
        l.set(d.bytes, 1, 300, l.end());
        l.set(d.bytes, 1, 1000, l.end());
        const r = try d.check();
        try r.expect(&.{.{ .problem = .fats_differ, .cluster = 300, .count = 2 }});
    }
}

test "the check reads the FAT in runs: a leak across a run's edge and a difference past the first run are found where they are" {
    for (both) |cached| {
        const d = try Disk.make("damaged-check-runs", test_disk.small32, cached);
        defer d.deinit();
        const l = Layout.of(d.bytes);
        const per: usize = test_disk.sector / 4;
        // The check reads 64 sectors a request: the FAT must span several.
        try testing.expect(d.vol.sectors_per_fat > 64);
        // Two clusters nothing holds, in both copies, either side of the edge
        // between the FAT's 64th and 65th sectors: one leaked run of two.
        const edge = 64 * per;
        for (0..2) |copy| {
            l.set(d.bytes, copy, edge - 1, l.end());
            l.set(d.bytes, copy, edge, l.end());
        }
        try d.mount(cached); // a held FAT holds them too
        // The second copy apart from the first in the 66th sector only.
        l.set(d.bytes, 1, edge + per + 5, l.end());
        const r = try d.check();
        try r.expect(&.{
            .{ .problem = .leaked, .cluster = @intCast(edge - 1), .count = 2 },
            .{ .problem = .fats_differ, .cluster = @intCast(edge + per + 5), .count = 1 },
        });
    }
}

test "the check finds a . or .. that points elsewhere" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-check-dots", shape, cached);
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        // A healthy volume (tools/fat16_read.py checks it clean), deeper than
        // the check walks. makePath stops where the check does, so the last
        // level is made by hand, as another program with no such limit would.
        const d = try Disk.make("limit-check-deep", shape, cached);
        defer d.deinit();
        const fifteen = try d.vol.makePath("d/" ** 14 ++ "d");
        const sixteen = try d.vol.makeDirIn(fifteen, "d");
        try d.vol.writeFileIn(sixteen, "f", "x");
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
        const healthy = std.mem.startsWith(u8, file.name, "healthy-");
        // A volume this machine refuses at mount (FAT32 mirroring off, a
        // version it does not know, a root out of range) is one it has found
        // wanting: the oracle must call it damaged too.
        var vol = fat16.Volume.mount(&blk, &scratch, 0) catch |e| {
            try judged.print(testing.allocator, "{s}: refused; {s}\n", .{ file.name, @errorName(e) });
            if (healthy) {
                std.debug.print("{s}", .{judged.items});
                return error.TestUnexpectedResult;
            }
            continue;
        };
        const seen = try testing.allocator.alloc(u8, vol.checkBytes());
        defer testing.allocator.free(seen);
        var r = test_disk.Report{};
        r.health = try vol.check(seen, &r, test_disk.Report.each);

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
        fn set(bytes: []u8, at: Layout, c: usize, v: u32) void {
            for (0..2) |copy| at.set(bytes, copy, c, v);
        }
    };
    var last: usize = first;
    var candidate: usize = 2;
    for (1..clusters) |_| {
        while (l.get(d.bytes, 0, candidate) != 0) candidate += 1;
        fat.set(d.bytes, l, last, @intCast(candidate));
        fat.set(d.bytes, l, candidate, l.end());
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
        c = l.get(d.bytes, 0, c);
    }
    try d.mount(cached);
}

test "a directory grows to FAT's limit of 65,536 entries, and no further" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("dirlimit", shape, cached);
        defer d.deinit();
        const per_cluster = test_disk.sector / 32;
        const limit = fat16.Volume.max_dir_entries / per_cluster; // 4,096 clusters
        // One cluster short of the limit, and full: the next name grows it
        // to exactly the limit.
        try fullDirectory(d, cached, "data/big", limit - 1);
        try d.vol.writeFile("data/big/one-more.md", "fits");
        try d.expectFile("data/big/one-more.md", "fits");
        var chain: [4200]fat16.Cluster = undefined;
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
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("ntcase", shape, cached);
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

// ---- a rewrite keeps the name (the box's judge, 2026-10-02) ------------------

test "a file rewritten under a name in another case keeps the name and alias it has" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("recase", shape, cached);
        defer d.deinit();
        // A long name, as the Store writes a topic's sidecar; a name that
        // needs no long one; and one that fits 8.3 only in upper case.
        try d.vol.writeFile("data/metal-talk.count", "1");
        try d.vol.writeFile("data/plan.md", "one");
        try d.vol.writeFile("data/KEEP.MD", "a");
        const alias = (try d.vol.open("data/metal-talk.count")).alias();
        var alias_buf: [12]u8 = undefined;
        const kept_alias = alias_buf[0..alias.len];
        @memcpy(kept_alias, alias);

        try d.vol.writeFile("data/Metal-Talk.count", "2");
        try d.vol.writeFile("data/PLAN.md", "two");
        try d.vol.writeFile("data/keep.md", "b");
        const data_dir = try d.vol.open("data");
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("metal-talk.count plan.md KEEP.MD", try d.names(data_dir.first_cluster, &buf));
        try testing.expectEqualStrings(kept_alias, (try d.vol.open("data/METAL-TALK.COUNT")).alias());
        try d.expectFile("data/metal-talk.count", "2");
        try d.expectFile("data/plan.md", "two");
        try d.expectFile("data/KEEP.MD", "b");

        // A new file still takes the case it is given.
        try d.vol.writeFile("data/New-Topic.md", "x");
        try testing.expectEqualStrings("metal-talk.count plan.md KEEP.MD New-Topic.md", try d.names(data_dir.first_cluster, &buf));
        try d.mount(cached);
        try testing.expectEqualStrings("metal-talk.count plan.md KEEP.MD New-Topic.md", try d.names(data_dir.first_cluster, &buf));
        try testing.expect(d.fatsAgree());
    }
}

// ---- a file near 4 GiB (REVIEW-restart-fat32.md F1) --------------------------

test "an append to a file within a cluster of 4 GiB answers TooBig past it, not a panic" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-near-4g", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/x", "abc");
        const e = try d.vol.open("data/x");
        // Its entry says 4 GiB less 100 bytes; the chain is still one cluster,
        // so the disk is damaged on purpose, but the arithmetic is what is
        // under test: it used to overflow before reading the chain.
        const at = e.lba * test_disk.sector + e.slot + 28;
        std.mem.writeInt(u32, d.bytes[at..][0..4], 0xFFFF_FF9C, .little);
        try d.mount(cached);
        try testing.expectError(fat16.Error.TooBig, d.vol.writeInto("data/x", 0xFFFF_FF9C, "x" ** 101));
        // Within the limit it gets past the sizes and meets the short chain.
        try testing.expect(std.meta.isError(d.vol.writeInto("data/x", 0xFFFF_FF9C, "more")));
    }
}

// ---- a file never replaces a directory (QUEUE item 36) -----------------------

test "a file written over a directory's name is refused, and the directory and its contents stay" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("file-over-dir", shape, cached);
        defer d.deinit();
        try d.vol.writeFile("data/plan/inside.md", "kept");
        const before = d.free();
        // In its own case and in another: FAT matches either.
        try testing.expectError(fat16.Error.IsDirectory, d.vol.writeFile("data/plan", "a file"));
        try testing.expectError(fat16.Error.IsDirectory, d.vol.writeFile("data/Plan", "a file"));
        try d.expectFile("data/plan/inside.md", "kept");
        try testing.expectEqual(before, d.free());
        try testing.expect((try d.vol.open("data/plan")).isDirectory());
        try d.mount(cached);
        try d.expectFile("data/plan/inside.md", "kept");
    }
}

test "a long name's orphan parts are tombstoned before a new entry is written after them, so it is not listed under their name" {
    for (configs) |cfg| {
        const d = try Disk.make("orphan-long-name", cfg.shape, cfg.cached);
        defer d.deinit();
        // "c" is stored as a long name and the alias C~1, whose checksum is
        // 0xC0; so is the short name B's. Tombstone c's short entry alone, as
        // a remove stopped between its two steps leaves it: the long part
        // is an orphan, followed by a free slot.
        try d.vol.writeFile("data/c", "");
        const c = try d.vol.open("data/c");
        d.bytes[(d.vol.start_lba + c.lba) * test_disk.sector + c.slot] = 0xE5;
        try d.mount(cfg.cached);

        try d.vol.writeFile("data/B", "bee");
        try d.expectFile("data/b", "bee");
        try testing.expectError(fat16.Error.NotFound, d.vol.open("data/c"));
        const dir = try d.vol.open("data");
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("B", try d.names(dir.first_cluster, &buf));
    }
}

test "a path through a file names nothing, whatever the file's bytes spell" {
    for (configs) |cfg| {
        const d = try Disk.make("through-a-file", cfg.shape, cfg.cached);
        defer d.deinit();
        // A file whose first 32 bytes are a directory entry for "X", a file
        // of 5 bytes at cluster 2: what a walk through it would find.
        var bytes = [_]u8{0} ** 64;
        @memcpy(bytes[0..11], "X          ");
        bytes[11] = 0x20;
        bytes[26] = 2;
        bytes[28] = 5;
        try d.vol.writeFile("data/f", &bytes);
        try testing.expectError(fat16.Error.NotFound, d.vol.open("data/f/x"));
        try testing.expectError(fat16.Error.NotFound, d.vol.open("data/f/x/y"));
        try testing.expect(!(try d.vol.open("data/f")).isDirectory());
    }
}

// ---- rename, for a replace that survives a crash (QUEUE item 24) -------------

test "rename moves a file to a new name, and over a file, keeping that file's name" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("rename", shape, cached);
        defer d.deinit();
        var big: [3000]u8 = undefined;
        try d.vol.writeFile("data/old.count", pattern(&big, 7));
        try d.vol.writeFile("data/tmp1", "new contents");
        const before = d.free();

        // Over a file: `to` holds the new bytes under its own name, and its
        // old clusters (six of them) are free again; `from` is gone.
        try d.vol.rename("data/tmp1", "data/OLD.COUNT");
        try d.expectFile("data/old.count", "new contents");
        try testing.expectError(fat16.Error.NotFound, d.vol.open("data/tmp1"));
        try testing.expectEqual(before + 6, d.free());
        const data_dir = try d.vol.open("data");
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("old.count", try d.names(data_dir.first_cluster, &buf));

        // To a name nobody has: the case given, no cluster moved.
        try d.vol.writeFile("data/tmp2", "x");
        const mid = d.free();
        try d.vol.rename("data/tmp2", "data/Fresh-Name.md");
        try d.expectFile("data/fresh-name.md", "x");
        try testing.expectEqual(mid, d.free());
        try testing.expectEqualStrings("old.count Fresh-Name.md", try d.names(data_dir.first_cluster, &buf));

        // An empty file renames too.
        try d.vol.writeFile("data/empty", "");
        try d.vol.rename("data/empty", "data/old.count");
        try d.expectFile("data/old.count", "");

        // Refused: across directories, a directory either side, a missing
        // `from`. Renaming a file to its own name in another case does nothing.
        try d.vol.writeFile("data/a", "a");
        try d.vol.writeFile("other/b", "b");
        try testing.expectError(fat16.Error.BadName, d.vol.rename("data/a", "other/a"));
        _ = try d.vol.makePath("data/sub");
        try testing.expectError(fat16.Error.IsDirectory, d.vol.rename("data/a", "data/sub"));
        try testing.expectError(fat16.Error.BadName, d.vol.rename("data/sub", "data/c"));
        try testing.expectError(fat16.Error.NotFound, d.vol.rename("data/nothing", "data/a"));
        try d.vol.rename("data/a", "data/A");
        try d.expectFile("data/a", "a");

        try d.mount(cached);
        try d.expectFile("data/old.count", "");
        try d.expectFile("data/fresh-name.md", "x");
        try d.expectKept();
        try testing.expect(d.fatsAgree());
    }
}

test "a rename stopped at any point leaves the old file or the new, whole, and at worst leaked clusters" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        var stop: u64 = 0;
        var finished = false;
        while (!finished) : (stop += 1) {
            // Labelled by what the stop left, once it is known: a disk with
            // leaked clusters is damaged-*, and the oracle must find that; a
            // clean one must check clean. Every stop is kept on FAT16 with
            // the FAT on the disk; elsewhere only the last, to save room.
            var label_buf: [48]u8 = undefined;
            const d = try Disk.make("limit-rename-stop", shape, cached);
            defer d.deinit();
            var big: [3000]u8 = undefined;
            const old = pattern(&big, 3);
            try d.vol.writeFile("data/rec", old);
            try d.vol.writeFile("data/rec.tmp", "the new record");

            d.blk.fail_after = d.blk.requests + stop;
            if (d.vol.rename("data/rec.tmp", "data/rec")) |_| {
                finished = true;
            } else |_| {}
            d.blk.fail_after = null;
            // Mounted again as the boot does, FAT held or not: a held FAT
            // brings copies a stop left apart into line (cacheFat).
            try d.mount(cached);

            const got = try d.read("data/rec");
            defer testing.allocator.free(got);
            const is_old = std.mem.eql(u8, got, old);
            const is_new = std.mem.eql(u8, got, "the new record");
            if (!is_old and !is_new) {
                std.debug.print("stopped after {d} requests: data/rec is neither file ({d} bytes)\n", .{ stop, got.len });
                return error.TestUnexpectedResult;
            }
            if (finished) try testing.expect(is_new);
            // Whatever is left over is leaked clusters, never a cross-link,
            // a short file or a broken chain. And FAT copies that differ:
            // every FAT update writes the first copy, then the second, so a
            // stop between the two leaves them apart, rename or not.
            const r = try d.check();
            for (r.found[0..r.len]) |f| {
                if (f.problem != .leaked and f.problem != .fats_differ) {
                    std.debug.print("stopped after {d} requests: {s} at {s}\n", .{ stop, @tagName(f.problem), f.text() });
                    return error.TestUnexpectedResult;
                }
            }
            if (shape.kind == .fat16 and !cached) {
                const kind = if (r.health.clean()) "" else "damaged-";
                d.label = try std.fmt.bufPrint(&label_buf, "{s}rename-stop-{d:0>2}", .{ kind, stop });
            }
        }
        // It took more than one request, so the loop did stop it part-way.
        try testing.expect(stop > 2);
    }
}

test "a FAT whose copies differ is held as the first, and the others are written from it" {
    for (formats) |shape| {
        const d = try Disk.make("fats-brought-into-line", shape, false);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        // As a machine stopped between the copies' writes leaves them: the
        // second behind the first, in two sectors.
        const l = Layout.of(d.bytes);
        const per_sector: usize = if (shape.kind == .fat32) test_disk.sector / 4 else test_disk.sector / 2;
        l.set(d.bytes, 1, 3 * per_sector + 7, l.end());
        l.set(d.bytes, 1, 9 * per_sector + 1, l.end());
        try testing.expect(!d.fatsAgree());
        const writes = d.blk.writes;

        try d.mount(true);
        try testing.expectEqual(@as(u32, 2), d.repaired);
        try testing.expectEqual(@as(u32, 0), d.trusted); // the second has clusters nothing holds
        try testing.expectEqual(writes + 2, d.blk.writes); // those two sectors, nothing else
        try testing.expect(d.fatsAgree());
        try testing.expectEqual(@as(u32, 0), l.get(d.bytes, 0, 3 * per_sector + 7));
        try d.expectFile("data/f", "x");
        const r = try d.check();
        try r.expect(&.{});
        // Agreeing copies are left alone.
        try d.mount(true);
        try testing.expectEqual(@as(u32, 0), d.repaired);
        try testing.expectEqual(writes + 2, d.blk.writes);
    }
}

test "a first FAT copy that reads wrong is not written over the second: the copy that checks clean is the FAT (B26)" {
    for (formats) |shape| {
        const d = try Disk.make("first-copy-rotted", shape, false);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        // The file's cluster, the last one taken: its first copy's entry is
        // made free, as a rotted sector of the first copy would read.
        const l = Layout.of(d.bytes);
        var c: usize = 2;
        var last: usize = 0;
        while (c <= l.end() and c < 1000) : (c += 1) {
            if (l.get(d.bytes, 0, c) != 0) last = c;
        }
        try testing.expect(last >= 3);
        const was = l.get(d.bytes, 1, last);
        l.set(d.bytes, 0, last, 0);
        try testing.expect(!d.fatsAgree());

        try d.mount(true);
        try testing.expectEqual(@as(u32, 1), d.repaired);
        try testing.expectEqual(@as(u32, 1), d.trusted); // the second copy
        try testing.expect(d.fatsAgree());
        try testing.expectEqual(was, l.get(d.bytes, 0, last)); // the first, healed from it
        try d.expectFile("data/f", "x");
        const r = try d.check();
        try r.expect(&.{});
    }
}

test "copies apart and a directory that cannot be read: the volume mounts, and neither copy is written over (metal-vmm QUEUE 103)" {
    // (CC, 2026-10-08.) Weighing the copies
    // (B26) runs a whole check, which reads every directory. Before B26
    // copies apart were brought into line from the first and the volume
    // mounted; now one directory sector that fails to read fails the mount,
    // and on metal the boot stops ("the FAT could not be held in memory").
    // A disk with a bad sector in a folder and a rotted FAT sector is the
    // disk B25 and B26 were for. The check failing should leave the choice
    // unmade: mount with the first copy held, and write neither, so the
    // second copy, perhaps the good one, is there for a boot that can weigh.
    for (formats) |shape| {
        const d = try Disk.make("damaged-weigh-unreadable", shape, false);
        defer d.deinit();
        try d.vol.writeFile("data/f", "x");
        const l = Layout.of(d.bytes);
        var c: usize = 2;
        var last: usize = 0;
        while (c <= l.end() and c < 1000) : (c += 1) {
            if (l.get(d.bytes, 0, c) != 0) last = c;
        }
        try testing.expect(last >= 3);
        const was = l.get(d.bytes, 1, last);
        l.set(d.bytes, 0, last, 0);
        const damaged = try testing.allocator.dupe(u8, d.bytes);
        defer testing.allocator.free(damaged);
        const buf = try testing.allocator.alloc(u8, d.vol.fatBytes());
        defer testing.allocator.free(buf);
        const room = try testing.allocator.alloc(u8, d.vol.checkBytes());
        defer testing.allocator.free(room);

        // How many requests come before the check: the copies read and
        // compared, unweighed, less the sectors written to repair them.
        try d.mount(false);
        const r0 = d.blk.requests;
        const unweighed = try d.vol.cacheFatChecked(buf, null);
        const before_check = d.blk.requests - r0 - unweighed.repaired;
        @memcpy(d.bytes, damaged);

        // The same mount, weighing, and the check's first read fails.
        try d.mount(false);
        d.blk.fault = .{ .at = d.blk.requests + before_check, .kind = .fails };
        const m = try d.vol.cacheFatChecked(buf, room);
        try testing.expect(!m.checked);
        try testing.expect(m.unweighed);
        try testing.expectEqual(@as(u32, 0), m.repaired);
        try testing.expectEqual(was, l.get(d.bytes, 1, last)); // the second copy kept
    }
}

test "a name past ASCII is refused, not written to read back as another (metal-vmm QUEUE 104)" {
    // A long name holds each byte as one UTF-16 unit, and a unit past ASCII
    // read back as '?': "café" (UTF-8) was written, and then found under
    // no name it was given, so a second write made a second file.
    for (configs) |cfg| {
        const d = try Disk.make("non-ascii", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/plain", "x");
        try testing.expectError(fat16.Error.BadName, d.vol.writeFile("data/caf\xc3\xa9", "x"));
        try testing.expectError(fat16.Error.BadName, d.vol.writeFile("data/\xe2\x82\xac/f", "x")); // a folder made on the way
        try testing.expectError(fat16.Error.BadName, d.vol.rename("data/plain", "data/na\xefve"));
        try d.expectFile("data/plain", "x"); // a refused rename keeps what it would have moved
    }
}

// ---- the survivors of mutation testing (MUTATION.md, metal-vmm QUEUE 107) ----

test "a file ending inside a sector leaves zeros past its end, not what a file before it left (mutant F6)" {
    for (configs) |cfg| {
        const d = try Disk.make("f6-tail", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/old", "Y" ** 1500);
        const old = (try d.vol.open("data/old")).first_cluster;
        try d.vol.remove("data/old");
        try d.vol.writeFile("data/new", "x" ** 10); // the freed cluster, first
        const e = try d.vol.open("data/new");
        try testing.expectEqual(old, e.first_cluster);
        const l = Layout.of(d.bytes);
        const at = (l.data_sector + (e.first_cluster - 2) * d.bytes[13]) * test_disk.sector;
        try testing.expectEqualStrings("x" ** 10, d.bytes[at..][0..10]);
        try testing.expect(std.mem.allEqual(u8, d.bytes[at + 10 ..][0 .. test_disk.sector - 10], 0));
    }
}

test "reading at a file's very end reads nothing, even where its chain ends there too (mutant F10)" {
    for (configs) |cfg| {
        const d = try Disk.make("f10-end", cfg.shape, cfg.cached);
        defer d.deinit();
        const cluster_bytes = @as(usize, d.bytes[13]) * test_disk.sector;
        const data = try testing.allocator.alloc(u8, 2 * cluster_bytes);
        defer testing.allocator.free(data);
        try d.vol.writeFile("data/f", pattern(data, 3));
        const e = try d.vol.open("data/f");
        var out: [16]u8 = undefined;
        try testing.expectEqual(@as(usize, 0), try d.vol.readAt(e, e.size, &out));
    }
}

test "the check finds a chain exactly one cluster short of its size (mutant F14)" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("damaged-f14-short", shape, cached);
        defer d.deinit();
        const cluster_bytes: u32 = @as(u32, d.bytes[13]) * test_disk.sector;
        const data = try testing.allocator.alloc(u8, 2 * cluster_bytes);
        defer testing.allocator.free(data);
        try d.vol.writeFile("f", pattern(data, 4)); // two clusters
        const e = try d.vol.open("f");
        setEntry(d, e, .size, 2 * cluster_bytes + 1); // three's worth
        try d.mount(cached);
        const r = try d.check();
        try r.expect(&.{.{ .problem = .short, .path = "/f", .cluster = e.first_cluster, .count = 2 }});
    }
}

test "a name removed leaves its entries for the next name of the same length (mutant F15)" {
    for (configs) |cfg| {
        const d = try Disk.make("f15-reuse", cfg.shape, cfg.cached);
        defer d.deinit();
        try d.vol.writeFile("data/keep", "k");
        try d.vol.writeFile("data/gone", "g");
        const gone = try d.vol.open("data/gone");
        try d.vol.writeFile("data/last", "l");
        try d.vol.remove("data/gone");
        try d.vol.writeFile("data/next", "n");
        const next = try d.vol.open("data/next");
        try testing.expectEqual(gone.lba, next.lba);
        try testing.expectEqual(gone.slot, next.slot);
    }
}

test "FAT copies apart that check alike: neither is written over (the night of 2026-10-08, seed 16341)" {
    for (formats) |shape| {
        const d = try Disk.make("damaged-weigh-tie", shape, false);
        defer d.deinit();
        // A cluster marked bad in the first copy, free in the second: neither
        // is a leak, so the two check alike.
        const l = Layout.of(d.bytes);
        const c: usize = 900;
        l.set(d.bytes, 0, c, l.bad());
        const writes = d.blk.writes;
        try d.mount(true);
        try testing.expect(!d.fatsAgree());
        try testing.expectEqual(@as(u32, 0), d.repaired);
        try testing.expectEqual(writes, d.blk.writes); // nothing written
        try testing.expectEqual(l.bad(), l.get(d.bytes, 0, c));
        try testing.expectEqual(@as(u32, 0), l.get(d.bytes, 1, c));
    }
}

test "FAT copies that tie: the next change to a differing sector writes the held copy's version to both (a finding, metal-vmm QUEUE 124(f): the box decides)" {
    // **THIS PINS WHAT IS, NOT WHAT SHOULD BE.** On a tie the first copy is
    // held and neither is written, so the second's version is kept for a
    // boot that can weigh. But a change to a FAT sector writes the held
    // sector to every copy, so the first change in a sector that differs
    // makes the second copy the first's there, entries the change never
    // touched among them: the tie postpones the choice, then makes it.
    //
    // **IT DOES NOT CHOOSE BETWEEN THE FIXES** (metal-vmm QUEUE 127(g)). The
    // difference here is a bad-cluster mark against a free entry, and a tie
    // needs a difference that neutral: rot that freed a cluster a file holds
    // breaks that copy's chain, and the other copy wins outright. Under
    // P124(f)'s "merge toward allocated" the mark is the nonzero side, so
    // both copies end as here and this stays green; under "keep each copy's
    // own" the second copy stays free at 900 and this goes red. A fix is
    // judged by its own red test, not by this one.
    for (formats) |shape| {
        const d = try Disk.make("damaged-weigh-tie-written", shape, false);
        defer d.deinit();
        const l = Layout.of(d.bytes);
        const c: usize = 900;
        l.set(d.bytes, 0, c, l.bad());
        try d.mount(true);
        try testing.expect(!d.fatsAgree());
        try testing.expectEqual(@as(u32, 0), l.get(d.bytes, 1, c));
        // A file long enough that its chain runs through the FAT sector
        // that holds entry 900, around it.
        const per_sector: usize = if (l.kind == .fat32) 128 else 256;
        const bytes = try testing.allocator.alloc(u8, (c / per_sector * per_sector + per_sector) * 512);
        defer testing.allocator.free(bytes);
        @memset(bytes, 'x');
        try d.vol.writeFile("big", bytes);
        // The second copy now says what the first said of a cluster the
        // write never touched.
        try testing.expectEqual(l.bad(), l.get(d.bytes, 1, c));
        try testing.expectEqual(l.bad(), l.get(d.bytes, 0, c));
    }
}

test "a repair of FAT copies apart that the disk refuses: the mount goes on (the night of 2026-10-08, seed 18771)" {
    for (formats) |shape| {
        const d = try Disk.make("damaged-repair-refused", shape, false);
        defer d.deinit();
        try d.vol.writeFile("f", "x");
        // The second copy apart from the first by clusters nothing holds: the
        // first checks cleaner, and the second is to be written from it.
        const l = Layout.of(d.bytes);
        l.set(d.bytes, 1, 300, l.end());
        const damaged = try testing.allocator.dupe(u8, d.bytes);
        defer testing.allocator.free(damaged);
        const buf = try testing.allocator.alloc(u8, d.vol.fatBytes());
        defer testing.allocator.free(buf);
        const room = try testing.allocator.alloc(u8, d.vol.checkBytes());
        defer testing.allocator.free(room);

        // How many requests come before the repair: the copies read and
        // weighed, less the sectors written to repair them.
        try d.mount(false);
        const r0 = d.blk.requests;
        const whole = try d.vol.cacheFatChecked(buf, room);
        try testing.expect(whole.repaired > 0);
        const before_repair = d.blk.requests - r0 - whole.repaired;
        @memcpy(d.bytes, damaged);

        // The same mount, and the repair's first write fails.
        try d.mount(false);
        d.blk.fault = .{ .at = d.blk.requests + before_repair, .kind = .fails };
        const m = try d.vol.cacheFatChecked(buf, room);
        d.blk.fault = null;
        try testing.expect(m.checked);
        try testing.expect(!m.unweighed);
        try testing.expect(m.repair_failed);
        try testing.expectEqual(@as(u32, 0), m.trusted);
        try testing.expectEqual(@as(u32, 0), m.repaired);
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

// ---- FAT32's own cases (QUEUE item 17, FAT32.md "Judged against Linux") ------

/// A FAT32 volume big enough for files past cluster 65,535: about 44 MiB.
const big32 = Shape{ .sectors = 90_000, .kind = .fat32, .suffix = "-fat32" };

test "FAT32: files that start past cluster 65,535 are found by both halves of their cluster, and read back" {
    for (both) |cached| {
        const d = try Disk.make("fat32-high", big32, cached);
        defer d.deinit();
        try testing.expectEqual(fat16.Kind.fat32, d.vol.kind);
        // 33 MiB first: 67,584 clusters, so what follows starts past 65,535.
        const huge = try testing.allocator.alloc(u8, 33 << 20);
        defer testing.allocator.free(huge);
        _ = pattern(huge, 11);
        try d.vol.writeFile("data/huge.bin", huge);
        var data: [3000]u8 = undefined;
        var path: [64]u8 = undefined;
        for (0..5) |k| {
            const p = try std.fmt.bufPrint(&path, "data/after/file-{d}.md", .{k});
            try d.vol.writeFile(p, pattern(&data, @intCast(k)));
            const e = try d.vol.open(p);
            try testing.expect(e.first_cluster > 0xFFFF);
            // Both halves on the disk, as the spec lays them out.
            const raw = d.bytes[e.lba * test_disk.sector + e.slot ..][0..32];
            const hi = std.mem.readInt(u16, raw[20..22], .little);
            const lo = std.mem.readInt(u16, raw[26..28], .little);
            try testing.expectEqual(e.first_cluster, (@as(u32, hi) << 16) | lo);
        }
        // And after a fresh mount, which reads them back from the disk.
        try d.mount(cached);
        for (0..5) |k| {
            const p = try std.fmt.bufPrint(&path, "data/after/file-{d}.md", .{k});
            try d.expectFile(p, pattern(&data, @intCast(k)));
        }
        try d.expectFile("data/huge.bin", huge);
        // An append past the end of a high file, and a directory made there.
        try d.vol.writeInto("data/after/file-0.md", 3000, "and more");
        _ = try d.vol.makePath("data/after/deeper");
        try d.vol.writeFile("data/after/deeper/x", "x");
        try d.expectFile("data/after/deeper/x", "x");
    }
}

test "FAT32: the root is a chain, and grows past its first cluster as FAT16's cannot" {
    for (both) |cached| {
        const d = try Disk.make("fat32-root", test_disk.small32, cached);
        defer d.deinit();
        var path: [64]u8 = undefined;
        // Three entries a name, sixteen a cluster: 60 names need 12 clusters.
        for (0..60) |k| {
            const p = try std.fmt.bufPrint(&path, "root-file-number-{d:0>3}.txt", .{k});
            try d.vol.writeFile(p, p);
        }
        const l = Layout.of(d.bytes);
        var chain: [64]fat16.Cluster = undefined;
        try testing.expect(chainOf(d, l.root_cluster, &chain).len >= 12);
        for (0..60) |k| {
            const p = try std.fmt.bufPrint(&path, "root-file-number-{d:0>3}.txt", .{k});
            try d.expectFile(p, p);
        }
        // A directory in the root has ".." = 0, as the spec spells the root.
        _ = try d.vol.makePath("sub");
        const sub = try d.vol.open("sub");
        const dotdot = d.bytes[(l.data_sector + sub.first_cluster - 2) * test_disk.sector + 32 ..][0..32];
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, dotdot[26..28], .little));
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, dotdot[20..22], .little));
    }
}

test "FAT32: an entry's reserved top four bits survive a write through it" {
    for (both) |cached| {
        const d = try Disk.make("fat32-reserved", test_disk.small32, cached);
        defer d.deinit();
        var data: [1024]u8 = undefined; // two clusters
        try d.vol.writeFile("f", pattern(&data, 2));
        const e = try d.vol.open("f");
        const l = Layout.of(d.bytes);
        var chain: [8]fat16.Cluster = undefined;
        const last = chainOf(d, e.first_cluster, &chain)[1];
        // Another tool set the reserved bits on the last entry, an end mark.
        for (0..2) |copy| l.set(d.bytes, copy, last, 0xA000_0000 | l.end());
        try d.mount(cached);
        // An append links a new cluster from that entry: its value changes,
        // and its top four bits must not.
        try d.vol.writeInto("f", 1024, "more");
        for (0..2) |copy| {
            const raw = std.mem.readInt(u32, d.bytes[l.fat_start + copy * l.fat_bytes + @as(usize, last) * 4 ..][0..4], .little);
            try testing.expectEqual(@as(u32, 0xA000_0000), raw & 0xF000_0000);
            try testing.expect(raw & 0x0FFF_FFFF != l.end());
        }
        var all: [1028]u8 = undefined;
        @memcpy(all[0..1024], &data);
        @memcpy(all[1024..], "more");
        try d.expectFile("f", &all);
    }
}

test "FAT32: FSInfo's free count and hint are marked unknown on the first write, in both copies" {
    for (both) |cached| {
        const d = try Disk.make("fat32-fsinfo", test_disk.small32, cached);
        defer d.deinit();
        // As a tool that kept them would leave them: set, and right.
        for ([_]usize{ 1, 7 }) |s| {
            std.mem.writeInt(u32, d.bytes[s * test_disk.sector + 488 ..][0..4], @intCast(d.free()), .little);
            std.mem.writeInt(u32, d.bytes[s * test_disk.sector + 492 ..][0..4], 3, .little);
        }
        try d.mount(cached);
        // Reading changes nothing.
        _ = d.vol.open("nothing") catch {};
        try testing.expectEqual(@as(u32, @intCast(d.free())), std.mem.readInt(u32, d.bytes[1 * test_disk.sector + 488 ..][0..4], .little));
        try d.vol.writeFile("x", "a write");
        for ([_]usize{ 1, 7 }) |s| {
            try testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, d.bytes[s * test_disk.sector + 488 ..][0..4], .little));
            try testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, d.bytes[s * test_disk.sector + 492 ..][0..4], .little));
        }
    }
}

test "FAT32: a volume this machine cannot write safely is refused at mount, each with its own error" {
    const bytes = try testing.allocator.alloc(u8, test_disk.small32.sectors * test_disk.sector);
    defer testing.allocator.free(bytes);
    var blk = virtio.Block.inMemory(bytes);
    var scratch: [test_disk.sector]u8 align(16) = undefined;
    const Case = struct { what: []const u8, offset: usize, value: u32, size: u8, want: fat16.Error };
    const cases = [_]Case{
        .{ .what = "mirroring off", .offset = 40, .value = 0x80, .size = 2, .want = fat16.Error.NotMirrored },
        .{ .what = "version 1", .offset = 42, .value = 1, .size = 2, .want = fat16.Error.FatVersion },
        .{ .what = "a root cluster past the volume", .offset = 44, .value = 0x0FFF_0000, .size = 4, .want = fat16.Error.BadRoot },
        .{ .what = "a root cluster of 1", .offset = 44, .value = 1, .size = 4, .want = fat16.Error.BadRoot },
        .{ .what = "a FAT16 root count on FAT32", .offset = 17, .value = 512, .size = 2, .want = fat16.Error.BadBootSector },
    };
    for (cases) |c| {
        test_disk.format(bytes, test_disk.small32);
        if (c.size == 2) std.mem.writeInt(u16, bytes[c.offset..][0..2], @intCast(c.value), .little) else std.mem.writeInt(u32, bytes[c.offset..][0..4], c.value, .little);
        testing.expectError(c.want, fat16.Volume.mount(&blk, &scratch, 0)) catch |e| {
            std.debug.print("refusing {s}\n", .{c.what});
            return e;
        };
    }
    // Past sector 2^32: the volume starts at sector 32 of the disk and says
    // it is nearly 2^32 sectors long.
    test_disk.format(bytes, test_disk.small32);
    @memcpy(bytes[32 * test_disk.sector ..][0..test_disk.sector], bytes[0..test_disk.sector]);
    std.mem.writeInt(u32, bytes[32 * test_disk.sector + 32 ..][0..4], 0xFFFF_FFF0, .little);
    try testing.expectError(fat16.Error.VolumeTooLarge, fat16.Volume.mount(&blk, &scratch, 32));
    // More clusters than FAT32's 28-bit numbers can name: their top numbers
    // are the bad-cluster and end-of-chain marks (QUEUE.md item 69). The
    // FAT is said to be big enough for them, so only the count refuses it.
    test_disk.format(bytes, test_disk.small32);
    std.mem.writeInt(u32, bytes[32..][0..4], 0xFFFF_FFF0, .little); // sectors in all
    std.mem.writeInt(u32, bytes[36..][0..4], 0x0200_0000, .little); // sectors per FAT
    try testing.expectError(fat16.Error.TooManyClusters, fat16.Volume.mount(&blk, &scratch, 0));
    // And the same volume, untouched, mounts.
    test_disk.format(bytes, test_disk.small32);
    const v = try fat16.Volume.mount(&blk, &scratch, 0);
    try testing.expectEqual(fat16.Kind.fat32, v.kind);
    try testing.expectEqual(@as(?u32, 0x3232_3232), v.serial);
}

test "FAT16: a boot sector this machine cannot trust is refused at mount, each with its own error" {
    const bytes = try testing.allocator.alloc(u8, test_disk.small.sectors * test_disk.sector);
    defer testing.allocator.free(bytes);
    var blk = virtio.Block.inMemory(bytes);
    var scratch: [test_disk.sector]u8 align(16) = undefined;
    // Where the data begins on the volume test_disk.small makes, from its
    // own fields, so a total just past it, or short of it, can be written.
    test_disk.format(bytes, test_disk.small);
    const reserved = std.mem.readInt(u16, bytes[14..16], .little);
    const per_fat = std.mem.readInt(u16, bytes[22..24], .little);
    const root_sectors = std.mem.readInt(u16, bytes[17..19], .little) * 32 / test_disk.sector;
    const data_start: u32 = reserved + @as(u32, bytes[16]) * per_fat + root_sectors;

    const Case = struct { what: []const u8, offset: usize, value: u32, size: u8, want: fat16.Error };
    const cases = [_]Case{
        .{ .what = "no 55 AA", .offset = 510, .value = 0, .size = 1, .want = fat16.Error.BadBootSector },
        .{ .what = "1,024-byte sectors", .offset = 11, .value = 1024, .size = 2, .want = fat16.Error.NotFat16 },
        .{ .what = "no sectors a cluster", .offset = 13, .value = 0, .size = 1, .want = fat16.Error.BadBootSector },
        .{ .what = "255 sectors a cluster", .offset = 13, .value = 255, .size = 1, .want = fat16.Error.BadBootSector },
        .{ .what = "no reserved sectors", .offset = 14, .value = 0, .size = 2, .want = fat16.Error.BadBootSector },
        .{ .what = "no FATs", .offset = 16, .value = 0, .size = 1, .want = fat16.Error.BadBootSector },
        .{ .what = "three FATs", .offset = 16, .value = 3, .size = 1, .want = fat16.Error.BadBootSector },
        .{ .what = "a FAT of no sectors", .offset = 22, .value = 0, .size = 2, .want = fat16.Error.BadBootSector },
        .{ .what = "no sectors at all", .offset = 19, .value = 0, .size = 2, .want = fat16.Error.BadBootSector },
        .{ .what = "a volume that ends before its data", .offset = 19, .value = data_start, .size = 2, .want = fat16.Error.BadBootSector },
        .{ .what = "too few clusters for FAT16 (FAT12)", .offset = 19, .value = data_start + 100, .size = 2, .want = fat16.Error.NotFat16 },
        .{ .what = "a FAT16 with no root entries", .offset = 17, .value = 0, .size = 2, .want = fat16.Error.BadBootSector },
    };
    for (cases) |c| {
        test_disk.format(bytes, test_disk.small);
        switch (c.size) {
            1 => bytes[c.offset] = @intCast(c.value),
            2 => std.mem.writeInt(u16, bytes[c.offset..][0..2], @intCast(c.value), .little),
            else => unreachable,
        }
        // The 32-bit total is 0 on this shape, so the 16-bit one is the size.
        testing.expectError(c.want, fat16.Volume.mount(&blk, &scratch, 0)) catch |e| {
            std.debug.print("refusing {s}\n", .{c.what});
            return e;
        };
    }
    // And the same volume, untouched, mounts.
    test_disk.format(bytes, test_disk.small);
    const v = try fat16.Volume.mount(&blk, &scratch, 0);
    try testing.expectEqual(fat16.Kind.fat16, v.kind);
}

test "a FAT is held only in a buffer that holds all of it, and a file past 4 GiB is refused before anything is written" {
    const d = try Disk.make("refused-sizes", small, false);
    defer d.deinit();
    const short = try testing.allocator.alloc(u8, d.vol.fatBytes() - 1);
    defer testing.allocator.free(short);
    try testing.expectError(fat16.Error.TooBig, d.vol.cacheFat(short));
    // A file of 4 GiB: FAT's size field is 32 bits. The size is checked
    // before a byte of it is read, so the slice need not be backed.
    const huge = @as([*]const u8, @ptrFromInt(0x1000))[0 .. 1 << 32];
    try testing.expectError(fat16.Error.TooBig, d.vol.writeFile("data/huge", huge));
    try testing.expectEqual(d.free(), d.vol.free_clusters);
}

// ---- the free-cluster cursor (FAT32.md §8) -----------------------------------

/// Every cluster below the cursor is in use, read from the FAT on the disk:
/// what makes a search from the cursor choose what a search from 2 would.
fn expectCursorSound(d: *test_disk.Disk) !void {
    const l = Layout.of(d.bytes);
    var c: usize = 2;
    while (c < d.vol.alloc_hint) : (c += 1) {
        if (l.get(d.bytes, 0, c) == 0) {
            std.debug.print("cluster {d} is free, below the cursor at {d}\n", .{ c, d.vol.alloc_hint });
            return error.TestUnexpectedResult;
        }
    }
}

test "the cursor: every cluster below it stays in use, through writes, removes, a refused write and a remount" {
    for (configs) |cfg| {
        const shape, const cached = .{ cfg.shape, cfg.cached };
        const d = try Disk.make("cursor", shape, cached);
        defer d.deinit();
        var data: [5000]u8 = undefined;
        var path: [64]u8 = undefined;
        for (0..30) |k| {
            const p = try std.fmt.bufPrint(&path, "data/f{d}", .{k});
            try d.vol.writeFile(p, pattern(data[0 .. 100 + 150 * k], @intCast(k)));
            try expectCursorSound(d);
        }
        // Holes, low and high: the cursor goes back to the lowest, and the
        // next write fills from there, as a search from 2 would.
        for ([_]usize{ 3, 17, 4, 25 }) |k| {
            const p = try std.fmt.bufPrint(&path, "data/f{d}", .{k});
            const first = (try d.vol.open(p)).first_cluster;
            try d.vol.remove(p);
            try testing.expect(d.vol.alloc_hint <= first);
            try expectCursorSound(d);
        }
        const lowest_free = blk: {
            const l = Layout.of(d.bytes);
            var c: usize = 2;
            while (l.get(d.bytes, 0, c) != 0) c += 1;
            break :blk c;
        };
        try d.vol.writeFile("data/new", "fills the first hole");
        try testing.expectEqual(@as(fat16.Cluster, @intCast(lowest_free)), (try d.vol.open("data/new")).first_cluster);
        try expectCursorSound(d);
        try d.vol.removeTree("data");
        try expectCursorSound(d);
        try d.mount(cached);
        try testing.expectEqual(@as(fat16.Cluster, 2), d.vol.alloc_hint);
        try d.vol.writeFile("after-a-mount", "x");
        try expectCursorSound(d);
    }
}

test "the cursor: on a FAT32 volume 33 MiB full, a small write reads a few FAT sectors, not 67,000" {
    // The FAT on the disk, so each entry looked at is a read the device
    // counts.
    const d = try Disk.make("cursor-cost", big32, false);
    defer d.deinit();
    const huge = try testing.allocator.alloc(u8, 33 << 20);
    defer testing.allocator.free(huge);
    @memset(huge, 7);
    try d.vol.writeFile("data/huge.bin", huge);
    const before = d.blk.requests;
    try d.vol.writeFile("data/small.md", "a small file after a big one");
    const reads = d.blk.requests - before;
    // A search from 2 would read a FAT sector for each of the 67,584
    // clusters in use. From the cursor it is the directory walk and a handful.
    try testing.expect(reads < 200);
    try d.expectFile("data/small.md", "a small file after a big one");
}

test "a lookup reads a directory in bursts and stops at the name, finding what the sector-at-a-time walk finds" {
    // 4 KB clusters, so a directory's cluster is many sectors; FAT16, so the
    // fixed root is a run of its own as well.
    const shape = Shape{ .sectors = 65536, .sectors_per_cluster = 8, .suffix = "-burst" };
    const d = try Disk.make("dir-burst", shape, true);
    defer d.deinit();
    // The bursts alone: the directory cache (`dirs`) would answer the
    // lookups after the first, and has a test of its own below.
    d.vol.dirs = null;
    const dir = try d.vol.makePath("chat/conversation/sessions");
    // Long names, three slots each: two clusters and part of a third.
    var name: [40]u8 = undefined;
    const files = 60;
    for (0..files) |k| {
        const n = try std.fmt.bufPrint(&name, "a-session-with-a-long-name-{d:0>4}", .{k});
        try d.vol.writeFileIn(dir, n, n);
    }
    var cluster_burst: [8 * fat16.sector_size]u8 = undefined;
    const bursts = [_]?[]u8{ null, d.vol.dir_burst, &cluster_burst };
    var cost: [bursts.len]u64 = undefined;
    for (bursts, 0..) |b, i| {
        d.vol.dir_burst = b;
        const before = d.blk.requests;
        for (0..files) |k| {
            const n = try std.fmt.bufPrint(&name, "a-session-with-a-long-name-{d:0>4}", .{k});
            const e = (try d.vol.find(dir, n)).?;
            try testing.expectEqualStrings(n, e.text());
        }
        try testing.expect((try d.vol.find(dir, "not-there")) == null);
        cost[i] = d.blk.requests - before;
    }
    // A cluster at a request is about an eighth of a sector at a request.
    try testing.expect(cost[2] * 4 < cost[0]);
    try testing.expect(cost[1] < cost[0]);
    // The first name is in the first sector: one request, however long the
    // directory.
    d.vol.dir_burst = null;
    const before = d.blk.requests;
    _ = (try d.vol.find(dir, "a-session-with-a-long-name-0000")).?;
    try testing.expectEqual(@as(u64, 1), d.blk.requests - before);
    // The volume keeps the burst it was given, for deinit's check.
    d.vol.dir_burst = &d.dir_burst;
}

test "folders held in memory: a lookup made before reads no sector, and a write keeps what is held the disk's" {
    const shape = Shape{ .sectors = 65536, .sectors_per_cluster = 8, .suffix = "-dirs" };
    const d = try Disk.make("dir-cache", shape, true);
    defer d.deinit();
    var keys: [4096]u32 = undefined;
    var data: [4096 * fat16.sector_size]u8 = undefined;
    d.vol.cacheDirs(&keys, &data);
    defer d.vol.cacheDirs(&d.dir_keys, &d.dir_data);
    const dir = try d.vol.makePath("chat/conversation/sessions");
    var name: [40]u8 = undefined;
    for (0..60) |k| {
        const n = try std.fmt.bufPrint(&name, "a-session-with-a-long-name-{d:0>4}", .{k});
        try d.vol.writeFileIn(dir, n, n);
    }
    // The first round reads the folders; the second finds them in memory.
    for (0..2) |round| {
        const before = d.blk.requests;
        for (0..60) |k| {
            const n = try std.fmt.bufPrint(&name, "a-session-with-a-long-name-{d:0>4}", .{k});
            const e = (try d.vol.find(dir, n)).?;
            try testing.expectEqualStrings(n, e.text());
        }
        if (round == 1) try testing.expectEqual(@as(u64, 0), d.blk.requests - before);
    }
    // A file added, one removed, one renamed: what the folder holds now is
    // found from memory as the disk has it.
    try d.vol.writeFileIn(dir, "a new one", "new");
    try d.vol.remove("chat/conversation/sessions/a-session-with-a-long-name-0007");
    try d.vol.rename("chat/conversation/sessions/a-session-with-a-long-name-0009", "chat/conversation/sessions/renamed");
    try testing.expect((try d.vol.find(dir, "a new one")) != null);
    try testing.expect((try d.vol.find(dir, "a-session-with-a-long-name-0007")) == null);
    try testing.expect((try d.vol.find(dir, "a-session-with-a-long-name-0009")) == null);
    try testing.expect((try d.vol.find(dir, "renamed")) != null);
    // And the uncached walk agrees, entry for entry.
    const held = d.vol.dirs;
    d.vol.dirs = null;
    try testing.expect((try d.vol.find(dir, "a new one")) != null);
    try testing.expect((try d.vol.find(dir, "a-session-with-a-long-name-0007")) == null);
    try testing.expect((try d.vol.find(dir, "renamed")) != null);
    d.vol.dirs = held;
}

// `remove` once took a directory's entry as it takes a file's, and left the
// directory's clusters and everything under it allocated, reachable from
// nothing (the cloud session's finding, item 77). It refuses one now, as
// Linux's unlink does (EISDIR; metal-vmm QUEUE B22), and the volume the
// refusal leaves checks clean on the way out (test_disk's deinit).
test "remove refuses a directory, and leaves the volume clean" {
    const d = try test_disk.Disk.make("remove-dir", test_disk.small, false);
    defer d.deinit();
    try d.vol.writeFile("data/dir/inside.txt", "under the directory");
    try testing.expectError(fat16.Error.IsDirectory, d.vol.remove("data/dir"));
}
