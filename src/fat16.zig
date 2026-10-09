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
//! **WHAT A `Volume` HOLDS IN MEMORY, AND WHOSE COPY IT IS.** The disk is the
//! source of every fact here. Everything a `Volume` holds is reconstructable:
//! the next mount rebuilds it from the disk, and nothing promised lives only
//! here. Each copy has a role, and a rule for when it disagrees with the disk:
//!
//! - the geometry (`fat_start` .. `data_start`, `kind`, `root_cluster`,
//!   `serial`): a cache of the boot sector, read once at `mount`. Nothing on
//!   this machine writes the boot sector, so it cannot go stale.
//! - `fat`, the held FAT: a cache of the FAT's first copy (or of the copy
//!   `cacheFatChecked` weighed cleaner), read whole at mount. Every change is
//!   made in it, written whole-sector to each copy on the disk, and kept only
//!   if the first copy's write is answered. So once mounted it is what the
//!   disk's copies are written FROM: in practice the source of each sector a
//!   change touches (`fatSet`).
//! - `free_clusters`: derived from the FAT. Counted at mount, then moved
//!   entry by entry (`keepCount`); never recounted while the machine runs.
//! - `next_free`: a hint for allocation. Wrong costs a longer search, never
//!   a wrong cluster (`allocChain`).
//! - `fsinfo_unknown`: a cache of one fact about the disk, "FSInfo's hints say
//!   unknown". False at every mount, so each mount writes them once.
//! - `dirs`: a cache of directory sectors, exact or absent: a write that
//!   succeeds updates what it holds, a write that fails drops it.
//! - `scratch`, `dir_burst`, a `Lister`'s sector: buffers in motion. What
//!   they hold means nothing past the operation that filled them.
//!
//! FSInfo's own free count and next-free cluster, on the disk, are hints
//! for other systems. This machine never reads them for its own use.
//!
//! What is still missing: FAT12, and renaming a directory.

const std = @import("std");
const virtio = @import("virtio.zig");
const props = @import("coverage");

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
const civil = @import("civil.zig");

pub const sector_size: u32 = 512;
pub const Error = error{
    NotFat16,
    BadBootSector,
    ReadFailed,
    WriteFailed,
    NotFound,
    TooBig,
    BadChain,
    BadName,
    Full,
    DirectoryFull,
    /// FAT32 with mirroring off (BPB_ExtFlags bit 7): one FAT is live and the
    /// rest stale, and this machine writes every copy (FAT32.md §3).
    NotMirrored,
    /// A FAT32 version this machine does not know (BPB_FSVer is not 0).
    FatVersion,
    /// A FAT32 root cluster outside the data region.
    BadRoot,
    /// A volume that runs past sector 2^32: this machine's sector numbers are
    /// 32 bits (FAT32.md §10).
    VolumeTooLarge,
    /// More clusters than FAT32's 28-bit cluster numbers can name.
    TooManyClusters,
    /// A file asked to replace a directory, which Linux refuses too (EISDIR).
    IsDirectory,
};

/// **WHICH FAT A VOLUME IS**, decided as Microsoft's specification decides
/// it: by its count of clusters, never by what the boot sector calls itself.
/// Fewer than 4,085 is FAT12, which this machine does not take; fewer than
/// 65,525 is FAT16; more is FAT32.
pub const Kind = enum { fat16, fat32 };

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
/// **A CLUSTER NUMBER**, and a FAT entry's value: 32 bits, so that FAT32's
/// 28-bit clusters fit (FAT32.md §1). FAT16's are the low 16.
pub const Cluster = u32;

const chain_end: Cluster = 0xFFF8;
/// The FAT's mark for a cluster the disk cannot hold data in. It is in use,
/// by nothing, and is not a leak.
const bad_cluster: Cluster = 0xFFF7;
/// FAT32's: its entries are 28 bits, so its marks are too.
const fat32_mask: Cluster = 0x0FFF_FFFF;
const fat32_chain_end: Cluster = 0x0FFF_FFF8;
const fat32_bad_cluster: Cluster = 0x0FFF_FFF7;

fn le16(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

fn le32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

/// The longest name this filesystem will hold. VFAT allows 255. The
/// application's longest is 96: `<sid>.reactions.jsonl` at a session id of
/// 80, which it allows (MIGRATION.md). At 64 such a file could be written by
/// Linux and then found here only under its 8.3 alias. A buffer per entry is
/// a buffer on a machine with a bump allocator, so it is the application's
/// longest and no more: 8 long-name parts.
pub const max_name: usize = 96;

/// **A FAT16 DIRECTORY ENTRY CARRIES A DATE, AND THIS MACHINE WRITES IT.**
///
/// It is the only timestamp the format has: two 16-bit fields, packed, with the
/// year counted from 1980 and the seconds counted in TWOS. So a time written
/// here reads back rounded DOWN to an even second, and that is the resolution
/// of everything above — chat's "recent activity" sorts conversations by file
/// modification time, and two messages in the same two seconds sort by name.
///
/// **UTC, and no time zone anywhere.** DOS dates are local time by convention
/// and the Linux VFAT driver applies the mount's `tz` to them; nothing on this
/// machine has a time zone, and the application renders Eastern from a Unix
/// time. So these are UTC, and a Linux mount that wants to agree says `tz=UTC`.
///
/// Out of range is `none` rather than a wrong date: before 1980 there is no
/// representation, and after 2107 the year field wraps.
pub const Dos = struct {
    date: u16,
    time: u16,

    /// No date: what an entry written by something that had no clock carries,
    /// and what `toUnix` reports as zero rather than as 1980.
    pub const none = Dos{ .date = 0, .time = 0 };

    /// The first and last instants the format can hold.
    pub const first_unix: i64 = 315532800; // 1980-01-01T00:00:00Z
    pub const last_unix: i64 = 4354819199; // 2107-12-31T23:59:59Z

    pub fn fromUnix(secs: i64) Dos {
        if (secs < first_unix or secs > last_unix) return none;
        const c = civil.fromUnix(secs);
        const year: u16 = @intCast(c.year - 1980);
        return .{
            .date = year << 9 | @as(u16, c.month) << 5 | c.day,
            .time = @as(u16, c.hour) << 11 | @as(u16, c.minute) << 5 | (@as(u16, c.second) / 2),
        };
    }

    /// Unix seconds, or 0 for an entry with no date. A date field of zero is
    /// what "nobody wrote one" looks like on disk, and answering 1980 for it
    /// would be a timestamp nobody meant.
    pub fn toUnix(self: Dos) i64 {
        if (self.date == 0) return 0;
        const c = civil.Civil{
            .year = @as(i32, self.date >> 9) + 1980,
            .month = @intCast((self.date >> 5) & 0x0F),
            .day = @intCast(self.date & 0x1F),
            .hour = @intCast(self.time >> 11),
            .minute = @intCast((self.time >> 5) & 0x3F),
            .second = @intCast((self.time & 0x1F) * 2),
        };
        // A field can hold month 0, day 0 or hour 31: garbage on the disk must
        // not become a plausible date.
        if (c.month < 1 or c.month > 12) return 0;
        if (c.day < 1 or c.day > civil.daysInMonth(c.year, c.month)) return 0;
        if (c.hour > 23 or c.minute > 59 or c.second > 58) return 0;
        return civil.toUnix(c);
    }
};

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
    first_cluster: Cluster,
    size: u32,
    /// When the file was last written, from the entry's own date fields; 0 when
    /// nothing ever wrote one.
    mtime_unix: i64 = 0,

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

/// What `Volume.check` found wrong with a volume.
pub const Problem = enum {
    /// A chain runs into a free cluster, past the last cluster, or into the
    /// bad-cluster mark (or a directory has no chain at all). `cluster` is
    /// the last one it holds.
    broken,
    /// A chain reaches a cluster another chain holds already, or one earlier
    /// in itself: a cross-link, or a loop. `cluster` is that cluster; the
    /// path is the second chain to reach it.
    crossed,
    /// A file's chain holds fewer clusters than its size needs (`count`).
    short,
    /// A file's chain holds more clusters than its size needs (`count`): the
    /// tail is in use and nothing can reach it.
    long,
    /// `count` clusters from `cluster` are marked in use and nothing holds
    /// them: what a write that stopped part-way leaves behind.
    leaked,
    /// The FAT's copies differ, in `count` sectors; `cluster` is the first
    /// entry that does.
    fats_differ,
    /// "." is not its own directory, or ".." not its parent, or the root
    /// holds either.
    bad_dot,
    /// FAT32's FSInfo says a free count (`count`) that is set and wrong, or
    /// a next-free hint outside the data region (`cluster`): what fsck.fat
    /// reports. Unknown (0xFFFFFFFF) is always right.
    fsinfo,
    /// A directory deeper than the check walks. That is a limit of the
    /// check, not damage: nothing under it was checked, and since what it
    /// holds would look leaked, leaks were not looked for at all.
    too_deep,

    /// **DAMAGE, OR WHAT A STOP LEAVES.** A machine stopped part-way may
    /// leave clusters leaked (a write's), a chain long (an append's), the
    /// FAT's copies apart (`cacheFat` mends them at the next mount), or
    /// FSInfo's count stale; and `too_deep` is the check's limit. The rest
    /// is damage no stop of this driver leaves.
    pub fn damage(p: Problem) bool {
        return switch (p) {
            .broken, .crossed, .short, .bad_dot => true,
            .leaked, .long, .fats_differ, .fsinfo, .too_deep => false,
        };
    }
};

pub const Finding = struct {
    problem: Problem,
    /// Where it was found, from the root ("/data/chat/plan.md"); empty for
    /// the volume as a whole. It points into the checker, so a caller that
    /// keeps it copies it.
    path: []const u8,
    cluster: Cluster = 0,
    count: u32 = 0,
};

/// What `Volume.check` walked, and how many findings it made.
pub const Health = struct {
    files: u32 = 0,
    directories: u32 = 0,
    /// Clusters held by the files and directories walked.
    used: u32 = 0,
    leaked: u32 = 0,
    problems: u32 = 0,

    pub fn clean(self: Health) bool {
        return self.problems == 0;
    }
};

/// **DIRECTORY SECTORS, HELD** (`Volume.dirs`): direct-mapped, one sector a
/// slot, a slot's key the sector's LBA plus one (0: empty). A sector put
/// where another is held replaces it.
pub const DirCache = struct {
    keys: []u32,
    data: []u8,
    hits: u64 = 0,
    misses: u64 = 0,

    fn slot(c: *const DirCache, lba: u32) usize {
        return @as(usize, (lba *% 2654435761) >> 7) % c.keys.len;
    }

    fn at(c: *DirCache, i: usize) *[sector_size]u8 {
        return c.data[i * sector_size ..][0..sector_size];
    }

    /// The sector at `lba`, if held.
    pub fn get(c: *DirCache, lba: u32) ?*[sector_size]u8 {
        const i = c.slot(lba);
        if (c.keys[i] == lba +% 1) {
            c.hits += 1;
            return c.at(i);
        }
        c.misses += 1;
        return null;
    }

    fn put(c: *DirCache, lba: u32, bytes: *const [sector_size]u8) void {
        const i = c.slot(lba);
        c.keys[i] = lba +% 1;
        @memcpy(c.at(i), bytes);
    }

    /// Copies `n` sectors from `lba` into `out` if every one is held.
    fn copyOut(c: *DirCache, lba: u32, n: u32, out: []u8) bool {
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const i = c.slot(lba + k);
            if (c.keys[i] != lba + k +% 1) {
                c.misses += 1;
                return false;
            }
        }
        k = 0;
        while (k < n) : (k += 1) @memcpy(out[k * sector_size ..][0..sector_size], c.at(c.slot(lba + k)));
        c.hits += 1;
        return true;
    }

    /// `n` sectors from `lba` were written from `from`: each one held is
    /// what was written now.
    fn wrote(c: *DirCache, lba: u32, n: u32, from: [*]const u8) void {
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const i = c.slot(lba + k);
            if (c.keys[i] == lba + k +% 1) @memcpy(c.at(i), from[k * sector_size ..][0..sector_size]);
        }
    }

    /// `n` sectors from `lba` are no longer known: a write to them failed.
    fn drop(c: *DirCache, lba: u32, n: u32) void {
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const i = c.slot(lba + k);
            if (c.keys[i] == lba + k +% 1) c.keys[i] = 0;
        }
    }
};

pub const Volume = struct {
    blk: *virtio.Block,

    /// **WHERE THE DATES ON THIS VOLUME COME FROM.** The filesystem has no
    /// clock of its own and must not invent one, so the host hands it the
    /// machine's: io.zig points this at the wall clock once the RTC has been
    /// read. It answers null until then — a probe kernel that never sets a
    /// clock writes entries with no date rather than a plausible wrong one.
    clock: ?*const fn () ?i64 = null,
    /// One sector of identity-mapped scratch, which the device writes into.
    /// **IN MOTION, NOT A COPY**: one operation's sector at a time, never read
    /// for what an earlier operation left in it.
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
    kind: Kind = .fat16,
    /// FAT32's root is a chain, from here. Cluster 0 still means "the root"
    /// everywhere in this file's API, as a `..` entry spells it on both kinds;
    /// `dirStart` turns it into this.
    root_cluster: Cluster = 0,
    /// FAT32's FSInfo sector, and the backup boot sector (its FSInfo copy is
    /// the sector after it), relative to the volume.
    fsinfo_sector: u32 = 0,
    backup_boot: u32 = 0,
    /// Whether this mount has marked FSInfo's free count and next-free hint
    /// unknown yet: done on the first change to the FAT (FAT32.md §7).
    /// **A CACHE OF A FACT ON THE DISK**, set only once both FSInfo writes have
    /// landed, and never re-read: nothing else on this machine writes FSInfo.
    /// Lost, it is false again at the next mount, which writes FSInfo once more.
    fsinfo_unknown: bool = false,
    /// The highest cluster number the data region holds.
    max_cluster: Cluster,
    /// **HOW MANY CLUSTERS ARE FREE, KEPT** (QUEUE.md item 14): counted once
    /// at mount, then moved by `fatSet`, the one place a FAT entry changes,
    /// whenever an entry goes from free to used or back. So every path that
    /// takes or gives back clusters keeps it, the failure paths included, and
    /// `space` is a field read instead of a walk of the FAT per request.
    ///
    /// **ONE COPY OF A VOLUME WRITES.** A `Volume` is a value, and its copies
    /// share the held FAT (a slice) but not this count. So two copies that
    /// both wrote would each count only their own writes. On this machine
    /// only io.zig's copy writes once it has one (`mount`, `keepData`).
    ///
    /// **DERIVED, AND STORED.** Its source is the FAT; mount derives it, and
    /// from then on it is moved, not re-derived: `countFreeAgain` recounts,
    /// and only the tests and simulators call it. A count gone wrong stays
    /// wrong until the next mount derives it again.
    free_clusters: u32 = 0,
    /// **WHERE THE NEXT ALLOCATION STARTS LOOKING** (FAT32.md §8). Every
    /// cluster below it is in use: it starts at 2, moves only past clusters
    /// an allocation took or found taken, and moves back to any cluster
    /// `freeChain` gives back. So the first free cluster from here is the
    /// first free cluster on the volume, the one a search from 2 would find,
    /// and allocation chooses exactly what it chose before, without
    /// re-reading every entry below on each small file. On FAT32's millions
    /// of clusters that scan is the cost.
    ///
    /// **A HINT.** Allocation reads the FAT at every candidate, so a cursor
    /// past a free cluster costs only the choice: a cluster further on, or a
    /// wrap. 2 at every mount.
    next_free: Cluster = 2,
    /// **CLEANUPS AFTER A COMMIT THAT FAILED** (metal-vmm QUEUE 131,
    /// kernel-facts #3 and #6): a chain given back, or a long name's parts
    /// cleared, once the one write that decides the operation was asked.
    /// The operation is done; what was not cleaned is a leak the boot's
    /// check reports and the box's #4 reclaims. Counted here, said by a
    /// property, never swallowed and never the operation's error.
    cleanups_failed: u64 = 0,
    /// **A RESERVE FOR SMALL WRITES** (metal-vmm QUEUE 132, Steve 2026-10-09:
    /// "a little breathing room for emergencies"): clusters an allocation of
    /// more than `small_clusters` may not take. 64 MiB of clusters, or a
    /// sixteenth of a volume too small for that, set at mount. A bulk write
    /// (an upload, a long append) is refused `Full` first, while small
    /// records, a directory's growth and a replace's second chain still go,
    /// and a remove always does. The kernel decides by size alone, so the
    /// application needs no policy.
    reserve_clusters: u32 = 0,
    /// Writes of a FAT copy past the first that failed (`copyApart`).
    fat_copies_failed: u64 = 0,
    /// **WHICH VOLUME THIS IS**: the serial number mkfs chose at random when it
    /// formatted it (the extended boot record's volume ID, offset 39), or null
    /// on a boot sector without one. Linux's `blkid` shows it as the UUID,
    /// `92DE-8831`, high half first.
    serial: ?u32 = null,

    /// **THE FAT, HELD IN MEMORY**, once the host has given it somewhere to
    /// live. Without it every FAT lookup is a device read — and a soak of
    /// five thousand chat requests showed what that costs: the free-cluster
    /// search starts at cluster 2 every time, so every small file replaced
    /// walked past every cluster the growing transcript held, one block read
    /// apiece, and the machine's own time to answer rose from 10 ms to over
    /// 150 ms while nothing about the request changed. Held here, a lookup is a
    /// memory read and a set is a memory write plus one sector per FAT copy.
    ///
    /// Null is still a working volume: the probes that judge the uncached path
    /// leave it that way.
    ///
    /// **A CACHE OF THE FAT THAT THE DISK'S COPIES ARE WRITTEN FROM.** Read at
    /// mount from the copy `cacheFatChecked` trusts, it is never read from the
    /// disk again while the machine runs: a lookup answers from it alone. A
    /// change is made here first and written as the whole held sector to every
    /// copy (`fatSet`), so a sector of it that is wrong is written over the
    /// disk's at the next change to that sector. Lost, the next mount reads
    /// and weighs the copies again.
    fat: ?[]u8 = null,

    /// **WHERE `find` READS A DIRECTORY, MANY SECTORS AT A REQUEST**, once the
    /// host has given it memory: a whole multiple of the sector, and
    /// identity-mapped, since the device writes it. Without it a lookup reads
    /// a directory a sector per request, and a picture six directories deep on
    /// a droplet's volume (32 KB clusters, network storage) took about 290
    /// requests to find before its 64 of data were read (QUEUE.md item 90).
    /// Only `find` uses it: nothing writes while a lookup reads, so a burst it
    /// has read cannot go stale under it. A listing the application holds
    /// open keeps its sector of its own (`Lister`).
    dir_burst: ?[]u8 = null,

    /// **DIRECTORY SECTORS HELD IN MEMORY** (`cacheDirs`), once the host has
    /// given it memory. A chat message touches five or six files, each
    /// found folder by folder; with only the burst, a send cost about 400
    /// sector reads, and a droplet's volume answered each in 3 to 5 ms
    /// (2026-10-07: sends of a second, Recent of three). Held here, a lookup
    /// that has been made before reads memory.
    ///
    /// **WHAT IT HOLDS IS ALWAYS THE DISK'S**: a directory read puts its
    /// sectors here, every sector read looks here first, and every write
    /// that succeeds updates the copy of each sector it wrote, so a sector
    /// held is the sector on the disk whoever wrote it (a directory's
    /// cluster freed and given to a file included). A write that fails drops
    /// its sectors, since what the disk holds then is not known.
    ///
    /// **A CACHE: EXACT, OR ABSENT.** Never written back; a slot replaced or
    /// dropped is read from the disk again when next asked for. Holding it
    /// exact needs every write to go through `writeSector`/`writeSectors`,
    /// and every one in this file does. `readSectors` neither looks here nor
    /// puts here (a `Lister` does both around it), which is safe because what
    /// is held is exact.
    dirs: ?DirCache = null,

    /// Holds directory sectors in `keys.len` slots of `data` from now on
    /// (`dirs`). `data` is `keys.len` sectors.
    pub fn cacheDirs(self: *Volume, keys: []u32, data: []u8) void {
        std.debug.assert(data.len == keys.len * sector_size and keys.len > 0);
        @memset(keys, 0);
        self.dirs = .{ .keys = keys, .data = data };
    }

    /// How much memory `cacheFat` needs: one copy of the FAT.
    pub fn fatBytes(self: *const Volume) usize {
        return @as(usize, self.sectors_per_fat) * sector_size;
    }

    /// What `cacheFatChecked` found of the FAT's copies.
    pub const Mirrors = struct {
        /// Sectors of a copy written to bring it into line with the other.
        repaired: u32 = 0,
        /// The copy the other was brought into line with: 0, the first,
        /// unless the second checked cleaner.
        trusted: u32 = 0,
        /// Whether the copies differed and each was checked, and what the
        /// check found with each: problems, then leaked clusters.
        checked: bool = false,
        health: [2]Health = .{ .{}, .{} },
        /// The copies differed and could not be weighed (the check failed):
        /// the first is held, neither was written.
        unweighed: bool = false,
        /// The copies differed and checked alike: the first is held, and
        /// neither is written over, since nothing says which is right.
        ///
        /// Here and when `unweighed`, **NEITHER IS WRITTEN AT MOUNT, NOT FOR
        /// THE REST OF THE BOOT**: the first change to an entry in a sector
        /// that differs writes the held sector, the first copy's, whole over
        /// the second (`fatSet`).
        tied: bool = false,
        /// The disk refused a repair's write: the mount goes on with the FAT
        /// held, and the copies are as far apart as the writes left them.
        repair_failed: bool = false,
    };

    /// The most differing sectors that are weighed copy against copy; past
    /// it the first copy is the FAT, as before the choice was made.
    pub const max_weighed_sectors = 64;

    /// `cacheFatChecked` without a check: the first copy is the FAT.
    pub fn cacheFat(self: *Volume, buf: []u8) Error!u32 {
        return (try self.cacheFatChecked(buf, null)).repaired;
    }

    /// Reads the FAT into `buf` and uses it from then on, and brings its
    /// copies into line where they differ.
    ///
    /// **COPIES APART ARE BROUGHT INTO LINE, NOT REFUSED.** Every change here
    /// writes the first copy, then the others (`fatSet`), so a machine
    /// stopped between the two leaves them apart by a sector. Refusing such a
    /// volume stopped the boot, and the machine could never boot again
    /// (QUEUE.md item 80). From here a change is written to each copy as the
    /// whole held sector, so a copy left apart would be overwritten
    /// piecemeal anyway, saying nothing; the count is the caller's to report.
    ///
    /// `buf` must be identity-mapped, because the device writes FAT sectors
    /// straight out of it.
    ///
    /// **WHICH COPY IS THE FAT** (B26, Steve 2026-10-08). Where the copies
    /// differ, and `seen` is given (room for `check`), the volume is checked
    /// with each copy's sectors, and the copy with fewer problems, then fewer
    /// leaked clusters, is the FAT; the other is written from it. A tie is
    /// the first copy. A machine stopped between the copies' writes leaves
    /// them apart, and the check keeps whichever agrees with the directories;
    /// a sector of the first copy that reads wrong (silent rot) is no longer
    /// written over the good one. More than `max_weighed_sectors` differing
    /// is the first copy, unweighed.
    pub fn cacheFatChecked(self: *Volume, buf: []u8, seen: ?[]u8) Error!Mirrors {
        if (buf.len < self.fatBytes()) {
            props.reachable(@src(), "fat: a FAT cache buffer too small for the FAT is refused", null);
            return Error.TooBig;
        }
        const fat = buf[0..self.fatBytes()];
        try self.readSectors(self.fat_start, self.sectors_per_fat, fat.ptr);
        // The other copies are compared in runs, not a sector at a time: a
        // FAT32 FAT of 12.5 MiB is 25,600 sectors (FAT32.md §9).
        var run: [run_sectors * sector_size]u8 align(16) = undefined;
        var differ: [max_weighed_sectors]u32 = undefined;
        var n_differ: usize = 0;
        var too_many = false;
        var copy: u32 = 1;
        while (copy < self.num_fats) : (copy += 1) {
            var s: u32 = 0;
            while (s < self.sectors_per_fat) {
                const n = @min(run_sectors, self.sectors_per_fat - s);
                try self.readSectors(self.fat_start + copy * self.sectors_per_fat + s, n, &run);
                var k: u32 = 0;
                while (k < n) : (k += 1) {
                    if (std.mem.eql(u8, run[k * sector_size ..][0..sector_size], fat[(s + k) * sector_size ..][0..sector_size])) continue;
                    if (n_differ == differ.len) too_many = true else {
                        differ[n_differ] = s + k;
                        n_differ += 1;
                    }
                }
                s += n;
            }
        }
        self.fat = fat;
        var m: Mirrors = .{};
        if (n_differ == 0) return m;
        if (too_many) {
            props.reachable(@src(), "fat: more FAT sectors differ than are weighed, and the first copy is the FAT", null);
            const n = self.mirrorFirst(fat, &run) catch {
                repairRefused();
                return .{ .repair_failed = true };
            };
            return .{ .repaired = n };
        }
        // The second copy's version of each differing sector, kept to weigh.
        var second: [max_weighed_sectors][sector_size]u8 = undefined;
        for (differ[0..n_differ], 0..) |at, i| try self.readSector(self.fat_start + self.sectors_per_fat + at, &second[i]);
        if (seen) |room| {
            // **A WEIGHING THAT CANNOT RUN LEAVES THE CHOICE UNMADE** (CC,
            // metal-vmm QUEUE 103): the check reads every directory, and one
            // that fails to read would fail the mount, where copies apart
            // used to mount. The first copy is held, and neither is written
            // over, so the second, perhaps the good one, is there for a boot
            // that can weigh.
            const first_health = self.check(room, {}, ignoreFinding) catch {
                unweighed();
                return .{ .unweighed = true };
            };
            m.health[0] = first_health;
            var first: [max_weighed_sectors][sector_size]u8 = undefined;
            for (differ[0..n_differ], 0..) |at, i| {
                const held = fat[at * sector_size ..][0..sector_size];
                first[i] = held.*;
                held.* = second[i];
            }
            m.health[1] = self.check(room, {}, ignoreFinding) catch {
                for (differ[0..n_differ], 0..) |at, i| fat[at * sector_size ..][0..sector_size].* = first[i];
                unweighed();
                return .{ .unweighed = true };
            };
            m.checked = true;
            const better = m.health[1].problems < m.health[0].problems or
                (m.health[1].problems == m.health[0].problems and m.health[1].leaked < m.health[0].leaked);
            if (better) {
                props.reachable(@src(), "fat: the second FAT copy checks cleaner than the first, and is the FAT", null);
                m.trusted = 1;
                // The kept free count was the first copy's (mount counts it):
                // it moves with every entry the second copy changed.
                const per = self.entriesPerSector();
                for (differ[0..n_differ], 0..) |at, i| {
                    var e: u32 = 0;
                    while (e < per) : (e += 1) {
                        const c = at * per + e;
                        if (c < 2 or c > self.max_cluster) continue;
                        const was = self.entryIn(&first[i], e);
                        const now = self.entryIn(&second[i], e);
                        if (was == 0 and now != 0) self.free_clusters -|= 1;
                        if (was != 0 and now == 0) self.free_clusters += 1;
                    }
                }
            } else {
                for (differ[0..n_differ], 0..) |at, i| fat[at * sector_size ..][0..sector_size].* = first[i];
                // **A TIE WRITES NEITHER** (the night of 2026-10-08, seed
                // 16341): a first copy that read wrong but checked as well
                // as the second was written over the good one, and the disk
                // left differing where it had not.
                if (m.health[0].problems == m.health[1].problems and m.health[0].leaked == m.health[1].leaked) {
                    props.reachable(@src(), "fat: FAT copies apart check alike, and neither is written over", null);
                    m.tied = true;
                    return m;
                }
            }
        }
        // The copy not trusted is written from the held FAT, sector by sector.
        // **A REPAIR THE DISK REFUSES DOES NOT STOP THE MOUNT** (the night of
        // 2026-10-08, seed 18771: one refused write, and the boot stopped):
        // the FAT is held either way, and later changes write each sector
        // they touch to every copy.
        const into = if (m.trusted == 0) self.fat_start + self.sectors_per_fat else self.fat_start;
        for (differ[0..n_differ]) |at| {
            self.writeSector(into + at, fat[at * sector_size ..][0..sector_size]) catch {
                repairRefused();
                m.repair_failed = true;
                return m;
            };
            m.repaired += 1;
        }
        return m;
    }

    /// Every other copy written from the first where they differ.
    fn mirrorFirst(self: *Volume, fat: []u8, run: *[run_sectors * sector_size]u8) Error!u32 {
        var repaired: u32 = 0;
        var copy: u32 = 1;
        while (copy < self.num_fats) : (copy += 1) {
            var s: u32 = 0;
            while (s < self.sectors_per_fat) {
                const n = @min(run_sectors, self.sectors_per_fat - s);
                const at = self.fat_start + copy * self.sectors_per_fat + s;
                try self.readSectors(at, n, run);
                var k: u32 = 0;
                while (k < n) : (k += 1) {
                    const first = fat[(s + k) * sector_size ..][0..sector_size];
                    if (std.mem.eql(u8, run[k * sector_size ..][0..sector_size], first)) continue;
                    try self.writeSector(at + k, first);
                    repaired += 1;
                }
                s += n;
            }
        }
        return repaired;
    }

    fn ignoreFinding(_: void, _: Finding) void {}

    /// One coverage site for every repair write the disk refused.
    fn repairRefused() void {
        props.reachable(@src(), "fat: a repair of the FAT's copies is refused by the disk, and the mount goes on", null);
    }

    /// One coverage site for both checks of a weighing that could not run.
    fn unweighed() void {
        props.reachable(@src(), "fat: FAT copies apart cannot be weighed (the check failed), and neither is written over", null);
    }

    /// Reads the boot sector and works out where everything is.
    ///
    /// **A BOOT SECTOR IS NOT TRUSTED.** Every field it names is checked before
    /// it is used to compute an offset, because a sector of zeros or of someone
    /// else's filesystem would otherwise send reads anywhere.
    pub fn mount(blk: *virtio.Block, scratch: *[sector_size]u8, start_lba: u32) Error!Volume {
        if (blk.read(start_lba, @intFromPtr(scratch)) != virtio.blk_s_ok) {
            props.reachable(@src(), "fat: a mount cannot read the boot sector", null);
            return Error.ReadFailed;
        }
        const b = scratch.*;

        if (b[510] != 0x55 or b[511] != 0xAA) {
            props.reachable(@src(), "fat: a mount refuses a sector without the boot signature", null);
            return Error.BadBootSector;
        }

        const bytes_per_sector = le16(b[11..13]);
        const sectors_per_cluster: u32 = b[13];
        const reserved: u32 = le16(b[14..16]);
        const num_fats: u32 = b[16];
        const root_entries: u32 = le16(b[17..19]);
        const fat16_sectors: u32 = le16(b[22..24]);
        const sectors_per_fat: u32 = if (fat16_sectors != 0) fat16_sectors else le32(b[36..40]);
        var total: u32 = le16(b[19..21]);
        if (total == 0) total = le32(b[32..36]);

        if (bytes_per_sector != sector_size) {
            props.reachable(@src(), "fat: a mount refuses sectors that are not 512 bytes", null);
            return Error.NotFat16;
        }
        if (sectors_per_cluster == 0 or sectors_per_cluster > 128) {
            props.reachable(@src(), "fat: a mount refuses a cluster size no volume has", null);
            return Error.BadBootSector;
        }
        if (reserved == 0 or num_fats == 0 or num_fats > 2) {
            props.reachable(@src(), "fat: a mount refuses no reserved sectors, or a count of FATs it does not keep", null);
            return Error.BadBootSector;
        }
        if (sectors_per_fat == 0) {
            props.reachable(@src(), "fat: a mount refuses a FAT of no sectors", null);
            return Error.BadBootSector;
        }
        // Sector numbers here are 32 bits, the volume's own and the disk's.
        if (@as(u64, start_lba) + total > 0xFFFF_FFFF) {
            props.reachable(@src(), "fat: a mount refuses a volume past 32-bit sectors", null);
            return Error.VolumeTooLarge;
        }

        const fats = std.math.mul(u32, num_fats, sectors_per_fat) catch {
            props.reachable(@src(), "fat: a mount refuses FATs whose total size overflows", null);
            return Error.BadBootSector;
        };
        const root_start = std.math.add(u32, reserved, fats) catch {
            props.reachable(@src(), "fat: a mount refuses reserved sectors and FATs whose sum overflows", null);
            return Error.BadBootSector;
        };
        const root_sectors = (root_entries * dirent_size + sector_size - 1) / sector_size;
        const data_start = root_start + root_sectors;
        if (total == 0 or data_start >= total) {
            props.reachable(@src(), "fat: a mount refuses a volume with no data region", null);
            return Error.BadBootSector;
        }

        // The kind is how many clusters the data region holds, not anything
        // the boot sector says about itself.
        const clusters = (total - data_start) / sectors_per_cluster;
        if (clusters < 4085) {
            props.reachable(@src(), "fat: a mount refuses a volume too small for FAT16", null);
            return Error.NotFat16;
        }
        const kind: Kind = if (clusters < 65525) .fat16 else .fat32;
        // **FAT32'S CLUSTER NUMBERS ARE 28 BITS**, and from 0x0FFFFFF7 up they
        // are marks (a bad cluster, the end of a chain). A volume with more
        // clusters than numbers below the marks would have chains that end
        // where they should go on. Refused, rather than read as far as the
        // disk lets it (QUEUE.md item 69).
        if (kind == .fat32 and clusters > 0x0FFF_FFF5) {
            props.reachable(@src(), "fat: a mount refuses a FAT32 volume with more clusters than its numbers", null);
            return Error.TooManyClusters;
        }
        var root_cluster: Cluster = 0;
        switch (kind) {
            .fat16 => if (root_entries == 0) {
                props.reachable(@src(), "fat: a mount refuses a FAT16 root of no entries", null);
                return Error.BadBootSector;
            },
            .fat32 => {
                // FAT32's own fields, checked like every other (FAT32.md §3).
                if (root_entries != 0 or fat16_sectors != 0) {
                    props.reachable(@src(), "fat: a mount refuses FAT32 with FAT16's fields set", null);
                    return Error.BadBootSector;
                }
                if (le16(b[40..42]) & 0x80 != 0) {
                    props.reachable(@src(), "fat: a mount refuses a FAT32 volume that is not mirrored", null);
                    return Error.NotMirrored;
                }
                if (le16(b[42..44]) != 0) {
                    props.reachable(@src(), "fat: a mount refuses a FAT32 version it does not know", null);
                    return Error.FatVersion;
                }
                root_cluster = le32(b[44..48]);
                if (root_cluster < 2 or root_cluster > clusters + 1) {
                    props.reachable(@src(), "fat: a mount refuses a FAT32 root outside the data", null);
                    return Error.BadRoot;
                }
            },
        }
        // A FAT too short for the clusters it describes would have `fatGet`
        // read past its end, into the next copy or the root.
        const entry_bytes: u32 = if (kind == .fat32) 4 else 2;
        if (@as(u64, sectors_per_fat) * (sector_size / entry_bytes) < @as(u64, clusters) + 2) {
            props.reachable(@src(), "fat: a mount refuses a FAT too short for its clusters", null);
            return Error.BadBootSector;
        }

        var vol: Volume = .{
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
            .kind = kind,
            .root_cluster = root_cluster,
            .fsinfo_sector = if (kind == .fat32) le16(b[48..50]) else 0,
            .backup_boot = if (kind == .fat32) le16(b[50..52]) else 0,
            // 0x29 says the extended boot record, and with it the serial, is
            // there: at 38 on FAT16, at 66 on FAT32.
            .serial = switch (kind) {
                .fat16 => if (b[38] == 0x29) le32(b[39..43]) else null,
                .fat32 => if (b[66] == 0x29) le32(b[67..71]) else null,
            },
        };
        vol.free_clusters = try vol.countFree();
        vol.reserve_clusters = @min(reserve_bytes / (vol.sectors_per_cluster * sector_size), (vol.max_cluster - 1) / 16);
        return vol;
    }

    /// Free clusters, counted in the first FAT on the disk a sector at a
    /// time: `sectors_per_fat` reads, not one per cluster.
    fn countFree(self: *Volume) Error!u32 {
        var free: u32 = 0;
        const per = self.entriesPerSector();
        var run: [run_sectors * sector_size]u8 align(16) = undefined;
        var s: u32 = 0;
        while (s < self.sectors_per_fat) {
            const n = @min(run_sectors, self.sectors_per_fat - s);
            try self.readSectors(self.fat_start + s, n, &run);
            var i: u32 = 0;
            while (i < n * per) : (i += 1) {
                const c = s * per + i;
                if (c < 2) continue;
                if (c > self.max_cluster) return free;
                if (self.entryIn(&run, i) == 0) free += 1;
            }
            s += n;
        }
        return free;
    }

    /// How many sectors a FAT is read in at a time, where it is read whole:
    /// a buffer of this many on the stack.
    const run_sectors = 64;

    /// Bytes a FAT entry takes: 2 on FAT16, 4 on FAT32.
    fn entryBytes(self: *const Volume) u32 {
        return if (self.kind == .fat32) 4 else 2;
    }

    fn entriesPerSector(self: *const Volume) u32 {
        return sector_size / self.entryBytes();
    }

    /// The `i`th FAT entry in a sector of the FAT: its value, which on FAT32
    /// is the low 28 bits (the top four are reserved).
    fn entryIn(self: *const Volume, sector: []const u8, i: u32) Cluster {
        return switch (self.kind) {
            .fat16 => le16(sector[i * 2 ..][0..2]),
            .fat32 => le32(sector[i * 4 ..][0..4]) & fat32_mask,
        };
    }

    /// The first value that ends a chain, on this kind.
    fn chainEndValue(self: *const Volume) Cluster {
        return if (self.kind == .fat32) fat32_chain_end else chain_end;
    }

    /// What a chain's last entry is written as.
    fn endMark(self: *const Volume) Cluster {
        return if (self.kind == .fat32) 0x0FFF_FFFF else 0xFFFF;
    }

    fn badMark(self: *const Volume) Cluster {
        return if (self.kind == .fat32) fat32_bad_cluster else bad_cluster;
    }

    /// The cluster a directory starts at: on FAT32, cluster 0 (the root, as
    /// this file's API and a `..` entry spell it) is `root_cluster`.
    fn dirStart(self: *const Volume, dir_cluster: Cluster) Cluster {
        return if (dir_cluster == 0 and self.kind == .fat32) self.root_cluster else dir_cluster;
    }

    /// An entry decoded, with FAT32's high cluster half (bytes 20..22). On
    /// FAT16 those bytes belonged to OS/2's extended attributes, and are not a
    /// cluster.
    fn entryFrom(self: *const Volume, e: []const u8) Entry {
        var entry = decode(e);
        if (self.kind == .fat32) {
            entry.first_cluster |= @as(Cluster, le16(e[20..22])) << 16;
            if (entry.first_cluster > 0xFFFF) props.reachable(@src(), "fat: a FAT32 entry's first cluster is past 65535", null);
        }
        return entry;
    }

    fn readSector(self: *Volume, lba: u32, into: *[sector_size]u8) Error!void {
        if (self.dirs) |*c| if (c.get(lba)) |held| {
            @memcpy(into, held);
            return;
        };
        if (self.blk.read(self.start_lba + lba, @intFromPtr(into)) != virtio.blk_s_ok) {
            props.reachable(@src(), "fat: a sector read fails", null);
            return Error.ReadFailed;
        }
    }

    /// `count` whole sectors straight into `into`, in as few requests as the
    /// driver allows. `into` must be identity-mapped, which on this machine
    /// everything is: the device writes it directly.
    fn readSectors(self: *Volume, lba: u32, count: u32, into: [*]u8) Error!void {
        var done: u32 = 0;
        while (done < count) {
            const n = @min(count - done, virtio.Block.max_sectors);
            const status = self.blk.readMany(self.start_lba + lba + done, @intFromPtr(into + done * sector_size), n);
            if (status != virtio.blk_s_ok) {
                props.reachable(@src(), "fat: a run of sectors fails to read", null);
                return Error.ReadFailed;
            }
            done += n;
        }
    }

    /// The sector a cluster starts at. Cluster numbering starts at 2, which is
    /// the oldest off-by-two in computing.
    fn clusterSector(self: *Volume, cluster: Cluster) u32 {
        return self.data_start + (@as(u32, cluster) - 2) * self.sectors_per_cluster;
    }

    /// The next cluster in a chain, or null at its end.
    ///
    /// **A LINK PAST THE LAST CLUSTER IS A BROKEN CHAIN**, not a cluster: the
    /// FAT has no entry for it (a held FAT would be indexed past its end) and
    /// `clusterSector` would put it past the volume, where a write lands on
    /// whatever the disk holds next. That includes 0xFFF7, the bad-cluster
    /// mark, which nothing should be chained through.
    fn nextCluster(self: *Volume, cluster: Cluster) Error!?Cluster {
        const v = try self.fatGet(cluster);
        if (v >= self.chainEndValue()) return null;
        if (!self.inData(v)) {
            props.reachable(@src(), "fat: a chain leads outside the data area", null);
            return Error.BadChain;
        }
        return v;
    }

    /// A cluster the data region holds: 2 to `max_cluster`.
    fn inData(self: *const Volume, cluster: Cluster) bool {
        return cluster >= 2 and cluster <= self.max_cluster;
    }

    /// **A CHAIN THAT COMES BACK TO A CLUSTER IT PASSED GOES ROUND FOR EVER**:
    /// a FAT damaged into a loop would hang every walk along it. A walk hands
    /// each cluster it reaches to `pass`, which answers BadChain once the
    /// chain has repeated one.
    ///
    /// It is Brent's cycle finding, in four words of state: remember one
    /// cluster, and remember a later one each time the steps since reach the
    /// next power of two. A loop is found within about two laps of it, so a
    /// looped directory hands out each name at most a few times before its
    /// listing fails, not once for every cluster on the volume.
    const Loop = struct {
        /// The cluster remembered. Zero is never in a chain.
        seen: Cluster = 0,
        power: u32 = 1,
        steps: u32 = 0,

        fn pass(self: *Loop, cluster: Cluster) Error!void {
            if (cluster == self.seen) {
                props.reachable(@src(), "fat: a chain that loops is refused", null);
                return Error.BadChain;
            }
            self.steps += 1;
            if (self.steps == self.power) {
                self.seen = cluster;
                self.power *= 2;
                self.steps = 0;
            }
        }
    };

    /// Where a directory's next sector is. The root is a fixed run outside the
    /// data region; everything else is a cluster chain. Keeping the difference
    /// in one place is what lets `list`, `slotFor` and `grow` all work on
    /// either.
    const Walk = struct {
        vol: *Volume,
        root: bool,
        cluster: Cluster,
        lba: u32,
        left_in_root: u32,
        in_cluster: u32 = 0,
        /// So that a looped chain ends the walk.
        loop: Loop = .{},

        fn start(vol: *Volume, dir_cluster: Cluster) Error!Walk {
            // FAT32's root is a chain like any other directory's.
            const first = vol.dirStart(dir_cluster);
            if (first != 0 and !vol.inData(first)) {
                props.reachable(@src(), "fat: a directory's first cluster is outside the data", null);
                return Error.BadChain;
            }
            return .{
                .vol = vol,
                .root = first == 0,
                .cluster = first,
                .lba = if (first == 0) vol.root_start else vol.clusterSector(first),
                .left_in_root = vol.root_sectors,
                // As `pass(first)` leaves it.
                .loop = .{ .seen = first, .power = 2 },
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
            try self.loop.pass(self.cluster);
            self.lba = self.vol.clusterSector(self.cluster);
            self.in_cluster = 0;
            return true;
        }

        /// The sectors from this one to the end of its stretch of disk: the
        /// rest of the cluster, or the rest of FAT16's fixed root.
        fn sectorsLeftInRun(self: *const Walk) u32 {
            return if (self.root) self.left_in_root else self.vol.sectors_per_cluster - self.in_cluster;
        }
    };

    /// **A DIRECTORY, ONE ENTRY AT A TIME**, from a sector of its own: what
    /// io.zig's directory iterator hands the application. It used to be
    /// `list` into a fixed array of 256 entries, and a directory past that
    /// stopped the machine. The application makes such folders: a player may
    /// keep 500 game sessions (angry-gopher's game_limits.zig), and nothing
    /// bounds how many players there are. A cursor has no ceiling, and its
    /// memory is one sector and one long name, however long the directory.
    ///
    /// Its sector is its own, not `scratch`, so whatever the volume does
    /// between two `next` calls cannot change what it is reading. What the
    /// directory itself holds is read as it is reached: an entry written
    /// meanwhile, past where the cursor is, is seen.
    pub const Lister = struct {
        walk: Walk,
        sector: [sector_size]u8 = undefined,
        at: usize = 0,
        loaded: bool = false,
        done: bool = false,
        // A long name arrives before its entry, in reverse order, so it is
        // collected here and handed over with the short entry that closes it.
        long: [max_name]u8 = undefined,
        long_len: usize = 0,
        long_sum: u8 = 0,
        long_ok: bool = false,
        /// Set by `find` alone (the volume's `dir_burst`): sectors are read
        /// up to a stretch at a time, and `burst_n` of them from `burst_lba`
        /// are held.
        burst: ?[]u8 = null,
        burst_lba: u32 = 0,
        burst_n: u32 = 0,

        /// Reads the walk's sector, unless the burst already holds it; the
        /// volume's directory cache answers what it holds, and keeps what is
        /// read (`Volume.dirs`).
        fn load(self: *Lister) Error!void {
            const vol = self.walk.vol;
            const lba = self.walk.lba;
            const b = self.burst orelse {
                try vol.readSector(lba, &self.sector);
                if (vol.dirs) |*c| c.put(lba, &self.sector);
                return;
            };
            if (lba >= self.burst_lba and lba < self.burst_lba + self.burst_n) return;
            const n = @min(@as(u32, @intCast(b.len / sector_size)), self.walk.sectorsLeftInRun());
            self.burst_lba = lba;
            self.burst_n = n;
            if (vol.dirs) |*c| if (c.copyOut(lba, n, b)) return;
            self.burst_n = 0;
            try vol.readSectors(lba, n, b.ptr);
            self.burst_n = n;
            if (vol.dirs) |*c| {
                var k: u32 = 0;
                while (k < n) : (k += 1) c.put(lba + k, b[k * sector_size ..][0..sector_size]);
            }
        }

        /// The walk's sector, as `load` left it.
        fn current(self: *Lister) *const [sector_size]u8 {
            const b = self.burst orelse return &self.sector;
            return b[(self.walk.lba - self.burst_lba) * sector_size ..][0..sector_size];
        }

        /// The next real entry, or null at the directory's end.
        pub fn next(self: *Lister) Error!?Entry {
            while (!self.done) {
                if (!self.loaded) {
                    try self.load();
                    self.loaded = true;
                    self.at = 0;
                }
                const sector = self.current();
                while (self.at + dirent_size <= sector_size) {
                    const at = self.at;
                    self.at += dirent_size;
                    const e = sector[at..][0..dirent_size];
                    if (e[0] == 0x00) { // nothing further in this directory
                        self.done = true;
                        return null;
                    }
                    if (e[0] == 0xE5) {
                        self.long_ok = false;
                        continue;
                    }
                    if (e[11] == attr_long_name) {
                        takeLongPart(e, &self.long, &self.long_len, &self.long_sum, &self.long_ok);
                        continue;
                    }
                    if (e[11] & attr_volume_label != 0) {
                        self.long_ok = false;
                        continue;
                    }
                    var entry = self.walk.vol.entryFrom(e);
                    entry.lba = self.walk.lba;
                    entry.slot = @intCast(at);
                    // **THE CHECKSUM IS WHAT TIES A LONG NAME TO ITS ENTRY.** A
                    // run whose checksum does not match the short name it
                    // precedes belongs to a file that was deleted and partly
                    // overwritten, and using it would put the wrong name on the
                    // wrong bytes.
                    if (self.long_ok and self.long_len > 0 and self.long_sum == shortChecksum(e[0..11].*)) {
                        entry.long_len = @intCast(@min(self.long_len, entry.long.len));
                        @memcpy(entry.long[0..entry.long_len], self.long[0..entry.long_len]);
                    }
                    self.long_ok = false;
                    self.long_len = 0;
                    return entry;
                }
                if (!(try self.walk.next())) {
                    self.done = true;
                    return null;
                }
                self.loaded = false;
            }
            return null;
        }
    };

    /// A cursor over a directory's entries. Cluster 0 means the root
    /// directory, which on FAT16 is a fixed run of sectors outside the data
    /// region rather than a chain.
    pub fn lister(self: *Volume, dir_cluster: Cluster) Error!Lister {
        return .{ .walk = try Walk.start(self, dir_cluster) };
    }

    /// Walks the entries of a directory, calling `each` for every real one:
    /// a `Lister` run to its end.
    pub fn list(
        self: *Volume,
        dir_cluster: Cluster,
        context: anytype,
        comptime each: fn (@TypeOf(context), Entry) void,
    ) Error!void {
        var l = try self.lister(dir_cluster);
        while (try l.next()) |entry| each(context, entry);
    }

    /// The entry named `name` in a directory, or null. Case-insensitive, as
    /// 8.3 names are. **IT STOPS AT THE NAME**: the rest of the directory is
    /// not read, and is read in bursts up to that point (`dir_burst`).
    pub fn find(self: *Volume, dir_cluster: Cluster, name: []const u8) Error!?Entry {
        var l = try self.lister(dir_cluster);
        l.burst = self.dir_burst;
        while (try l.next()) |e| if (eqlFold(e.text(), name)) return e;
        return null;
    }

    /// Walks a slash-separated path from the root. "EFI/BOOT/BOOTX64.EFI".
    pub fn open(self: *Volume, path: []const u8) Error!Entry {
        var cluster: Cluster = 0;
        var at: usize = 0;
        var result: ?Entry = null;
        while (at < path.len) {
            var end = at;
            while (end < path.len and path[end] != '/') end += 1;
            if (end > at) {
                // **NOT THROUGH A FILE.** `a/b` with `a` a file read a's bytes
                // as directory entries, and could find in them whatever they
                // spelled. A path through a file names nothing.
                if (result) |r| if (!r.isDirectory()) {
                    props.reachable(@src(), "fat: a path through a file names nothing", null);
                    return Error.NotFound;
                };
                const e = (try self.find(cluster, path[at..end])) orelse return Error.NotFound;
                result = e;
                cluster = e.first_cluster;
            }
            at = end + 1;
        }
        return result orelse Error.NotFound;
    }

    fn writeSector(self: *Volume, lba: u32, from: *[sector_size]u8) Error!void {
        if (self.blk.write(self.start_lba + lba, @intFromPtr(from)) != virtio.blk_s_ok) {
            if (self.dirs) |*c| c.drop(lba, 1);
            props.reachable(@src(), "fat: a sector write fails", null);
            return Error.WriteFailed;
        }
        if (self.dirs) |*c| c.wrote(lba, 1, from);
    }

    /// `count` whole sectors straight from `from`, as one request. `from` is
    /// the caller's buffer, which the device reads directly.
    ///
    /// **ONE REQUEST, NOT A LOOP.** writeRuns never asks for more than one
    /// request's worth — a run is capped there — and nothing else writes in
    /// bulk, so a loop that split a longer write would be code no test could
    /// reach. Asking for more is an error instead.
    fn writeSectors(self: *Volume, lba: u32, count: u32, from: [*]const u8) Error!void {
        if (count > virtio.Block.max_sectors) {
            props.@"unreachable"(@src(), "fat: a write of more sectors than one request", null);
            return Error.TooBig;
        }
        if (self.blk.writeMany(self.start_lba + lba, @intFromPtr(from), count) != virtio.blk_s_ok) {
            if (self.dirs) |*c| c.drop(lba, count);
            props.reachable(@src(), "fat: a run of sectors fails to write", null);
            return Error.WriteFailed;
        }
        if (self.dirs) |*c| c.wrote(lba, count, from);
    }

    /// How many bytes the data region holds, and how many of them no file
    /// has: the kept count (`free_clusters`), so a field read.
    pub fn space(self: *Volume) Error!struct { total: u64, free: u64 } {
        const cluster_bytes: u64 = @as(u64, self.sectors_per_cluster) * sector_size;
        return .{ .total = (@as(u64, self.max_cluster) - 1) * cluster_bytes, .free = @as(u64, self.free_clusters) * cluster_bytes };
    }

    /// The free count afresh, from the FAT on the disk: what `free_clusters`
    /// must always equal. For tests, and for a check that wants to say so.
    /// It counts the FIRST COPY on the disk, not the held FAT: where
    /// `cacheFatChecked` trusted the second copy and the repair was refused,
    /// the kept count follows the held FAT and this does not.
    pub fn countFreeAgain(self: *Volume) Error!u32 {
        return self.countFree();
    }

    /// The FAT entry for a cluster.
    fn fatGet(self: *Volume, cluster: Cluster) Error!Cluster {
        const width = self.entryBytes();
        const at = @as(u32, cluster) * width;
        if (self.fat) |fat| return self.entryIn(fat[at - at % sector_size ..][0..sector_size], at % sector_size / width);
        try self.readSector(self.fat_start + at / sector_size, self.scratch);
        return self.entryIn(self.scratch, at % sector_size / width);
    }

    /// Puts `value` into the entry at byte `at` of a FAT sector. **On FAT32
    /// the top four bits of the entry are kept**: the spec reserves them, and
    /// another tool may have set them (FAT32.md §4).
    fn putEntry(self: *const Volume, sector: []u8, at: u32, value: Cluster) void {
        switch (self.kind) {
            .fat16 => {
                sector[at] = @truncate(value);
                sector[at + 1] = @truncate(value >> 8);
            },
            .fat32 => {
                const kept = le32(sector[at..][0..4]) & ~fat32_mask;
                std.mem.writeInt(u32, sector[at..][0..4], kept | (value & fat32_mask), .little);
            },
        }
    }

    /// Sets the FAT entry for a cluster, **in every copy of the FAT**. A
    /// volume whose second FAT disagrees with its first is one that other
    /// tools will quietly repair, or quietly believe.
    ///
    /// **WHAT IS HELD MOVES ONLY WITH THE FIRST COPY.** The kept free count,
    /// and the FAT when it is held, change once the first copy's write has
    /// landed, and not when it fails: they moved first, and a write the device
    /// refused left them saying a cluster had changed that had not, for as
    /// long as the machine ran (QUEUE.md item 80). Once the first copy has
    /// landed it is the FAT (cacheFat), so a later copy's failure is an
    /// error and changes nothing held.
    fn fatSet(self: *Volume, cluster: Cluster, value: Cluster) Error!void {
        try self.forgetFsInfo();
        const width = self.entryBytes();
        const at = @as(u32, cluster) * width;
        const in_sector = at / sector_size;
        // **THE FIRST COPY DECIDES** (QUEUE 131, kernel-facts #7). Every read
        // here follows it, so its write is the change: a failure there is
        // the caller's, and the sector is read again to learn what landed
        // (a write the disk called failed may have), never assumed old. A
        // later copy that fails is copies apart, which the next mount brings
        // into line with the first (cacheFat): counted and said, not the
        // operation's failure.
        if (self.fat) |fat| {
            // The cached sector is the truth — cacheFat brought every copy
            // into line with it — so it is written to each copy whole, and no
            // copy is read back first. Where cacheFat left the copies apart
            // (a tie, a weighing that could not run, a repair refused), this
            // write is what brings them into line, with the held sector.
            //
            // A refused first write puts the old entry back: the held sector
            // then says the disk kept the old one, which a refused write does
            // not promise. `dirs` drops a sector in the same case; the FAT is
            // held whole and has no "not known" to drop to. The next mount
            // weighs the copies again.
            const sector = fat[in_sector * sector_size ..][0..sector_size];
            const old = self.entryIn(sector, at % sector_size / width);
            self.putEntry(sector, at % sector_size, value);
            self.writeSector(self.fat_start + in_sector, sector) catch |e| {
                self.readSector(self.fat_start + in_sector, sector) catch {
                    // Not even read: what the disk holds is unknown, and the
                    // held sector goes on as it was, the old value.
                    props.reachable(@src(), "fat: a FAT sector whose write failed cannot be read again", null);
                    self.putEntry(sector, at % sector_size, old);
                    return e;
                };
                self.keepCount(old, self.entryIn(sector, at % sector_size / width));
                return e;
            };
            self.keepCount(old, value);
            var c: u32 = 1;
            while (c < self.num_fats) : (c += 1) {
                self.writeSector(self.fat_start + c * self.sectors_per_fat + in_sector, sector) catch self.copyApart();
            }
            return;
        }
        var copy: u32 = 0;
        while (copy < self.num_fats) : (copy += 1) {
            const lba = self.fat_start + copy * self.sectors_per_fat + in_sector;
            if (copy == 0) {
                try self.readSector(lba, self.scratch);
                // The first copy is the one every read here follows.
                const old = self.entryIn(self.scratch, at % sector_size / width);
                self.putEntry(self.scratch, at % sector_size, value);
                self.writeSector(lba, self.scratch) catch |e| {
                    // What landed, read again for the count.
                    const now = if (self.readSector(lba, self.scratch)) |_| self.entryIn(self.scratch, at % sector_size / width) else |_| old;
                    self.keepCount(old, now);
                    return e;
                };
                self.keepCount(old, value);
                continue;
            }
            self.readSector(lba, self.scratch) catch {
                self.copyApart();
                continue;
            };
            self.putEntry(self.scratch, at % sector_size, value);
            self.writeSector(lba, self.scratch) catch self.copyApart();
        }
    }

    /// A FAT copy past the first that could not be written: apart from the
    /// first until the next mount brings it into line (QUEUE 131, #7).
    fn copyApart(self: *Volume) void {
        self.fat_copies_failed +%= 1;
        props.reachable(@src(), "fat: a FAT copy past the first fails to write, and is left apart", .{ .count = self.fat_copies_failed });
    }

    /// **FSINFO'S FREE COUNT AND NEXT-FREE HINT, MARKED UNKNOWN** on the first
    /// change to a FAT32 volume's FAT after mount, in FSInfo and in the backup
    /// boot sector's copy of it (FAT32.md §7). Both are hints, which Linux
    /// recomputes when they say 0xFFFFFFFF; one left set and wrong is what
    /// fsck.fat reports. One sector write a copy, once a mount.
    ///
    /// Marked done once both writes have landed: marked first, a write the
    /// device refused left a count set and wrong for as long as the machine
    /// ran (QUEUE.md item 80). A failure is an error, and the next change
    /// tries again.
    fn forgetFsInfo(self: *Volume) Error!void {
        if (self.kind != .fat32 or self.fsinfo_unknown) return;
        for ([_]u32{ self.fsinfo_sector, self.backup_boot + 1 }) |lba| {
            if (lba == 0 or lba >= self.fat_start) continue; // no such sector in the reserved area
            try self.readSector(lba, self.scratch);
            if (le32(self.scratch[0..4]) != 0x4161_5252 or le32(self.scratch[484..488]) != 0x6141_7272) continue;
            std.mem.writeInt(u32, self.scratch[488..492], 0xFFFF_FFFF, .little);
            std.mem.writeInt(u32, self.scratch[492..496], 0xFFFF_FFFF, .little);
            try self.writeSector(lba, self.scratch);
        }
        props.reachable(@src(), "fat: a FAT32 volume's FSInfo count is let go", null);
        self.fsinfo_unknown = true;
    }

    /// Moves the kept free count for one FAT entry going from `old` to `new`.
    /// Saturating: a count that went wrong must not stop the machine; the
    /// host tests compare it with a fresh one after every operation.
    /// **THE DERIVED VALUE, MOVED IN STEP WITH ITS SOURCE**, not recomputed
    /// from it: the next mount's count is the reconcile.
    fn keepCount(self: *Volume, old: Cluster, new: Cluster) void {
        if (old == 0 and new != 0) props.always(@src(), self.free_clusters > 0, "fat: the kept free count never runs below zero", null);
        // The fewest free clusters any run left (zig-coverage-sdk's
        // comparisons): a property only, beside the one above.
        if (old == 0 and new != 0) props.alwaysGreaterThan(@src(), self.free_clusters, 0, "fat: a cluster is taken with one free", null);
        if (old == 0 and new != 0) self.free_clusters -|= 1;
        if (old != 0 and new == 0) self.free_clusters += 1;
    }

    /// A chain of `count` clusters, linked and terminated. Answers its first.
    /// A count of zero answers cluster 0, which is what an empty file holds.
    ///
    /// **A FAILED ALLOCATION LEAVES NOTHING BEHIND.** If the volume runs out
    /// part way, what was taken is given back before the error is returned,
    /// because a half-built chain nothing points at is a leak no `fsck` here
    /// would ever find.
    fn allocChain(self: *Volume, count: u32) Error!Cluster {
        if (count == 0) return 0;
        // **THE RESERVE** (`reserve_clusters`, QUEUE 132): a large
        // allocation that would leave less free than it is refused before it
        // takes anything; a small one may go into it.
        if (count > small_clusters and self.free_clusters < @as(u64, count) + self.reserve_clusters) {
            props.reachable(@src(), "fat: a large allocation is refused to keep the reserve for small writes", .{ .count = count, .free = self.free_clusters });
            return Error.Full;
        }
        var first: Cluster = 0;
        var previous: Cluster = 0;
        // **WHAT IT TOOK GOES BACK ON EVERY ERROR** (QUEUE 131, #6), not only
        // on a full volume: a FAT read or write that fails part-way leaked
        // the chain so far. Nothing points at it yet.
        errdefer if (first != 0) self.giveBack(first);
        var taken: u32 = 0;
        var candidate: Cluster = @max(self.next_free, 2);
        // Once round the whole volume at most: a cursor that was wrong (a FAT
        // changed under it) costs a wrap, not a wrong answer.
        var looked: u32 = 0;
        const clusters: u32 = self.max_cluster - 1;

        while (taken < count) {
            if (candidate > self.max_cluster) {
                props.reachable(@src(), "fat: the allocation cursor wraps around the volume", null);
                candidate = 2;
            }
            if (looked == clusters) {
                props.reachable(@src(), "fat: an allocation finds the volume full", .{ .count = count, .taken = taken });
                if (first != 0) {
                    props.reachable(@src(), "fat: a volume full part-way through an allocation gives back what it took", .{ .taken = taken });
                }
                return Error.Full; // the errdefer gives it back
            }
            looked += 1;
            if ((try self.fatGet(candidate)) != 0) {
                candidate += 1;
                continue;
            }
            // Its own mark may land and still fail: given back if it did.
            self.fatSet(candidate, self.endMark()) catch |e| { // the end, until something follows
                if (self.fatGet(candidate)) |now| if (now != 0) self.giveBack(candidate) else {} else |_| {}
                return e;
            };
            // Taken and not yet linked: given back on its own if the link
            // fails, as the chain before it is by the errdefer.
            if (previous != 0) self.fatSet(previous, candidate) catch |e| {
                self.giveBack(candidate);
                return e;
            };
            if (first == 0) first = candidate;
            previous = candidate;
            taken += 1;
            candidate += 1;
        }
        self.next_free = candidate;
        return first;
    }

    /// A cleanup after the commit (`cleanups_failed`): its failure is a
    /// leak, counted, not the operation's error.
    fn afterCommit(self: *Volume, done: Error!void) void {
        done catch {
            self.cleanups_failed +%= 1;
            props.reachable(@src(), "fat: a cleanup after the commit failed, and is left a leak", .{ .count = self.cleanups_failed });
        };
    }

    /// The reserve's size (`reserve_clusters`), and the largest allocation
    /// it lets through.
    pub const reserve_bytes: u32 = 64 << 20;
    pub const small_clusters: u32 = 2;

    /// Clusters taken and not yet pointed at, given back on an error before
    /// the commit (QUEUE 131, #6). A give-back that fails is counted with the
    /// cleanups (`cleanups_failed`), never swallowed: the clusters are a
    /// leak the boot's check reports.
    fn giveBack(self: *Volume, first: Cluster) void {
        self.freeChain(first) catch {
            self.cleanups_failed +%= 1;
            props.reachable(@src(), "fat: clusters taken before a failure could not be given back, and are left a leak", .{ .count = self.cleanups_failed });
        };
    }

    fn freeChain(self: *Volume, first: Cluster) Error!void {
        var cluster = first;
        while (self.inData(cluster)) {
            const next = try self.fatGet(cluster);
            props.always(@src(), next != 0, "fat: every cluster freed was in use", .{ .cluster = cluster });
            try self.fatSet(cluster, 0);
            // A fatSet that fails after the first copy landed leaves this
            // cluster free behind the cursor: "every cluster below it is in
            // use" no longer holds until the next mount, and allocation
            // passes the cluster by.
            if (cluster < self.next_free) self.next_free = cluster;
            cluster = next;
        }
    }

    /// Writes `bytes` into a chain that is already long enough. The last
    /// sector is padded with zeros: a cluster is written whole, and the
    /// directory's size field is what says how much of it is the file.
    fn writeChain(self: *Volume, first: Cluster, bytes: []const u8) Error!void {
        return self.writeRuns(first, 0, bytes, .zeros);
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
    ///
    /// **AND THE ORPHANS JUST BEFORE IT.** A long name's parts must be followed
    /// at once by their short entry, so live parts followed by a free slot are
    /// an orphan: what a write or a remove that failed or stopped part-way
    /// leaves. Harmless while the slot after them stays free; but the reader
    /// ties a long name to the entry after it by an 8-bit checksum, so a new
    /// entry written there whose short name happens to sum the same (1 in
    /// 256: `B` and `C~1` do) is listed under the orphan's name and lost
    /// under its own (QUEUE.md item 87, found by the page cache's test).
    /// writeEntry tombstones them first.
    const Run = struct {
        slots: [max_long_parts + 1]Slot = undefined,
        len: u32 = 0,
        orphans: [max_long_parts]Slot = undefined,
        orphans_len: u32 = 0,
    };

    fn findRun(self: *Volume, dir_cluster: Cluster, needed: u32) Error!Run {
        if (needed == 0 or needed > max_long_parts + 1) {
            // Names stop at `max_name` (96), 8 parts: a guard, not a refusal.
            props.@"unreachable"(@src(), "fat: a name needing more long-name parts than FAT allows", null);
            return Error.BadName;
        }
        var walk = try Walk.start(self, dir_cluster);
        var run = Run{};
        // Live long-name parts since the last other entry: the last of them,
        // in order, as many as a name has.
        var parts: [max_long_parts]Slot = undefined;
        var parts_len: u32 = 0;

        while (true) {
            try self.readSector(walk.lba, self.scratch);
            var at: u32 = 0;
            while (at + dirent_size <= sector_size) : (at += dirent_size) {
                const first = self.scratch[at];
                if (first == 0x00 or first == 0xE5) {
                    if (run.len == 0) {
                        @memcpy(run.orphans[0..parts_len], parts[0..parts_len]);
                        run.orphans_len = parts_len;
                    }
                    parts_len = 0;
                    run.slots[run.len] = .{ .lba = walk.lba, .at = at };
                    run.len += 1;
                    if (run.len == needed) {
                        props.sometimes(@src(), run.slots[0].lba != run.slots[run.len - 1].lba, "fat: a name's run of entries straddles a sector", .{ .needed = needed });
                        return run;
                    }
                } else {
                    run.len = 0;
                    if (self.scratch[at + 11] == attr_long_name) {
                        if (parts_len == parts.len) {
                            std.mem.copyForwards(Slot, parts[0 .. parts.len - 1], parts[1..]);
                            parts_len -= 1;
                        }
                        parts[parts_len] = .{ .lba = walk.lba, .at = at };
                        parts_len += 1;
                    } else parts_len = 0;
                }
            }
            // A run MAY straddle sectors and clusters: the walk says where the
            // next entry is, and each slot records the sector it was found in.
            if (!(try walk.next())) break;
        }

        // **THE ROOT DIRECTORY CANNOT GROW.** On FAT16 it is a fixed run of
        // sectors sized when the volume was made, which is the one hard limit
        // this filesystem has that a caller can hit in normal use.
        if (dir_cluster == 0 and self.kind == .fat16) {
            props.reachable(@src(), "fat: a FAT16 root directory is full", .{ .needed = needed });
            return Error.DirectoryFull;
        }
        try self.grow(dir_cluster);
        return self.findRun(dir_cluster, needed);
    }

    /// Adds one zeroed cluster to the end of a directory's chain.
    fn grow(self: *Volume, dir_cluster: Cluster) Error!void {
        const end = try self.chainEnd(self.dirStart(dir_cluster));
        // **FAT'S LIMIT ON A DIRECTORY: 65,536 ENTRIES**, 2 MiB. Past it
        // fsck.fat calls the directory broken, and Linux, which would have to
        // read the volume after this machine wrote it, may refuse it. So a
        // directory stops growing there, and the write that needed the room
        // is refused as a full directory, as a full root is.
        const per_cluster = self.sectors_per_cluster * (sector_size / dirent_size);
        if ((end.clusters + 1) * per_cluster > max_dir_entries) {
            props.reachable(@src(), "fat: a directory reaches FAT's most entries", null);
            return Error.DirectoryFull;
        }
        props.reachable(@src(), "fat: a directory grows by a cluster", .{ .clusters = end.clusters });
        // The largest directory any run grew, against FAT's most.
        props.alwaysLessThanOrEqualTo(@src(), (end.clusters + 1) * per_cluster, max_dir_entries, "fat: a directory grown stays within FAT's most entries", null);
        const last = end.last;

        const fresh = try self.allocChain(1);
        // Given back on a failure before the link that makes it the
        // directory's (QUEUE 131, #6); not after, since that write may have
        // landed (#2).
        var committing = false;
        errdefer if (!committing) self.giveBack(fresh);
        var s: u32 = 0;
        @memset(self.scratch, 0);
        while (s < self.sectors_per_cluster) : (s += 1) {
            try self.writeSector(self.clusterSector(fresh) + s, self.scratch);
        }
        committing = true;
        self.fatSet(last, fresh) catch |e| {
            // The link failed: what the FAT says now, read again (#7), tells
            // whether it landed. If not, nothing points at the cluster.
            if (self.fatGet(last)) |now| if (now != fresh) self.giveBack(fresh) else {} else |_| {}
            return e;
        };
    }

    /// The most entries a directory may hold (Microsoft's FAT specification:
    /// a directory is at most 2 MiB, of 32-byte entries).
    pub const max_dir_entries: u32 = 65536;

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
    fn removeEntry(self: *Volume, dir_cluster: Cluster, name: []const u8) Error!void {
        return self.unlinkEntry(dir_cluster, name, true);
    }

    /// removeEntry's work. With `free` false the entry goes and its chain
    /// stays allocated, for `rename`, which hands the chain to another entry.
    /// One long-name part marked deleted, where the walk found it.
    fn clearPart(self: *Volume, lba: u32, at: u32) Error!void {
        try self.readSector(lba, self.scratch);
        self.scratch[at] = 0xE5;
        try self.writeSector(lba, self.scratch);
    }

    fn unlinkEntry(self: *Volume, dir_cluster: Cluster, name: []const u8, free: bool) Error!void {
        const Pos = struct { lba: u32, at: u32 };
        var walk = try Walk.start(self, dir_cluster);
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

                var entry = self.entryFrom(e);
                const has_long = long_ok and long_len > 0 and long_sum == shortChecksum(e[0..11].*);
                if (has_long) {
                    entry.long_len = @intCast(@min(long_len, entry.long.len));
                    @memcpy(entry.long[0..entry.long_len], long_buf[0..entry.long_len]);
                }

                if (eqlFold(entry.text(), name)) {
                    const chain = entry.first_cluster;
                    const short_lba = walk.lba;
                    const run = parts[0..part_count];
                    if (has_long and parts_overflowed) { // cannot remove what cannot be found whole
                        props.reachable(@src(), "fat: a long name of more parts than FAT allows cannot be removed", null);
                        return Error.BadName;
                    }

                    // 1. the short entry, while its sector is in scratch: the
                    // commit. From here the entry is gone, and what follows
                    // is cleanup whose failure leaves orphaned long-name
                    // parts or a leaked chain, what a stop leaves, not the
                    // operation's error (QUEUE 131, #3).
                    self.scratch[at] = 0xE5;
                    try self.writeSector(short_lba, self.scratch);

                    // 2. the long-name parts, each where the walk found it
                    if (has_long) {
                        for (run) |pos| self.afterCommit(self.clearPart(pos.lba, pos.at));
                    }

                    // 3. and only now, the data
                    if (free and chain >= 2) self.afterCommit(self.freeChain(chain));
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
    /// The date to stamp on an entry being written now.
    fn stamp(self: *Volume) Dos {
        const clock = self.clock orelse return .none;
        const now = clock() orelse return .none;
        return Dos.fromUnix(now);
    }

    fn writeEntry(
        self: *Volume,
        run: Run,
        name: []const u8,
        short: [11]u8,
        attr: u8,
        first: Cluster,
        size: u32,
        /// Set true just before the short entry's write, the commit: a
        /// caller undoes nothing after it (QUEUE 131, #2), and may give back
        /// what it took on a failure before it (#6).
        committing: ?*bool,
    ) Error!void {
        const parts = longParts(name);
        const sum = shortChecksum(short);
        if (run.len != parts + 1) { // the run was sized for another name
            props.@"unreachable"(@src(), "fat: a directory run sized for another name", null);
            return Error.BadName;
        }

        // An orphan just before the run goes first (see Run): a stop after
        // this leaves it gone and the run still free.
        for (run.orphans[0..run.orphans_len]) |o| {
            try self.readSector(o.lba, self.scratch);
            self.scratch[o.at] = 0xE5;
            try self.writeSector(o.lba, self.scratch);
        }

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
        // Created now, written now, read now: a file this machine is creating
        // has one moment, and all three fields say so.
        const when = self.stamp();
        putDos(e[14..18], when); // creation time, creation date
        putLe16(e[18..20], when.date); // last access date
        putDos(e[22..26], when); // write time, write date
        putCluster(e, first);
        e[28] = @truncate(size);
        e[29] = @truncate(size >> 8);
        e[30] = @truncate(size >> 16);
        e[31] = @truncate(size >> 24);
        if (committing) |c| c.* = true;
        try self.writeSector(slot.lba, self.scratch);
    }

    /// An 8.3 alias for a name. A name that already fits is its own alias; one
    /// that does not gets SESSIO~1, SESSIO~2, and so on until one is free.
    fn aliasFor(self: *Volume, dir_cluster: Cluster, name: []const u8) Error![11]u8 {
        // **A NEW NAME IS ASCII** (metal-vmm QUEUE 104). A long name holds a
        // byte as one UTF-16 unit, and `takeLongPart` reads a unit past ASCII
        // as '?': a name past it would be written, then found under no name
        // it was given. Every name made here comes through this, before
        // anything is changed (`writeFileIn`, `makeDirIn`, `rename`).
        for (name) |c| if (c >= 0x80) {
            props.reachable(@src(), "fat: a name past ASCII is refused", null);
            return Error.BadName;
        };
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
        props.reachable(@src(), "fat: no 8.3 alias is left for a name", null);
        return Error.BadName;
    }

    /// Whether a directory already holds this exact 8.3 field.
    fn aliasTaken(self: *Volume, dir_cluster: Cluster, short: [11]u8) Error!bool {
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
    ///
    /// **A REWRITE KEEPS THE NAME THE FILE HAS.** Names are matched without
    /// case, so `PLAN.md` replaces `plan.md`; the file stays `plan.md`, with
    /// the same 8.3 alias, as an append keeps it and as Linux's vfat keeps it
    /// on a truncating open. Only a new file takes the case it was given.
    ///
    /// **A DIRECTORY OF THAT NAME IS REFUSED, NOT REPLACED.** Removing its
    /// entry would orphan everything in it, and say nothing; Linux refuses
    /// the same write (EISDIR, std's `IsDir`), and so does this.
    pub fn writeFileIn(self: *Volume, dir_cluster: Cluster, given: []const u8, bytes: []const u8) Error!void {
        if (given.len == 0 or given.len > max_name) {
            props.reachable(@src(), "fat: a write's name is empty or too long", null);
            return Error.BadName;
        }
        const old = try self.find(dir_cluster, given);
        if (old) |*e| if (e.isDirectory()) {
            props.reachable(@src(), "fat: a write onto a directory is refused", null);
            return Error.IsDirectory;
        };
        const per_cluster = self.sectors_per_cluster * sector_size;
        if (bytes.len > 0xFFFF_FFFF) {
            props.reachable(@src(), "fat: a file of 4 GiB or more is refused", null);
            return Error.TooBig;
        }
        const clusters: u32 = @intCast((@as(u64, bytes.len) + per_cluster - 1) / per_cluster);
        if (old) |e| return self.overwrite(e, clusters, bytes);

        const name = given;
        const short = try self.aliasFor(dir_cluster, name);
        const needs_long = needsLongName(name);
        const parts: u32 = if (needs_long) longParts(name) else 0;
        const run = try self.findRun(dir_cluster, parts + 1);

        const first = try self.allocChain(clusters);
        // A failure before the entry gives the chain back (QUEUE 131, #6); a
        // failure of the entry's write may have landed, and leaves it (#2).
        var committing = false;
        errdefer if (!committing) self.giveBack(first);
        if (bytes.len > 0) try self.writeChain(first, bytes);

        // The entry goes last: until it is written, nothing points at the data,
        // so a machine that stops here has lost a file rather than corrupted one.
        // `committing` is set at its short entry's write.
        try self.writeEntry(run, if (needs_long) name else name[0..0], short, 0x20, first, @intCast(bytes.len), &committing);
    }

    /// **AN OVERWRITE IS ONE SECTOR WRITE** (essay kernel-facts #1). The new
    /// bytes go into a chain of their own, one write of the entry's sector
    /// points the file at it, and then the old chain is freed. A machine
    /// stopped anywhere leaves the old file or the new one, never neither;
    /// a volume without room for both refuses the write and keeps the old.
    /// The entry keeps its name, its alias and its long-name parts.
    ///
    /// **NO UNDO ONCE THE ENTRY'S WRITE IS ASKED.** A write the disk failed
    /// may still have landed, and freeing a chain the entry points at would
    /// give one cluster to two files. So a failure there leaves the new
    /// chain allocated (a leak at worst), and the boot's disk check says it.
    /// A failure freeing the old chain after it is no failure of the write:
    /// the file is the new one, and the old chain a leak (`afterCommit`,
    /// QUEUE 131, #3).
    fn overwrite(self: *Volume, old: Entry, clusters: u32, bytes: []const u8) Error!void {
        const first = try self.allocChain(clusters);
        if (bytes.len > 0) self.writeChain(first, bytes) catch |err| {
            self.giveBack(first);
            return err;
        };
        try self.setEntry(old, first, @intCast(bytes.len));
        self.afterCommit(self.freeChain(old.first_cluster));
    }

    /// Makes a directory in `dir_cluster`. Its first cluster holds `.` and `..`,
    /// which every directory but the root has and which `fsck` checks for.
    /// The entry goes last, so a machine stopped before it leaves no
    /// directory and a leaked cluster.
    ///
    /// **ROOM FOR THE ENTRY IS FOUND BEFORE THE CLUSTER IS TAKEN.** Taken
    /// first, a parent with no room left (a full FAT16 root: `DirectoryFull`)
    /// returned the error with the cluster still allocated and nothing
    /// pointing at it, a leak on every try (fat_sim, 2026-10-05). The run
    /// stays free while the cluster is taken and written: neither touches
    /// the parent's sectors.
    pub fn makeDirIn(self: *Volume, dir_cluster: Cluster, name: []const u8) Error!Cluster {
        if ((try self.find(dir_cluster, name))) |e| {
            if (e.isDirectory()) return e.first_cluster;
            props.reachable(@src(), "fat: a directory to be made is a file's name", null);
            return Error.BadName;
        }

        const short = try self.aliasFor(dir_cluster, name);
        const needs_long = needsLongName(name);
        const parts: u32 = if (needs_long) longParts(name) else 0;
        const run = try self.findRun(dir_cluster, parts + 1);

        const cluster = try self.allocChain(1);
        // A write refused before the commit gives the cluster back; a machine
        // that stops leaves it leaked, which the check reports.
        //
        // **NO ROLLBACK ONCE THE COMMIT IS TRIED** (metal-vmm QUEUE 131,
        // kernel-facts #2): the entry write that points at the cluster may
        // land and still answer an error, and the cluster freed under it is
        // one the next file takes, two in one cluster. So from `writeEntry`
        // on, a failure leaves the cluster taken: a leak if the entry did not
        // land, which the check reports and the boot reclaims (the box's #4).
        var committing = false;
        errdefer if (!committing) self.giveBack(cluster);
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
        putCluster(dot, cluster);
        const dotdot = self.scratch[dirent_size..][0..dirent_size];
        @memcpy(dotdot[0..11], "..         ");
        dotdot[11] = attr_directory;
        putCluster(dotdot, dir_cluster);
        try self.writeSector(self.clusterSector(cluster), self.scratch);

        try self.writeEntry(run, if (needs_long) name else name[0..0], short, attr_directory, cluster, 0, &committing);
        return cluster;
    }

    /// Walks a slash-separated path, making each directory that is missing, and
    /// answers the cluster of the last one.
    ///
    /// **NO DEEPER THAN THE CHECK WALKS** (`max_path_depth`): a directory
    /// past it is one `check` calls `too_deep`, so this code would make a
    /// volume its own check cannot vouch for. Refused as a name too long,
    /// which is what Linux says of a path past its limit.
    pub fn makePath(self: *Volume, path: []const u8) Error!Cluster {
        var cluster: Cluster = 0;
        var at: usize = 0;
        var depth: u32 = 0;
        while (at < path.len) {
            var end = at;
            while (end < path.len and path[end] != '/') end += 1;
            if (end > at) {
                depth += 1;
                if (depth > max_path_depth) {
                    props.reachable(@src(), "fat: a directory deeper than the check walks is refused", null);
                    return Error.BadName;
                }
                cluster = try self.makeDirIn(cluster, path[at..end]);
            }
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
    ///
    /// A machine stopped part-way leaves the old file, whole: the data lands
    /// past its size, and the size moves last. What else it may leave:
    /// leaked clusters, or a chain longer than the size (see below), which
    /// the next append fills.
    pub fn writeInto(self: *Volume, path: []const u8, offset: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        const entry = try self.open(path);
        if (entry.isDirectory()) {
            props.reachable(@src(), "fat: an overwrite of a directory is refused", null);
            return Error.BadName;
        }
        if (offset > entry.size) { // would leave a hole
            props.reachable(@src(), "fat: an overwrite past a file's end is refused", null);
            return Error.BadChain;
        }

        const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;
        const old_size: u32 = entry.size;
        const reach: u64 = @as(u64, offset) + bytes.len;
        if (reach > 0xFFFF_FFFF) {
            props.reachable(@src(), "fat: a write reaching past 4 GiB is refused", null);
            return Error.TooBig;
        }
        const new_size: u32 = @max(old_size, @as(u32, @intCast(reach)));

        // **IN 64 BITS**: rounding a size near 4 GiB up to whole clusters
        // overflows 32, which panicked where it should answer TooBig
        // (REVIEW-restart-fat32.md F1).
        const have: u32 = @intCast((@as(u64, old_size) + cluster_bytes - 1) / cluster_bytes);
        const need: u32 = @intCast((@as(u64, new_size) + cluster_bytes - 1) / cluster_bytes);

        // An empty file has no chain at all (first_cluster 0), so the first
        // append is also the allocation.
        //
        // **A FILE'S CLUSTERS ARE COUNTED IN ITS CHAIN, NOT FROM ITS SIZE.**
        // An append links its new clusters on, then writes the data, then
        // the entry's size: the FAT and the entry are different sectors, so a
        // machine stopped between the link and the entry leaves the old file,
        // whole, on a chain longer than its size needs (the check's `long`;
        // QUEUE.md item 79). Counted from the size, the next append linked
        // more clusters past those, and the file stayed long for good;
        // counted in the chain, it fills them first.
        var first = entry.first_cluster;
        if (have == 0 and first == 0) {
            first = try self.allocChain(need);
        } else {
            const end = try self.chainEnd(first);
            if (need > end.clusters) {
                props.reachable(@src(), "fat: an append links clusters onto a file", .{ .need = need, .have = end.clusters });
                const extra = try self.allocChain(need - end.clusters);
                try self.fatSet(end.last, extra);
            }
        }

        try self.writeAt(first, offset, bytes);
        try self.setEntry(entry, first, new_size);
    }

    /// A chain's last cluster, and how many clusters it holds.
    fn chainEnd(self: *Volume, first: Cluster) Error!struct { last: Cluster, clusters: u32 } {
        if (!self.inData(first)) {
            props.reachable(@src(), "fat: a file's first cluster is outside the data, at its chain's end", null);
            return Error.BadChain;
        }
        var cluster = first;
        var clusters: u32 = 1;
        var loop = Loop{};
        try loop.pass(first);
        while (try self.nextCluster(cluster)) |next| {
            try loop.pass(next);
            cluster = next;
            clusters += 1;
        }
        return .{ .last = cluster, .clusters = clusters };
    }

    /// Writes `bytes` into a chain at byte `offset`, which the chain must
    /// already be long enough to hold.
    ///
    /// **THE FIRST SECTOR IS READ BEFORE IT IS WRITTEN**, because an append
    /// almost never lands on a sector boundary: the bytes already in that
    /// sector are the end of the file, and writing a fresh sector over them
    /// would erase back to the last boundary. So is the last, for an overwrite
    /// inside the file.
    fn writeAt(self: *Volume, first: Cluster, offset: u32, bytes: []const u8) Error!void {
        return self.writeRuns(first, offset, bytes, .kept);
    }

    /// What goes in a sector a write ends inside: what was there already, or
    /// zeros. A new file's tail is zeroed, so nothing a deleted file left in
    /// that sector is carried along.
    const Tail = enum { kept, zeros };

    /// **A FILE IS WRITTEN AS RUNS**, the way it is read: a run is a cluster
    /// and every cluster after it whose number is one more. Whole sectors go
    /// straight from `bytes` to the device, one request per run; only a sector
    /// the write starts or ends inside goes through the scratch sector.
    fn writeRuns(self: *Volume, first: Cluster, offset: u32, bytes: []const u8, tail: Tail) Error!void {
        if (bytes.len == 0) return;
        const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;

        var cluster = first;
        if (!self.inData(cluster)) {
            // `first` is what `chainEnd` walked or `allocChain` made.
            props.@"unreachable"(@src(), "fat: a write finds a file's first cluster outside the data", null);
            return Error.BadChain;
        }
        var skip = offset / cluster_bytes;
        while (skip > 0) : (skip -= 1) {
            cluster = (try self.nextCluster(cluster)) orelse {
                props.reachable(@src(), "fat: a write finds a file's chain ends before its size, writing, at its start", null);
                return Error.BadChain;
            };
            if (cluster < 2) {
                props.@"unreachable"(@src(), "fat: a write finds a file's chain points at a reserved cluster, writing, at its start", null);
                return Error.BadChain;
            }
        }

        var sector_in_cluster: u32 = (offset % cluster_bytes) / sector_size;
        var skip_in_sector: u32 = (offset % cluster_bytes) % sector_size;
        var at: usize = 0;
        const max_run = @max(1, virtio.Block.max_sectors / self.sectors_per_cluster);
        while (at < bytes.len) {
            var run: u32 = 1;
            var last = cluster;
            var after: ?Cluster = null;
            while (true) {
                const have = run * cluster_bytes - sector_in_cluster * sector_size - skip_in_sector;
                if (at + have >= bytes.len) break;
                const next = (try self.nextCluster(last)) orelse break;
                if (run >= max_run or next != last + 1) {
                    after = next;
                    break;
                }
                last = next;
                run += 1;
            }

            var lba = self.clusterSector(cluster) + sector_in_cluster;
            var sectors_left = run * self.sectors_per_cluster - sector_in_cluster;

            if (skip_in_sector != 0) {
                // Starting inside a sector: keep what is before the offset.
                try self.readSector(lba, self.scratch);
                const n = @min(bytes.len - at, @as(usize, sector_size - skip_in_sector));
                @memcpy(self.scratch[skip_in_sector..][0..n], bytes[at..][0..n]);
                try self.writeSector(lba, self.scratch);
                at += n;
                lba += 1;
                sectors_left -= 1;
                skip_in_sector = 0;
            }

            const whole: u32 = @intCast(@min(@as(usize, sectors_left), (bytes.len - at) / sector_size));
            if (whole > 0) {
                try self.writeSectors(lba, whole, bytes[at..].ptr);
                at += @as(usize, whole) * sector_size;
                lba += whole;
                sectors_left -= whole;
            }

            if (at < bytes.len and sectors_left > 0) {
                // Ending inside a sector.
                switch (tail) {
                    .kept => try self.readSector(lba, self.scratch),
                    .zeros => @memset(self.scratch, 0),
                }
                const n = bytes.len - at;
                @memcpy(self.scratch[0..n], bytes[at..][0..n]);
                try self.writeSector(lba, self.scratch);
                at += n;
            }

            if (at >= bytes.len) break;
            cluster = after orelse ((try self.nextCluster(last)) orelse {
                props.reachable(@src(), "fat: a write finds a file's chain ends before its size, writing, past its first run", null);
                return Error.BadChain;
            });
            if (cluster < 2) {
                props.@"unreachable"(@src(), "fat: a write finds a file's chain points at a reserved cluster, writing, past its first run", null);
                return Error.BadChain;
            }
            sector_in_cluster = 0;
        }
    }

    /// Writes a file's length and first cluster back into its directory entry,
    /// in place. `entry.lba`/`entry.slot` are where `list` found it.
    fn setEntry(self: *Volume, entry: Entry, first_cluster: Cluster, size: u32) Error!void {
        if (entry.lba == 0) { // never located; refuse to guess
            props.@"unreachable"(@src(), "fat: an entry never located is written back", null);
            return Error.NotFound;
        }
        try self.readSector(entry.lba, self.scratch);
        const e = self.scratch[entry.slot..][0..dirent_size];
        // **A WRITE MOVES THE MODIFICATION TIME.** This is the one path that
        // changes a file that already exists — every append and every replace
        // lands here — and chat's "recent activity" IS this field.
        const when = self.stamp();
        putDos(e[22..26], when);
        putLe16(e[18..20], when.date);
        putCluster(e, first_cluster);
        e[28] = @truncate(size);
        e[29] = @truncate(size >> 8);
        e[30] = @truncate(size >> 16);
        e[31] = @truncate(size >> 24);
        try self.writeSector(entry.lba, self.scratch);
    }

    /// The cluster of a path's PARENT directory, plus the final component.
    /// "a/b/c" -> (cluster of a/b, "c"). A path with no slash is in the root.
    const Parent = struct { cluster: Cluster, name: []const u8 };

    fn parentOf(self: *Volume, path: []const u8) Error!Parent {
        // This file imports nothing, not even std: it is the driver, and the
        // two loops below are cheaper than the dependency.
        var end = path.len;
        while (end > 0 and path[end - 1] == '/') end -= 1;
        const trimmed = path[0..end];
        if (trimmed.len == 0) {
            props.reachable(@src(), "fat: a path with no name in it is refused", null);
            return Error.BadName;
        }

        var cut: ?usize = null;
        var i: usize = 0;
        while (i < trimmed.len) : (i += 1) {
            if (trimmed[i] == '/') cut = i;
        }
        if (cut == null) return .{ .cluster = 0, .name = trimmed };
        const at = cut.?;
        const dir = try self.open(trimmed[0..at]);
        if (!dir.isDirectory()) {
            props.reachable(@src(), "fat: a path whose parent is a file is refused", null);
            return Error.NotFat16;
        }
        return .{ .cluster = dir.first_cluster, .name = trimmed[at + 1 ..] };
    }

    /// **RENAMES A FILE WITHIN ITS DIRECTORY, OVER ANY FILE OF THE NEW NAME.**
    /// It is how a whole file is replaced without a moment when neither the
    /// old nor the new is there: the new is written under another name, then
    /// renamed over the old (angry-gopher's `store.replace`).
    ///
    /// The order, and what a machine that stops at each point leaves:
    ///   1. `from`'s entry goes; its chain stays allocated. Stopped here: `to`
    ///      is the old file, whole, and `from`'s clusters are leaked (the disk
    ///      check reports them).
    ///   2. when `to` exists, its short entry is pointed at `from`'s chain and
    ///      size, in one sector write. Stopped here: `to` is the new file,
    ///      whole, and its old clusters are leaked.
    ///   3. and only now `to`'s old chain is freed.
    /// When `to` does not exist, step 2 writes a new entry instead, and a
    /// machine that stops before it has lost a file nobody had yet.
    /// Never two entries on one chain, never a `to` that is neither file.
    ///
    /// `to` keeps the name it has (as a whole-file write does); a new `to`
    /// takes the case it is given. Both must be files in the same directory:
    /// a directory as `to` is `IsDirectory`, as on Linux; as `from`, `BadName`.
    pub fn rename(self: *Volume, from: []const u8, to: []const u8) Error!void {
        const a = try self.parentOf(from);
        const b = try self.parentOf(to);
        if (a.cluster != b.cluster) {
            props.reachable(@src(), "fat: a rename across directories is refused", null);
            return Error.BadName;
        }
        if (b.name.len == 0 or b.name.len > max_name) return Error.BadName;
        const src = (try self.find(a.cluster, a.name)) orelse {
            props.reachable(@src(), "fat: a rename of a file that is not there is refused", null);
            return Error.NotFound;
        };
        if (src.isDirectory()) {
            props.reachable(@src(), "fat: a rename of a directory is refused", null);
            return Error.BadName;
        }
        if (eqlFold(src.text(), b.name)) return; // the same file
        const dst = try self.find(b.cluster, b.name);
        if (dst) |d| if (d.isDirectory()) {
            props.reachable(@src(), "fat: a rename onto a directory is refused", null);
            return Error.IsDirectory;
        };

        // **A NEW `to` HAS ITS ROOM BEFORE `from` IS UNLINKED.** Unlinked
        // first, a directory with no room left (a full FAT16 root) returned
        // `DirectoryFull` with `from` gone and its chain leaked: a lost file,
        // on an error, not a stop (fat_sim, 2026-10-05). So a rename that
        // would fit only in the slots `from` frees is refused as full.
        var room: ?struct { short: [11]u8, run: Run } = null;
        if (dst == null) {
            const short = try self.aliasFor(b.cluster, b.name);
            const parts: u32 = if (needsLongName(b.name)) longParts(b.name) else 0;
            room = .{ .short = short, .run = try self.findRun(b.cluster, parts + 1) };
        }

        try self.unlinkEntry(a.cluster, a.name, false);

        if (dst) |d| {
            props.reachable(@src(), "fat: a rename replaces a file", null);
            try self.readSector(d.lba, self.scratch);
            const e = self.scratch[d.slot..][0..dirent_size];
            putCluster(e, src.first_cluster);
            e[28] = @truncate(src.size);
            e[29] = @truncate(src.size >> 8);
            e[30] = @truncate(src.size >> 16);
            e[31] = @truncate(src.size >> 24);
            const when = self.stamp();
            putLe16(e[18..20], when.date); // last access date
            putDos(e[22..26], when); // write time, write date
            try self.writeSector(d.lba, self.scratch);
            // The commit: `to` is the file now. The old chain freed after it
            // is cleanup (QUEUE 131, #3).
            if (d.first_cluster >= 2) self.afterCommit(self.freeChain(d.first_cluster));
            return;
        }

        const r = room.?;
        try self.writeEntry(r.run, if (needsLongName(b.name)) b.name else b.name[0..0], r.short, 0x20, src.first_cluster, src.size, null);
    }

    /// Deletes one file. removeEntry does the real work: it frees the
    /// cluster chain and tombstones both the short entry and the long-name
    /// run in front of it.
    ///
    /// **A DIRECTORY IS REFUSED** (`IsDirectory`), empty or not, as Linux's
    /// unlink refuses one (EISDIR). It once took a directory's entry like a
    /// file's and left everything under it allocated and reachable from
    /// nothing, a leak `check` reported (metal-vmm QUEUE B22, found by the
    /// cloud session's item 77). `removeTree` is how a directory goes.
    pub fn remove(self: *Volume, path: []const u8) Error!void {
        const p = try self.parentOf(path);
        const e = (try self.find(p.cluster, p.name)) orelse {
            props.reachable(@src(), "fat: a remove of a file that is not there is refused", null);
            return Error.NotFound;
        };
        if (e.isDirectory()) {
            props.reachable(@src(), "fat: a remove of a directory is refused", null);
            return Error.IsDirectory;
        }
        try self.removeEntry(p.cluster, p.name);
    }

    /// max_tree_depth bounds removeTree's recursion. The application's deepest
    /// tree is a player's game data, five levels down; this is generous, and it
    /// is a CAP rather than a guess because the recursion runs on a kernel
    /// stack with no guard page under it.
    const max_tree_depth: u32 = 16;

    /// The deepest directory `makePath` makes, counted from the root: `check`
    /// walks the root at depth 0 and calls a directory at `max_tree_depth`
    /// too deep, so the last it walks is one above that. `removeTree` counts
    /// from the directory it removes, so it takes any tree this allows.
    const max_path_depth: u32 = max_tree_depth - 1;

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
    ///
    /// **ONLY ABSENCE IS FINE.** Every other error is the caller's: a disk
    /// that stopped answering used to read as "nothing there", and an account
    /// deletion that removed nothing answered done (QUEUE.md item 79).
    pub fn removeTree(self: *Volume, path: []const u8) Error!void {
        const entry = self.open(path) catch |e| switch (e) {
            Error.NotFound => return,
            else => return e,
        };
        if (!entry.isDirectory()) return self.remove(path);
        try self.removeTreeAt(entry.first_cluster, 0);
        // The directory itself, emptied: by its entry, as removeTreeAt takes
        // each one under it (`remove` refuses a directory).
        const p = try self.parentOf(path);
        try self.removeEntry(p.cluster, p.name);
    }

    fn removeTreeAt(self: *Volume, dir_cluster: Cluster, depth: u32) Error!void {
        if (depth >= max_tree_depth) {
            props.reachable(@src(), "fat: a tree too deep to remove is refused", null);
            return Error.BadChain;
        }

        const First = struct {
            name: [max_name]u8 = undefined,
            len: usize = 0,
            is_dir: bool = false,
            cluster: Cluster = 0,
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
        props.reachable(@src(), "fat: a tree with more entries than a volume holds is refused as broken", null);
        return Error.DirectoryFull; // more entries than this is a broken volume
    }

    // ---- the boot-time check -------------------------------------------

    /// How many bytes `check` needs to borrow: a bit for every cluster.
    pub fn checkBytes(self: *const Volume) usize {
        return @as(usize, self.max_cluster) / 8 + 1;
    }

    /// **THE BOOT-TIME CHECK: WHAT IS WRONG WITH THIS VOLUME, SAID AND NEVER
    /// MENDED.** It walks the tree from the root and follows every chain,
    /// marking each cluster it holds in `seen` (`checkBytes` long, borrowed
    /// for the call). Then it reads the FAT on the disk for clusters in use
    /// that nothing holds, and compares the FAT's copies. Each thing wrong
    /// goes to `each` as a `Finding`, with the path it was found at; the
    /// answer counts what was walked and how many findings there were.
    ///
    /// **IT WRITES NOTHING.** A repair is a decision about whose data wins
    /// (which of two files sharing a cluster keeps it, whether a leaked run
    /// was a file the crash had not yet named), and fsck.vfat on a copy is
    /// where that decision belongs, made by a person, not by a machine
    /// halfway through booting.
    ///
    /// **THE MARKING IS WHAT ENDS THE WALK.** A chain that reaches a cluster
    /// already marked has crossed another chain, or looped back on itself,
    /// and it is followed no further; so every step marks a new cluster and
    /// the walk is at most as long as the volume. A directory whose chain
    /// crosses is not listed past the crossing, so a directory that points at
    /// its own ancestor is reported, not descended into for ever.
    ///
    /// The tree is walked `max_tree_depth` deep, as removeTree is: the
    /// recursion runs on a kernel stack with no guard page under it, and each
    /// level holds a sector.
    ///
    /// Errors are the disk's (ReadFailed), or `seen` too short (TooBig). A
    /// damaged volume is not an error: it is the answer.
    pub fn check(
        self: *Volume,
        seen: []u8,
        context: anytype,
        comptime each: fn (@TypeOf(context), Finding) void,
    ) Error!Health {
        if (seen.len < self.checkBytes()) {
            props.reachable(@src(), "fat: a check given too little room to mark clusters is refused", null);
            return Error.TooBig;
        }
        const len = self.checkBytes();
        @memset(seen[0..len], 0);
        var c = Checker(@TypeOf(context), each){ .vol = self, .seen = seen[0..len], .context = context };
        // FAT32's root is a chain, held like any directory's.
        const root_clusters: u32 = if (self.kind == .fat32) try c.chain(self.root_cluster, null) else 0;
        if (self.kind == .fat16 or root_clusters > 0) try c.directory(0, 0, root_clusters, 0);
        try c.fatOnDisk();
        return c.health;
    }

    fn Checker(comptime Context: type, comptime each: fn (Context, Finding) void) type {
        return struct {
            vol: *Volume,
            seen: []u8,
            context: Context,
            health: Health = .{},
            /// Some directory was not walked, so a leak cannot be told from
            /// what it holds.
            stopped_short: bool = false,
            /// The path being walked, for the findings: a name for each level.
            path: [max_tree_depth * (max_name + 1)]u8 = undefined,
            path_len: usize = 0,

            const Self = @This();

            fn report(self: *Self, problem: Problem, cluster: Cluster, count: u32) void {
                self.health.problems += 1;
                each(self.context, .{ .problem = problem, .path = self.path[0..self.path_len], .cluster = cluster, .count = count });
            }

            /// Marks `cluster` held, and answers whether it already was.
            fn mark(self: *Self, cluster: Cluster) bool {
                const bit = @as(u8, 1) << @intCast(cluster % 8);
                const was = self.seen[cluster / 8] & bit != 0;
                self.seen[cluster / 8] |= bit;
                return was;
            }

            fn held(self: *const Self, cluster: Cluster) bool {
                return self.seen[cluster / 8] & (@as(u8, 1) << @intCast(cluster % 8)) != 0;
            }

            /// Follows the chain from `first`, marking it, and answers how
            /// many clusters it holds before anything went wrong. `size` is a
            /// file's length, which its chain must match; null for a directory.
            fn chain(self: *Self, first: Cluster, size: ?u32) Error!u32 {
                const v = self.vol;
                const cluster_bytes = v.sectors_per_cluster * sector_size;
                const need: u32 = if (size) |n| (n + cluster_bytes - 1) / cluster_bytes else 0;
                if (first == 0) {
                    // An empty file has no chain. A directory always has one.
                    if (size == null or need > 0) self.report(if (size == null) .broken else .short, 0, 0);
                    return 0;
                }
                if (!v.inData(first)) {
                    self.report(.broken, first, 0);
                    return 0;
                }
                var n: u32 = 0;
                var cluster = first;
                while (true) {
                    if (self.mark(cluster)) {
                        self.report(.crossed, cluster, 0);
                        self.health.used += n;
                        return n;
                    }
                    n += 1;
                    const next = try v.fatGet(cluster);
                    if (next >= v.chainEndValue()) break;
                    if (!v.inData(next)) {
                        // Into a free cluster, past the last one, or into the
                        // bad-cluster mark. `cluster` is the last one held.
                        self.report(.broken, cluster, 0);
                        self.health.used += n;
                        return n;
                    }
                    cluster = next;
                }
                self.health.used += n;
                if (size != null) {
                    if (n < need) self.report(.short, first, n);
                    if (n > need) self.report(.long, first, n);
                }
                return n;
            }

            fn push(self: *Self, name: []const u8) usize {
                const was = self.path_len;
                if (self.path_len + 1 + name.len <= self.path.len) {
                    self.path[self.path_len] = '/';
                    @memcpy(self.path[self.path_len + 1 ..][0..name.len], name);
                    self.path_len += 1 + name.len;
                }
                return was;
            }

            /// Lists the directory at `cluster` (0: the root), over the first
            /// `clusters` clusters of its chain, which `chain` has already
            /// followed and found sound, and checks everything in it.
            fn directory(self: *Self, cluster: Cluster, parent: Cluster, clusters: u32, depth: u32) Error!void {
                const v = self.vol;
                // **A SECTOR OF ITS OWN**, not the volume's scratch: the walk
                // of each entry's chain reads the FAT through the scratch.
                var sector: [sector_size]u8 align(16) = undefined;
                var long: [max_name]u8 = undefined;
                var long_len: usize = 0;
                var long_sum: u8 = 0;
                var long_ok = false;

                // Only FAT16's root is a fixed run; FAT32's is a chain.
                const fixed_root = cluster == 0 and v.kind == .fat16;
                const sectors: u32 = if (fixed_root) v.root_sectors else clusters * v.sectors_per_cluster;
                var at_cluster = v.dirStart(cluster);
                var k: u32 = 0;
                while (k < sectors) : (k += 1) {
                    const lba = if (fixed_root) v.root_start + k else blk: {
                        if (k > 0 and k % v.sectors_per_cluster == 0) at_cluster = try v.fatGet(at_cluster);
                        break :blk v.clusterSector(at_cluster) + k % v.sectors_per_cluster;
                    };
                    try v.readSector(lba, &sector);
                    var at: usize = 0;
                    while (at + dirent_size <= sector_size) : (at += dirent_size) {
                        const e = sector[at..][0..dirent_size];
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
                        var entry = v.entryFrom(e);
                        if (long_ok and long_len > 0 and long_sum == shortChecksum(e[0..11].*)) {
                            entry.long_len = @intCast(@min(long_len, entry.long.len));
                            @memcpy(entry.long[0..entry.long_len], long[0..entry.long_len]);
                        }
                        long_ok = false;
                        long_len = 0;
                        try self.entryIn(entry, cluster, parent, depth);
                    }
                }
            }

            fn entryIn(self: *Self, entry: Entry, dir: Cluster, parent: Cluster, depth: u32) Error!void {
                const name = entry.text();
                // "." is this directory and ".." its parent, 0 for the root.
                if (eqlBytes(name, ".") or eqlBytes(name, "..")) {
                    const want = if (eqlBytes(name, ".")) dir else parent;
                    if (dir == 0 or entry.first_cluster != want) {
                        const was = self.push(name);
                        self.report(.bad_dot, entry.first_cluster, 0);
                        self.path_len = was;
                    }
                    return;
                }
                const was = self.push(name);
                defer self.path_len = was;
                if (entry.isDirectory()) {
                    self.health.directories += 1;
                    const n = try self.chain(entry.first_cluster, null);
                    if (n == 0) return;
                    if (depth + 1 >= max_tree_depth) {
                        self.stopped_short = true;
                        self.report(.too_deep, entry.first_cluster, 0);
                        return;
                    }
                    try self.directory(entry.first_cluster, dir, n, depth + 1);
                } else {
                    self.health.files += 1;
                    _ = try self.chain(entry.first_cluster, entry.size);
                }
            }

            /// The FAT as it sits on the disk: every copy against the first,
            /// and every cluster in use against what the walk held.
            fn fatOnDisk(self: *Self) Error!void {
                const v = self.vol;
                // **IN RUNS, NOT A SECTOR A REQUEST**: each copy is read
                // `run_sectors` at a time. A sector a request was two
                // thousand requests a disk at every boot, the most of what a
                // boot cost on metal-vmm.
                var firsts: [run_sectors * sector_size]u8 align(16) = undefined;
                var others: [run_sectors * sector_size]u8 align(16) = undefined;
                var differ: u32 = 0;
                var differ_at: Cluster = 0;
                var run_start: Cluster = 0;
                var run: u32 = 0;
                var free: u32 = 0;
                var base: u32 = 0;
                while (base < v.sectors_per_fat) {
                    const n = @min(run_sectors, v.sectors_per_fat - base);
                    try v.readSectors(v.fat_start + base, n, &firsts);
                    var copy: u32 = 1;
                    while (copy < v.num_fats) : (copy += 1) {
                        try v.readSectors(v.fat_start + copy * v.sectors_per_fat + base, n, &others);
                        var k: u32 = 0;
                        while (k < n) : (k += 1) {
                            const first = firsts[k * sector_size ..][0..sector_size];
                            const other = others[k * sector_size ..][0..sector_size];
                            if (std.mem.eql(u8, first, other)) continue;
                            if (differ == 0) {
                                var i: usize = 0;
                                while (first[i] == other[i]) i += 1;
                                differ_at = @intCast((base + k) * v.entriesPerSector() + i / v.entryBytes());
                            }
                            differ += 1;
                        }
                    }
                    var k: u32 = 0;
                    while (k < n) : (k += 1) {
                        const s = base + k;
                        // Leaks and the free count are the FAT the machine
                        // uses: the one held, when it is held (a sector of
                        // the first copy that reads wrong is not it, B26);
                        // the copies are compared as the disk holds them.
                        const entries: *const [sector_size]u8 = if (v.fat) |fat| fat[s * sector_size ..][0..sector_size] else firsts[k * sector_size ..][0..sector_size];
                        var i: u32 = 0;
                        const per = v.entriesPerSector();
                        while (i < per) : (i += 1) {
                            const c = s * per + i;
                            if (c < 2) continue;
                            if (c > v.max_cluster) break;
                            const value = v.entryIn(entries, i);
                            if (value == 0) free += 1;
                            const leaked = !self.stopped_short and value != 0 and value != v.badMark() and !self.held(@intCast(c));
                            if (leaked) {
                                if (run == 0) run_start = @intCast(c);
                                run += 1;
                            } else if (run > 0) {
                                self.leak(run_start, run);
                                run = 0;
                            }
                        }
                    }
                    base += n;
                }
                if (run > 0) self.leak(run_start, run);
                if (differ > 0) self.report(.fats_differ, differ_at, differ);
                if (v.kind == .fat32 and v.fsinfo_sector != 0 and v.fsinfo_sector < v.fat_start) {
                    var fsinfo: [sector_size]u8 align(16) = undefined;
                    try v.readSector(v.fsinfo_sector, &fsinfo);
                    if (le32(fsinfo[0..4]) == 0x4161_5252 and le32(fsinfo[484..488]) == 0x6141_7272) {
                        self.path_len = 0;
                        const count = le32(fsinfo[488..492]);
                        const hint = le32(fsinfo[492..496]);
                        if (count != 0xFFFF_FFFF and count != free) self.report(.fsinfo, 0, count);
                        if (hint != 0xFFFF_FFFF and !v.inData(hint)) self.report(.fsinfo, hint, 0);
                    }
                }
            }

            fn leak(self: *Self, start: Cluster, count: u32) void {
                self.health.leaked += count;
                self.path_len = 0;
                self.report(.leaked, start, count);
            }
        };
    }

    /// A whole file into `out`, which must be large enough to hold it.
    ///
    /// It is readAt from zero, so that every probe that reads a whole file —
    /// fat16, vfat, restore, stdio, append — also exercises the positional
    /// read the application uses for Range requests.
    pub fn readFile(self: *Volume, entry: Entry, out: []u8) Error!usize {
        if (entry.isDirectory()) {
            props.reachable(@src(), "fat: a directory read as a file is refused, reading a file whole", null);
            return Error.NotFound;
        }
        if (entry.size > out.len) {
            props.reachable(@src(), "fat: a file larger than the room to read it into is refused", null);
            return Error.TooBig;
        }
        const n = try self.readAt(entry, 0, out[0..entry.size]);
        if (n != entry.size) { // the chain ended before the size did
            // `readAt` refuses a chain that ends early before it answers.
            props.@"unreachable"(@src(), "fat: a file's chain ends before its size, reading a file whole", null);
            return Error.BadChain;
        }
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
    /// How a file sits on the disk.
    pub const Layout = struct {
        clusters: u32,
        /// Stretches of consecutive clusters. One is a contiguous file.
        runs: u32,
        /// The most clusters in any one run.
        longest: u32,
    };

    /// **FOR A PROBE TO CHECK ITS OWN COVERAGE**, and for telemetry: readAt
    /// takes a different path at every break in a chain, and a probe whose
    /// files happen to be contiguous is not testing that path at all.
    pub fn layout(self: *Volume, entry: Entry) Error!Layout {
        var out = Layout{ .clusters = 0, .runs = 0, .longest = 0 };
        var cluster = entry.first_cluster;
        if (cluster < 2) return out;
        if (!self.inData(cluster)) {
            props.reachable(@src(), "fat: a file's first cluster is outside the data, when its layout is asked", null);
            return Error.BadChain;
        }
        var previous: Cluster = 0;
        var run: u32 = 0;
        while (true) {
            out.clusters += 1;
            if (previous != 0 and cluster == previous + 1) {
                run += 1;
            } else {
                out.runs += 1;
                run = 1;
            }
            out.longest = @max(out.longest, run);
            previous = cluster;
            cluster = (try self.nextCluster(cluster)) orelse break;
            // A reserved cluster cannot come back from `nextCluster`; a
            // loop can, and goes round until the count passes the volume.
            if (cluster < 2) {
                props.@"unreachable"(@src(), "fat: a file's layout finds a reserved cluster", null);
                return Error.BadChain;
            }
            if (out.clusters > self.max_cluster) {
                props.reachable(@src(), "fat: a file's layout counts more clusters than the volume holds: a loop", null);
                return Error.BadChain;
            }
        }
        return out;
    }

    pub fn readAt(self: *Volume, entry: Entry, offset: u32, out: []u8) Error!usize {
        if (entry.isDirectory()) {
            props.reachable(@src(), "fat: a directory read as a file is refused, reading at an offset", null);
            return Error.NotFound;
        }
        if (offset >= entry.size or out.len == 0) return 0;
        const want: usize = @min(out.len, entry.size - offset);

        const cluster_bytes: u32 = self.sectors_per_cluster * sector_size;
        var cluster = entry.first_cluster;
        if (!self.inData(cluster)) { // a non-empty file has a chain
            props.reachable(@src(), "fat: a file's first cluster is outside the data", null);
            return Error.BadChain;
        }
        // **A CHAIN THAT LOOPS IS REFUSED**, as a directory walk and an append
        // refuse one. The read stops at the file's size, so without this a
        // looped chain answers its earlier clusters' bytes again as the
        // file's, with no error, to whoever asked for the file. `Loop` finds
        // a loop within about two laps of it, so a file that ends inside
        // those can still answer a repeated cluster: narrower, not closed.
        var loop = Loop{};
        try loop.pass(cluster);
        var skip = offset / cluster_bytes;
        while (skip > 0) : (skip -= 1) {
            cluster = (try self.nextCluster(cluster)) orelse {
                props.reachable(@src(), "fat: a file's chain ends before its size, reading at an offset, at its start", null);
                return Error.BadChain;
            };
            if (cluster < 2) {
                // `nextCluster` refuses any link outside the data first.
                props.@"unreachable"(@src(), "fat: a file's chain points at a reserved cluster, reading at an offset, at its start", null);
                return Error.BadChain;
            }
            try loop.pass(cluster);
        }

        // **A FILE IS READ AS RUNS.** A run is a cluster and every cluster
        // after it whose number is one more than the last — the stretch of
        // disk the file occupies without a gap. Whole sectors in a run go
        // straight into `out` as one request; only a sector the read starts or
        // ends inside goes through the scratch sector, because the device
        // cannot deliver part of one.
        var sector_in_cluster: u32 = (offset % cluster_bytes) / sector_size;
        var skip_in_sector: u32 = (offset % cluster_bytes) % sector_size;
        var got: usize = 0;
        const max_run = @max(1, virtio.Block.max_sectors / self.sectors_per_cluster);
        while (got < want) {
            // How far this run goes, stopping once it holds all that is wanted.
            var run: u32 = 1;
            var last = cluster;
            var after: ?Cluster = null;
            while (true) {
                const have = run * cluster_bytes - sector_in_cluster * sector_size - skip_in_sector;
                const next = try self.nextCluster(last);
                if (next == null) break;
                if (got + have >= want or run >= max_run or next.? != last + 1) {
                    after = next;
                    break;
                }
                last = next.?;
                try loop.pass(last);
                run += 1;
            }

            var lba = self.clusterSector(cluster) + sector_in_cluster;
            var sectors_left = run * self.sectors_per_cluster - sector_in_cluster;

            if (skip_in_sector != 0) {
                try self.readSector(lba, self.scratch);
                const n = @min(want - got, @as(usize, sector_size - skip_in_sector));
                @memcpy(out[got..][0..n], self.scratch[skip_in_sector..][0..n]);
                got += n;
                lba += 1;
                sectors_left -= 1;
                skip_in_sector = 0;
            }

            const whole: u32 = @intCast(@min(@as(usize, sectors_left), (want - got) / sector_size));
            if (whole > 0) {
                try self.readSectors(lba, whole, out[got..].ptr);
                got += @as(usize, whole) * sector_size;
                lba += whole;
                sectors_left -= whole;
            }

            if (got < want and sectors_left > 0) {
                try self.readSector(lba, self.scratch);
                const n = @min(want - got, @as(usize, sector_size));
                @memcpy(out[got..][0..n], self.scratch[0..n]);
                got += n;
            }

            if (got >= want) break;
            cluster = after orelse {
                props.reachable(@src(), "fat: a file's chain ends before its size, reading at an offset, past its first run", null);
                return Error.BadChain;
            };
            if (cluster < 2) {
                props.@"unreachable"(@src(), "fat: a file's chain points at a reserved cluster, reading at an offset, past its first run", null);
                return Error.BadChain;
            }
            try loop.pass(cluster);
            sector_in_cluster = 0;
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
    // As many parts as a name of max_name characters needs, which is what
    // writeFileIn accepts: max_name / 13 rounded DOWN refused the last part
    // of every name from 53 to 64 characters, so such a file was written and
    // then found only under its 8.3 alias.
    if (seq == 0 or seq > (max_name + 12) / 13) {
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
/// A directory entry's first cluster, both halves: the low at 26..28 and the
/// high at 20..22 (FAT32.md §6). On FAT16 the high half of every cluster is 0,
/// which is also what the spec wants those bytes to hold there; so one
/// writer serves both kinds, and a FAT32 file past cluster 65,535 is not the
/// case that gets forgotten.
fn putCluster(e: []u8, cluster: Cluster) void {
    e[26] = @truncate(cluster);
    e[27] = @truncate(cluster >> 8);
    e[20] = @truncate(cluster >> 16);
    e[21] = @truncate(cluster >> 24);
}

fn putLe16(out: *[2]u8, v: u16) void {
    out[0] = @truncate(v);
    out[1] = @truncate(v >> 8);
}

/// A time field then a date field, which is how both pairs sit on disk.
fn putDos(out: *[4]u8, d: Dos) void {
    putLe16(out[0..2], d.time);
    putLe16(out[2..4], d.date);
}

fn decode(e: []const u8) Entry {
    var out: Entry = .{
        .name = [_]u8{0} ** 12,
        .name_len = 0,
        .short = e[0..11].*,
        .attr = e[11],
        .first_cluster = le16(e[26..28]),
        .size = le32(e[28..32]),
        .mtime_unix = (Dos{ .time = le16(e[22..24]), .date = le16(e[24..26]) }).toUnix(),
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

    // **THE NT CASE BITS** (byte 12): Windows and mtools store a name that
    // fits 8.3 in one case, `topic.md` or `TOPIC.md`, as its upper-case alias
    // and no long name. Bit 3 says the base was lower case, bit 4 the
    // extension. The name to show and to list is then that, put in `long`; a
    // real long name, when `list` finds one, replaces it. `alias()` stays
    // the alias. Linux's vfat writes a long name instead, and so does this
    // file, so only a volume another system wrote has these.
    const lower_base = e[12] & 0x08 != 0;
    const lower_ext = e[12] & 0x10 != 0;
    if (lower_base or lower_ext) {
        for (out.name[0..n], 0..) |c, i| {
            const in_ext = i >= base;
            out.long[i] = if ((in_ext and lower_ext) or (!in_ext and lower_base)) std.ascii.toLower(c) else c;
        }
        out.long_len = @intCast(n);
    }
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

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// The pure half only — the packing of a date into the two 16-bit fields a
// directory entry carries. **The expected on-disk words were computed by hand
// from the format, and the round trip is checked against an INDEPENDENT
// oracle**: probe/run.sh writes a volume on the machine and asks the Linux
// VFAT driver what time it thinks those files were written.

const testing = std.testing;

test "the fields are packed the way the format says" {
    // 2026-09-17T10:38:52Z: year 46 since 1980, month 9, day 17; hour 10,
    // minute 38, second 52 -> 26 two-second units.
    const d = Dos.fromUnix(1789641532);
    try testing.expectEqual(@as(u16, 46 << 9 | 9 << 5 | 17), d.date);
    try testing.expectEqual(@as(u16, 10 << 11 | 38 << 5 | 26), d.time);
    try testing.expectEqual(@as(i64, 1789641532), d.toUnix());
}

test "an odd second rounds DOWN, and says so on the way back" {
    const d = Dos.fromUnix(1789641533);
    try testing.expectEqual(@as(i64, 1789641532), d.toUnix());
}

test "every two-second instant of a day round-trips" {
    const midnight: i64 = 1789603200; // 2026-09-17T00:00:00Z
    var s: i64 = 0;
    while (s < 86400) : (s += 2) {
        try testing.expectEqual(midnight + s, Dos.fromUnix(midnight + s).toUnix());
    }
}

test "the ends of the range, and past them" {
    try testing.expectEqual(@as(i64, Dos.first_unix), Dos.fromUnix(Dos.first_unix).toUnix());
    try testing.expectEqual(@as(i64, Dos.last_unix - 1), Dos.fromUnix(Dos.last_unix).toUnix());
    // A year the format cannot hold is no date, never a wrapped one.
    try testing.expectEqual(Dos.none, Dos.fromUnix(Dos.first_unix - 1));
    try testing.expectEqual(Dos.none, Dos.fromUnix(Dos.last_unix + 1));
    try testing.expectEqual(Dos.none, Dos.fromUnix(0));
    try testing.expectEqual(@as(i64, 0), Dos.none.toUnix());
}

test "a leap day survives both directions" {
    const leap: i64 = 1582934400; // 2020-02-29T00:00:00Z
    const d = Dos.fromUnix(leap);
    try testing.expectEqual(@as(u16, 40 << 9 | 2 << 5 | 29), d.date);
    try testing.expectEqual(leap, d.toUnix());
}

test "garbage on the disk is not a plausible date" {
    // Month 0, month 13, day 0, day 31 of September, hour 31, minute 63: each
    // is a bit pattern a damaged entry can hold, and none is a time.
    const bad = [_]Dos{
        .{ .date = 46 << 9 | 0 << 5 | 17, .time = 0 },
        .{ .date = 46 << 9 | 13 << 5 | 17, .time = 0 },
        .{ .date = 46 << 9 | 9 << 5 | 0, .time = 0 },
        .{ .date = 46 << 9 | 9 << 5 | 31, .time = 0 },
        .{ .date = 46 << 9 | 2 << 5 | 30, .time = 0 }, // February 30th
        .{ .date = 46 << 9 | 9 << 5 | 17, .time = 31 << 11 },
        .{ .date = 46 << 9 | 9 << 5 | 17, .time = 63 << 5 },
    };
    for (bad) |d| try testing.expectEqual(@as(i64, 0), d.toUnix());
}

test "February 29th of a non-leap year is refused" {
    // 2100 is not a leap year; the field can still hold the 29th.
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = 120 << 9 | 2 << 5 | 29, .time = 0 }).toUnix());
    // 2000 is, so the same shape 100 years earlier IS a date.
    try testing.expect((Dos{ .date = 20 << 9 | 2 << 5 | 29, .time = 0 }).toUnix() != 0);
}

test "a date of zero is no date, whatever the time field says" {
    try testing.expectEqual(@as(i64, 0), (Dos{ .date = 0, .time = 10 << 11 }).toUnix());
}

test "on disk the time word comes first, then the date word" {
    // The mutation this catches — the two words swapped — reads back through
    // our own decoder as a date in 2023 and passes every test above. It is the
    // Linux VFAT driver in probe/run.sh that noticed; this is the same
    // question asked where it is cheap.
    const when = Dos.fromUnix(1789641532);
    var e = [_]u8{0} ** dirent_size;
    putDos(e[22..26], when);
    try testing.expectEqual(when.time, le16(e[22..24]));
    try testing.expectEqual(when.date, le16(e[24..26]));
    try testing.expectEqual(@as(i64, 1789641532), decode(&e).mtime_unix);
}

/// The long-name entries a name is written as, last part first, as they sit
/// in a directory: what `writeEntry` writes, built here for the reader alone.
fn longEntriesFor(name: []const u8, sum: u8, out: [][32]u8) usize {
    const parts = longParts(name);
    var k: usize = 0;
    var seq: usize = parts;
    while (seq >= 1) : (seq -= 1) {
        var e = [_]u8{0xFF} ** 32;
        e[0] = @intCast(seq);
        if (seq == parts) e[0] |= 0x40;
        e[11] = attr_long_name;
        e[12] = 0;
        e[13] = sum;
        e[26] = 0;
        e[27] = 0;
        for (long_offsets, 0..) |off, i| {
            const at = (seq - 1) * 13 + i;
            const c: u16 = if (at < name.len) name[at] else if (at == name.len) 0 else 0xFFFF;
            e[off] = @truncate(c);
            e[off + 1] = @truncate(c >> 8);
        }
        out[k] = e;
        k += 1;
    }
    return k;
}

test "every name the writer accepts, the reader reads back whole" {
    // writeFileIn takes names up to max_name; the reader must take as many
    // long-name parts as such a name needs.
    var buf: [max_name]u8 = undefined;
    for (1..max_name + 1) |len| {
        for (buf[0..len], 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
        const name = buf[0..len];
        var entries: [8][32]u8 = undefined;
        const n = longEntriesFor(name, 0x5A, &entries);
        var long: [max_name]u8 = undefined;
        var long_len: usize = 0;
        var sum: u8 = 0;
        var ok = false;
        for (entries[0..n]) |*e| takeLongPart(e, &long, &long_len, &sum, &ok);
        try testing.expect(ok);
        try testing.expectEqualStrings(name, long[0..long_len]);
    }
}
