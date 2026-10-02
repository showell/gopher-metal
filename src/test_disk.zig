//! A FAT16 disk in memory, for host tests: formatted here from Microsoft's
//! FAT specification (not by `fat16.zig`), served by `virtio.Block.inMemory`,
//! and checked by reading its bytes directly where a check can be. Shared by
//! `fat16_test.zig` and `io_test.zig`.

const std = @import("std");
const virtio = @import("virtio.zig");
const fat16 = @import("fat16.zig");

const testing = std.testing;
pub const sector = 512;

/// A FAT16 volume's shape, as `format` writes it.
pub const Shape = struct {
    sectors: u32,
    sectors_per_cluster: u8 = 1,
    root_entries: u16 = 512,
};

/// Lays a fresh FAT16 filesystem over all of `disk`: a BPB, two FATs whose
/// first two entries are the media byte and an end mark, and an empty root.
pub fn format(disk: []u8, shape: Shape) void {
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

/// What the BPB on a disk says, read from its bytes.
pub const Layout = struct {
    fat_start: usize,
    fat_bytes: usize,
    clusters: usize,

    pub fn of(disk: []const u8) Layout {
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
pub const Disk = struct {
    /// What the image is called when the tests are asked to keep their
    /// images (-Dfat16-images): "damaged-" first for the ones a test broke on
    /// purpose, which a checker must find fault with.
    label: []const u8,
    /// Where `deinit` writes the image; empty: nowhere.
    images_dir: []const u8 = "",
    bytes: []u8,
    blk: virtio.Block,
    scratch: [sector]u8 align(16) = undefined,
    fat_cache: ?[]u8 = null,
    vol: fat16.Volume = undefined,

    /// Formats `shape` into a fresh disk and mounts it, holding its FAT in
    /// memory if `cached`. Heap-allocated: the volume points at the block and
    /// the scratch, which must not move.
    pub fn make(label: []const u8, shape: Shape, cached: bool) !*Disk {
        const d = try testing.allocator.create(Disk);
        errdefer testing.allocator.destroy(d);
        const bytes = try testing.allocator.alloc(u8, @as(usize, shape.sectors) * sector);
        format(bytes, shape);
        d.* = .{ .label = label, .bytes = bytes, .blk = virtio.Block.inMemory(bytes) };
        try d.mount(cached);
        return d;
    }

    pub fn mount(d: *Disk, cached: bool) !void {
        d.vol = try fat16.Volume.mount(&d.blk, &d.scratch, 0);
        if (d.fat_cache) |c| testing.allocator.free(c);
        d.fat_cache = null;
        if (cached) {
            d.fat_cache = try testing.allocator.alloc(u8, d.vol.fatBytes());
            try d.vol.cacheFat(d.fat_cache.?);
        }
    }

    pub fn deinit(d: *Disk) void {
        if (d.images_dir.len > 0) d.keep() catch |e| std.debug.panic("writing {s}: {s}", .{ d.label, @errorName(e) });
        if (d.fat_cache) |c| testing.allocator.free(c);
        testing.allocator.free(d.bytes);
        testing.allocator.destroy(d);
    }

    /// Writes the image to `images_dir`, named by its label and whether its
    /// FAT was held in memory.
    pub fn keep(d: *Disk) !void {
        const io = testing.io;
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, d.images_dir, .{});
        defer dir.close(io);
        var name: [128]u8 = undefined;
        const held = if (d.fat_cache != null) "held" else "disk";
        const file = try std.fmt.bufPrint(&name, "{s}-{s}.img", .{ d.label, held });
        try dir.writeFile(io, .{ .sub_path = file, .data = d.bytes });
    }

    /// Free clusters, counted in the first FAT as it sits on the disk.
    pub fn free(d: *const Disk) usize {
        const l = Layout.of(d.bytes);
        var n: usize = 0;
        for (2..l.clusters + 2) |c| {
            if (std.mem.readInt(u16, d.bytes[l.fat_start + c * 2 ..][0..2], .little) == 0) n += 1;
        }
        return n;
    }

    /// Both FAT copies on the disk, byte for byte the same.
    pub fn fatsAgree(d: *const Disk) bool {
        const l = Layout.of(d.bytes);
        return std.mem.eql(u8, d.bytes[l.fat_start..][0..l.fat_bytes], d.bytes[l.fat_start + l.fat_bytes ..][0..l.fat_bytes]);
    }

    /// The whole file at `path`, read through the volume.
    pub fn read(d: *Disk, path: []const u8) ![]u8 {
        const e = try d.vol.open(path);
        const out = try testing.allocator.alloc(u8, e.size);
        errdefer testing.allocator.free(out);
        const n = try d.vol.readFile(e, out);
        try testing.expectEqual(@as(usize, e.size), n);
        return out;
    }

    pub fn expectFile(d: *Disk, path: []const u8, want: []const u8) !void {
        const got = try d.read(path);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, want, got);
    }

    /// The names in a directory, joined by spaces, "." and ".." left out.
    pub fn names(d: *Disk, dir_cluster: u16, buf: []u8) ![]const u8 {
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
pub const small = Shape{ .sectors = 8192 };
