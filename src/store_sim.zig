//! **THE THREE STORES, UNDER A SEED** (metal-vmm QUEUE item 79): the model
//! (`store_model.zig`), the FAT store (`store_fat.zig`, on a disk in memory)
//! and the strict Linux store (`store_linux.zig`, in a temporary directory),
//! given the same operations, chosen by a seed from a pool of paths that
//! differ in case, nest under each other, and break the name rules.
//!
//! **THE ORACLES**, after every operation:
//!
//! - **One answer.** All three answer it alike: the same error, or the same
//!   bytes read. So FAT and Linux refuse the same names for the same reason,
//!   and both refuse what the model refuses.
//! - **One tree.** Every name, kind, size and byte the three hold is the
//!   same (`store_test.snapshot`).
//! - **What a cut leaves.** Some operations on the FAT store have the power
//!   cut part-way, at a request the seed picks. The volume is mounted again
//!   as the next boot would, and the file the operation was on must be what
//!   `store.zig` promises: `replace` wholly old or wholly new, `append` old
//!   or new, `write` old, new or gone, `remove` there or gone. Then the
//!   model and the Linux store are made what FAT holds, and the run goes on.

const std = @import("std");
const store = @import("store.zig");
const Model = @import("store_model.zig").Model;
const FatStore = @import("store_fat.zig").FatStore;
const LinuxStore = @import("store_linux.zig").LinuxStore;
const test_disk = @import("test_disk.zig");
const snapshot = @import("store_test.zig").snapshot;
const props = @import("coverage");
const Error = store.Error;

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const paths = [_][]const u8{
    "a",                  "A",                  "data/x.md",         "DATA/X.MD",
    "data/chat/topic.md", "data/Chat/Topic.md", "data/chat/u.jsonl", "data/chat",
    "data",               "auth/7/session",     "data/x.md/under",   "data//chat/",
    "data/a:b",           "data/what?",         "data/trailing.",    "data/.~hidden",
    "data/../a",          "",                   "a/b/c/d/e/f/g/h/i", "data/" ++ "n" ** 81,
};

/// The pool's other spellings of a name it also has: another case, or
/// empty parts.
fn isVariant(path: []const u8) bool {
    for ([_][]const u8{ "A", "DATA/X.MD", "data/Chat/Topic.md", "data//chat/" }) |v| {
        if (std.mem.eql(u8, path, v)) return true;
    }
    return false;
}

const Failure = error{SimulationFailed};

fn fail(seed: u64, comptime fmt: []const u8, args: anytype) Failure {
    std.debug.print("store_sim seed {d}: " ++ fmt ++ "\n", .{seed} ++ args);
    return error.SimulationFailed;
}

const Op = enum { read, write, append, remove, replace, list };

/// One operation's answer, comparable across stores.
const Answer = struct {
    err: ?Error = null,
    bytes: []const u8 = "",

    fn eql(a: Answer, b: Answer) bool {
        if (a.err) |ae| {
            const be = b.err orelse return false;
            return ae == be;
        }
        if (b.err != null) return false;
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

fn noItem(_: *anyopaque, _: store.Item) void {}

fn run(s: store.Store, op: Op, path: []const u8, bytes: []const u8, out: []u8) Answer {
    const r: Error![]const u8 = switch (op) {
        .read => if (s.read(path, out)) |n| out[0..n] else |e| e,
        .write => if (s.write(path, bytes)) |_| "" else |e| e,
        .append => if (s.append(path, bytes)) |_| "" else |e| e,
        .remove => if (s.remove(path)) |_| "" else |e| e,
        .replace => if (s.replace(path, bytes)) |_| "" else |e| e,
        .list => blk: {
            var dummy: u8 = 0;
            break :blk if (s.list(path, .{ .context = &dummy, .call = noItem })) |_| "" else |e| e;
        },
    };
    return if (r) |b| .{ .bytes = b } else |e| .{ .err = e };
}

const World = struct {
    seed: u64,
    gpa: std.mem.Allocator,
    model: Model,
    disk: *test_disk.Disk,
    fat: FatStore,
    tmp: std.testing.TmpDir,
    linux: LinuxStore,
    /// Room to read any file the volume can hold (a seed's appends grow
    /// them): before a cut, what it should leave, after it, and a copy.
    big: [4][]u8,

    fn reset(w: *World) !void {
        w.model.deinit();
        w.model = Model.init(w.gpa);
        w.tmp.cleanup();
        w.tmp = std.testing.tmpDir(.{ .iterate = true });
        w.linux = .{ .io = std.testing.io, .root = w.tmp.dir };
    }

    /// The model and the Linux store, made what FAT holds: after a cut.
    fn copyFromFat(w: *World) !void {
        try w.reset();
        try copyDir(w, "");
    }

    fn copyDir(w: *World, dir: []const u8) !void {
        const Collect = struct {
            gpa: std.mem.Allocator,
            names: std.ArrayListUnmanaged(struct { name: []u8, kind: store.Kind }) = .empty,
            fn each(c: *anyopaque, item: store.Item) void {
                const self: *@This() = @ptrCast(@alignCast(c));
                const name = self.gpa.dupe(u8, item.name) catch @panic("out of memory");
                self.names.append(self.gpa, .{ .name = name, .kind = item.kind }) catch @panic("out of memory");
            }
        };
        var c = Collect{ .gpa = w.gpa };
        defer {
            for (c.names.items) |n| w.gpa.free(n.name);
            c.names.deinit(w.gpa);
        }
        try w.fat.store_().list(dir, .{ .context = &c, .call = Collect.each });
        for (c.names.items) |n| {
            var pb: [512]u8 = undefined;
            const path = if (dir.len == 0) n.name else try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, n.name });
            switch (n.kind) {
                .file => {
                    const buf = w.big[3];
                    const got = try w.fat.store_().read(path, buf);
                    try w.model.write(path, buf[0..got]);
                    try w.linux.store_().write(path, buf[0..got]);
                },
                .directory => {
                    // A directory is made by a write under it; an empty one
                    // is made by writing a file there and removing it.
                    var probe_buf: [600]u8 = undefined;
                    const probe = try std.fmt.bufPrint(&probe_buf, "{s}/{s}", .{ path, "probe" });
                    for ([_]store.Store{ w.model.store_(), w.linux.store_() }) |s| {
                        try s.write(probe, "");
                        try s.remove(probe);
                    }
                    try copyDir(w, path);
                },
            }
        }
    }
};

pub fn runSeed(seed: u64) Failure!void {
    return runSeedInner(seed) catch |e| switch (e) {
        error.SimulationFailed => error.SimulationFailed,
        else => fail(seed, "{s}", .{@errorName(e)}),
    };
}

fn runSeedInner(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const gpa = std.testing.allocator;
    const shape = if (r.uintLessThan(u8, 4) == 0) test_disk.small32 else test_disk.small;
    var w = World{
        .seed = seed,
        .gpa = gpa,
        .model = Model.init(gpa),
        .disk = try test_disk.Disk.make("damaged-store-sim", shape, false),
        .fat = undefined,
        .tmp = std.testing.tmpDir(.{ .iterate = true }),
        .linux = undefined,
        .big = undefined,
    };
    for (&w.big) |*b| b.* = try gpa.alloc(u8, @as(usize, shape.sectors) * 512);
    defer for (w.big) |b| gpa.free(b);
    w.fat = .{ .vol = &w.disk.vol };
    w.linux = .{ .io = std.testing.io, .root = w.tmp.dir };
    defer {
        w.model.deinit();
        w.disk.deinit();
        w.tmp.cleanup();
    }
    const stores = [_]store.Store{ w.model.store_(), w.fat.store_(), w.linux.store_() };
    _ = stores;
    var bytes: [6000]u8 = undefined;
    var outs: [3][8192]u8 = undefined;
    const cut_every = r.intRangeAtMost(u32, 4, 20);
    for (0..r.intRangeAtMost(usize, 30, 120)) |step| {
        const op = r.enumValue(Op);
        const path = paths[r.uintLessThan(usize, paths.len)];
        const n = if (r.boolean()) r.uintLessThan(usize, 64) else r.uintLessThan(usize, bytes.len);
        r.bytes(bytes[0..n]);
        const writes_something = op == .write or op == .append or op == .replace or op == .remove;
        if (writes_something and r.uintLessThan(u32, cut_every) == 0) {
            try cutOne(&w, r, op, path, bytes[0..n], step);
            continue;
        }
        const a = [_]Answer{
            run(w.model.store_(), op, path, bytes[0..n], &outs[0]),
            run(w.fat.store_(), op, path, bytes[0..n], &outs[1]),
            run(w.linux.store_(), op, path, bytes[0..n], &outs[2]),
        };
        const alike = a[0].eql(a[1]) and a[0].eql(a[2]);
        props.always(@src(), alike, "store_sim: the three stores answer every operation alike", .{ .step = step, .op = @tagName(op) });
        if (!alike) return fail(seed, "step {d}, {s} \"{s}\": the model {any}, FAT {any}, Linux {any}", .{ step, @tagName(op), path, a[0].err, a[1].err, a[2].err });
        if (a[0].err) |e| switch (e) {
            Error.BadName => props.reachable(@src(), "store_sim: all three refuse a name, for the same reason", .{ .op = @tagName(op) }),
            Error.NotFound => props.reachable(@src(), "store_sim: all three find nothing there", null),
            Error.IsDirectory => props.reachable(@src(), "store_sim: all three refuse a file operation on a directory", null),
            Error.TooBig => props.reachable(@src(), "store_sim: all three refuse a read into too little room", null),
            else => {},
        } else if (op == .read and isVariant(path))
            props.reachable(@src(), "store_sim: a spelling in another case, or with empty parts, finds the same file", null);
        try same(&w, step);
    }
}

fn same(w: *World, step: usize) !void {
    const m = try snapshot(w.model.store_(), w.gpa);
    defer w.gpa.free(m);
    const f = try snapshot(w.fat.store_(), w.gpa);
    defer w.gpa.free(f);
    const l = try snapshot(w.linux.store_(), w.gpa);
    defer w.gpa.free(l);
    const alike = std.mem.eql(u8, m, f) and std.mem.eql(u8, m, l);
    props.always(@src(), alike, "store_sim: the three trees are the same after every operation", .{ .step = step });
    if (!alike) return fail(w.seed, "step {d}: the trees differ\nthe model:\n{s}FAT:\n{s}Linux:\n{s}", .{ step, m, f, l });
}

/// `op` on the FAT store with the power cut at a request the seed picks,
/// then the next boot's mount, and the promise for `op` checked on `path`.
fn cutOne(w: *World, r: std.Random, op: Op, path: []const u8, bytes: []const u8, step: usize) !void {
    const before_buf = w.big[0];
    const before: ?[]const u8 = if (w.fat.store_().read(path, before_buf)) |n| before_buf[0..n] else |e| switch (e) {
        Error.NotFound, Error.BadName, Error.IsDirectory => null,
        else => return fail(w.seed, "step {d}: before the cut, \"{s}\" reads as {s}", .{ step, path, @errorName(e) }),
    };
    // What the operation would leave, from the model, on a copy of what it
    // holds for this path only.
    const after_buf = w.big[1];
    var after: ?[]const u8 = null;
    switch (op) {
        .write, .replace => after = bytes,
        .append => if (before) |b| {
            @memcpy(after_buf[0..b.len], b);
            @memcpy(after_buf[b.len..][0..bytes.len], bytes);
            after = after_buf[0 .. b.len + bytes.len];
        } else {
            after = bytes;
        },
        else => after = null,
    }
    const base = w.disk.blk.requests;
    w.disk.blk.fail_after = base + r.uintLessThan(u64, 60);
    if (r.uintLessThan(u8, 3) == 0) w.disk.blk.fault = .{ .at = w.disk.blk.fail_after.? -| 1, .kind = .torn };
    var scratch: [8192]u8 = undefined;
    const answered = run(w.fat.store_(), op, path, bytes, &scratch);
    const cut = w.disk.blk.requests >= w.disk.blk.fail_after.?;
    w.disk.blk.fail_after = null;
    w.disk.blk.fault = null;
    try w.disk.mount(false);
    w.fat = .{ .vol = &w.disk.vol };
    if (!cut) {
        // The operation finished before the cut: an ordinary step, whose
        // answer the others must give too.
        try w.copyFromFat();
        _ = answered;
        try same(w, step);
        return;
    }
    props.reachable(@src(), "store_sim: a cut lands inside an operation", .{ .op = @tagName(op) });
    const now_buf = w.big[2];
    const now: ?[]const u8 = if (w.fat.store_().read(path, now_buf)) |n| now_buf[0..n] else |e| switch (e) {
        Error.NotFound, Error.BadName, Error.IsDirectory => null,
        else => return fail(w.seed, "step {d}, {s} \"{s}\" cut: the file reads as {s}", .{ step, @tagName(op), path, @errorName(e) }),
    };
    const is = struct {
        fn same(a: ?[]const u8, b: ?[]const u8) bool {
            if (a == null or b == null) return a == null and b == null;
            return std.mem.eql(u8, a.?, b.?);
        }
    };
    const old = is.same(now, before);
    const new = if (op == .remove) now == null else is.same(now, after);
    const kept = switch (op) {
        .replace => blk: {
            props.always(@src(), old or new, "store_sim: after a cut, a replaced file is wholly old or wholly new", .{ .step = step });
            break :blk old or new;
        },
        .append => blk: {
            props.always(@src(), old or new, "store_sim: after a cut, an appended file is old or new", .{ .step = step });
            break :blk old or new;
        },
        .write => blk: {
            props.always(@src(), old or new or now == null, "store_sim: after a cut, a written file is old, new or gone", .{ .step = step });
            break :blk old or new or now == null;
        },
        .remove => blk: {
            props.always(@src(), old or new, "store_sim: after a cut, a removed file is there or gone", .{ .step = step });
            break :blk old or new;
        },
        else => true,
    };
    if (!kept) return fail(w.seed, "step {d}, {s} \"{s}\" cut: the file is neither what store.zig allows", .{ step, @tagName(op), path });
    try w.copyFromFat();
    try same(w, step);
}

test "store_sim: a handful of seeds" {
    for (1..21) |seed| try runSeed(seed);
}
