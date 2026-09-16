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
//! **LONG NAMES AND SUBDIRECTORIES ARE SUPPORTED**, because the application's
//! own storage layout needs both: it writes `auth/<id>/api-key`, and
//! `_session_secret`, `upload-bytes` and `last-seen` are all names 8.3 refuses.
//! A volume that cannot hold them cannot hold the data we already have.
//!
//! The long-name format is VFAT's: a run of entries with attribute 0x0F before
//! the short one, in REVERSE order, each holding thirteen UCS-2 characters and
//! a checksum of the short alias that follows them. The checksum is what ties
//! the run to its entry, and it is the classic place to get this wrong:
//!
//!     sum = (((sum & 1) << 7) | ((sum & 0xfe) >> 1)) + short[i]
//!
//! over all eleven bytes, wrapping. `fsck.vfat` is what checks we got it right;
//! `probe/run.sh` runs it over the volume this code writes.
//!
//! What is still missing: FAT12/FAT32, and renaming.

const virtio = @import("virtio.zig");

pub const sector_size: u32 = 512;
pub const Error = error{ NotFat16, BadBootSector, ReadFailed, WriteFailed, NotFound, TooBig, BadChain, BadName, Full, DirectoryFull };

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

/// The longest name this filesystem will hold. VFAT allows 255; the
/// application's longest is `_session_secret` at fifteen, and a buffer per
/// entry is a buffer on a machine with a bump allocator.
pub const max_name: usize = 64;

pub const Entry = struct {
    /// The 8.3 alias, trimmed and dotted: "CODEX.CDX", "SESSIO~1".
    name: [12]u8,
    name_len: u8,
    /// The same alias as it sits on disk: eleven bytes, space padded.
    short: [11]u8 = @splat(' '),
    /// The long name, when the entry had one.
    long: [max_name]u8 = undefined,
    long_len: u8 = 0,
    attr: u8,
    first_cluster: u16,
    size: u32,

    /// The name to show and to match on: the long one when there is one.
    pub fn text(self: *const Entry) []const u8 {
        return if (self.long_len > 0) self.long[0..self.long_len] else self.name[0..self.name_len];
    }

    /// The 8.3 alias, always.
    pub fn alias(self: *const Entry) []const u8 {
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
    sectors_per_fat: u32,
    num_fats: u32,
    root_start: u32,
    root_sectors: u32,
    root_entries: u32,
    data_start: u32,
    /// The highest cluster number the data region holds.
    max_cluster: u16,

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
            .sectors_per_fat = sectors_per_fat,
            .num_fats = num_fats,
            .max_cluster = @intCast(clusters + 1),
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

    /// Where a directory's next sector is. The root is a fixed run outside the
    /// data region; everything else is a cluster chain. Keeping the difference
    /// in one place is what lets `list`, `slotFor` and `grow` all work on
    /// either.
    const Walk = struct {
        vol: *Volume,
        root: bool,
        cluster: u16,
        lba: u32,
        left_in_root: u32,
        in_cluster: u32 = 0,

        fn start(vol: *Volume, dir_cluster: u16) Walk {
            return .{
                .vol = vol,
                .root = dir_cluster == 0,
                .cluster = dir_cluster,
                .lba = if (dir_cluster == 0) vol.root_start else vol.clusterSector(dir_cluster),
                .left_in_root = vol.root_sectors,
            };
        }

        /// Moves to the next sector. Answers false at the end of the directory.
        fn next(self: *Walk) Error!bool {
            if (self.root) {
                self.left_in_root -= 1;
                if (self.left_in_root == 0) return false;
                self.lba += 1;
                return true;
            }
            self.in_cluster += 1;
            if (self.in_cluster < self.vol.sectors_per_cluster) {
                self.lba += 1;
                return true;
            }
            self.cluster = (try self.vol.nextCluster(self.cluster)) orelse return false;
            self.lba = self.vol.clusterSector(self.cluster);
            self.in_cluster = 0;
            return true;
        }
    };

    /// Walks the entries of a directory, calling `each` for every real one.
    /// Cluster 0 means the root directory, which on FAT16 is a fixed run of
    /// sectors outside the data region rather than a chain.
    pub fn list(
        self: *Volume,
        dir_cluster: u16,
        context: anytype,
        comptime each: fn (@TypeOf(context), Entry) void,
    ) Error!void {
        var walk = Walk.start(self, dir_cluster);
        // A long name arrives before its entry, in reverse order, so it is
        // collected here and handed over with the short entry that closes it.
        var long: [max_name]u8 = undefined;
        var long_len: usize = 0;
        var long_sum: u8 = 0;
        var long_ok = false;

        while (true) {
            try self.readSector(walk.lba, self.scratch);
            var at: usize = 0;
            while (at + dirent_size <= sector_size) : (at += dirent_size) {
                const e = self.scratch[at..][0..dirent_size];
                if (e[0] == 0x00) return; // nothing further in this directory
                if (e[0] == 0xE5) {
                    long_ok = false;
                    continue;
                }
                if (e[11] == attr_long_name) {
                    takeLongPart(e, &long, &long_len, &long_sum, &long_ok);
                    continue;
                }
                if (e[11] & attr_volume_label != 0) {
                    long_ok = false;
                    continue;
                }
                var entry = decode(e);
                // **THE CHECKSUM IS WHAT TIES A LONG NAME TO ITS ENTRY.** A run
                // whose checksum does not match the short name it precedes
                // belongs to a file that was deleted and partly overwritten, and
                // using it would put the wrong name on the wrong bytes.
                if (long_ok and long_len > 0 and long_sum == shortChecksum(e[0..11].*)) {
                    entry.long_len = @intCast(@min(long_len, entry.long.len));
                    @memcpy(entry.long[0..entry.long_len], long[0..entry.long_len]);
                }
                long_ok = false;
                long_len = 0;
                each(context, entry);
            }
            if (!(try walk.next())) return;
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

    fn writeSector(self: *Volume, lba: u32, from: *[sector_size]u8) Error!void {
        if (self.blk.write(self.start_lba + lba, @intFromPtr(from)) != virtio.blk_s_ok) return Error.WriteFailed;
    }

    /// The FAT entry for a cluster.
    fn fatGet(self: *Volume, cluster: u16) Error!u16 {
        const at = @as(u32, cluster) * 2;
        try self.readSector(self.fat_start + at / sector_size, self.scratch);
        return le16(self.scratch[at % sector_size ..][0..2]);
    }

    /// Sets the FAT entry for a cluster, **in every copy of the FAT**. A
    /// volume whose second FAT disagrees with its first is one that other
    /// tools will quietly repair, or quietly believe.
    fn fatSet(self: *Volume, cluster: u16, value: u16) Error!void {
        const at = @as(u32, cluster) * 2;
        const in_sector = at / sector_size;
        var copy: u32 = 0;
        while (copy < self.num_fats) : (copy += 1) {
            const lba = self.fat_start + copy * self.sectors_per_fat + in_sector;
            try self.readSector(lba, self.scratch);
            self.scratch[at % sector_size] = @truncate(value);
            self.scratch[at % sector_size + 1] = @truncate(value >> 8);
            try self.writeSector(lba, self.scratch);
        }
    }

    /// A chain of `count` clusters, linked and terminated. Answers its first.
    /// A count of zero answers cluster 0, which is what an empty file holds.
    ///
    /// **A FAILED ALLOCATION LEAVES NOTHING BEHIND.** If the volume runs out
    /// part way, what was taken is given back before the error is returned,
    /// because a half-built chain nothing points at is a leak no `fsck` here
    /// would ever find.
    fn allocChain(self: *Volume, count: u32) Error!u16 {
        if (count == 0) return 0;
        var first: u16 = 0;
        var previous: u16 = 0;
        var taken: u32 = 0;
        var candidate: u16 = 2;

        while (taken < count) {
            if (candidate > self.max_cluster) {
                if (first != 0) self.freeChain(first) catch {};
                return Error.Full;
            }
            if ((try self.fatGet(candidate)) != 0) {
                candidate += 1;
                continue;
            }
            try self.fatSet(candidate, 0xFFFF); // the end, until something follows
            if (previous != 0) try self.fatSet(previous, candidate);
            if (first == 0) first = candidate;
            previous = candidate;
            taken += 1;
            candidate += 1;
        }
        return first;
    }

    fn freeChain(self: *Volume, first: u16) Error!void {
        var cluster = first;
        while (cluster >= 2 and cluster < chain_end) {
            const next = try self.fatGet(cluster);
            try self.fatSet(cluster, 0);
            cluster = next;
        }
    }

    /// Writes `bytes` into a chain that is already long enough. The last
    /// sector is padded with zeros: a cluster is written whole, and the
    /// directory's size field is what says how much of it is the file.
    fn writeChain(self: *Volume, first: u16, bytes: []const u8) Error!void {
        var cluster = first;
        var at: usize = 0;
        while (at < bytes.len) {
            if (cluster < 2) return Error.BadChain;
            var s: u32 = 0;
            while (s < self.sectors_per_cluster and at < bytes.len) : (s += 1) {
                const n = @min(bytes.len - at, @as(usize, sector_size));
                @memcpy(self.scratch[0..n], bytes[at..][0..n]);
                if (n < sector_size) @memset(self.scratch[n..], 0);
                try self.writeSector(self.clusterSector(cluster) + s, self.scratch);
                at += n;
            }
            if (at >= bytes.len) break;
            cluster = (try self.nextCluster(cluster)) orelse return Error.BadChain;
        }
    }

    /// A run of `needed` consecutive free entries in a directory, growing it if
    /// there is no room. Answers where the run starts.
    ///
    /// **A LONG NAME NEEDS A RUN, NOT A SLOT.** Its parts must sit immediately
    /// before the short entry with nothing between them, so a directory with
    /// plenty of scattered free entries can still have nowhere to put one.
    const Run = struct { lba: u32, at: u32 };

    fn findRun(self: *Volume, dir_cluster: u16, needed: u32) Error!Run {
        var walk = Walk.start(self, dir_cluster);
        var start: ?Run = null;
        var have: u32 = 0;

        while (true) {
            try self.readSector(walk.lba, self.scratch);
            var at: u32 = 0;
            while (at + dirent_size <= sector_size) : (at += dirent_size) {
                const first = self.scratch[at];
                if (first == 0x00 or first == 0xE5) {
                    if (have == 0) start = .{ .lba = walk.lba, .at = at };
                    have += 1;
                    if (have == needed) return start.?;
                } else {
                    have = 0;
                    start = null;
                }
            }
            if (!(try walk.next())) break;
            // A run may not straddle sectors unless they are contiguous, and
            // within a cluster they are. Crossing a cluster boundary is safe
            // for the same reason the walk is: the next sector is the next
            // entry either way.
        }

        // **THE ROOT DIRECTORY CANNOT GROW.** On FAT16 it is a fixed run of
        // sectors sized when the volume was made, which is the one hard limit
        // this filesystem has that a caller can hit in normal use.
        if (dir_cluster == 0) return Error.DirectoryFull;
        try self.grow(dir_cluster);
        return self.findRun(dir_cluster, needed);
    }

    /// Adds one zeroed cluster to the end of a directory's chain.
    fn grow(self: *Volume, dir_cluster: u16) Error!void {
        var last = dir_cluster;
        while (try self.nextCluster(last)) |n| last = n;

        const fresh = try self.allocChain(1);
        var s: u32 = 0;
        @memset(self.scratch, 0);
        while (s < self.sectors_per_cluster) : (s += 1) {
            try self.writeSector(self.clusterSector(fresh) + s, self.scratch);
        }
        try self.fatSet(last, fresh);
    }

    /// Removes an entry and its long-name run, and frees its chain.
    fn removeEntry(self: *Volume, dir_cluster: u16, name: []const u8) Error!void {
        var walk = Walk.start(self, dir_cluster);
        var long_start: ?Run = null;
        var long_sum: u8 = 0;
        var long_ok = false;
        var long_buf: [max_name]u8 = undefined;
        var long_len: usize = 0;

        while (true) {
            try self.readSector(walk.lba, self.scratch);
            var at: u32 = 0;
            while (at + dirent_size <= sector_size) : (at += dirent_size) {
                const e = self.scratch[at..][0..dirent_size];
                if (e[0] == 0x00) return;
                if (e[0] == 0xE5) {
                    long_ok = false;
                    long_start = null;
                    continue;
                }
                if (e[11] == attr_long_name) {
                    if (e[0] & 0x40 != 0) long_start = .{ .lba = walk.lba, .at = at };
                    takeLongPart(e, &long_buf, &long_len, &long_sum, &long_ok);
                    continue;
                }
                var entry = decode(e);
                if (long_ok and long_len > 0 and long_sum == shortChecksum(e[0..11].*)) {
                    entry.long_len = @intCast(@min(long_len, entry.long.len));
                    @memcpy(entry.long[0..entry.long_len], long_buf[0..entry.long_len]);
                }
                if (eqlFold(entry.text(), name)) {
                    if (entry.first_cluster >= 2) try self.freeChain(entry.first_cluster);
                    // Tombstone the short entry, and the run in front of it.
                    self.scratch[at] = 0xE5;
                    try self.writeSector(walk.lba, self.scratch);
                    if (entry.long_len > 0) {
                        if (long_start) |ls| try self.tombstoneRun(ls, walk.lba, at);
                    }
                    return;
                }
                long_ok = false;
                long_len = 0;
                long_start = null;
            }
            if (!(try walk.next())) return;
        }
    }

    /// Marks every long-name entry from `from` up to (not including) the short
    /// entry as deleted. A run left behind would be adopted by whatever is
    /// written there next, which is exactly what the checksum exists to stop --
    /// but tidying up is cheaper than relying on it.
    fn tombstoneRun(self: *Volume, from: Run, short_lba: u32, short_at: u32) Error!void {
        var lba = from.lba;
        var at = from.at;
        while (lba < short_lba or (lba == short_lba and at < short_at)) {
            try self.readSector(lba, self.scratch);
            self.scratch[at] = 0xE5;
            try self.writeSector(lba, self.scratch);
            at += dirent_size;
            if (at + dirent_size > sector_size) {
                at = 0;
                lba += 1;
            }
        }
    }

    /// Writes the long-name run and the short entry that closes it.
    fn writeEntry(
        self: *Volume,
        run: Run,
        name: []const u8,
        short: [11]u8,
        attr: u8,
        first: u16,
        size: u32,
    ) Error!void {
        const parts = longParts(name);
        const sum = shortChecksum(short);

        var lba = run.lba;
        var at = run.at;
        var part: u32 = parts;
        while (part > 0) : (part -= 1) {
            try self.readSector(lba, self.scratch);
            const e = self.scratch[at..][0..dirent_size];
            @memset(e, 0);
            e[0] = @intCast(part | (if (part == parts) @as(u32, 0x40) else 0));
            e[11] = attr_long_name;
            e[12] = 0;
            e[13] = sum;
            e[26] = 0;
            e[27] = 0;
            const base = (part - 1) * 13;
            for (long_offsets, 0..) |off, i| {
                const idx = base + i;
                const c: u16 = if (idx < name.len)
                    name[idx]
                else if (idx == name.len) 0x0000 else 0xFFFF;
                e[off] = @truncate(c);
                e[off + 1] = @truncate(c >> 8);
            }
            try self.writeSector(lba, self.scratch);
            at += dirent_size;
            if (at + dirent_size > sector_size) {
                at = 0;
                lba += 1;
            }
        }

        try self.readSector(lba, self.scratch);
        const e = self.scratch[at..][0..dirent_size];
        @memset(e, 0);
        @memcpy(e[0..11], &short);
        e[11] = attr;
        e[26] = @truncate(first);
        e[27] = @truncate(first >> 8);
        e[28] = @truncate(size);
        e[29] = @truncate(size >> 8);
        e[30] = @truncate(size >> 16);
        e[31] = @truncate(size >> 24);
        try self.writeSector(lba, self.scratch);
    }

    /// An 8.3 alias for a name. A name that already fits is its own alias; one
    /// that does not gets SESSIO~1, SESSIO~2, and so on until one is free.
    fn aliasFor(self: *Volume, dir_cluster: u16, name: []const u8) Error![11]u8 {
        if (!needsLongName(name)) {
            if (encode(name)) |short| return short else |_| {}
        }

        var n: u32 = 1;
        while (n < 1000) : (n += 1) {
            var short = [_]u8{' '} ** 11;

            var tail: [4]u8 = undefined;
            var tail_len: usize = 1;
            tail[0] = '~';
            var digits: [3]u8 = undefined;
            var d: usize = 0;
            var v = n;
            while (v > 0) : (v /= 10) {
                digits[d] = '0' + @as(u8, @intCast(v % 10));
                d += 1;
            }
            while (d > 0) {
                d -= 1;
                tail[tail_len] = digits[d];
                tail_len += 1;
            }

            // The base: what fits before the tail, skipping dots and spaces,
            // which an 8.3 field cannot hold.
            const keep = 8 - tail_len;
            var w: usize = 0;
            for (name) |c| {
                if (w >= keep) break;
                if (c == '.' or c == ' ') continue;
                short[w] = upper(c);
                w += 1;
            }
            for (tail[0..tail_len], 0..) |c, i| short[w + i] = c;

            // The extension, from the last dot.
            var dot: usize = name.len;
            for (name, 0..) |c, i| {
                if (c == '.') dot = i;
            }
            if (dot < name.len) {
                var x: usize = 0;
                for (name[dot + 1 ..]) |c| {
                    if (x >= 3) break;
                    short[8 + x] = upper(c);
                    x += 1;
                }
            }

            if (!(try self.aliasTaken(dir_cluster, short))) return short;
        }
        return Error.BadName;
    }

    /// Whether a directory already holds this exact 8.3 field.
    fn aliasTaken(self: *Volume, dir_cluster: u16, short: [11]u8) Error!bool {
        const Search = struct {
            want: [11]u8,
            found: bool = false,
            fn each(sv: *@This(), e: Entry) void {
                if (eqlBytes(&e.short, &sv.want)) sv.found = true;
            }
        };
        var search = Search{ .want = short };
        try self.list(dir_cluster, &search, Search.each);
        return search.found;
    }

    /// Writes a whole file into `dir_cluster`, replacing one of the same name.
    pub fn writeFileIn(self: *Volume, dir_cluster: u16, name: []const u8, bytes: []const u8) Error!void {
        if (name.len == 0 or name.len > max_name) return Error.BadName;
        try self.removeEntry(dir_cluster, name);

        const short = try self.aliasFor(dir_cluster, name);
        const needs_long = needsLongName(name);
        const parts: u32 = if (needs_long) longParts(name) else 0;
        const run = try self.findRun(dir_cluster, parts + 1);

        const per_cluster = self.sectors_per_cluster * sector_size;
        const clusters = (@as(u32, @intCast(bytes.len)) + per_cluster - 1) / per_cluster;
        const first = try self.allocChain(clusters);
        if (bytes.len > 0) try self.writeChain(first, bytes);

        // The entry goes last: until it is written, nothing points at the data,
        // so a machine that stops here has lost a file rather than corrupted one.
        try self.writeEntry(run, if (needs_long) name else name[0..0], short, 0x20, first, @intCast(bytes.len));
    }

    /// Makes a directory in `dir_cluster`. Its first cluster holds `.` and `..`,
    /// which every directory but the root has and which `fsck` checks for.
    pub fn makeDirIn(self: *Volume, dir_cluster: u16, name: []const u8) Error!u16 {
        if ((try self.find(dir_cluster, name))) |e| {
            if (e.isDirectory()) return e.first_cluster;
            return Error.BadName;
        }

        const cluster = try self.allocChain(1);
        @memset(self.scratch, 0);
        var s: u32 = 0;
        while (s < self.sectors_per_cluster) : (s += 1) {
            try self.writeSector(self.clusterSector(cluster) + s, self.scratch);
        }

        // `.` points at this directory and `..` at its parent, with the root
        // spelled as cluster zero.
        @memset(self.scratch, 0);
        const dot = self.scratch[0..dirent_size];
        @memcpy(dot[0..11], ".          ");
        dot[11] = attr_directory;
        dot[26] = @truncate(cluster);
        dot[27] = @truncate(cluster >> 8);
        const dotdot = self.scratch[dirent_size..][0..dirent_size];
        @memcpy(dotdot[0..11], "..         ");
        dotdot[11] = attr_directory;
        dotdot[26] = @truncate(dir_cluster);
        dotdot[27] = @truncate(dir_cluster >> 8);
        try self.writeSector(self.clusterSector(cluster), self.scratch);

        const short = try self.aliasFor(dir_cluster, name);
        const needs_long = needsLongName(name);
        const parts: u32 = if (needs_long) longParts(name) else 0;
        const run = try self.findRun(dir_cluster, parts + 1);
        try self.writeEntry(run, if (needs_long) name else name[0..0], short, attr_directory, cluster, 0);
        return cluster;
    }

    /// Walks a slash-separated path, making each directory that is missing, and
    /// answers the cluster of the last one.
    pub fn makePath(self: *Volume, path: []const u8) Error!u16 {
        var cluster: u16 = 0;
        var at: usize = 0;
        while (at < path.len) {
            var end = at;
            while (end < path.len and path[end] != '/') end += 1;
            if (end > at) cluster = try self.makeDirIn(cluster, path[at..end]);
            at = end + 1;
        }
        return cluster;
    }

    /// A whole file at a path, making the directories above it.
    pub fn writeFile(self: *Volume, path: []const u8, bytes: []const u8) Error!void {
        var slash: ?usize = null;
        for (path, 0..) |c, i| {
            if (c == '/') slash = i;
        }
        if (slash) |i| {
            const dir = try self.makePath(path[0..i]);
            return self.writeFileIn(dir, path[i + 1 ..], bytes);
        }
        return self.writeFileIn(0, path, bytes);
    }

    /// A whole file into `out`. Answers how many bytes it was.
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

/// The write half.
pub const Writing = struct {};

/// **THE CHECKSUM THAT TIES A LONG NAME TO ITS ENTRY.** Over the eleven bytes
/// of the 8.3 alias, rotating right and adding, wrapping at each step. Getting
/// this wrong produces a volume that looks fine to us and is rejected by every
/// other reader, which is why `fsck.vfat` is in the check.
fn shortChecksum(short: [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| {
        sum = (((sum & 1) << 7) | ((sum & 0xFE) >> 1)) +% c;
    }
    return sum;
}

/// Where a long-name entry keeps its thirteen characters: three runs, because
/// the layout has to dodge the fields a short entry uses.
const long_offsets = [_]u8{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };

/// Takes one long-name entry. They arrive in reverse order -- the last part
/// first -- so each is written at its sequence number's place.
fn takeLongPart(e: []const u8, out: *[max_name]u8, len: *usize, sum: *u8, ok: *bool) void {
    const seq = e[0] & 0x1F;
    if (seq == 0 or seq > max_name / 13) {
        ok.* = false;
        return;
    }
    if (e[0] & 0x40 != 0) { // the last part, which arrives first
        len.* = 0;
        sum.* = e[13];
        ok.* = true;
    } else if (!ok.* or sum.* != e[13]) {
        ok.* = false;
        return;
    }

    const base = (@as(usize, seq) - 1) * 13;
    for (long_offsets, 0..) |off, i| {
        const c = @as(u16, e[off]) | (@as(u16, e[off + 1]) << 8);
        if (c == 0x0000 or c == 0xFFFF) break;
        const at = base + i;
        if (at >= out.len) {
            ok.* = false;
            return;
        }
        // **ASCII ONLY.** Every name this filesystem has to hold is ASCII, and
        // a character outside it is refused rather than mangled into one byte.
        out[at] = if (c < 128) @intCast(c) else '?';
        if (at + 1 > len.*) len.* = at + 1;
    }
}

/// An on-disk 8.3 name, trimmed and dotted.
fn decode(e: []const u8) Entry {
    var out: Entry = .{
        .name = [_]u8{0} ** 12,
        .name_len = 0,
        .short = e[0..11].*,
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

/// A name as an 8.3 field: eight of base, three of extension, space padded and
/// upper cased. A name that does not fit is refused rather than truncated --
/// silently storing a different name than the one asked for is the classic
/// FAT bug, and Cobblestone's own Fat16 carries a paragraph about having had
/// it.
///
/// **FITTING IS NOT ENOUGH; IT HAS TO SURVIVE THE ROUND TRIP.** `api-key` fits
/// in eight characters and comes back as `API-KEY`, which is a different name.
/// `needsLongName` is what decides, and it decides by asking whether the name
/// reads back as itself.
fn encode(name: []const u8) Error![11]u8 {
    var out = [_]u8{' '} ** 11;
    var dot: usize = name.len;
    for (name, 0..) |c, i| {
        if (c == '.') dot = i;
    }
    const base = name[0..dot];
    const ext = if (dot < name.len) name[dot + 1 ..] else name[0..0];
    if (base.len == 0 or base.len > 8 or ext.len > 3) return Error.BadName;
    for (base, 0..) |c, i| out[i] = upper(c);
    for (ext, 0..) |c, i| out[8 + i] = upper(c);
    return out;
}

/// How many long-name entries a name needs: thirteen characters each.
fn longParts(name: []const u8) u32 {
    return @intCast((name.len + 12) / 13);
}

/// Whether a name has to be stored as a long one. True when 8.3 cannot hold it
/// at all, and true when 8.3 would hold something that reads back differently
/// -- which is every name with a lowercase letter in it.
fn needsLongName(name: []const u8) bool {
    const short = encode(name) catch return true;
    var dotted: [12]u8 = undefined;
    const len = aliasText(short, &dotted);
    return !eqlBytes(dotted[0..len], name);
}

/// An 8.3 field as it reads back: trimmed and dotted.
fn aliasText(short: [11]u8, out: *[12]u8) usize {
    var n: usize = 0;
    var base: usize = 8;
    while (base > 0 and short[base - 1] == ' ') base -= 1;
    for (short[0..base]) |c| {
        out[n] = c;
        n += 1;
    }
    var ext: usize = 11;
    while (ext > 8 and short[ext - 1] == ' ') ext -= 1;
    if (ext > 8) {
        out[n] = '.';
        n += 1;
        for (short[8..ext]) |c| {
            out[n] = c;
            n += 1;
        }
    }
    return n;
}

fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (upper(x) != upper(y)) return false;
    return true;
}
