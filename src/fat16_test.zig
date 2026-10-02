//! `fat16.zig` on a disk in memory (`virtio.Block.inMemory`): mount, write,
//! read back, append, remove, fill the disk, and damage it on purpose, all
//! on the host.
//!
//! **THE VOLUMES ARE MADE HERE, FROM THE SPEC**, not by `fat16.zig`
//! (Microsoft's FAT specification: the BPB, two FATs, a fixed root). And the
//! checks read the disk's bytes directly where they can: the free clusters
//! are counted in the FAT as it sits on the disk, and the two FAT copies are
//! compared byte for byte. So a test does not ask `fat16.zig` to vouch for
//! itself.
//!
//! An independent reader of the images, written from the spec in Python, is
//! QUEUE.md item 4; the images these tests make are what it reads.

const std = @import("std");
const virtio = @import("virtio.zig");
const fat16 = @import("fat16.zig");

const testing = std.testing;
const sector = 512;

/// A FAT16 volume's shape, as `format` writes it.
const Shape = struct {
    sectors: u32,
    sectors_per_cluster: u8 = 1,
    root_entries: u16 = 512,
};

/// Lays a fresh FAT16 filesystem over all of `disk`: a BPB, two FATs whose
/// first two entries are the media byte and an end mark, and an empty root.
fn format(disk: []u8, shape: Shape) void {
    @memset(disk, 0);
    const reserved: u32 = 1;
    // A FAT large enough for every cluster the data region could hold, and a
    // little more: the spec allows a FAT longer than its clusters need.
    const fat_sectors: u32 = ((shape.sectors / shape.sectors_per_cluster + 2) * 2 + sector - 1) / sector;

    const b = disk[0..sector];
    b[0] = 0xEB;
    b[1] = 0x3C;
    b[2] = 0x90;
    @memcpy(b[3..11], "MSWIN4.1");
    std.mem.writeInt(u16, b[11..13], sector, .little);
    b[13] = shape.sectors_per_cluster;
    std.mem.writeInt(u16, b[14..16], @intCast(reserved), .little);
    b[16] = 2;
    std.mem.writeInt(u16, b[17..19], shape.root_entries, .little);
    if (shape.sectors < 0x10000) {
        std.mem.writeInt(u16, b[19..21], @intCast(shape.sectors), .little);
    } else {
        std.mem.writeInt(u32, b[32..36], shape.sectors, .little);
    }
    b[21] = 0xF8;
    std.mem.writeInt(u16, b[22..24], @intCast(fat_sectors), .little);
    b[38] = 0x29;
    @memcpy(b[43..54], "GOPHER     ");
    @memcpy(b[54..62], "FAT16   ");
    b[510] = 0x55;
    b[511] = 0xAA;

    for (0..2) |copy| {
        const fat = disk[(reserved + copy * fat_sectors) * sector ..];
        std.mem.writeInt(u16, fat[0..2], 0xFFF8, .little);
        std.mem.writeInt(u16, fat[2..4], 0xFFFF, .little);
    }
}

/// What the BPB on a disk says, read from its bytes.
const Layout = struct {
    fat_start: usize,
    fat_bytes: usize,
    clusters: usize,

    fn of(disk: []const u8) Layout {
        const reserved = std.mem.readInt(u16, disk[14..16], .little);
        const fat_sectors = std.mem.readInt(u16, disk[22..24], .little);
        const root_entries = std.mem.readInt(u16, disk[17..19], .little);
        var total: u32 = std.mem.readInt(u16, disk[19..21], .little);
        if (total == 0) total = std.mem.readInt(u32, disk[32..36], .little);
        const data_start = reserved + 2 * fat_sectors + (root_entries * 32 + sector - 1) / sector;
        return .{
            .fat_start = @as(usize, reserved) * sector,
            .fat_bytes = @as(usize, fat_sectors) * sector,
            .clusters = (total - data_start) / disk[13],
        };
    }
};

/// A disk in memory with a mounted volume on it.
const Disk = struct {
    bytes: []u8,
    blk: virtio.Block,
    scratch: [sector]u8 align(16) = undefined,
    fat_cache: ?[]u8 = null,
    vol: fat16.Volume = undefined,

    /// Formats `shape` into a fresh disk and mounts it, holding its FAT in
    /// memory if `cached`. Heap-allocated: the volume points at the block and
    /// the scratch, which must not move.
    fn make(shape: Shape, cached: bool) !*Disk {
        const d = try testing.allocator.create(Disk);
        errdefer testing.allocator.destroy(d);
        const bytes = try testing.allocator.alloc(u8, @as(usize, shape.sectors) * sector);
        format(bytes, shape);
        d.* = .{ .bytes = bytes, .blk = virtio.Block.inMemory(bytes) };
        try d.mount(cached);
        return d;
    }

    fn mount(d: *Disk, cached: bool) !void {
        d.vol = try fat16.Volume.mount(&d.blk, &d.scratch, 0);
        if (d.fat_cache) |c| testing.allocator.free(c);
        d.fat_cache = null;
        if (cached) {
            d.fat_cache = try testing.allocator.alloc(u8, d.vol.fatBytes());
            try d.vol.cacheFat(d.fat_cache.?);
        }
    }

    fn deinit(d: *Disk) void {
        if (d.fat_cache) |c| testing.allocator.free(c);
        testing.allocator.free(d.bytes);
        testing.allocator.destroy(d);
    }

    /// Free clusters, counted in the first FAT as it sits on the disk.
    fn free(d: *const Disk) usize {
        const l = Layout.of(d.bytes);
        var n: usize = 0;
        for (2..l.clusters + 2) |c| {
            if (std.mem.readInt(u16, d.bytes[l.fat_start + c * 2 ..][0..2], .little) == 0) n += 1;
        }
        return n;
    }

    /// Both FAT copies on the disk, byte for byte the same.
    fn fatsAgree(d: *const Disk) bool {
        const l = Layout.of(d.bytes);
        return std.mem.eql(u8, d.bytes[l.fat_start..][0..l.fat_bytes], d.bytes[l.fat_start + l.fat_bytes ..][0..l.fat_bytes]);
    }

    /// The whole file at `path`, read through the volume.
    fn read(d: *Disk, path: []const u8) ![]u8 {
        const e = try d.vol.open(path);
        const out = try testing.allocator.alloc(u8, e.size);
        errdefer testing.allocator.free(out);
        const n = try d.vol.readFile(e, out);
        try testing.expectEqual(@as(usize, e.size), n);
        return out;
    }

    fn expectFile(d: *Disk, path: []const u8, want: []const u8) !void {
        const got = try d.read(path);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, want, got);
    }

    /// The names in a directory, joined by spaces, "." and ".." left out.
    fn names(d: *Disk, dir_cluster: u16, buf: []u8) ![]const u8 {
        const Collect = struct {
            buf: []u8,
            len: usize = 0,
            fn each(s: *@This(), e: fat16.Entry) void {
                const t = e.text();
                if (std.mem.eql(u8, t, ".") or std.mem.eql(u8, t, "..")) return;
                if (s.len > 0) {
                    s.buf[s.len] = ' ';
                    s.len += 1;
                }
                @memcpy(s.buf[s.len..][0..t.len], t);
                s.len += t.len;
            }
        };
        var c = Collect{ .buf = buf };
        try d.vol.list(dir_cluster, &c, Collect.each);
        return buf[0..c.len];
    }
};

/// 4 MiB of 512-byte clusters: about 8,000 clusters, well inside FAT16.
const small = Shape{ .sectors = 8192 };

fn pattern(buf: []u8, seed: u8) []u8 {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
    return buf;
}

// Every test runs with the FAT on the disk and with it held in memory: the
// two paths through `fatGet` and `fatSet` must agree.
const both = [_]bool{ false, true };

test "a volume formatted from the spec mounts, and its root is empty" {
    for (both) |cached| {
        const d = try Disk.make(small, cached);
        defer d.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("", try d.names(0, &buf));
        try testing.expect(d.free() > 4085);
    }
}

test "a file is read back exactly, at every size around a sector and a cluster" {
    for (both) |cached| {
        const d = try Disk.make(small, cached);
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
        const d = try Disk.make(small, cached);
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
    const d = try Disk.make(small, true);
    defer d.deinit();
    const long = "a" ** (fat16.max_name + 1);
    try testing.expectError(fat16.Error.BadName, d.vol.writeFile(long, "x"));
}

test "a replaced file gives back what it held" {
    for (both) |cached| {
        const d = try Disk.make(small, cached);
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
        const d = try Disk.make(small, cached);
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
        const d = try Disk.make(small, cached);
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
        const d = try Disk.make(small, cached);
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
        const d = try Disk.make(.{ .sectors = 4085 + 1 + 2 * 17 + 32 }, cached);
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
        const d = try Disk.make(small, cached);
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
    const d = try Disk.make(small, false);
    defer d.deinit();
    try d.vol.writeFile("data/x", "before");
    d.blk.fail_after = d.blk.requests;
    try testing.expectError(fat16.Error.ReadFailed, d.vol.open("data/x"));
    try testing.expect(std.meta.isError(d.vol.writeFile("data/y", "after")));
}
