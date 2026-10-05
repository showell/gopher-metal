//! **FAT16 AND FAT32 AGAINST A RANDOM WORKLOAD AND A MODEL OF WHAT THEY HOLD.**
//!
//! Each run is one seed. The seed chooses a volume (FAT16 or FAT32), how big
//! the files run (enough to fill the volume, or not), and a sequence of the
//! operations the application makes: whole-file writes and rewrites, appends,
//! removes, renames, directories made and trees removed, and remounts — the
//! next boot. Names come from a pool shaped like the application's: long
//! names, 8.3 names, names that differ only past their eighth character, deep
//! paths, and enough numbered names to fill a directory.
//!
//! **THE ORACLES**, after every operation:
//!
//! - **The model.** Every file the model holds reads back byte for byte, and
//!   every directory opens as one. An operation that fails for want of room
//!   (`Full`, `DirectoryFull`) may leave what it touched as it was or as it
//!   would have been, nothing else: a replace may lose the old file (fat16.zig
//!   removes it first, as Linux's truncate does), an append keeps the old
//!   file whole.
//! - **The volume.** `Volume.check` finds nothing: no leaked cluster, no
//!   chain shared, no orphaned long name. The kept free count is the count
//!   of the FAT on the disk, the volume's own recount agrees, and the FAT
//!   copies are the same bytes.
//! - **Both paths, one disk.** The same seed runs with the FAT on the disk
//!   and with it held in memory, and must leave byte-identical volumes, as
//!   `probe/run.sh` requires of the probes.
//!
//! A failing seed is reported with the operation it failed at; it is the
//! repro. fat16.zig's coverage properties (COVERAGE.md) say which of its
//! paths the runs reached.

const std = @import("std");
const fat16 = @import("fat16.zig");
const test_disk = @import("test_disk.zig");
const props = @import("coverage");
const testing = std.testing;

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const dirs = [_][]const u8{ "data", "data/chat", "data/chat/A Long Topic Name", "auth", "auth/7" };
const names = [_][]const u8{
    "a",
    "B.TXT",
    "messages.jsonl",
    "a rather long file name that needs several parts.txt",
    "x.y.z",
    "UPPER",
    "last-seen-by-user",
    "last-seen-by-admin",
};
/// Numbered names, for a run that fills a directory.
const numbered = 700;

const Op = enum { write, append, remove, rename, mkdir, remove_tree, remount };

const Scenario = struct {
    shape: test_disk.Shape,
    ops: usize,
    /// The largest file a write makes.
    max_bytes: usize,
    /// **FILLING THE VOLUME**: files sized to it, so a handful of live ones
    /// leave no room, and the allocation cursor goes round.
    filling: bool,
    /// **FILLING A DIRECTORY**: hundreds of operations, mostly on numbered
    /// names in one directory. The root of a FAT16 volume is a fixed 512
    /// entries, the one limit this filesystem has that the application can
    /// meet in normal use.
    crowded: bool,
    crowd_dir: usize,
    /// The model and the volume are checked whole every this many
    /// operations, and after each of the first twenty that found no room.
    check_every: usize,

    fn choose(rng: std.Random) Scenario {
        const fat32 = rng.uintLessThan(u8, 4) == 0;
        const shape = if (fat32) test_disk.small32 else test_disk.small;
        const volume_bytes = @as(usize, shape.sectors) * test_disk.sector;
        const mode = rng.uintLessThan(u8, 4);
        const filling = mode == 1;
        const crowded = mode == 2;
        return .{
            .shape = shape,
            .ops = if (crowded) rng.intRangeAtMost(usize, 800, 1200) else rng.intRangeAtMost(usize, 20, 120),
            .max_bytes = if (filling) volume_bytes * 3 / 8 else ([_]usize{ 300, 6000, 70_000, 600_000 })[rng.uintLessThan(usize, 4)],
            .filling = filling,
            .crowded = crowded,
            .crowd_dir = if (crowded and rng.boolean()) dirs.len else rng.uintLessThan(usize, dirs.len + 1),
            .check_every = if (crowded) 50 else 1,
        };
    }
};

const Model = struct {
    files: std.StringHashMap([]u8),
    dirs: std.StringHashMap(void),

    fn init() Model {
        return .{ .files = .init(testing.allocator), .dirs = .init(testing.allocator) };
    }

    fn deinit(m: *Model) void {
        var f = m.files.iterator();
        while (f.next()) |e| {
            testing.allocator.free(e.key_ptr.*);
            testing.allocator.free(e.value_ptr.*);
        }
        m.files.deinit();
        var d = m.dirs.keyIterator();
        while (d.next()) |k| testing.allocator.free(k.*);
        m.dirs.deinit();
    }

    fn setFile(m: *Model, path: []const u8, bytes: []const u8) !void {
        const copy = try testing.allocator.dupe(u8, bytes);
        if (m.files.getPtr(path)) |v| {
            testing.allocator.free(v.*);
            v.* = copy;
        } else try m.files.put(try testing.allocator.dupe(u8, path), copy);
    }

    fn dropFile(m: *Model, path: []const u8) void {
        if (m.files.fetchRemove(path)) |kv| {
            testing.allocator.free(kv.key);
            testing.allocator.free(kv.value);
        }
    }

    fn addDir(m: *Model, path: []const u8) !void {
        if (path.len == 0 or m.dirs.contains(path)) return;
        try m.dirs.put(try testing.allocator.dupe(u8, path), {});
    }

    /// Every directory a path needs, in the model.
    fn addParents(m: *Model, path: []const u8) !void {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| : (i = slash + 1) {
            try m.addDir(path[0..slash]);
        }
    }

    /// A tree, gone: the directory and everything under it.
    fn dropTree(m: *Model, dir: []const u8) !void {
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(testing.allocator);
        var f = m.files.keyIterator();
        while (f.next()) |k| if (under(k.*, dir)) try doomed.append(testing.allocator, k.*);
        for (doomed.items) |k| m.dropFile(k);
        doomed.clearRetainingCapacity();
        var d = m.dirs.keyIterator();
        while (d.next()) |k| if (std.mem.eql(u8, k.*, dir) or under(k.*, dir)) try doomed.append(testing.allocator, k.*);
        for (doomed.items) |k| {
            const kv = m.dirs.fetchRemove(k).?;
            testing.allocator.free(kv.key);
        }
    }
};

fn under(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

const Sim = struct {
    seed: u64,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    sc: Scenario,
    cached: bool,
    disk: *test_disk.Disk,
    model: Model,
    step: usize = 0,
    path_buf: [256]u8 = undefined,
    path2_buf: [256]u8 = undefined,
    bytes: []u8,
    /// The first oracle that failed, if any.
    broken: ?[]const u8 = null,
    /// How many operations failed for want of room, for the report.
    full: usize = 0,
    /// The last operation, and what it said, for the report.
    last: Op = .remount,
    last_said: []const u8 = "ok",

    fn init(seed: u64, cached: bool) !Sim {
        var prng = std.Random.DefaultPrng.init(seed);
        const sc = Scenario.choose(prng.random());
        return .{
            .seed = seed,
            .prng = prng,
            .rng = undefined,
            .sc = sc,
            .cached = cached,
            .disk = try test_disk.Disk.make("fat-sim", sc.shape, cached),
            .model = .init(),
            .bytes = try testing.allocator.alloc(u8, sc.max_bytes),
        };
    }

    fn deinit(s: *Sim) void {
        s.model.deinit();
        testing.allocator.free(s.bytes);
        // test_disk checks a disk left healthy on the way out; a run that
        // failed has already said why, so it is not asked again.
        if (s.broken != null) s.disk.blk.fail_after = 0;
        s.disk.deinit();
    }

    fn fault(s: *Sim, what: []const u8) void {
        if (s.broken == null) s.broken = what;
    }

    fn pickDir(s: *Sim) []const u8 {
        if (s.sc.crowded and s.rng.uintLessThan(u8, 4) != 0) return if (s.sc.crowd_dir == dirs.len) "" else dirs[s.sc.crowd_dir];
        const k = s.rng.uintLessThan(usize, dirs.len + 1);
        return if (k == dirs.len) "" else dirs[k];
    }

    fn pickName(s: *Sim, buf: []u8) []const u8 {
        // Half of them long names, two or three entries each: a directory
        // fills in fewer files, and a long name needs a run, not a slot.
        if (s.sc.crowded and s.rng.uintLessThan(u8, 10) != 0) {
            const k = s.rng.uintLessThan(usize, numbered);
            return (if (k % 2 == 0) std.fmt.bufPrint(buf, "n{d}", .{k}) else std.fmt.bufPrint(buf, "message number {d}.jsonl", .{k})) catch unreachable;
        }
        return names[s.rng.uintLessThan(usize, names.len)];
    }

    fn join(dir: []const u8, name: []const u8, buf: []u8) []const u8 {
        if (dir.len == 0) return std.fmt.bufPrint(buf, "{s}", .{name}) catch unreachable;
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch unreachable;
    }

    /// Bytes no other write in this run has, so a file that reads back
    /// another's contents is caught.
    fn content(s: *Sim, n: usize) []const u8 {
        for (s.bytes[0..n], 0..) |*b, k| b.* = @truncate(k *% 31 +% s.step *% 7 +% 1);
        return s.bytes[0..n];
    }

    fn size(s: *Sim) usize {
        // Mostly small, now and then up to the scenario's largest; filling,
        // mostly large.
        if (s.sc.filling and s.rng.uintLessThan(u8, 3) != 0) return s.rng.uintAtMost(usize, s.sc.max_bytes);
        if (s.rng.uintLessThan(u8, 5) == 0) return s.rng.uintAtMost(usize, s.sc.max_bytes);
        return s.rng.uintAtMost(usize, @min(s.sc.max_bytes, 600));
    }

    fn roomless(e: anyerror) bool {
        return e == fat16.Error.Full or e == fat16.Error.DirectoryFull;
    }

    fn run(s: *Sim) !void {
        s.rng = s.prng.random();
        while (s.step < s.sc.ops and s.broken == null) : (s.step += 1) {
            const full = s.full;
            try s.turn();
            // After an operation that found no room, at once, but only for the
            // first twenty: a full directory refuses nearly everything after,
            // and the leaks this has found showed on the first refusals.
            const refused = s.full != full and s.full <= 20;
            const due = refused or s.step % s.sc.check_every == 0 or s.step + 1 == s.sc.ops;
            if (s.broken == null and due) try s.verify();
        }
        if (s.broken) |what| {
            std.debug.print("fat_sim seed {d} ({s}, {s}) failed at operation {d}, a {s} that said {s}: {s}\n", .{
                s.seed, if (s.cached) "FAT held in memory" else "FAT on the disk", if (s.sc.shape.kind == .fat32) "FAT32" else "FAT16",
                s.step, @tagName(s.last),                                          s.last_said,
                what,
            });
            return error.SimulationFailed;
        }
    }

    fn turn(s: *Sim) !void {
        const roll = s.rng.uintLessThan(u8, 100);
        // Crowding a directory is mostly making names in it.
        const op: Op = if (s.sc.crowded and roll < 50) .write else switch (roll) {
            0...29 => .write,
            30...54 => .append,
            55...64 => .remove,
            65...74 => .rename,
            75...82 => .mkdir,
            83...87 => .remove_tree,
            else => .remount,
        };
        const vol = &s.disk.vol;
        s.last = op;
        s.last_said = "ok";
        switch (op) {
            .write => {
                const path = join(s.pickDir(), s.pickName(&s.path2_buf), &s.path_buf);
                const bytes = s.content(s.size());
                const old = s.model.files.get(path);
                if (vol.writeFile(path, bytes)) {
                    try s.model.setFile(path, bytes);
                    try s.model.addParents(path);
                } else |e| {
                    if (!roomless(e)) return s.fault(@errorName(e));
                    s.last_said = @errorName(e);
                    s.full += 1;
                    props.reachable(@src(), "fat_sim: a write finds no room", .{ .seed = s.seed });
                    try s.settle(path, old, null);
                }
            },
            .append => {
                const path = join(s.pickDir(), s.pickName(&s.path2_buf), &s.path_buf);
                const bytes = s.content(@max(1, s.size()));
                const old = s.model.files.get(path) orelse {
                    if (vol.writeInto(path, 0, bytes)) {
                        return s.fault("an append to a file that is not there succeeded");
                    } else |e| if (e != fat16.Error.NotFound) return s.fault(@errorName(e));
                    return;
                };
                if (vol.writeInto(path, @intCast(old.len), bytes)) {
                    const whole = try std.mem.concat(testing.allocator, u8, &.{ old, bytes });
                    defer testing.allocator.free(whole);
                    try s.model.setFile(path, whole);
                } else |e| {
                    if (!roomless(e)) return s.fault(@errorName(e));
                    s.last_said = @errorName(e);
                    s.full += 1;
                    props.reachable(@src(), "fat_sim: an append finds no room", .{ .seed = s.seed });
                    // An append that could not finish leaves the old file whole.
                }
            },
            .remove => {
                const path = join(s.pickDir(), s.pickName(&s.path2_buf), &s.path_buf);
                if (vol.remove(path)) {
                    if (!s.model.files.contains(path)) return s.fault("a remove of a file that is not there succeeded");
                    s.model.dropFile(path);
                } else |e| {
                    if (e != fat16.Error.NotFound or s.model.files.contains(path)) return s.fault(@errorName(e));
                }
            },
            .rename => {
                const dir = s.pickDir();
                var name_a: [40]u8 = undefined;
                var name_b: [40]u8 = undefined;
                const from = join(dir, s.pickName(&name_a), &s.path_buf);
                const to = join(dir, s.pickName(&name_b), &s.path2_buf);
                if (std.mem.eql(u8, from, to)) return;
                const old_from = s.model.files.get(from);
                const old_to = s.model.files.get(to);
                if (vol.rename(from, to)) {
                    const moved = old_from orelse return s.fault("a rename of a file that is not there succeeded");
                    const copy = try testing.allocator.dupe(u8, moved);
                    defer testing.allocator.free(copy);
                    s.model.dropFile(from);
                    try s.model.setFile(to, copy);
                } else |e| {
                    if (e == fat16.Error.NotFound and old_from == null) return;
                    if (!roomless(e)) return s.fault(@errorName(e));
                    s.last_said = @errorName(e);
                    s.full += 1;
                    props.reachable(@src(), "fat_sim: a rename finds no room", .{ .seed = s.seed });
                    // Either nothing happened, or all of it.
                    try s.settle(to, old_to, old_from);
                    try s.settle(from, old_from, null);
                }
            },
            .mkdir => {
                const dir = dirs[s.rng.uintLessThan(usize, dirs.len)];
                if (vol.makePath(dir)) |_| {
                    try s.model.addParents(dir);
                    try s.model.addDir(dir);
                } else |e| {
                    if (!roomless(e)) return s.fault(@errorName(e));
                    s.last_said = @errorName(e);
                    s.full += 1;
                    try s.settleDirs();
                }
            },
            .remove_tree => {
                const dir = dirs[s.rng.uintLessThan(usize, dirs.len)];
                vol.removeTree(dir) catch |e| return s.fault(@errorName(e));
                try s.model.dropTree(dir);
            },
            .remount => {
                props.reachable(@src(), "fat_sim: the volume is mounted again", null);
                s.disk.mount(s.cached) catch |e| return s.fault(@errorName(e));
            },
        }
    }

    /// After an operation that found no room: `path` holds one of the two
    /// states it may (`before`, or `after` if the operation went through), and
    /// the model follows what the disk says.
    fn settle(s: *Sim, path: []const u8, before: ?[]const u8, after: ?[]const u8) !void {
        const got = s.disk.read(path) catch |e| switch (e) {
            fat16.Error.NotFound => {
                // Absent is allowed: a replace removes the old file first.
                s.model.dropFile(path);
                return;
            },
            else => return s.fault(@errorName(e)),
        };
        defer testing.allocator.free(got);
        const ok = (before != null and std.mem.eql(u8, got, before.?)) or (after != null and std.mem.eql(u8, got, after.?));
        if (!ok) return s.fault("an operation that found no room left a file that is neither its old self nor its new one");
        try s.model.setFile(path, got);
        try s.model.addParents(path);
    }

    /// The model's directories as the disk has them, after a makePath that
    /// found no room part-way.
    fn settleDirs(s: *Sim) !void {
        for (dirs) |d| {
            if (s.disk.vol.open(d)) |e| {
                if (!e.isDirectory()) return s.fault("a directory's path opens as a file");
                try s.model.addDir(d);
            } else |_| {}
        }
    }

    fn verify(s: *Sim) !void {
        const d = s.disk;
        const r = try d.check();
        if (!r.health.clean()) {
            std.debug.print("  the check found {d} problems, the first {s} at {s}\n", .{ r.health.problems, @tagName(r.found[0].problem), r.found[0].text() });
            return s.fault("the volume does not check clean");
        }
        if (d.vol.free_clusters != d.free()) return s.fault("the kept free count is not the FAT's");
        if ((try d.vol.countFreeAgain()) != d.free()) return s.fault("the volume's recount is not the FAT's");
        if (!d.fatsAgree()) return s.fault("the FAT copies differ");
        var f = s.model.files.iterator();
        while (f.next()) |e| {
            const got = d.read(e.key_ptr.*) catch return s.fault("a file the model holds does not open");
            defer testing.allocator.free(got);
            if (!std.mem.eql(u8, got, e.value_ptr.*)) return s.fault("a file reads back other bytes than were written");
        }
        var k = s.model.dirs.keyIterator();
        while (k.next()) |dir| {
            const e = d.vol.open(dir.*) catch return s.fault("a directory the model holds does not open");
            if (!e.isDirectory()) return s.fault("a directory the model holds opens as a file");
        }
    }
};

/// Runs one seed with the FAT on the disk and with it held in memory; an
/// error, with the operation that failed printed, if any oracle fails.
pub fn runSeed(seed: u64) !void {
    var hashes: [2]u64 = undefined;
    var full: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |cached, i| {
        var s = try Sim.init(seed, cached);
        defer s.deinit();
        try s.run();
        hashes[i] = std.hash.Wyhash.hash(0, s.disk.bytes);
        full[i] = s.full;
    }
    props.sometimes(@src(), full[0] > 0, "fat_sim: some run finds the volume full", .{ .seed = seed });
    if (hashes[0] != hashes[1]) {
        std.debug.print("fat_sim seed {d}: the FAT on the disk and the FAT held in memory left different volumes\n", .{seed});
        return error.SimulationFailed;
    }
}

/// The seeds `zig build test` runs. A seed that once failed and was fixed
/// stays here, named, as a regression test.
const seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ regressions;

/// Seeds that once failed, each under what it found.
const regressions = [_]u64{
    // A full FAT16 root: a rename to a new name unlinked `from` before
    // finding room for `to`, and a lost file's chain leaked (fat16.zig's
    // rename).
    38,
    // A full FAT16 root: a directory's cluster was taken before room for its
    // entry was found, and leaked on DirectoryFull, by a write making its
    // parents (33) and by a mkdir (45) (fat16.zig's makeDirIn).
    33,
    45,
};

test "FAT16 and FAT32 against a random workload, a handful of seeds, both FAT paths" {
    for (seeds) |seed| try runSeed(seed);
}
