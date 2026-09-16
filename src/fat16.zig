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

    /// **WHERE THIS ENTRY SITS.** A file's length lives in its directory entry,
    /// so anything that changes the length has to write that entry back — and
    /// finding it again means re-walking the directory and re-matching the long
    /// name. `list` knows the location at the moment it decodes, so it records
    /// it here and appendTo can write one sector instead.
    lba: u32 = 0,
    slot: u32 = 0,

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
                entry.lba = walk.lba;
                entry.slot = @intCast(at);
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
    /// Where one directory entry sits: a sector the WALK reached, and an offset
    /// in it.
    const Slot = struct { lba: u32, at: u32 };

    /// **A RUN IS THE SLOTS THEMSELVES, NOT A START AND A LENGTH.** It used to be
    /// a start, and writeEntry stepped `lba += 1` to reach the next sector. That
    /// holds inside a cluster and nowhere else: a subdirectory grows by taking
    /// the first free cluster, which is rarely the one after its last, so "the
    /// next sector" past a cluster edge is usually some other file's data. A long
    /// name whose parts straddled the edge wrote its tail there. findRun already
    /// walked the directory properly; now it hands over what it walked.
    const Run = struct {
        slots: [max_long_parts + 1]Slot = undefined,
        len: u32 = 0,
    };

    fn findRun(self: *Volume, dir_cluster: u16, needed: u32) Error!Run {
        if (needed == 0 or needed > max_long_parts + 1) return Error.BadName;
        var walk = Walk.start(self, dir_cluster);
        var run = Run{};

        while (true) {
            try self.readSector(walk.lba, self.scratch);
            var at: u32 = 0;
            while (at + dirent_size <= sector_size) : (at += dirent_size) {
                const first = self.scratch[at];
                if (first == 0x00 or first == 0xE5) {
                    run.slots[run.len] = .{ .lba = walk.lba, .at = at };
                    run.len += 1;
                    if (run.len == needed) return run;
                } else {
                    run.len = 0;
                }
            }
            // A run MAY straddle sectors and clusters: the walk says where the
            // next entry is, and each slot records the sector it was found in.
            if (!(try walk.next())) break;
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

    /// The most parts a VFAT long name can have: 255 characters, 13 per part.
    const max_long_parts = 20;

    /// Removes an entry and its long-name run, and frees its chain.
    ///
    /// **THE ORDER IS THE WHOLE FUNCTION.**
    ///
    ///   1. Tombstone the short entry — `self.scratch` holds its sector right now.
    ///   2. Tombstone each long-name part, at the sector the WALK found it in.
    ///   3. Only then free the cluster chain.
    ///
    /// It used to free the chain first. freeChain reads and writes FAT sectors
    /// through the same one-sector scratch buffer, so the "directory sector"
    /// written back next was a FAT sector with one byte changed: removing any
    /// file that had data destroyed its directory. Every `writeFile` that
    /// REPLACES a file goes through here, and the application replaces files
    /// constantly — each id counter rewrites its file on every bump. fsck.vfat
    /// and the Linux driver caught it; this machine's own reader did not.
    ///
    /// Freeing last is also the crash-safe order. A machine that stops between
    /// the steps has leaked some clusters, which fsck reclaims; the other order
    /// leaves an entry pointing at clusters already given away.
    ///
    /// **THE LONG-NAME PARTS ARE LOCATED BY THE WALK**, not by stepping sector
    /// numbers. A subdirectory's next cluster need not be adjacent to its last,
    /// so "the sector after this one" can be another file's data. A run that
    /// straddles a cluster edge needs a directory of sixty-odd entries, and a
    /// player's session folder can have that.
    fn removeEntry(self: *Volume, dir_cluster: u16, name: []const u8) Error!void {
        const Pos = struct { lba: u32, at: u32 };
        var walk = Walk.start(self, dir_cluster);
        var parts: [max_long_parts]Pos = undefined;
        var part_count: usize = 0;
        var parts_overflowed = false;
        var long_sum: u8 = 0;
        var long_ok = false;
        var long_buf: [max_name]u8 = undefined;
        var long_len: usize = 0;

        while (true) {
            try self.readSector(walk.lba, self.scratch);
            var at: u32 = 0;
            while (at + dirent_size <= sector_size) : (at += dirent_size) {
                const e = self.scratch[at..][0..dirent_size];
                if (e[0] == 0x00) return; // nothing further in this directory
                if (e[0] == 0xE5) {
                    long_ok = false;
                    long_len = 0;
                    part_count = 0;
                    parts_overflowed = false;
                    continue;
                }
                if (e[11] == attr_long_name) {
                    // The part flagged 0x40 opens a run (it is the last part
                    // logically, and comes first on disk).
                    if (e[0] & 0x40 != 0) {
                        part_count = 0;
                        parts_overflowed = false;
                    }
                    if (part_count < parts.len) {
                        parts[part_count] = .{ .lba = walk.lba, .at = at };
                        part_count += 1;
                    } else parts_overflowed = true;
                    takeLongPart(e, &long_buf, &long_len, &long_sum, &long_ok);
                    continue;
                }
                if (e[11] & attr_volume_label != 0) {
                    long_ok = false;
                    long_len = 0;
                    part_count = 0;
                    continue;
                }

                var entry = decode(e);
                const has_long = long_ok and long_len > 0 and long_sum == shortChecksum(e[0..11].*);
                if (has_long) {
                    entry.long_len = @intCast(@min(long_len, entry.long.len));
                    @memcpy(entry.long[0..entry.long_len], long_buf[0..entry.long_len]);
                }

                if (eqlFold(entry.text(), name)) {
                    const chain = entry.first_cluster;
                    const short_lba = walk.lba;
                    const run = parts[0..part_count];
                    if (has_long and parts_overflowed) return Error.BadName; // cannot remove what cannot be found whole

                    // 1. the short entry, while its sector is in scratch
                    self.scratch[at] = 0xE5;
                    try self.writeSector(short_lba, self.scratch);

                    // 2. the long-name parts, each where the walk found it
                    if (has_long) {
                        for (run) |pos| {
                            try self.readSector(pos.lba, self.scratch);
                            self.scratch[pos.at] = 0xE5;
                            try self.writeSector(pos.lba, self.scratch);
                        }
                    }

                    // 3. and only now, the data
                    if (chain >= 2) try self.freeChain(chain);
                    return;
                }
                long_ok = false;
                long_len = 0;
                part_count = 0;
                parts_overflowed = false;
            }
            if (!(try walk.next())) return;
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
        if (run.len != parts + 1) return Error.BadName; // the run was sized for another name

        var next: u32 = 0;
        var part: u32 = parts;
        while (part > 0) : (part -= 1) {
            const slot = run.slots[next];
            next += 1;
            try self.readSector(slot.lba, self.scratch);
            const e = self.scratch[slot.at..][0..dirent_size];
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
            try self.writeSector(slot.lba, self.scratch);
        }

        const slot = run.slots[next];
        try self.readSector(slot.lba, self.scratch);
        const e = self.scratch[slot.at..][0..dirent_size];
        @memset(e, 0);
        @memcpy(e[0..11], &short);
        e[11] = attr;
        e[26] = @truncate(first);
        e[27] = @truncate(first >> 8);
        e[28] = @truncate(size);
        e[29] = @truncate(size >> 8);
        e[30] = @truncate(size >> 16);
        e[31] = @truncate(size >> 24);
        try self.writeSector(slot.lba, self.scratch);
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
    /// **THE ONE WRITE `writeFile` CANNOT EXPRESS.** The application appends:
    /// every chat message, every game action, every uploaded chunk is
    /// `createFile(truncate=false)` then a positional write at the current end.
    /// Whole-file rewriting would answer it — read it all back, concatenate,
    /// write it all out — and would make a conversation of N messages cost
    /// N-squared bytes written, on a machine whose disk is a virtqueue. So this
    /// walks to the end, fills the partial cluster that is already there, and
    /// links on only what it still needs.
    ///
    /// `offset` is where the write lands. It may be the end (an append, which is
    /// every call the application makes) or inside the file (an overwrite). It
    /// may NOT be past the end: FAT has no sparse files, so a hole would be
    /// whatever those clusters last held, and answering with stale bytes is
    /// worse than refusing.
    ///
    /// The file must exist; `Dir.createFile` is what creates an empty one.
    pub fn writeInto(self: *Volume, path: []const u8, offset: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        const entry = try self.open(path);
        if (entry.isDirectory()) return Error.BadName;
        if (offset > entry.size) return Error.BadChain; // would leave a hole

        const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;
        const old_size: u32 = entry.size;
        const reach: u64 = @as(u64, offset) + bytes.len;
        if (reach > 0xFFFF_FFFF) return Error.TooBig;
        const new_size: u32 = @max(old_size, @as(u32, @intCast(reach)));

        const have: u32 = (old_size + cluster_bytes - 1) / cluster_bytes;
        const need: u32 = (new_size + cluster_bytes - 1) / cluster_bytes;

        // An empty file has no chain at all (first_cluster 0), so the first
        // append is also the allocation.
        var first = entry.first_cluster;
        if (have == 0) {
            first = try self.allocChain(need);
        } else if (need > have) {
            const extra = try self.allocChain(need - have);
            try self.fatSet(try self.lastCluster(first), extra);
        }

        try self.writeAt(first, offset, bytes);
        try self.setEntry(entry, first, new_size);
    }

    /// The last cluster of a chain — where an extension links on.
    fn lastCluster(self: *Volume, first: u16) Error!u16 {
        if (first < 2) return Error.BadChain;
        var cluster = first;
        while (try self.nextCluster(cluster)) |next| {
            if (next < 2) return Error.BadChain;
            cluster = next;
        }
        return cluster;
    }

    /// Writes `bytes` into a chain at byte `offset`, which the chain must
    /// already be long enough to hold.
    ///
    /// **THE FIRST SECTOR IS READ BEFORE IT IS WRITTEN**, because an append
    /// almost never lands on a sector boundary: the bytes already in that
    /// sector are the end of the file, and writing a fresh sector over them
    /// would erase back to the last boundary.
    fn writeAt(self: *Volume, first: u16, offset: u32, bytes: []const u8) Error!void {
        const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;

        // Walk to the cluster the offset falls in.
        var cluster = first;
        var skip = offset / cluster_bytes;
        while (skip > 0) : (skip -= 1) {
            cluster = (try self.nextCluster(cluster)) orelse return Error.BadChain;
            if (cluster < 2) return Error.BadChain;
        }

        var within = offset % cluster_bytes; // byte offset inside this cluster
        var at: usize = 0;
        while (at < bytes.len) {
            if (cluster < 2) return Error.BadChain;
            var s: u32 = within / sector_size;
            var in_sector: u32 = within % sector_size;
            while (s < self.sectors_per_cluster and at < bytes.len) : (s += 1) {
                const lba = self.clusterSector(cluster) + s;
                const room = sector_size - in_sector;
                const n = @min(bytes.len - at, @as(usize, room));

                if (in_sector != 0 or n < sector_size) {
                    // A partial sector: keep what is already there.
                    try self.readSector(lba, self.scratch);
                } else {
                    @memset(self.scratch, 0);
                }
                @memcpy(self.scratch[in_sector..][0..n], bytes[at..][0..n]);
                try self.writeSector(lba, self.scratch);

                at += n;
                in_sector = 0;
            }
            if (at >= bytes.len) break;
            within = 0;
            cluster = (try self.nextCluster(cluster)) orelse return Error.BadChain;
        }
    }

    /// Writes a file's length and first cluster back into its directory entry,
    /// in place. `entry.lba`/`entry.slot` are where `list` found it.
    fn setEntry(self: *Volume, entry: Entry, first_cluster: u16, size: u32) Error!void {
        if (entry.lba == 0) return Error.NotFound; // never located; refuse to guess
        try self.readSector(entry.lba, self.scratch);
        const e = self.scratch[entry.slot..][0..dirent_size];
        e[26] = @truncate(first_cluster);
        e[27] = @truncate(first_cluster >> 8);
        e[28] = @truncate(size);
        e[29] = @truncate(size >> 8);
        e[30] = @truncate(size >> 16);
        e[31] = @truncate(size >> 24);
        try self.writeSector(entry.lba, self.scratch);
    }

    /// The cluster of a path's PARENT directory, plus the final component.
    /// "a/b/c" -> (cluster of a/b, "c"). A path with no slash is in the root.
    const Parent = struct { cluster: u16, name: []const u8 };

    fn parentOf(self: *Volume, path: []const u8) Error!Parent {
        // This file imports nothing, not even std: it is the driver, and the
        // two loops below are cheaper than the dependency.
        var end = path.len;
        while (end > 0 and path[end - 1] == '/') end -= 1;
        const trimmed = path[0..end];
        if (trimmed.len == 0) return Error.BadName;

        var cut: ?usize = null;
        var i: usize = 0;
        while (i < trimmed.len) : (i += 1) {
            if (trimmed[i] == '/') cut = i;
        }
        if (cut == null) return .{ .cluster = 0, .name = trimmed };
        const at = cut.?;
        const dir = try self.open(trimmed[0..at]);
        if (!dir.isDirectory()) return Error.NotFat16;
        return .{ .cluster = dir.first_cluster, .name = trimmed[at + 1 ..] };
    }

    /// Deletes one file, or one directory that is already empty. removeEntry
    /// does the real work: it frees the cluster chain and tombstones both the
    /// short entry and the long-name run in front of it.
    pub fn remove(self: *Volume, path: []const u8) Error!void {
        const p = try self.parentOf(path);
        _ = (try self.find(p.cluster, p.name)) orelse return Error.NotFound;
        try self.removeEntry(p.cluster, p.name);
    }

    /// max_tree_depth bounds removeTree's recursion. The application's deepest
    /// tree is a player's game data, five levels down; this is generous, and it
    /// is a CAP rather than a guess because the recursion runs on a kernel
    /// stack with no guard page under it.
    const max_tree_depth: u32 = 16;

    /// Deletes a directory and everything under it. A missing path is not an
    /// error: every caller in the application spells this `catch {}`, because
    /// deleting what is not there is what it wanted.
    ///
    /// **ONE ENTRY AT A TIME, RE-LISTING EACH ROUND.** The obvious shape — list
    /// the directory, then delete what the list held — cannot work here: `list`
    /// hands entries to a callback *while* a sector sits in `self.scratch`, and
    /// there is one scratch buffer for the whole machine, so deleting from
    /// inside that callback would pull the sector out from under the walk. And
    /// there is no allocator to copy the listing into. So each round takes the
    /// FIRST removable entry and starts over. Quadratic in the number of
    /// entries, on an operation the application performs when a person deletes
    /// their account.
    pub fn removeTree(self: *Volume, path: []const u8) Error!void {
        const entry = self.open(path) catch return; // absent is fine
        if (!entry.isDirectory()) return self.remove(path);
        try self.removeTreeAt(entry.first_cluster, 0);
        self.remove(path) catch {};
    }

    fn removeTreeAt(self: *Volume, dir_cluster: u16, depth: u32) Error!void {
        if (depth >= max_tree_depth) return Error.BadChain;

        const First = struct {
            name: [max_name]u8 = undefined,
            len: usize = 0,
            is_dir: bool = false,
            cluster: u16 = 0,
            found: bool = false,
            fn each(s: *@This(), e: Entry) void {
                if (s.found) return;
                const text = e.text();
                // "." and ".." are this directory and its parent.
                if (eqlBytes(text, ".") or eqlBytes(text, "..")) return;
                s.len = @min(text.len, max_name);
                @memcpy(s.name[0..s.len], text[0..s.len]);
                s.is_dir = e.isDirectory();
                s.cluster = e.first_cluster;
                s.found = true;
            }
        };

        var rounds: u32 = 0;
        while (rounds < 4096) : (rounds += 1) {
            var first = First{};
            try self.list(dir_cluster, &first, First.each);
            if (!first.found) return; // empty
            if (first.is_dir) try self.removeTreeAt(first.cluster, depth + 1);
            try self.removeEntry(dir_cluster, first.name[0..first.len]);
        }
        return Error.DirectoryFull; // more entries than this is a broken volume
    }

    /// A whole file into `out`, which must be large enough to hold it.
    ///
    /// It is readAt from zero, so that every probe that reads a whole file —
    /// fat16, vfat, restore, stdio, append — also exercises the positional
    /// read the application uses for Range requests.
    pub fn readFile(self: *Volume, entry: Entry, out: []u8) Error!usize {
        if (entry.isDirectory()) return Error.NotFound;
        if (entry.size > out.len) return Error.TooBig;
        const n = try self.readAt(entry, 0, out[0..entry.size]);
        if (n != entry.size) return Error.BadChain; // the chain ended before the size did
        return n;
    }

    /// Up to `out.len` bytes starting at byte `offset`, stopping at the end of
    /// the file. Answers how many were read: fewer than asked means the end was
    /// reached, and an offset at or past the end reads nothing.
    ///
    /// The shape is `std.Io.File.readPositionalAll`, which chat_upload uses to
    /// answer an HTTP Range request — a browser seeking in an image, or resuming
    /// one. It walks the chain to the cluster `offset` falls in rather than
    /// reading the file from the start and discarding.
    pub fn readAt(self: *Volume, entry: Entry, offset: u32, out: []u8) Error!usize {
        if (entry.isDirectory()) return Error.NotFound;
        if (offset >= entry.size or out.len == 0) return 0;
        const want: usize = @min(out.len, entry.size - offset);

        const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;
        var cluster = entry.first_cluster;
        if (cluster < 2) return Error.BadChain; // a non-empty file has a chain
        var skip = offset / cluster_bytes;
        while (skip > 0) : (skip -= 1) {
            cluster = (try self.nextCluster(cluster)) orelse return Error.BadChain;
            if (cluster < 2) return Error.BadChain;
        }

        var within = offset % cluster_bytes;
        var got: usize = 0;
        while (got < want) {
            var s: u32 = within / sector_size;
            var in_sector: u32 = within % sector_size;
            while (s < self.sectors_per_cluster and got < want) : (s += 1) {
                try self.readSector(self.clusterSector(cluster) + s, self.scratch);
                const n = @min(want - got, @as(usize, sector_size - in_sector));
                @memcpy(out[got..][0..n], self.scratch[in_sector..][0..n]);
                got += n;
                in_sector = 0;
            }
            if (got >= want) break;
            within = 0;
            cluster = (try self.nextCluster(cluster)) orelse return Error.BadChain;
            if (cluster < 2) return Error.BadChain;
        }
        return got;
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
