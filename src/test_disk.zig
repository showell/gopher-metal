//! A FAT16 or FAT32 disk in memory, for host tests: formatted here from Microsoft's
//! FAT specification (not by `fat16.zig`), served by `virtio.Block.inMemory`,
//! and checked by reading its bytes directly where a check can be. Shared by
//! `fat16_test.zig` and `io_test.zig`.

const std = @import("std");
const virtio = @import("virtio.zig");
const fat16 = @import("fat16.zig");

const testing = std.testing;
pub const sector = 512;

/// A volume's shape, as `format` writes it. The kind must be what the
/// cluster count makes it (the spec decides by count): FAT32 needs 65,525
/// clusters or more.
pub const Shape = struct {
    sectors: u32,
    sectors_per_cluster: u8 = 1,
    root_entries: u16 = 512,
    kind: fat16.Kind = .fat16,
    /// Added to a kept image's name, so the two kinds' images of one test
    /// do not overwrite each other.
    suffix: []const u8 = "",
};

/// Lays a fresh filesystem of `shape.kind` over all of `disk`.
pub fn format(disk: []u8, shape: Shape) void {
    switch (shape.kind) {
        .fat16 => format16(disk, shape),
        .fat32 => format32(disk, shape),
    }
}

/// FAT32, from the spec: 32 reserved sectors with FSInfo at 1 and the backup
/// boot sector at 6 (its FSInfo copy at 7); no fixed root, so the root is
/// cluster 2, a chain of one; two FATs of 4-byte entries, whose first three
/// are the media mark, an end mark, and the root's end. FSInfo's free count
/// and hint are "unknown", which the spec allows and Linux recomputes.
fn format32(disk: []u8, shape: Shape) void {
    @memset(disk, 0);
    const reserved: u32 = 32;
    const fat_sectors: u32 = ((shape.sectors / shape.sectors_per_cluster + 2) * 4 + sector - 1) / sector;
    const b = disk[0..sector];
    b[0] = 0xEB;
    b[1] = 0x58;
    b[2] = 0x90;
    @memcpy(b[3..11], "MSWIN4.1");
    std.mem.writeInt(u16, b[11..13], sector, .little);
    b[13] = shape.sectors_per_cluster;
    std.mem.writeInt(u16, b[14..16], @intCast(reserved), .little);
    b[16] = 2;
    // Root entries, the 16-bit total and the 16-bit FAT size are all 0.
    b[21] = 0xF8;
    std.mem.writeInt(u32, b[32..36], shape.sectors, .little);
    std.mem.writeInt(u32, b[36..40], fat_sectors, .little);
    std.mem.writeInt(u32, b[44..48], 2, .little); // the root's first cluster
    std.mem.writeInt(u16, b[48..50], 1, .little); // FSInfo
    std.mem.writeInt(u16, b[50..52], 6, .little); // the backup boot sector
    b[64] = 0x80;
    b[66] = 0x29;
    std.mem.writeInt(u32, b[67..71], 0x3232_3232, .little);
    @memcpy(b[71..82], "NO NAME    ");
    @memcpy(b[82..90], "FAT32   ");
    b[510] = 0x55;
    b[511] = 0xAA;

    const fsinfo = disk[sector..][0..sector];
    std.mem.writeInt(u32, fsinfo[0..4], 0x4161_5252, .little);
    std.mem.writeInt(u32, fsinfo[484..488], 0x6141_7272, .little);
    std.mem.writeInt(u32, fsinfo[488..492], 0xFFFF_FFFF, .little);
    std.mem.writeInt(u32, fsinfo[492..496], 0xFFFF_FFFF, .little);
    std.mem.writeInt(u32, fsinfo[508..512], 0xAA55_0000, .little);
    @memcpy(disk[6 * sector ..][0..sector], b);
    @memcpy(disk[7 * sector ..][0..sector], fsinfo);

    for (0..2) |copy| {
        const fat = disk[(reserved + copy * fat_sectors) * sector ..];
        std.mem.writeInt(u32, fat[0..4], 0x0FFF_FFF8, .little);
        std.mem.writeInt(u32, fat[4..8], 0x0FFF_FFFF, .little);
        std.mem.writeInt(u32, fat[8..12], 0x0FFF_FFFF, .little); // the root, one cluster
    }
}

/// FAT16: a BPB, two FATs whose first two entries are the media byte and an
/// end mark, and an empty root.
fn format16(disk: []u8, shape: Shape) void {
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
    @memcpy(b[43..54], "NO NAME    "); // the spec's label for none: the root holds no label entry
    @memcpy(b[54..62], "FAT16   ");
    b[510] = 0x55;
    b[511] = 0xAA;

    for (0..2) |copy| {
        const fat = disk[(reserved + copy * fat_sectors) * sector ..];
        std.mem.writeInt(u16, fat[0..2], 0xFFF8, .little);
        std.mem.writeInt(u16, fat[2..4], 0xFFFF, .little);
    }
}

/// What the BPB on a disk says, read from its bytes, and the FAT read and
/// written the same way: from the spec, not through fat16.zig.
pub const Layout = struct {
    fat_start: usize,
    fat_bytes: usize,
    clusters: usize,
    /// The sector cluster 2 starts at.
    data_sector: usize,
    kind: fat16.Kind,
    /// FAT32's root cluster; 0 on FAT16.
    root_cluster: u32,

    pub fn of(disk: []const u8) Layout {
        const reserved = std.mem.readInt(u16, disk[14..16], .little);
        var fat_sectors: u32 = std.mem.readInt(u16, disk[22..24], .little);
        if (fat_sectors == 0) fat_sectors = std.mem.readInt(u32, disk[36..40], .little);
        const root_entries = std.mem.readInt(u16, disk[17..19], .little);
        var total: u32 = std.mem.readInt(u16, disk[19..21], .little);
        if (total == 0) total = std.mem.readInt(u32, disk[32..36], .little);
        const data_start = reserved + 2 * fat_sectors + (@as(u32, root_entries) * 32 + sector - 1) / sector;
        const clusters = (total - data_start) / disk[13];
        const kind: fat16.Kind = if (clusters >= 65525) .fat32 else .fat16;
        return .{
            .fat_start = @as(usize, reserved) * sector,
            .fat_bytes = @as(usize, fat_sectors) * sector,
            .clusters = clusters,
            .data_sector = data_start,
            .kind = kind,
            .root_cluster = if (kind == .fat32) std.mem.readInt(u32, disk[44..48], .little) else 0,
        };
    }

    fn width(l: Layout) usize {
        return if (l.kind == .fat32) 4 else 2;
    }

    /// FAT entry `c` in copy `copy`: on FAT32 its low 28 bits.
    pub fn get(l: Layout, disk: []const u8, copy: usize, c: usize) u32 {
        const at = l.fat_start + copy * l.fat_bytes + c * l.width();
        return if (l.kind == .fat32)
            std.mem.readInt(u32, disk[at..][0..4], .little) & 0x0FFF_FFFF
        else
            std.mem.readInt(u16, disk[at..][0..2], .little);
    }

    /// Sets FAT entry `c` in copy `copy` to exactly `v`, all 32 bits on FAT32.
    pub fn set(l: Layout, disk: []u8, copy: usize, c: usize, v: u32) void {
        const at = l.fat_start + copy * l.fat_bytes + c * l.width();
        if (l.kind == .fat32)
            std.mem.writeInt(u32, disk[at..][0..4], v, .little)
        else
            std.mem.writeInt(u16, disk[at..][0..2], @intCast(v), .little);
    }

    /// What a chain's last entry is written as, and the bad-cluster mark.
    pub fn end(l: Layout) u32 {
        return if (l.kind == .fat32) 0x0FFF_FFFF else 0xFFFF;
    }
    pub fn bad(l: Layout) u32 {
        return if (l.kind == .fat32) 0x0FFF_FFF7 else 0xFFF7;
    }
    /// Whether `v` ends a chain.
    pub fn ends(l: Layout, v: u32) bool {
        return v >= (if (l.kind == .fat32) @as(u32, 0x0FFF_FFF8) else 0xFFF8);
    }
};

/// A disk in memory with a mounted volume on it.
pub const Disk = struct {
    /// What its buffers come from, and what `keep` writes through.
    gpa: std.mem.Allocator,
    io: std.Io,
    /// What the image is called when the tests are asked to keep their
    /// images (-Dfat16-images): "damaged-" first for the ones a test broke on
    /// purpose, which a checker must find fault with.
    label: []const u8,
    /// The shape's suffix, after the label in a kept image's name.
    suffix: []const u8 = "",
    /// Where `deinit` writes the image; empty: nowhere.
    images_dir: []const u8 = "",
    bytes: []u8,
    blk: virtio.Block,
    scratch: [sector]u8 align(16) = undefined,
    fat_cache: ?[]u8 = null,
    /// A cached disk also reads directories in bursts, as the host's do, of
    /// three sectors: an odd size, so a burst ends inside a cluster as often
    /// as at its end.
    dir_burst: [3 * fat16.sector_size]u8 = undefined,
    /// A cached disk holds directory sectors too (fat16's `dirs`), in few
    /// slots, an odd number: sectors replace each other often, as they would
    /// in a volume larger than the host's cache.
    dir_keys: [61]u32 = undefined,
    dir_data: [61 * fat16.sector_size]u8 = undefined,
    vol: fat16.Volume = undefined,
    /// FAT sectors the last mount's `cacheFatChecked` brought into line, and
    /// which copy it trusted.
    repaired: u32 = 0,
    trusted: u32 = 0,
    /// Room for the mount's check of each FAT copy, as gopher.zig gives it.
    check_room: ?[]u8 = null,

    /// Formats `shape` into a fresh disk and mounts it, holding its FAT in
    /// memory if `cached`. Heap-allocated: the volume points at the block and
    /// the scratch, which must not move.
    pub fn make(label: []const u8, shape: Shape, cached: bool) !*Disk {
        return makeIn(testing.allocator, testing.io, label, shape, cached);
    }

    /// `make`, with the allocator and the `Io` a simulator run as a program
    /// is given (metal-vmm QUEUE 106): `std.testing`'s exist only in a test.
    pub fn makeIn(gpa: std.mem.Allocator, io: std.Io, label: []const u8, shape: Shape, cached: bool) !*Disk {
        const d = try gpa.create(Disk);
        errdefer gpa.destroy(d);
        const bytes = try gpa.alloc(u8, @as(usize, shape.sectors) * sector);
        format(bytes, shape);
        d.* = .{ .gpa = gpa, .io = io, .label = label, .suffix = shape.suffix, .bytes = bytes, .blk = virtio.Block.inMemory(bytes) };
        try d.mount(cached);
        return d;
    }

    pub fn mount(d: *Disk, cached: bool) !void {
        d.vol = try fat16.Volume.mount(&d.blk, &d.scratch, 0);
        if (d.fat_cache) |c| d.gpa.free(c);
        d.fat_cache = null;
        if (d.check_room) |r| d.gpa.free(r);
        d.check_room = null;
        if (cached) {
            d.fat_cache = try d.gpa.alloc(u8, d.vol.fatBytes());
            if (d.check_room) |r| d.gpa.free(r);
            d.check_room = try d.gpa.alloc(u8, d.vol.checkBytes());
            const m = try d.vol.cacheFatChecked(d.fat_cache.?, d.check_room.?);
            d.repaired = m.repaired;
            d.trusted = m.trusted;
            d.vol.dir_burst = &d.dir_burst;
            d.vol.cacheDirs(&d.dir_keys, &d.dir_data);
        }
    }

    pub fn deinit(d: *Disk) void {
        // **EVERY DISK A TEST LEFT HEALTHY MUST CHECK CLEAN**, so each test
        // here is also a test of `Volume.check`, and of the volume. Not one a
        // test damaged ("damaged-"), nor one built to reach a limit of the
        // check ("limit-"), nor one that stops answering (fail_after).
        const tested = std.mem.startsWith(u8, d.label, "damaged-") or std.mem.startsWith(u8, d.label, "limit-");
        if (!tested and d.blk.fail_after == null) {
            const r = d.check() catch |e| std.debug.panic("{s}: the check failed: {s}", .{ d.label, @errorName(e) });
            const kept = d.vol.free_clusters;
            if (kept != d.free()) std.debug.panic("{s}: the kept free count is {d}, and the FAT on the disk has {d} free", .{ d.label, kept, d.free() });
            if (!r.health.clean()) std.debug.panic("{s}: left healthy, and the check found {d} problems, the first {s} at {s}", .{ d.label, r.health.problems, @tagName(r.found[0].problem), r.found[0].text() });
        }
        if (d.images_dir.len > 0) d.keep() catch |e| std.debug.panic("writing {s}: {s}", .{ d.label, @errorName(e) });
        if (d.fat_cache) |c| d.gpa.free(c);
        if (d.check_room) |r| d.gpa.free(r);
        d.gpa.free(d.bytes);
        d.gpa.destroy(d);
    }

    /// Writes the image to `images_dir`, named by its label and whether its
    /// FAT was held in memory.
    pub fn keep(d: *Disk) !void {
        const io = d.io;
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, d.images_dir, .{});
        defer dir.close(io);
        var name: [128]u8 = undefined;
        const held = if (d.fat_cache != null) "held" else "disk";
        const file = try std.fmt.bufPrint(&name, "{s}{s}-{s}.img", .{ d.label, d.suffix, held });
        try dir.writeFile(io, .{ .sub_path = file, .data = d.bytes });
        // Beside it, the volume's kept free count, for tools/fat16_read.py to
        // count against (tools/check_fat16_images.sh).
        var count: [16]u8 = undefined;
        const free_name = try std.fmt.bufPrint(&name, "{s}{s}-{s}.free", .{ d.label, d.suffix, held });
        try dir.writeFile(io, .{ .sub_path = free_name, .data = try std.fmt.bufPrint(&count, "{d}\n", .{d.vol.free_clusters}) });
    }

    /// The volume's kept free count (`free_clusters`) equals a fresh count of
    /// the FAT on the disk, made here from the spec, and fat16.zig's own.
    pub fn expectKept(d: *Disk) !void {
        try testing.expectEqual(d.free(), d.vol.free_clusters);
        try testing.expectEqual(@as(u32, @intCast(d.free())), try d.vol.countFreeAgain());
    }

    /// Free clusters, counted in the first FAT as it sits on the disk.
    pub fn free(d: *const Disk) usize {
        const l = Layout.of(d.bytes);
        var n: usize = 0;
        for (2..l.clusters + 2) |c| {
            if (l.get(d.bytes, 0, c) == 0) n += 1;
        }
        return n;
    }

    /// Both FAT copies on the disk, byte for byte the same.
    pub fn fatsAgree(d: *const Disk) bool {
        const l = Layout.of(d.bytes);
        return std.mem.eql(u8, d.bytes[l.fat_start..][0..l.fat_bytes], d.bytes[l.fat_start + l.fat_bytes ..][0..l.fat_bytes]);
    }

    /// `Volume.check`, with what it found kept, and **THE DISK UNCHANGED BY
    /// IT**, byte for byte: the check reports and never repairs.
    ///
    /// Unchanged is proven by the disk's count of writes, not by a copy of
    /// it: the volume reaches the disk only through `blk`, and a copy of a
    /// 35 MB FAT32 disk on every check was most of the time of the test that
    /// checks after every stop (QUEUE.md item 79).
    pub fn check(d: *Disk) !Report {
        const writes = d.blk.writes;
        const seen = try d.gpa.alloc(u8, d.vol.checkBytes());
        defer d.gpa.free(seen);
        var r = Report{};
        r.health = try d.vol.check(seen, &r, Report.each);
        try testing.expectEqual(r.health.problems, r.len);
        try testing.expectEqual(writes, d.blk.writes);
        return r;
    }

    /// The whole file at `path`, read through the volume.
    pub fn read(d: *Disk, path: []const u8) ![]u8 {
        const e = try d.vol.open(path);
        const out = try d.gpa.alloc(u8, e.size);
        errdefer d.gpa.free(out);
        const n = try d.vol.readFile(e, out);
        try testing.expectEqual(@as(usize, e.size), n);
        return out;
    }

    pub fn expectFile(d: *Disk, path: []const u8, want: []const u8) !void {
        const got = try d.read(path);
        defer d.gpa.free(got);
        try testing.expectEqualSlices(u8, want, got);
    }

    /// The names in a directory, joined by spaces, "." and ".." left out.
    pub fn names(d: *Disk, dir_cluster: fat16.Cluster, buf: []u8) ![]const u8 {
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

/// What `Volume.check` found, each finding with its path copied.
pub const Report = struct {
    pub const Found = struct {
        problem: fat16.Problem,
        path: [256]u8 = undefined,
        path_len: usize = 0,
        cluster: fat16.Cluster,
        count: u32,

        pub fn text(f: *const Found) []const u8 {
            return f.path[0..f.path_len];
        }
    };

    found: [16]Found = undefined,
    len: usize = 0,
    health: fat16.Health = .{},

    pub fn each(r: *Report, f: fat16.Finding) void {
        if (r.len == r.found.len) return;
        var k = Found{ .problem = f.problem, .cluster = f.cluster, .count = f.count };
        k.path_len = @min(f.path.len, k.path.len);
        @memcpy(k.path[0..k.path_len], f.path[0..k.path_len]);
        r.found[r.len] = k;
        r.len += 1;
    }

    /// One finding, as a test expects it.
    pub const Want = struct { problem: fat16.Problem, path: []const u8 = "", cluster: fat16.Cluster, count: u32 = 0 };

    /// Exactly these findings, in this order.
    pub fn expect(r: *const Report, want: []const Want) !void {
        errdefer for (r.found[0..r.len]) |f| std.debug.print("  found {s} at '{s}', cluster {d}, count {d}\n", .{ @tagName(f.problem), f.text(), f.cluster, f.count });
        try testing.expectEqual(want.len, r.len);
        for (want, r.found[0..r.len]) |w, f| {
            try testing.expectEqual(w.problem, f.problem);
            try testing.expectEqualStrings(w.path, f.text());
            try testing.expectEqual(w.cluster, f.cluster);
            try testing.expectEqual(w.count, f.count);
        }
    }
};

/// The smallest FAT32 there is, near enough: 68,874 clusters of 512 bytes
/// (FAT32 needs 65,525), about 34 MiB.
pub const small32 = Shape{ .sectors = 70_000, .kind = .fat32, .suffix = "-fat32" };

/// 4 MiB of 512-byte clusters: about 8,000 clusters, well inside FAT16.
pub const small = Shape{ .sectors = 8192 };

/// **A WRITE CACHE FOR A DISK IN MEMORY** (metal-vmm QUEUE 112): what a
/// disk with a cache does, which no other disk in the host tests does. A
/// write lands in the disk's bytes, which is what it shows until the power
/// goes, and waits here; a flush makes every waiting write durable. A cut
/// keeps what was durable and whichever waiting writes the test chooses,
/// since a cache writes back in no order it promises.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    /// What survives a cut: the disk as of its last flush.
    kept: []u8,
    waiting: std.ArrayList(Write) = .empty,
    hook: virtio.Block.Cache = undefined,

    pub const Write = struct { lba: u64, bytes: []u8 };

    /// A cache in front of `d`, from its bytes now: everything on it so far
    /// is durable. Heap-allocated, as the block points at it.
    pub fn attach(d: *Disk) !*Cache {
        const c = try d.gpa.create(Cache);
        errdefer d.gpa.destroy(c);
        c.* = .{ .gpa = d.gpa, .kept = try d.gpa.dupe(u8, d.bytes) };
        c.hook = .{ .context = c, .wrote = wrote, .flushed = flushed };
        d.blk.cache = &c.hook;
        return c;
    }

    /// The disk writes through again; what waits is dropped.
    pub fn detach(c: *Cache, d: *Disk) void {
        d.blk.cache = null;
        c.drop();
        c.waiting.deinit(c.gpa);
        c.gpa.free(c.kept);
        c.gpa.destroy(c);
    }

    fn drop(c: *Cache) void {
        for (c.waiting.items) |w| c.gpa.free(w.bytes);
        c.waiting.clearRetainingCapacity();
    }

    fn wrote(context: *anyopaque, lba: u64, bytes: []const u8) void {
        const c: *Cache = @ptrCast(@alignCast(context));
        const copy = c.gpa.dupe(u8, bytes) catch @panic("test_disk.Cache: out of memory");
        c.waiting.append(c.gpa, .{ .lba = lba, .bytes = copy }) catch @panic("test_disk.Cache: out of memory");
    }

    fn flushed(context: *anyopaque) void {
        const c: *Cache = @ptrCast(@alignCast(context));
        for (c.waiting.items) |w| @memcpy(c.kept[@intCast(w.lba * sector)..][0..w.bytes.len], w.bytes);
        c.drop();
    }

    /// Writes waiting for a flush.
    pub fn pending(c: *const Cache) usize {
        return c.waiting.items.len;
    }

    /// **THE POWER GOES**: the disk becomes what was durable, and each
    /// waiting write lands too, in the order written, where `keep` says
    /// so. A write that lands is whole: a torn sector is the block's
    /// `Fault.torn`, not the cache's.
    pub fn cut(c: *Cache, d: *Disk, context: anytype, comptime keep: fn (@TypeOf(context), usize) bool) void {
        for (c.waiting.items, 0..) |w, i| {
            if (keep(context, i)) @memcpy(c.kept[@intCast(w.lba * sector)..][0..w.bytes.len], w.bytes);
        }
        c.drop();
        @memcpy(d.bytes, c.kept);
    }
};

test "a write cache: a flush keeps, a cut drops what waits, and keeps what it is told" {
    const d = try Disk.make("damaged-cache", small, false);
    defer d.deinit();
    const c = try Cache.attach(d);
    defer c.detach(d);
    var one: [sector]u8 align(16) = @splat(1);
    var two: [sector]u8 align(16) = @splat(2);
    const at = d.bytes.len / sector - 2;
    try testing.expectEqual(virtio.blk_s_ok, d.blk.write(at, @intFromPtr(&one)));
    try testing.expectEqual(virtio.blk_s_ok, d.blk.flush());
    try testing.expectEqual(@as(usize, 0), c.pending());
    try testing.expectEqual(virtio.blk_s_ok, d.blk.write(at, @intFromPtr(&two)));
    try testing.expectEqual(virtio.blk_s_ok, d.blk.write(at + 1, @intFromPtr(&two)));
    try testing.expectEqual(@as(u8, 2), d.bytes[at * sector]);
    const Every = struct {
        fn second(_: void, i: usize) bool {
            return i == 1;
        }
    };
    c.cut(d, {}, Every.second);
    try testing.expectEqual(@as(u8, 1), d.bytes[at * sector]);
    try testing.expectEqual(@as(u8, 2), d.bytes[(at + 1) * sector]);
    // A flush once the power is gone keeps nothing.
    try testing.expectEqual(virtio.blk_s_ok, d.blk.write(at, @intFromPtr(&two)));
    d.blk.fail_after = d.blk.requests;
    try testing.expectEqual(virtio.blk_s_ioerr, d.blk.flush());
    d.blk.fail_after = null;
    c.cut(d, {}, struct {
        fn none(_: void, _: usize) bool {
            return false;
        }
    }.none);
    try testing.expectEqual(@as(u8, 1), d.bytes[at * sector]);
}
