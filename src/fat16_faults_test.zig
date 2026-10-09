//! `fat16.zig` when the machine stops, and when the disk fails or lies
//! (QUEUE.md items 79 and 80): every operation the application uses, stopped
//! after each write, and with each request failing or lying once. Apart from
//! `fat16_test.zig` so the two run side by side: each is a test of hundreds
//! of runs.

const std = @import("std");
const fat16 = @import("fat16.zig");
const options = @import("fat16_test_options");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Shape = test_disk.Shape;
const Layout = test_disk.Layout;
const formats = [_]Shape{ test_disk.small, test_disk.small32 };
const configs = blk: {
    var out: [formats.len * 2]struct { shape: Shape, cached: bool } = undefined;
    for (formats, 0..) |f, i| {
        out[2 * i] = .{ .shape = f, .cached = false };
        out[2 * i + 1] = .{ .shape = f, .cached = true };
    }
    break :blk out;
};

/// `test_disk.Disk`, kept as an image when the tests are asked to keep them
/// (-Dfat16-images), for tools/check_fat16_images.sh to judge.
const Disk = struct {
    fn make(label: []const u8, shape: Shape, cached: bool) !*test_disk.Disk {
        const d = try test_disk.Disk.make(label, shape, cached);
        d.images_dir = options.images_dir;
        return d;
    }

    /// Not kept: a disk the tests failed or lied to on purpose, run after
    /// run, whose last state may hold the damage that allows (a leak), and
    /// is no one outcome to name. The stop test keeps its images itself,
    /// each named by what the check found.
    fn makeUnkept(label: []const u8, shape: Shape, cached: bool) !*test_disk.Disk {
        return test_disk.Disk.make(label, shape, cached);
    }
};

// ---- the machine stopped at every write (QUEUE item 79) ---------------------
//
// Each operation the application uses, stopped after its 1st, 2nd, ... Nth
// write to the disk, for every N until it finishes, on FAT16 and FAT32,
// with the FAT on the disk and held in memory. A stop is the disk refusing
// every request from then on (`fail_after_writes`), which is what a machine
// that stopped leaves: nothing more was written. (A stop between two reads
// leaves what the write before them left.) Then the image is mounted again
// as the next boot would, and must hold one of the outcomes the operation's
// doc names, with nothing worse than leaked clusters and FAT copies apart
// (`allowed`), and must still take a new file.

/// What a path may hold after a stop.
const State = union(enum) { absent, dir, file: []const u8 };

/// On FAT32, FSInfo set as mkfs.fat leaves it: a free count that is right,
/// and a next-free hint, in FSInfo and its backup. test_disk leaves both
/// unknown, which no stale count can be wrong against.
fn setFsInfo(d: *test_disk.Disk) void {
    if (Layout.of(d.bytes).kind != .fat32) return;
    for ([_]usize{ 1, 7 }) |s| {
        const at = s * test_disk.sector;
        std.mem.writeInt(u32, d.bytes[at + 488 ..][0..4], @intCast(d.free()), .little);
        std.mem.writeInt(u32, d.bytes[at + 492 ..][0..4], 2, .little);
    }
}
const Want = struct {
    path: []const u8,
    /// What a stop may leave; the last is what the finished operation left.
    any: []const State,
};
const Stopped = struct {
    name: []const u8,
    setup: *const fn (v: *fat16.Volume) anyerror!void,
    run: *const fn (v: *fat16.Volume) fat16.Error!void,
    want: []const Want,
    /// No two of these paths are both present (a rename's two names).
    one_of: []const []const u8 = &.{},
    /// An append, of `tail`: a stop may leave the file on a chain longer
    /// than its size (writeInto's doc), and the same append made again must
    /// use those clusters, leaving the chain exact.
    appends: ?struct { path: []const u8, tail: []const u8 } = null,
};

/// What a stop may leave besides the outcome itself: clusters nothing holds
/// (fsck reclaims them), and FAT copies apart (every FAT change writes the
/// first copy, then the second). An append may also leave a chain longer
/// than its file (`long`), until the next append.
const allowed = [_]fat16.Problem{ .leaked, .fats_differ };
const allowed_append = [_]fat16.Problem{ .leaked, .fats_differ, .long };

fn patterned(comptime n: usize, comptime seed: u8) [n]u8 {
    @setEvalBranchQuota(n * 8 + 1000);
    var b: [n]u8 = undefined;
    for (&b, 0..) |*c, i| c.* = @truncate(i *% 31 +% seed);
    return b;
}
const old_rec = patterned(3000, 3);
const new_rec = patterned(1300, 9);
const tail_small = patterned(100, 5);
const tail_big = patterned(2100, 6);
const old_plus_small = old_rec ++ tail_small;
const old_plus_big = old_rec ++ tail_big;
const after_bytes = patterned(2000, 11);

const stopped_ops = [_]Stopped{
    .{
        .name = "write a new file",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                _ = try v.makePath("data/chat");
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.writeFile("data/chat/a-new-conversation.md", &old_rec);
            }
        }.f,
        .want = &.{.{ .path = "data/chat/a-new-conversation.md", .any = &.{ .absent, .{ .file = &old_rec } } }},
    },
    .{
        .name = "write a new file, making its directories",
        .setup = struct {
            fn f(_: *fat16.Volume) !void {}
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.writeFile("data/games/7/state", &new_rec);
            }
        }.f,
        .want = &.{
            .{ .path = "data", .any = &.{ .absent, .dir } },
            .{ .path = "data/games", .any = &.{ .absent, .dir } },
            .{ .path = "data/games/7", .any = &.{ .absent, .dir } },
            .{ .path = "data/games/7/state", .any = &.{ .absent, .{ .file = &new_rec } } },
        },
    },
    .{
        // **A WRITE OVER A FILE IS OLD OR NEW, NEVER GONE** (essay
        // kernel-facts #1): the new chain is written first, and one sector
        // write points the entry at it.
        .name = "replace a file",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                try v.writeFile("data/rec", &old_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.writeFile("data/rec", &new_rec);
            }
        }.f,
        .want = &.{.{ .path = "data/rec", .any = &.{ .{ .file = &old_rec }, .{ .file = &new_rec } } }},
    },
    .{
        .name = "append inside the last cluster",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                try v.writeFile("data/log", &old_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.writeInto("data/log", old_rec.len, &tail_small);
            }
        }.f,
        .appends = .{ .path = "data/log", .tail = &tail_small },
        .want = &.{.{ .path = "data/log", .any = &.{ .{ .file = &old_rec }, .{ .file = &old_plus_small } } }},
    },
    .{
        .name = "append past the last cluster",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                try v.writeFile("data/log", &old_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.writeInto("data/log", old_rec.len, &tail_big);
            }
        }.f,
        .appends = .{ .path = "data/log", .tail = &tail_big },
        .want = &.{.{ .path = "data/log", .any = &.{ .{ .file = &old_rec }, .{ .file = &old_plus_big } } }},
    },
    .{
        .name = "append to an empty file",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                try v.writeFile("data/log", "");
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.writeInto("data/log", 0, &tail_big);
            }
        }.f,
        .appends = .{ .path = "data/log", .tail = &tail_big },
        .want = &.{.{ .path = "data/log", .any = &.{ .{ .file = "" }, .{ .file = &tail_big } } }},
    },
    .{
        .name = "make a directory",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                _ = try v.makePath("data");
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                _ = try v.makePath("data/sessions");
            }
        }.f,
        .want = &.{.{ .path = "data/sessions", .any = &.{ .absent, .dir } }},
    },
    .{
        .name = "remove a file",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                try v.writeFile("data/a-rather-long-name-for-a-file.md", &old_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.remove("data/a-rather-long-name-for-a-file.md");
            }
        }.f,
        .want = &.{.{ .path = "data/a-rather-long-name-for-a-file.md", .any = &.{ .{ .file = &old_rec }, .absent } }},
    },
    .{
        // A person deleting their account: their tree goes one entry at a
        // time, so a stop leaves part of it.
        .name = "remove a tree",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                try v.writeFile("data/users/7/profile", &new_rec);
                try v.writeFile("data/users/7/games/1/state", &old_rec);
                try v.writeFile("data/users/7/games/2/state", &tail_big);
                try v.writeFile("data/users/8/profile", "someone else");
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.removeTree("data/users/7");
            }
        }.f,
        .want = &.{
            .{ .path = "data/users/7/profile", .any = &.{ .{ .file = &new_rec }, .absent } },
            .{ .path = "data/users/7/games/1/state", .any = &.{ .{ .file = &old_rec }, .absent } },
            .{ .path = "data/users/7/games/2/state", .any = &.{ .{ .file = &tail_big }, .absent } },
            .{ .path = "data/users/7/games", .any = &.{ .dir, .absent } },
            .{ .path = "data/users/7", .any = &.{ .dir, .absent } },
            .{ .path = "data/users/8/profile", .any = &.{.{ .file = "someone else" }} },
        },
    },
    .{
        // The Store's replace: the new bytes under a temporary name, then a
        // rename over the old.
        .name = "rename over a file",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                try v.writeFile("data/rec", &old_rec);
                try v.writeFile("data/rec.tmp", &new_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.rename("data/rec.tmp", "data/rec");
            }
        }.f,
        .want = &.{
            .{ .path = "data/rec", .any = &.{ .{ .file = &old_rec }, .{ .file = &new_rec } } },
            .{ .path = "data/rec.tmp", .any = &.{ .{ .file = &new_rec }, .absent } },
        },
        .one_of = &.{ "data/rec.tmp", "data/rec" },
    },
    .{
        // To a name nobody has: a stop between its two steps loses a file
        // nobody had yet (rename's doc).
        .name = "rename to a new name",
        .setup = struct {
            fn f(v: *fat16.Volume) !void {
                try v.writeFile("data/rec.tmp", &new_rec);
            }
        }.f,
        .run = struct {
            fn f(v: *fat16.Volume) fat16.Error!void {
                return v.rename("data/rec.tmp", "data/A-New-Record.md");
            }
        }.f,
        .want = &.{
            .{ .path = "data/rec.tmp", .any = &.{ .{ .file = &new_rec }, .absent } },
            .{ .path = "data/a-new-record.md", .any = &.{ .absent, .{ .file = &new_rec } } },
        },
        .one_of = &.{ "data/rec.tmp", "data/a-new-record.md" },
    },
};

/// What `path` holds on `d`, as a State; a file's bytes go in `buf`.
fn stateOf(d: *test_disk.Disk, path: []const u8, buf: []u8) !State {
    const e = d.vol.open(path) catch |err| switch (err) {
        fat16.Error.NotFound => return .absent,
        else => return err,
    };
    if (e.isDirectory()) return .dir;
    if (e.size > buf.len) return error.TestUnexpectedResult;
    const n = try d.vol.readFile(e, buf);
    return .{ .file = buf[0..n] };
}

fn sameState(a: State, b: State) bool {
    return switch (a) {
        .absent => b == .absent,
        .dir => b == .dir,
        .file => |x| b == .file and std.mem.eql(u8, x, b.file),
    };
}

fn describe(s: State) []const u8 {
    return switch (s) {
        .absent => "absent",
        .dir => "a directory",
        .file => "a file",
    };
}

/// The report holds only what `allowed` names.
fn onlyAllowed(r: *const test_disk.Report, these: []const fat16.Problem, op: []const u8, kind: []const u8, when: []const u8, n: u64) !void {
    for (r.found[0..r.len]) |f| {
        if (std.mem.indexOfScalar(fat16.Problem, these, f.problem) == null) {
            std.debug.print("{s} ({s}), {s} {d}: {s} at {s}\n", .{ op, kind, when, n, @tagName(f.problem), f.text() });
            return error.TestUnexpectedResult;
        }
    }
}

test "every operation stopped after every write leaves an outcome its doc names, and at worst leaked clusters" {
    var buf: [8192]u8 = undefined;
    for (stopped_ops, 0..) |op, op_index| {
        for (configs) |cfg| {
            const kind = if (cfg.shape.kind == .fat32) "FAT32" else "FAT16";
            // For the oracle (tools/check_fat16_images.sh): on FAT16 with the
            // FAT on the disk, the image the stop left, the first of each
            // outcome, named by what the check found; an outcome is what each
            // path held and which problems the check found. Every stop's
            // image would be hundreds of 4 MiB files.
            const keeps = cfg.shape.kind == .fat16 and !cfg.cached;
            var outcomes: [32]u64 = undefined;
            var outcomes_len: usize = 0;
            var stop: u64 = 0;
            var finished = false;
            var seen_partial = false;
            // One disk, set up once and put back before each stop, and
            // mounted afresh as a boot would: a disk of its own for every
            // stop was most of this test's time, in page faults.
            var label_buf: [48]u8 = undefined;
            const d = try Disk.make("limit-stopped", cfg.shape, cfg.cached);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try testing.allocator.dupe(u8, d.bytes);
            defer testing.allocator.free(before);
            while (!finished) : (stop += 1) {
                @memcpy(d.bytes, before);
                try d.mount(cfg.cached);
                d.label = "limit-stopped";

                d.blk.fail_after_writes = d.blk.writes + stop;
                // Done, it says: and finished, when no cleanup after its
                // commit failed. One that did is done with a leak (metal-vmm
                // QUEUE 131, #3), and the stops go on past it.
                const said_done = if (op.run(&d.vol)) |_| true else |_| false;
                // Nor one whose FAT copy past the first failed: done, with
                // the copies apart until the next mount (#7).
                if (said_done and d.vol.cleanups_failed == 0 and d.vol.fat_copies_failed == 0) finished = true;
                d.blk.fail_after_writes = null;
                if (!finished and !std.mem.eql(u8, before, d.bytes)) seen_partial = true;

                // The next boot: mounted again as before. The kernel holds
                // the FAT, and copies a stop left apart are brought into line
                // with the first at that mount (cacheFat); that used to
                // refuse the volume, and the machine never booted again.
                try d.mount(cfg.cached);
                var outcome: u64 = 0;
                for (op.want) |w| {
                    const got = try stateOf(d, w.path, &buf);
                    for (w.any, 0..) |st, i| {
                        if (sameState(st, got)) outcome = outcome * 8 + i;
                    }
                    const ok = if (said_done)
                        sameState(w.any[w.any.len - 1], got)
                    else for (w.any) |s| {
                        if (sameState(s, got)) break true;
                    } else false;
                    if (!ok) {
                        std.debug.print("{s} ({s}, FAT {s}), stopped after {d} writes: {s} is {s}, and not one of the outcomes named\n", .{ op.name, kind, if (cfg.cached) "held" else "on disk", stop, w.path, describe(got) });
                        return error.TestUnexpectedResult;
                    }
                }
                if (op.one_of.len == 2) {
                    // The new bytes under both names would be two entries on
                    // one chain.
                    var other: [8192]u8 = undefined;
                    const a = try stateOf(d, op.one_of[0], &buf);
                    const b = try stateOf(d, op.one_of[1], &other);
                    if (sameState(a, .{ .file = &new_rec }) and sameState(b, .{ .file = &new_rec })) {
                        std.debug.print("{s} ({s}), stopped after {d} writes: the new bytes under both names\n", .{ op.name, kind, stop });
                        return error.TestUnexpectedResult;
                    }
                }
                const r = try d.check();
                try onlyAllowed(&r, if (op.appends != null) &allowed_append else &allowed, op.name, kind, "stopped after write", stop);
                if (finished) try testing.expect(r.health.clean());

                // The image as the next boot finds it, for the oracle.
                for (r.found[0..r.len]) |f| outcome |= @as(u64, 1) << @intCast(@as(u32, 56) + @intFromEnum(f.problem));
                if (keeps and d.images_dir.len > 0 and std.mem.indexOfScalar(u64, outcomes[0..outcomes_len], outcome) == null) {
                    outcomes[outcomes_len] = outcome;
                    outcomes_len += 1;
                    const damaged = if (r.health.clean()) "" else "damaged-";
                    d.label = try std.fmt.bufPrint(&label_buf, "{s}stopped-{d:0>2}-{d:0>3}", .{ damaged, op_index, stop });
                    try d.keep();
                    d.label = "limit-stopped";
                }

                // And the volume goes on: a new file is written and read back;
                // an appended file takes the next append, whatever the stop
                // left it as; and nothing is worse than leaked.
                try d.vol.writeFile("data/after", &after_bytes);
                try d.expectFile("data/after", &after_bytes);
                if (op.appends) |a| {
                    const was = try d.read(a.path);
                    defer testing.allocator.free(was);
                    try d.vol.writeInto(a.path, @intCast(was.len), a.tail);
                    const want = try std.mem.concat(testing.allocator, u8, &.{ was, a.tail });
                    defer testing.allocator.free(want);
                    try d.expectFile(a.path, want);
                }
                const r2 = try d.check();
                try onlyAllowed(&r2, &allowed, op.name, kind, "stopped after write", stop);
            }
            // The loop did stop it part-way, with something on the disk.
            if (!seen_partial) {
                std.debug.print("{s} ({s}): no stop left a partial write\n", .{ op.name, kind });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ---- the device lies (QUEUE item 80) -----------------------------------------
//
// The same operations, with one request that goes wrong and a machine that
// carries on: it fails (an error the device reports), or it answers OK and
// does not do what it says (a write that lands nothing, a write torn in half,
// a read of other bytes than the disk's).

/// The kept free count, and the FAT if it is held, are the disk's.
fn heldIsDisk(d: *test_disk.Disk, op: []const u8, kind: []const u8, n: u64) !void {
    if (d.vol.derived.free != d.free()) {
        std.debug.print("{s} ({s}): request {d} failed; the kept free count is {d}, the disk has {d}\n", .{ op, kind, n, d.vol.derived.free, d.free() });
        return error.TestUnexpectedResult;
    }
    if (d.vol.fat) |held| {
        const l = Layout.of(d.bytes);
        if (!std.mem.eql(u8, held, d.bytes[l.fat_start..][0..held.len])) {
            std.debug.print("{s} ({s}): request {d} failed, and the FAT held in memory is not the disk's\n", .{ op, kind, n });
            return error.TestUnexpectedResult;
        }
    }
}

/// How many requests `op` makes on a fresh disk, from its setup on.
fn requestsOf(op: Stopped, cfg: anytype) !u64 {
    const d = try Disk.makeUnkept("limit-count", cfg.shape, cfg.cached);
    defer d.deinit();
    try op.setup(&d.vol);
    setFsInfo(d);
    try d.mount(cfg.cached);
    const before = d.blk.requests;
    try op.run(&d.vol);
    return d.blk.requests - before;
}

test "a request that fails before a write's commit gives back every cluster it took (metal-vmm QUEUE 131, kernel-facts #6)" {
    // A failure part-way through taking clusters (a FAT read or write, the
    // zeros of a directory's new cluster, the file's own bytes) gave back
    // nothing but on a full volume: every other error leaked what it had
    // taken, and the error said nothing of it. Before the commit nothing
    // points at those clusters, so nothing excuses keeping them. On FAT16,
    // where a new file's last request is its entry's write, the commit:
    // every request before it fails once, in turn.
    const big = [_]u8{'b'} ** (3 * 512 + 100); // several clusters on the small shape
    for (configs) |cfg| {
        if (cfg.shape.kind != .fat16) continue;
        for ([_]bool{ false, true }) |grows| {
            const d = try Disk.makeUnkept("limit-give-back", cfg.shape, cfg.cached);
            defer d.deinit();
            _ = try d.vol.makePath("data/full");
            if (grows) {
                // Its first cluster full, but for `.` and `..`: the write
                // grows it.
                const slots = d.vol.sectors_per_cluster * (512 / 32) - 2;
                var i: u32 = 0;
                var name: [32]u8 = undefined;
                while (i < slots) : (i += 1) {
                    try d.vol.writeFile(try std.fmt.bufPrint(&name, "data/full/F{d}", .{i}), "x");
                }
            }
            const before = try testing.allocator.dupe(u8, d.bytes);
            defer testing.allocator.free(before);
            try d.mount(cfg.cached);
            const r0 = d.blk.requests;
            try d.vol.writeFile("data/full/BIG.DAT", &big);
            const total = d.blk.requests - r0;
            var n: u64 = 0;
            while (n + 1 < total) : (n += 1) {
                @memcpy(d.bytes, before);
                try d.mount(cfg.cached);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = .fails };
                const result = d.vol.writeFile("data/full/BIG.DAT", &big);
                d.blk.fault = null;
                // Done only when the failure was a FAT copy past the first,
                // which is no failure of the write (#7).
                if ((d.vol.fat_copies_failed != 0) == std.meta.isError(result)) {
                    std.debug.print("a new file{s} (FAT {s}): request {d} of {d} failed; the write {s}, and {d} FAT copy writes failed\n", .{ if (grows) ", growing its directory" else "", if (cfg.cached) "held" else "on disk", n, total, if (std.meta.isError(result)) "failed" else "said done", d.vol.fat_copies_failed });
                    return error.TestUnexpectedResult;
                }
                try d.mount(cfg.cached);
                const r = try d.check();
                if (r.health.leaked != 0) {
                    std.debug.print("a new file{s} (FAT {s}): request {d} of {d} failed, before the commit, and {d} clusters are leaked\n", .{ if (grows) ", growing its directory" else "", if (cfg.cached) "held" else "on disk", n, total, r.health.leaked });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "a request that fails is an error, and the machine carries on with nothing worse than a stop leaves" {
    var buf: [8192]u8 = undefined;
    for (stopped_ops) |op| {
        for (configs) |cfg| {
            // FAT32 with its FAT held, as the kernel holds it; the path with
            // the FAT on the disk is the same code on both, and runs on
            // FAT16. FAT32's disk is 35 MB, and this is a test of every request.
            if (cfg.shape.kind == .fat32 and !cfg.cached) continue;
            const kind = if (cfg.shape.kind == .fat32) "FAT32" else "FAT16";
            const total = try requestsOf(op, cfg);
            const d = try Disk.makeUnkept("limit-fails", cfg.shape, cfg.cached);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try testing.allocator.dupe(u8, d.bytes);
            defer testing.allocator.free(before);
            // Put back only when something was written since: most failed
            // requests come before any write, and the disk is 35 MB on FAT32.
            var clean_at: ?u64 = null;
            var n: u64 = 0;
            while (n < total) : (n += 1) {
                if (clean_at != d.blk.writes) @memcpy(d.bytes, before);
                clean_at = d.blk.writes;
                try d.mount(cfg.cached);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = .fails };
                const result = op.run(&d.vol);
                d.blk.fault = null;
                const said_done = if (result) |_| true else |_| false;

                // What the machine holds in memory is still the disk's, at
                // once (a later change to the same FAT sector would write
                // the held one over the disk's and hide it), and after it
                // goes on, on the same mount.
                try heldIsDisk(d, op.name, kind, n);
                try d.vol.writeFile("data/after", &after_bytes);
                try d.expectFile("data/after", &after_bytes);
                try heldIsDisk(d, op.name, kind, n);

                // And the next boot finds an outcome the operation names.
                try d.mount(cfg.cached);
                var done = true;
                for (op.want) |w| {
                    const got = try stateOf(d, w.path, &buf);
                    for (w.any) |st| {
                        if (sameState(st, got)) break;
                    } else {
                        std.debug.print("{s} ({s}): request {d} failed; {s} is {s}, not an outcome named\n", .{ op.name, kind, n, w.path, describe(got) });
                        return error.TestUnexpectedResult;
                    }
                    if (!sameState(w.any[w.any.len - 1], got)) done = false;
                }
                // **DONE IS SAID OF WHAT IS DONE, AND ONLY OF IT** (metal-vmm
                // QUEUE 131, kernel-facts #3): a request that failed landed
                // nothing, so an operation that answers done must have left
                // its finished outcome (the last one named), and one that
                // left it must answer done. A cleanup after the commit (a
                // chain freed, a long name's parts) that fails is a leak the
                // check reports, not the operation's failure.
                if (said_done != done) {
                    std.debug.print("{s} ({s}, FAT {s}): request {d} of {d} failed; the operation {s}, and its outcome is {s}\n", .{ op.name, kind, if (cfg.cached) "held" else "on disk", n, total, if (said_done) "said it was done" else "said it failed", if (done) "the finished one" else "not the finished one" });
                    return error.TestUnexpectedResult;
                }
                const r = try d.check();
                try onlyAllowed(&r, if (op.appends != null) &allowed_append else &allowed, op.name, kind, "failed request", n);
            }
        }
    }
}

test "a write that lands and answers failure is an error, and leaves nothing worse than a stop: no rollback once a commit was tried (metal-vmm QUEUE 131)" {
    // A caller cannot tell a refused write that landed from one that did not.
    // Whatever it undoes after trying its commit (the entry that points at
    // what it made) must be safe either way: a cluster freed under an entry
    // that landed is one the next file takes, two files in one cluster.
    var buf: [8192]u8 = undefined;
    for (stopped_ops) |op| {
        for (configs) |cfg| {
            if (cfg.shape.kind == .fat32 and !cfg.cached) continue;
            const kind = if (cfg.shape.kind == .fat32) "FAT32" else "FAT16";
            const total = try requestsOf(op, cfg);
            const d = try Disk.makeUnkept("limit-lands-fails", cfg.shape, cfg.cached);
            defer d.deinit();
            try op.setup(&d.vol);
            setFsInfo(d);
            const before = try testing.allocator.dupe(u8, d.bytes);
            defer testing.allocator.free(before);
            var clean_at: ?u64 = null;
            var n: u64 = 0;
            while (n < total) : (n += 1) {
                if (clean_at != d.blk.writes) @memcpy(d.bytes, before);
                clean_at = d.blk.writes;
                try d.mount(cfg.cached);
                d.blk.fault = .{ .at = d.blk.requests + n, .kind = .lands_and_fails };
                // Its answer is either: a read the fault met is served as
                // it is, since only writes lie.
                op.run(&d.vol) catch {};
                d.blk.fault = null;
                // What the machine holds is the disk's, whatever the write
                // answered: a FAT sector the disk took and called failed is
                // read again, not assumed old (QUEUE 131, #7).
                try heldIsDisk(d, op.name, kind, n);
                try d.mount(cfg.cached);
                for (op.want) |w| {
                    const got = try stateOf(d, w.path, &buf);
                    for (w.any) |st| {
                        if (sameState(st, got)) break;
                    } else {
                        std.debug.print("{s} ({s}): request {d} landed and failed; {s} is {s}, not an outcome named\n", .{ op.name, kind, n, w.path, describe(got) });
                        return error.TestUnexpectedResult;
                    }
                }
                const r = try d.check();
                try onlyAllowed(&r, if (op.appends != null) &allowed_append else &allowed, op.name, kind, "write that landed and failed", n);
                // And it still takes a new file.
                try d.vol.writeFile("data/after", &after_bytes);
                try d.expectFile("data/after", &after_bytes);
            }
        }
    }
}

test "a disk that lies (a write that lands nothing or half, a read of other bytes) never stops the machine, and the next boot mounts and checks it" {
    const virtio = @import("virtio.zig");
    // What `Volume.check` found across every run, by problem: the boot's
    // disk check is where a lie that damaged the volume is seen.
    var found = [_]u32{0} ** @typeInfo(fat16.Problem).@"enum".fields.len;
    var runs: u32 = 0;
    for ([_]@FieldType(virtio.Block.Fault, "kind"){ .lands_nothing, .torn, .garbage }) |lie| {
        for (stopped_ops) |op| {
            for (configs) |cfg| {
                if (!cfg.cached) continue; // the FAT held, as the kernel holds it
                // On FAT32, only the read of other bytes, where its wider
                // entries and cluster fields are what is parsed: a write that
                // lies is the same code on both, and FAT32's disk is 35 MB.
                if (cfg.shape.kind == .fat32 and lie != .garbage) continue;
                const total = try requestsOf(op, cfg);
                const d = try Disk.makeUnkept("limit-lies", cfg.shape, cfg.cached);
                defer d.deinit();
                try op.setup(&d.vol);
                setFsInfo(d);
                const before = try testing.allocator.dupe(u8, d.bytes);
                defer testing.allocator.free(before);
                var clean_at: ?u64 = null;
                var n: u64 = 0;
                while (n < total) : (n += 1) {
                    if (clean_at != d.blk.writes) @memcpy(d.bytes, before);
                    clean_at = d.blk.writes;
                    try d.mount(cfg.cached);
                    d.blk.fault = .{ .at = d.blk.requests + n, .kind = lie, .seed = @truncate(n) };
                    // It returns, whatever it answers: no panic, no loop
                    // that does not end.
                    op.run(&d.vol) catch {};
                    d.blk.fault = null;
                    d.mount(cfg.cached) catch |e| {
                        std.debug.print("{s}, {s}, request {d}: the next boot does not mount: {s}\n", .{ op.name, @tagName(lie), n, @errorName(e) });
                        return error.TestUnexpectedResult;
                    };
                    // Every finding counted: a read of other bytes can leave
                    // more than test_disk.Report keeps.
                    const Count = struct {
                        by: *@TypeOf(found),
                        fn each(c: *@This(), f: fat16.Finding) void {
                            c.by[@intFromEnum(f.problem)] += 1;
                        }
                    };
                    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
                    defer testing.allocator.free(seen);
                    var count = Count{ .by = &found };
                    const writes = d.blk.writes;
                    _ = d.vol.check(seen, &count, Count.each) catch |e| {
                        std.debug.print("{s}, {s}, request {d}: the next boot's check does not run: {s}\n", .{ op.name, @tagName(lie), n, @errorName(e) });
                        return error.TestUnexpectedResult;
                    };
                    try testing.expectEqual(writes, d.blk.writes);
                    runs += 1;
                }
            }
        }
    }
    try testing.expect(runs > 1000);
}
