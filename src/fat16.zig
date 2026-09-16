//! FAT16, read side: mount a volume, walk a directory, read a file.
//!
//! This is the filesystem `Io.Dir` will sit on, and it is FAT16 for two
//! reasons. The application above it asks only for whole-file reads, whole-file
//! writes and directory listings — eleven operations, none of them needing
//! seeks or partial writes — which is exactly what FAT16 is good at. And there
//! is already a FAT16 next door in `roc-apps/floor`, written in Roc and green
//! against these same fixtures, which makes it an oracle rather than a second
//! opinion.
//!
//! **NOTHING HERE ALLOCATES.** The caller supplies every buffer, because the
//! buffers a sector lands in must be identity-mapped physical memory for the
//! device to write into them. That constraint comes all the way up from
//! virtio, and hiding it behind an allocator would only move the day it bites.
//!
//! What is missing: writing, long names (they are skipped, and the 8.3 alias
//! beside them is used), and FAT12/FAT32.

const virtio = @import("virtio.zig");

pub const sector_size: u32 = 512;
pub const Error = error{ NotFat16, BadBootSector, ReadFailed, NotFound, TooBig, BadChain };

/// A directory entry as it sits on disk.
const dirent_size: u32 = 32;
const attr_read_only: u8 = 0x01;
const attr_hidden: u8 = 0x02;
const attr_system: u8 = 0x04;
const attr_volume_label: u8 = 0x08;
const attr_directory: u8 = 0x10;
/// A long-name fragment: read-only, hidden, system and volume label all at
/// once, which no real entry is. Skipping these is what makes a volume with
/// long names still readable through its 8.3 aliases.
const attr_long_name: u8 = 0x0F;

/// The first cluster number that means "no more". FAT16 reserves 0xFFF8 and up.
const chain_end: u16 = 0xFFF8;

fn le16(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

fn le32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

pub const Entry = struct {
    /// The 8.3 name, trimmed and dotted: "CODEX.CDX", "EFI".
    name: [12]u8,
    name_len: u8,
    attr: u8,
    first_cluster: u16,
    size: u32,

    pub fn text(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isDirectory(self: *const Entry) bool {
        return self.attr & attr_directory != 0;
    }
};

pub const Volume = struct {
    blk: *virtio.Block,
    /// One sector of identity-mapped scratch, which the device writes into.
    scratch: *[sector_size]u8,

    /// Where this volume starts on the disk. **Every sector number below is
    /// relative to the volume**, and this is the only place the disk's own
    /// numbering appears -- a GPT partition rarely starts at zero.
    start_lba: u32,

    sectors_per_cluster: u32,
    fat_start: u32,
    root_start: u32,
    root_sectors: u32,
    root_entries: u32,
    data_start: u32,

    /// Reads the boot sector and works out where everything is.
    ///
    /// **A BOOT SECTOR IS NOT TRUSTED.** Every field it names is checked before
    /// it is used to compute an offset, because a sector of zeros or of someone
    /// else's filesystem would otherwise send reads anywhere.
    pub fn mount(blk: *virtio.Block, scratch: *[sector_size]u8, start_lba: u32) Error!Volume {
        if (blk.read(start_lba, @intFromPtr(scratch)) != virtio.blk_s_ok) return Error.ReadFailed;
        const b = scratch.*;

        if (b[510] != 0x55 or b[511] != 0xAA) return Error.BadBootSector;

        const bytes_per_sector = le16(b[11..13]);
        const sectors_per_cluster: u32 = b[13];
        const reserved: u32 = le16(b[14..16]);
        const num_fats: u32 = b[16];
        const root_entries: u32 = le16(b[17..19]);
        const sectors_per_fat: u32 = le16(b[22..24]);
        var total: u32 = le16(b[19..21]);
        if (total == 0) total = le32(b[32..36]);

        if (bytes_per_sector != sector_size) return Error.NotFat16;
        if (sectors_per_cluster == 0 or sectors_per_cluster > 128) return Error.BadBootSector;
        if (reserved == 0 or num_fats == 0 or num_fats > 2) return Error.BadBootSector;
        if (root_entries == 0 or sectors_per_fat == 0) return Error.BadBootSector;

        const root_start = reserved + num_fats * sectors_per_fat;
        const root_sectors = (root_entries * dirent_size + sector_size - 1) / sector_size;
        const data_start = root_start + root_sectors;
        if (total == 0 or data_start >= total) return Error.BadBootSector;

        // FAT16 is defined by how many clusters the data region holds, not by
        // anything the boot sector says about itself.
        const clusters = (total - data_start) / sectors_per_cluster;
        if (clusters < 4085 or clusters >= 65525) return Error.NotFat16;

        return .{
            .blk = blk,
            .scratch = scratch,
            .start_lba = start_lba,
            .sectors_per_cluster = sectors_per_cluster,
            .fat_start = reserved,
            .root_start = root_start,
            .root_sectors = root_sectors,
            .root_entries = root_entries,
            .data_start = data_start,
        };
    }

    fn readSector(self: *Volume, lba: u32, into: *[sector_size]u8) Error!void {
        if (self.blk.read(self.start_lba + lba, @intFromPtr(into)) != virtio.blk_s_ok) return Error.ReadFailed;
    }

    /// The sector a cluster starts at. Cluster numbering starts at 2, which is
    /// the oldest off-by-two in computing.
    fn clusterSector(self: *Volume, cluster: u16) u32 {
        return self.data_start + (@as(u32, cluster) - 2) * self.sectors_per_cluster;
    }

    /// The next cluster in a chain, or null at its end.
    fn nextCluster(self: *Volume, cluster: u16) Error!?u16 {
        const at = @as(u32, cluster) * 2;
        try self.readSector(self.fat_start + at / sector_size, self.scratch);
        const v = le16(self.scratch[at % sector_size ..][0..2]);
        if (v >= chain_end) return null;
        if (v < 2) return Error.BadChain;
        return v;
    }

    /// Walks the entries of a directory, calling `each` for every real one.
    /// Cluster 0 means the root directory, which on FAT16 is a fixed run of
    /// sectors outside the data region rather than a chain.
    pub fn list(
        self: *Volume,
        dir_cluster: u16,
        context: anytype,
        comptime each: fn (@TypeOf(context), Entry) void,
    ) Error!void {
        var cluster = dir_cluster;
        var root_left = self.root_sectors;
        var lba: u32 = if (dir_cluster == 0) self.root_start else self.clusterSector(cluster);
        var in_cluster: u32 = 0;

        while (true) {
            try self.readSector(lba, self.scratch);
            var at: usize = 0;
            while (at + dirent_size <= sector_size) : (at += dirent_size) {
                const e = self.scratch[at..][0..dirent_size];
                if (e[0] == 0x00) return; // nothing further in this directory
                if (e[0] == 0xE5) continue; // deleted
                if (e[11] == attr_long_name) continue; // a long-name fragment
                if (e[11] & attr_volume_label != 0) continue;
                each(context, decode(e));
            }

            // On to the next sector, which for the root is simply the next one
            // and for anything else may cross into another cluster.
            if (dir_cluster == 0) {
                root_left -= 1;
                if (root_left == 0) return;
                lba += 1;
            } else {
                in_cluster += 1;
                if (in_cluster == self.sectors_per_cluster) {
                    cluster = (try self.nextCluster(cluster)) orelse return;
                    lba = self.clusterSector(cluster);
                    in_cluster = 0;
                } else {
                    lba += 1;
                }
            }
        }
    }

    /// The entry named `name` in a directory, or null. Case-insensitive, as
    /// 8.3 names are.
    pub fn find(self: *Volume, dir_cluster: u16, name: []const u8) Error!?Entry {
        const Search = struct {
            want: []const u8,
            found: ?Entry = null,
            fn each(s: *@This(), e: Entry) void {
                if (s.found != null) return;
                if (eqlFold(e.text(), s.want)) s.found = e;
            }
        };
        var search = Search{ .want = name };
        try self.list(dir_cluster, &search, Search.each);
        return search.found;
    }

    /// Walks a slash-separated path from the root. "EFI/BOOT/BOOTX64.EFI".
    pub fn open(self: *Volume, path: []const u8) Error!Entry {
        var cluster: u16 = 0;
        var at: usize = 0;
        var result: ?Entry = null;
        while (at < path.len) {
            var end = at;
            while (end < path.len and path[end] != '/') end += 1;
            if (end > at) {
                const e = (try self.find(cluster, path[at..end])) orelse return Error.NotFound;
                result = e;
                cluster = e.first_cluster;
            }
            at = end + 1;
        }
        return result orelse Error.NotFound;
    }

    /// A whole file into `out`. Answers how many bytes it was.
    pub fn readFile(self: *Volume, entry: Entry, out: []u8) Error!usize {
        if (entry.isDirectory()) return Error.NotFound;
        if (entry.size > out.len) return Error.TooBig;

        var left: usize = entry.size;
        var written: usize = 0;
        var cluster = entry.first_cluster;
        while (left > 0) {
            if (cluster < 2) return Error.BadChain;
            var s: u32 = 0;
            while (s < self.sectors_per_cluster and left > 0) : (s += 1) {
                try self.readSector(self.clusterSector(cluster) + s, self.scratch);
                const n = @min(left, sector_size);
                @memcpy(out[written..][0..n], self.scratch[0..n]);
                written += n;
                left -= n;
            }
            if (left == 0) break;
            cluster = (try self.nextCluster(cluster)) orelse return Error.BadChain;
        }
        return written;
    }
};

/// An on-disk 8.3 name, trimmed and dotted.
fn decode(e: []const u8) Entry {
    var out: Entry = .{
        .name = [_]u8{0} ** 12,
        .name_len = 0,
        .attr = e[11],
        .first_cluster = le16(e[26..28]),
        .size = le32(e[28..32]),
    };
    var n: usize = 0;
    var base: usize = 8;
    while (base > 0 and e[base - 1] == ' ') base -= 1;
    for (e[0..base]) |c| {
        out.name[n] = c;
        n += 1;
    }
    var ext: usize = 11;
    while (ext > 8 and e[ext - 1] == ' ') ext -= 1;
    if (ext > 8) {
        out.name[n] = '.';
        n += 1;
        for (e[8..ext]) |c| {
            out.name[n] = c;
            n += 1;
        }
    }
    out.name_len = @intCast(n);
    return out;
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (upper(x) != upper(y)) return false;
    return true;
}
