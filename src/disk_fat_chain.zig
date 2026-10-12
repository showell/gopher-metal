//! disk_fat_chain: cluster chains. Free space found and taken
//! (`allocChain`), given back after a commit (`freeAfterCommit`), written
//! (`writeChain`), and the ledger that proves every cluster taken is linked,
//! given back, or counted as left (split from disk_fat.zig by metal-vmm QUEUE
//! 173).

const std = @import("std");
const builtin = @import("builtin");
const virtio = @import("virtio.zig");
const props = @import("coverage");
const plant = @import("plant.zig");
const dirent = @import("disk_fat_dirent.zig");
const Cluster = dirent.Cluster;
const disk_fat = @import("disk_fat.zig");
const Volume = disk_fat.Volume;
const Landing = Volume.Landing;
const sector_size = disk_fat.sector_size;
const Error = disk_fat.Error;

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

/// The data region's bytes, and how many are free (`free_clusters`).
pub fn space(self: *Volume) Error!struct { total: u64, free: u64 } {
    const cluster_bytes: u64 = @as(u64, self.sectors_per_cluster) * sector_size;
    return .{ .total = (@as(u64, self.max_cluster) - 1) * cluster_bytes, .free = @as(u64, self.free_clusters) * cluster_bytes };
}

/// The free count afresh from the FIRST COPY on the disk, not the held
/// FAT, for tests and simulators. It equals `free_clusters` except where
/// the disk's first copy and the held FAT differ: the second copy trusted
/// and its repair refused, or a failed write taken as landed that did not.
pub fn countFreeAgain(self: *Volume) Error!u32 {
    return (try self.deriveFrom(.disk)).free;
}

/// A chain of `count` clusters, linked and terminated; answers its first.
/// A count of zero answers cluster 0, an empty file's.
///
/// **A FAILED ALLOCATION GIVES BACK WHAT IT TOOK**, on every error, since
/// nothing points at the chain yet. Where a failed write leaves an entry
/// that cannot be read exactly, the chain is left a counted leak instead
/// (`leftLeaked`), never walked through rot.
pub fn allocChain(self: *Volume, count: u32, spend: Spend) Error!Cluster {
    if (count == 0) return 0;
    // **THE RESERVE** (`reserve_clusters`): an allocation for a large
    // file that would leave less free than the reserve, once what the
    // operation frees after it is back, is refused before it takes
    // anything. One that takes no more than it frees spends nothing.
    if (spend.bytes > small_bytes and count > spend.frees and self.free_clusters + spend.frees < @as(u64, count) + self.reserve_clusters) {
        props.reachable(@src(), "fat: a large allocation is refused to keep the reserve for small writes", .{ .count = count, .free = self.free_clusters, .bytes = spend.bytes });
        return Error.Full;
    }
    if (self.fat) |fat| return self.allocChainHeld(fat, count);
    var first: Cluster = 0;
    var previous: Cluster = 0;
    // The clusters linked from `first`: `taken`, and a candidate whose
    // failed link landed.
    var in_chain: u32 = 0;
    errdefer if (first != 0) self.giveBack(first, in_chain);
    var taken: u32 = 0;
    var candidate: Cluster = @max(self.alloc_hint, 2);
    // Once round the volume at most: a wrong hint costs a wrap, not a
    // wrong answer.
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
        // Its own mark may land and still fail, by `fatSet`'s verdict:
        // landed, given back; not landed, nothing to do; unknown, a
        // cluster that may be taken or free (148(b)).
        var mark: Landing = .before;
        self.fatSet(candidate, self.endMark(), &mark) catch |e| { // the end, until something follows
            switch (mark) {
                .before => {},
                .landed => {
                    self.took(1);
                    self.giveBack(candidate, 1);
                },
                // Never counted taken, as it may not be: one cluster
                // that may be left taken, nothing pointing at it.
                .unknown => {
                    self.leftUnsure(0);
                    self.unsure_clusters +|= 1;
                },
            }
            return e;
        };
        self.took(1);
        // A failed link, by the verdict. Landed: the chain has the
        // candidate, and the errdefer frees both (freeing it here too
        // would free it twice). Not landed: the candidate goes back
        // alone, the chain by the errdefer. Unknown: candidate and chain
        // are a counted leak, and the errdefer does not walk them.
        var link: Landing = .before;
        if (previous != 0) self.fatSet(previous, candidate, &link) catch |e| {
            switch (link) {
                .landed => in_chain += 1,
                .before => self.giveBack(candidate, 1),
                .unknown => {
                    self.leftLeaked(taken + 1);
                    first = 0;
                },
            }
            return e;
        };
        if (first == 0) first = candidate;
        previous = candidate;
        taken += 1;
        in_chain = taken;
        candidate += 1;
    }
    self.alloc_hint = candidate;
    return first;
}

/// `allocChain` with the FAT held: **A FAT SECTOR AT A TIME** (metal-vmm
/// B42). Every free cluster the chain still needs in one sector is
/// marked and linked in the held sector, the last an end, and the sector
/// is written once to each copy; then the batch is linked to the chain
/// so far by one `fatSet`, as a single cluster was. Per cluster, two
/// entries each wrote their sector to both copies: four writes, ~5.8 ms
/// each on production's volume. Nothing points at the chain until the
/// caller's commit, so a stop between the writes leaves lost clusters,
/// as it did.
///
/// **A BATCH'S WRITE HAS ONE VERDICT** (`heldRefused`), as one mark's
/// did: not landed, the held sector goes back as it was; landed, the
/// batch is taken and given back; unknown, taken as written and never
/// counted taken, a counted leak.
pub fn allocChainHeld(self: *Volume, fat: []u8, count: u32) Error!Cluster {
    var first: Cluster = 0;
    var previous: Cluster = 0;
    // The clusters linked from `first`: `taken`, and a batch whose
    // failed link landed.
    var in_chain: u32 = 0;
    errdefer if (first != 0) self.giveBack(first, in_chain);
    var taken: u32 = 0;
    var candidate: Cluster = @max(self.alloc_hint, 2);
    // Once round the volume at most: a wrong hint costs a wrap, not a
    // wrong answer.
    var looked: u32 = 0;
    const clusters: u32 = self.max_cluster - 1;
    const width = self.entryBytes();

    while (taken < count) {
        // The batch's first: the next free cluster.
        while (true) {
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
            if ((try self.fatGet(candidate)) == 0) break;
            candidate += 1;
        }
        // Let go before the first change, as `fatSet` does: a full
        // volume answers Full having written nothing.
        try self.forgetFsInfo();
        const in_sector = candidate * width / sector_size;
        const sector = fat[in_sector * sector_size ..][0..sector_size];
        var was: [sector_size]u8 = undefined;
        @memcpy(&was, sector);
        const batch_first = candidate;
        var last: Cluster = 0;
        var n: u32 = 0;
        // Every free cluster left in this sector that the chain still
        // needs, each linked from the one before, the last an end.
        batch: while (true) {
            self.putEntry(sector, candidate * width % sector_size, self.endMark());
            if (last != 0) self.putEntry(sector, last * width % sector_size, candidate);
            last = candidate;
            n += 1;
            candidate += 1;
            if (taken + n == count) break;
            while (candidate <= self.max_cluster and candidate * width / sector_size == in_sector and looked < clusters) {
                looked += 1;
                if (self.entryIn(sector, candidate * width % sector_size / width) == 0) continue :batch;
                candidate += 1;
            }
            break;
        }
        if (n > 1) props.reachable(@src(), "fat: an allocation takes several clusters in one FAT sector write", .{ .clusters = n });

        self.writeSector(self.fat_start + in_sector, sector) catch |e| {
            switch (self.heldRefused(self.fat_start + in_sector, sector, &was)) {
                .before => @memcpy(sector, &was),
                .landed => {
                    self.keepTaken(n);
                    self.writeCopies(in_sector, sector);
                    self.took(n);
                    self.giveBack(batch_first, n);
                },
                // Taken as written, and the first copy written again
                // once, as `fatSet` does: the batch is then taken on the
                // disk too, nothing pointing at it, so taken and a
                // counted leak, all `n` of it. Where that write fails
                // too, the disk may hold it taken or free (148(b)).
                .unknown => {
                    self.keepTaken(n);
                    const again = if (self.writeSector(self.fat_start + in_sector, sector)) true else |_| false;
                    if (!again) self.copyApart();
                    self.writeCopies(in_sector, sector);
                    self.took(n);
                    if (again) self.leftLeaked(n) else self.leftUnsure(n);
                },
            }
            return e;
        };
        self.keepTaken(n);
        self.writeCopies(in_sector, sector);
        self.took(n);
        // The batch linked on, by the verdict, as one cluster was.
        // Landed: the chain has the batch, and the errdefer frees both.
        // Not landed: the batch goes back alone, the chain by the
        // errdefer. Unknown: batch and chain are a counted leak, and the
        // errdefer does not walk them.
        var link: Landing = .before;
        if (previous != 0) self.fatSet(previous, batch_first, &link) catch |e| {
            switch (link) {
                .landed => in_chain += n,
                .before => self.giveBack(batch_first, n),
                .unknown => {
                    self.leftLeaked(taken + n);
                    first = 0;
                },
            }
            return e;
        };
        if (first == 0) first = batch_first;
        previous = last;
        taken += n;
        in_chain = taken;
    }
    self.alloc_hint = candidate;
    return first;
}

/// `n` free clusters taken, in the kept count.
pub fn keepTaken(self: *Volume, n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) self.keepCount(0, self.endMark());
}

/// `n` clusters freed, in the kept count.
pub fn keepFreed(self: *Volume, n: u32) void {
    self.free_clusters +|= n;
    // As keepCount's floor, a ceiling: more free than the volume holds
    // would admit writes that then fail part way (the normalization hunt).
    props.always(@src(), self.free_clusters <= self.max_cluster - 1, "fat: the kept free count never runs past the volume's clusters", .{ .free = self.free_clusters, .clusters = self.max_cluster - 1 });
}

/// **WHETHER A HELD FAT SECTOR'S REFUSED WRITE LANDED**, read back once
/// into scratch and judged on the entries the write changed (where
/// `written` and `was` differ) only: the held sector may differ from the
/// disk's elsewhere and be right to (copies left apart, an earlier write
/// taken as landed). Every one as written, `landed`; every one as it
/// was, `before`; anything else, or a read-back that failed, `unknown`.
/// A batch taken (`allocChainHeld`) and a batch freed
/// (`freeAfterCommitHeld`) are judged by it.
pub fn heldRefused(self: *Volume, lba: u32, written: *const [sector_size]u8, was: *const [sector_size]u8) Landing {
    self.readSector(lba, self.scratch) catch {
        props.reachable(@src(), "fat: a held FAT sector whose write failed cannot be read again", null);
        return .unknown;
    };
    const width = self.entryBytes();
    var as_written = true;
    var as_was = true;
    var i: u32 = 0;
    while (i < sector_size / width) : (i += 1) {
        const new = self.entryIn(written, i);
        const old = self.entryIn(was, i);
        if (new == old) continue;
        const now = self.entryIn(self.scratch, i);
        if (now != new) as_written = false;
        if (now != old) as_was = false;
    }
    if (as_written) return .landed;
    if (as_was) return .before;
    props.reachable(@src(), "fat: a held FAT sector whose write failed reads back as neither", null);
    return .unknown;
}

/// The reserve's most (`reserve_clusters`), and the largest file that may
/// spend it.
pub const reserve_bytes: u32 = 64 << 20;

pub const small_bytes: u32 = 64 << 10;

/// What an allocation is for, as the reserve judges it: the size of the
/// file it makes (an appended file's size after; zero for a directory's
/// growth), and the clusters the operation frees after it (an
/// overwrite's old chain).
pub const Spend = struct { bytes: u64, frees: u64 = 0 };

/// The `clusters` the operation took, left taken because what a failed
/// write left could not be read exactly: a counted leak
/// (`cleanups_failed`), and their end in the ledger.
pub fn leftLeaked(self: *Volume, clusters: u32) void {
    self.cleanups_failed +%= 1;
    self.leaked_clusters +|= clusters;
    props.reachable(@src(), "fat: clusters left taken, what a failed write left not read exactly", .{ .count = self.cleanups_failed });
    self.ended(clusters);
}

/// The `clusters` the operation took, left taken where what a failed
/// write left is `unknown`: an entry may point at them, or none may
/// (148(a)). Counted apart (`unsure_clusters`), and their end in the
/// ledger.
pub fn leftUnsure(self: *Volume, clusters: u32) void {
    self.cleanups_failed +%= 1;
    self.unsure_clusters +|= clusters;
    props.reachable(@src(), "fat: clusters left taken, and whether an entry points at them is unknown", .{ .count = self.cleanups_failed });
    self.ended(clusters);
}

/// The chain from `first`, `clusters` long, taken and not yet pointed
/// at, given back on an error before the commit. Either way the
/// clusters end in the ledger.
///
/// **THE CHAIN IS WALKED AS IT WAS MADE, NOT AS IT READS.** Exactly
/// `clusters` of it, each next in the data region and the last an end
/// mark. Without a held FAT each next is read from the disk, and a disk
/// that lies reads back another value: a walk that followed it stopped
/// short and left the rest taken and uncounted (the ledger found it). A
/// next of any other shape stops the walk. What is left, and a give-back
/// whose read or write fails, is a counted leak (`cleanups_failed`),
/// never swallowed.
///
/// **NOT EVERY LIE IS SEEN.** A read that answers some other cluster in
/// the data region still leads the walk on: into another file's chain at
/// worst, freeing up to `clusters` of it. Only a held FAT, which reads
/// nothing back from the disk, rules that out.
pub fn giveBack(self: *Volume, first: Cluster, clusters: u32) void {
    defer self.ended(clusters);
    var cluster = first;
    var freed: u32 = 0;
    while (freed < clusters) : (freed += 1) {
        const next = self.fatGet(cluster) catch return self.notGivenBack(freed, clusters);
        const shaped = if (freed + 1 == clusters) self.isEnd(next) else self.inData(next);
        if (!shaped) {
            props.reachable(@src(), "fat: a chain given back reads back other than it was made, and is left a counted leak", .{ .at = freed, .of = clusters, .next = next });
            return self.notGivenBack(freed, clusters);
        }
        // **THE HINT IS LOWERED FIRST**, as in freeAfterCommit.
        if (cluster < self.alloc_hint) self.alloc_hint = cluster;
        // A refused free, by its verdict (148(b)): landed, the cluster
        // is free and not left; unknown, it may be either.
        var landing: Landing = .before;
        self.fatSet(cluster, 0, &landing) catch return switch (landing) {
            .before => self.notGivenBack(freed, clusters),
            .landed => self.notGivenBack(freed + 1, clusters),
            .unknown => {
                self.unsure_clusters +|= 1;
                self.notGivenBack(freed + 1, clusters);
            },
        };
        cluster = next;
    }
}

pub fn notGivenBack(self: *Volume, freed: u32, clusters: u32) void {
    self.cleanups_failed +%= 1;
    // PLANT (src/plant.zig): a give-back that fails counts one cluster
    // fewer than it leaves, so fsck.fat reclaims one more than the end
    // line says, which the judge's counted_leak must not excuse
    // (metal-vmm 148(d)).
    if (comptime plant.on == .counted_leak_short) {
        // Fires only where it does harm: a give-back that left some.
        if (clusters > freed) props.reachable(@src(), "PLANT: counted-leak-short fires", null);
        self.leaked_clusters +|= (clusters - freed) -| 1;
    } else self.leaked_clusters +|= clusters - freed;
    props.reachable(@src(), "fat: clusters taken before a failure could not be given back, and are left a leak", .{ .count = self.cleanups_failed, .freed = freed, .of = clusters });
}

/// **THE LEDGER RUNS WHEREVER SAFETY DOES** (metal-vmm 146(f)): Debug
/// and ReleaseSafe, so the host tests, the long tier's ReleaseSafe sweep
/// and the served kernel. Its sites are in every catalog anyway
/// (`catalogFile` registers them from the source), and off they read as
/// never reached in every ReleaseSafe report; on, they are judged there
/// too. The cost is a counter per cluster taken and a compare per
/// operation. Off in ReleaseFast and ReleaseSmall, which this repo does
/// not build.
///
/// **IN THE SERVED KERNEL IT JUDGES NOTHING** (147): an unbalanced
/// operation breaks a site, and outside `-Dcoverage` `on_broken` is
/// null and the sink unset, so the break is a counter no one reads. It
/// is a check in the tests, coverage builds and sweeps, not in
/// production.
pub const ledger_on = std.debug.runtime_safety;

/// Clusters `allocChain` took.
pub fn took(self: *Volume, clusters: u32) void {
    // Saturating: a counter in the served kernel must not be able to panic it.
    if (ledger_on) self.ledger_open +|= clusters;
}

/// Clusters that ended: committed, linked, given back or a counted leak.
pub fn ended(self: *Volume, clusters: u32) void {
    if (!ledger_on) return;
    props.alwaysLessThanOrEqualTo(@src(), clusters, self.ledger_open, "fat: an operation ends no more clusters than it took", null);
    self.ledger_open -|= clusters;
}

/// Clusters linked into a chain an entry already points at (`grow`'s
/// new cluster, an append's): that link is their commit.
pub fn linked(self: *Volume, clusters: u32) void {
    self.ended(clusters);
}

/// **EVERY PUBLIC OPERATION THAT CHANGES THE VOLUME ENDS HERE** (a
/// `defer` at its top, so after its own errdefers): nothing it took is
/// left open. Cleared after, so one miss is reported once.
pub fn balanced(self: *Volume) void {
    if (!ledger_on) return;
    props.always(@src(), self.ledger_open == 0, "fat: every cluster an operation took ended committed, linked, given back or a counted leak", .{ .open = self.ledger_open });
    self.ledger_open = 0;
}

/// **A CHAIN FREED AFTER THE COMMIT THAT LET IT GO**: a cleanup, whose
/// failure is no error of the operation's but a counted leak of what is
/// left (148(b)): the rest of the chain from where it stopped, counted
/// by walking it, and the cluster whose freeing was refused by where its
/// FAT write stands (`fatSet`'s verdict): freed, not, or unknown.
pub fn freeAfterCommit(self: *Volume, first: Cluster) void {
    if (self.fat) |fat| return self.freeAfterCommitHeld(fat, first);
    var cluster = first;
    while (self.inData(cluster)) {
        const next = self.fatGet(cluster) catch return self.chainLeft(cluster);
        props.always(@src(), next != 0, "fat: every cluster freed was in use", .{ .cluster = cluster });
        // **THE HINT IS LOWERED FIRST.** A lower hint is always sound,
        // and a fatSet that fails may still have freed the cluster.
        if (cluster < self.alloc_hint) self.alloc_hint = cluster;
        var landing: Landing = .before;
        self.fatSet(cluster, 0, &landing) catch return switch (landing) {
            .landed => self.chainLeft(next),
            .before => self.chainLeft(cluster),
            .unknown => {
                self.unsure_clusters +|= 1;
                self.chainLeft(next);
            },
        };
        cluster = next;
    }
}

/// `freeAfterCommit` with the FAT held: **A FAT SECTOR AT A TIME**, as
/// `allocChainHeld` takes one. The chain's clusters whose entries are in
/// one sector are freed in the held sector, in the chain's order, until
/// the chain leaves it, and the sector is written once to each copy. A
/// 1 MiB file's old chain on the host tests' 512-byte clusters was 2,048
/// entries, each its sector to two copies: 4,096 writes, now ~20.
///
/// **A REFUSED WRITE STOPS IT, AS ONE ENTRY'S DID**, by `heldRefused`'s
/// verdict: not landed, the held sector goes back as it was and the
/// chain from the batch's first is left; landed, the batch is free and
/// the rest is left; unknown, the batch is taken as freed and the first
/// copy written again once, and the batch may be free or taken where
/// that fails too. What is left is a counted leak (`chainLeft`).
///
/// **AN UNKNOWN IS UNSURE ONLY WHERE THE WRITE AGAIN FAILS**, as in
/// `allocChainHeld`: written again, the batch is free on the disk too.
/// Without a held FAT, `fatSet` never writes again, so its unknown is
/// always one cluster that may be free or taken.
pub fn freeAfterCommitHeld(self: *Volume, fat: []u8, first: Cluster) void {
    const width = self.entryBytes();
    var cluster = first;
    while (self.inData(cluster)) {
        // Let go before the first change, as `fatSet` does.
        self.forgetFsInfo() catch return self.chainLeft(cluster);
        const in_sector = cluster * width / sector_size;
        const sector = fat[in_sector * sector_size ..][0..sector_size];
        var was: [sector_size]u8 = undefined;
        @memcpy(&was, sector);
        const batch_first = cluster;
        var n: u32 = 0;
        while (self.inData(cluster) and cluster * width / sector_size == in_sector) {
            const at = cluster * width % sector_size;
            const next = self.entryIn(sector, at / width);
            // A free entry in a chain (rot, or a loop back to a cluster
            // this batch freed) ends it, as one entry at a time did.
            props.always(@src(), next != 0, "fat: every cluster freed was in use", .{ .cluster = cluster });
            // **THE HINT IS LOWERED FIRST**: a lower hint is always
            // sound, and a write that fails may still have freed it.
            if (cluster < self.alloc_hint) self.alloc_hint = cluster;
            if (next == 0) {
                cluster = 0;
                break;
            }
            self.putEntry(sector, at, 0);
            n += 1;
            cluster = next;
        }
        if (n == 0) return;
        if (n > 1) props.reachable(@src(), "fat: a chain frees several clusters in one FAT sector write", .{ .clusters = n });
        self.writeSector(self.fat_start + in_sector, sector) catch {
            switch (self.heldRefused(self.fat_start + in_sector, sector, &was)) {
                .before => {
                    @memcpy(sector, &was);
                    self.chainLeft(batch_first);
                },
                .landed => {
                    self.keepFreed(n);
                    self.writeCopies(in_sector, sector);
                    self.chainLeft(cluster);
                },
                .unknown => {
                    self.keepFreed(n);
                    const again = if (self.writeSector(self.fat_start + in_sector, sector)) true else |_| false;
                    if (!again) {
                        self.copyApart();
                        self.unsure_clusters +|= n;
                    }
                    self.writeCopies(in_sector, sector);
                    self.chainLeft(cluster);
                },
            }
            return;
        };
        self.keepFreed(n);
        self.writeCopies(in_sector, sector);
    }
}

/// The chain from `from` left taken after a commit, nothing pointing at
/// it: a counted cleanup, its clusters counted by walking it, or a leak
/// of a size not known (`unsized_leaks`) where the walk fails.
pub fn chainLeft(self: *Volume, from: Cluster) void {
    self.cleanups_failed +%= 1;
    props.reachable(@src(), "fat: a chain freed after the commit could not be freed whole, and the rest is left a leak", .{ .count = self.cleanups_failed });
    if (!self.inData(from)) return;
    const end = self.chainEnd(from) catch {
        self.unsized_leaks +|= 1;
        return;
    };
    self.leaked_clusters +|= end.clusters;
}

/// Writes `bytes` into a chain already long enough, the last sector
/// padded with zeros: the entry's size says how much is the file.
pub fn writeChain(self: *Volume, first: Cluster, bytes: []const u8) Error!void {
    return self.writeRuns(first, 0, bytes, .zeros);
}
