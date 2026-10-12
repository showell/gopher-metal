//! `disk_fat.zig`'s FAT32 cases on a disk in memory, and its free-cluster
//! cursor (FAT32.md; split from disk_fat_test.zig by metal-vmm QUEUE 173).

const std = @import("std");
const disk_fat = @import("disk_fat.zig");
const virtio = @import("virtio.zig");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Shape = test_disk.Shape;
const Layout = test_disk.Layout;
const small = test_disk.small;
const disk_fat_test = @import("disk_fat_test.zig");
const chainOf = disk_fat_test.chainOf;
const pattern = disk_fat_test.pattern;
const configs = disk_fat_test.configs;
const Disk = disk_fat_test.Disk;
const both = disk_fat_test.both;

// ---- FAT32's own cases (QUEUE item 17, FAT32.md "Judged against Linux") ------

/// A FAT32 volume big enough for files past cluster 65,535: about 44 MiB.
const big32 = Shape{ .sectors = 90_000, .kind = .fat32, .suffix = "-fat32" };

test "FAT32: files that start past cluster 65,535 are found by both halves of their cluster, and read back" {
    for (both) |cached| {
        const d = try Disk.make("fat32-high", big32, cached);
        defer d.deinit();
        try testing.expectEqual(disk_fat.Kind.fat32, d.vol.kind);
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
        var chain: [64]disk_fat.Cluster = undefined;
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
        var chain: [8]disk_fat.Cluster = undefined;
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
    const Case = struct { what: []const u8, offset: usize, value: u32, size: u8, want: disk_fat.Error };
    const cases = [_]Case{
        .{ .what = "mirroring off", .offset = 40, .value = 0x80, .size = 2, .want = disk_fat.Error.NotMirrored },
        .{ .what = "version 1", .offset = 42, .value = 1, .size = 2, .want = disk_fat.Error.FatVersion },
        .{ .what = "a root cluster past the volume", .offset = 44, .value = 0x0FFF_0000, .size = 4, .want = disk_fat.Error.BadRoot },
        .{ .what = "a root cluster of 1", .offset = 44, .value = 1, .size = 4, .want = disk_fat.Error.BadRoot },
        .{ .what = "a FAT16 root count on FAT32", .offset = 17, .value = 512, .size = 2, .want = disk_fat.Error.BadBootSector },
    };
    for (cases) |c| {
        test_disk.format(bytes, test_disk.small32);
        if (c.size == 2) std.mem.writeInt(u16, bytes[c.offset..][0..2], @intCast(c.value), .little) else std.mem.writeInt(u32, bytes[c.offset..][0..4], c.value, .little);
        testing.expectError(c.want, disk_fat.Volume.mount(&blk, &scratch, 0)) catch |e| {
            std.debug.print("refusing {s}\n", .{c.what});
            return e;
        };
    }
    // Past sector 2^32: the volume starts at sector 32 of the disk and says
    // it is nearly 2^32 sectors long.
    test_disk.format(bytes, test_disk.small32);
    @memcpy(bytes[32 * test_disk.sector ..][0..test_disk.sector], bytes[0..test_disk.sector]);
    std.mem.writeInt(u32, bytes[32 * test_disk.sector + 32 ..][0..4], 0xFFFF_FFF0, .little);
    try testing.expectError(disk_fat.Error.VolumeTooLarge, disk_fat.Volume.mount(&blk, &scratch, 32));
    // More clusters than FAT32's 28-bit numbers can name: their top numbers
    // are the bad-cluster and end-of-chain marks (QUEUE.md item 69). The
    // FAT is said to be big enough for them, so only the count refuses it.
    test_disk.format(bytes, test_disk.small32);
    std.mem.writeInt(u32, bytes[32..][0..4], 0xFFFF_FFF0, .little); // sectors in all
    std.mem.writeInt(u32, bytes[36..][0..4], 0x0200_0000, .little); // sectors per FAT
    try testing.expectError(disk_fat.Error.TooManyClusters, disk_fat.Volume.mount(&blk, &scratch, 0));
    // And the same volume, untouched, mounts.
    test_disk.format(bytes, test_disk.small32);
    const v = try disk_fat.Volume.mount(&blk, &scratch, 0);
    try testing.expectEqual(disk_fat.Kind.fat32, v.kind);
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

    const Case = struct { what: []const u8, offset: usize, value: u32, size: u8, want: disk_fat.Error };
    const cases = [_]Case{
        .{ .what = "no 55 AA", .offset = 510, .value = 0, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "1,024-byte sectors", .offset = 11, .value = 1024, .size = 2, .want = disk_fat.Error.NotFat16 },
        .{ .what = "no sectors a cluster", .offset = 13, .value = 0, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "255 sectors a cluster", .offset = 13, .value = 255, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "no reserved sectors", .offset = 14, .value = 0, .size = 2, .want = disk_fat.Error.BadBootSector },
        .{ .what = "no FATs", .offset = 16, .value = 0, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "three FATs", .offset = 16, .value = 3, .size = 1, .want = disk_fat.Error.BadBootSector },
        .{ .what = "a FAT of no sectors", .offset = 22, .value = 0, .size = 2, .want = disk_fat.Error.BadBootSector },
        .{ .what = "no sectors at all", .offset = 19, .value = 0, .size = 2, .want = disk_fat.Error.BadBootSector },
        .{ .what = "a volume that ends before its data", .offset = 19, .value = data_start, .size = 2, .want = disk_fat.Error.BadBootSector },
        .{ .what = "too few clusters for FAT16 (FAT12)", .offset = 19, .value = data_start + 100, .size = 2, .want = disk_fat.Error.NotFat16 },
        .{ .what = "a FAT16 with no root entries", .offset = 17, .value = 0, .size = 2, .want = disk_fat.Error.BadBootSector },
    };
    for (cases) |c| {
        test_disk.format(bytes, test_disk.small);
        switch (c.size) {
            1 => bytes[c.offset] = @intCast(c.value),
            2 => std.mem.writeInt(u16, bytes[c.offset..][0..2], @intCast(c.value), .little),
            else => unreachable,
        }
        // The 32-bit total is 0 on this shape, so the 16-bit one is the size.
        testing.expectError(c.want, disk_fat.Volume.mount(&blk, &scratch, 0)) catch |e| {
            std.debug.print("refusing {s}\n", .{c.what});
            return e;
        };
    }
    // And the same volume, untouched, mounts.
    test_disk.format(bytes, test_disk.small);
    const v = try disk_fat.Volume.mount(&blk, &scratch, 0);
    try testing.expectEqual(disk_fat.Kind.fat16, v.kind);
}

test "a FAT is held only in a buffer that holds all of it, and a file past 4 GiB is refused before anything is written" {
    const d = try Disk.make("refused-sizes", small, false);
    defer d.deinit();
    const short = try testing.allocator.alloc(u8, d.vol.fatBytes() - 1);
    defer testing.allocator.free(short);
    try testing.expectError(disk_fat.Error.TooBig, d.vol.cacheFat(short));
    // A file of 4 GiB: FAT's size field is 32 bits. The size is checked
    // before a byte of it is read, so the slice need not be backed.
    const huge = @as([*]const u8, @ptrFromInt(0x1000))[0 .. 1 << 32];
    try testing.expectError(disk_fat.Error.TooBig, d.vol.writeFile("data/huge", huge));
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
        try testing.expectEqual(@as(disk_fat.Cluster, @intCast(lowest_free)), (try d.vol.open("data/new")).first_cluster);
        try expectCursorSound(d);
        try d.vol.removeTree("data");
        try expectCursorSound(d);
        try d.mount(cached);
        try testing.expectEqual(@as(disk_fat.Cluster, 2), d.vol.alloc_hint);
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
    var cluster_burst: [8 * disk_fat.sector_size]u8 = undefined;
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
    var data: [4096 * disk_fat.sector_size]u8 = undefined;
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
    try testing.expectError(disk_fat.Error.IsDirectory, d.vol.remove("data/dir"));
}

test "a remove, and a tree's, that answers success left nothing behind: a read that lies on the second walk is an error (metal-vmm QUEUE 172)" {
    // Each request a remove makes after its lookup, read back as other bytes
    // (the first a zero: "nothing further in this directory").
    var n: u64 = 0;
    while (n < 40) : (n += 1) {
        inline for (.{ "data/X.DAT", "data/sub" }) |path| {
            // Lied to on purpose: a leak is allowed ("limit-"), a false "done" is not.
            const d = try test_disk.Disk.make("limit-remove-lies", test_disk.small, false);
            defer d.deinit();
            try d.vol.writeFile("data/X.DAT", "a file to remove");
            try d.vol.writeFile("data/sub/inner.txt", "a tree to remove");
            // Past the lookup that finds it (a lie there is absence, which
            // removeTree calls done, and remove refuses): the walk after.
            const before_lookup = d.blk.requests;
            _ = try d.vol.open(path);
            const lookup = d.blk.requests - before_lookup;
            d.blk.fault = .{ .at = d.blk.requests + lookup + n, .kind = .garbage, .seed = 0 };
            const removed = if (comptime std.mem.eql(u8, path, "data/X.DAT")) d.vol.remove(path) else d.vol.removeTree(path);
            d.blk.fault = null;
            if (removed) |_| {
                // Said done: the next boot finds it gone.
                try d.mount(false);
                if (d.vol.open(path)) |_| {
                    std.debug.print("{s}: request {d} read as other bytes, and the remove said done\n", .{ path, n });
                    return error.TestUnexpectedResult;
                } else |e| try testing.expectEqual(disk_fat.Error.NotFound, e);
            } else |_| {}
        }
    }
}
