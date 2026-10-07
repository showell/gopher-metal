//! **THE STORE PRODUCTION RUNS, JUDGED** (zig build store-judge; essay
//! notes/where-the-metal-stack-stands.md, "The Store").
//!
//! On the droplet a chat message is angry-gopher's `store.zig`, over this
//! repo's `io.zig`, over `fat16`. This drives that stack and angry-gopher's
//! same `store.zig` over Linux's `std.Io` in a temporary folder, against the
//! model (`store_model.zig`), with the same seeded operations, and requires
//! the same answer from all three at every step and the same tree after it.
//!
//! Two compilations of one file: `ag_store_linux` is angry-gopher's
//! `zig-server/src/store.zig` as it is, and `ag_store_metal` is the port's
//! copy (port.sh), whose `Io` is `@import("metal").io`: this judge's world,
//! so the io it writes through is the one these tests mount disks on.

const std = @import("std");
const world = @import("judge_world");
const linux_store = @import("ag_store_linux");
const metal_store = @import("ag_store_metal");
const testing = std.testing;

const io_mod = world.io;
const test_disk = world.test_disk;
const Model = world.store_model.Model;
const Store = world.store.Store;

/// What an operation answered, in the terms angry-gopher's callers act on.
const Said = enum { ok, not_found, through_file, is_directory, bad_name, no_space, other };

fn said(e: anyerror) Said {
    return switch (e) {
        error.FileNotFound, error.NotFound => .not_found,
        // A path whose folder is a file: std.Io's answer.
        error.NotDir => .through_file,
        error.IsDir, error.IsDirectory => .is_directory,
        error.BadName, error.PathTooLong, error.PathTooDeep, error.NameTooLong => .bad_name,
        error.NoSpaceLeft, error.NoSpace => .no_space,
        else => .other,
    };
}

const Answer = struct {
    said: Said,
    /// What a read gave, or a listing's names and kinds, one a line, sorted.
    bytes: []const u8 = "",
    err: ?anyerror = null,

    fn eql(a: Answer, b: Answer) bool {
        return a.said == b.said and std.mem.eql(u8, a.bytes, b.bytes);
    }
};

const Op = enum { read, write, append, remove, replace, list };

/// Paths shaped like the application's, and spellings of them in another
/// case, under the data root.
const paths = [_][]const u8{
    "chat/1_2/sessions/general.md",
    "chat/1_2/sessions/GENERAL.md",
    "chat/1_2/sessions/general.count",
    "chat/1_2/sessions/A Long Topic Name.md",
    "chat/1_2/sessions/a long topic name.md",
    "chat/1_2/meta.json",
    "chat/1_3/sessions/general.md",
    "players/p17/record.json",
    "players/P17/record.json",
    "players/p17",
    "chat",
    "chat/1_2/sessions",
    "uploads/a.png",
    "bad:name",
    "trailing.",
};

const World = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    model: Model,
    disk: *test_disk.Disk,
    tmp: testing.TmpDir,
    /// The Linux side's roots, as paths from the working directory; the
    /// store keeps both (`setBases`), so they live as long as the world.
    linux_root: []const u8,
    linux_auth: []const u8,
    /// Where the model's reads land, reused.
    model_buf: []u8,

    fn make(gpa: std.mem.Allocator) !World {
        var w: World = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .model = Model.init(gpa),
            .disk = try test_disk.Disk.make("store-judge", test_disk.small, false),
            .tmp = testing.tmpDir(.{}),
            .linux_root = undefined,
            .linux_auth = undefined,
            .model_buf = try gpa.alloc(u8, 1 << 20),
        };
        io_mod.mount(w.disk.vol);
        io_mod.keepData(&.{ "data", "auth" }, null);
        w.linux_root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/data", .{w.tmp.sub_path});
        try w.tmp.dir.createDirPath(testing.io, "data");
        w.linux_auth = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/auth", .{w.tmp.sub_path});
        linux_store.setBases(w.linux_root, w.linux_auth);
        metal_store.setBases("data", "auth");
        return w;
    }

    fn deinit(w: *World) void {
        if (io_mod.siteVolume()) |v| w.disk.vol = v.*;
        w.disk.deinit();
        w.model.deinit();
        w.tmp.cleanup();
        w.gpa.free(w.linux_root);
        w.gpa.free(w.linux_auth);
        w.gpa.free(w.model_buf);
        w.arena.deinit();
    }

    fn linuxPath(w: *World, rel: []const u8) ![]const u8 {
        if (rel.len == 0) return w.linux_root;
        return std.fmt.allocPrint(w.arena.allocator(), "{s}/{s}", .{ w.linux_root, rel });
    }

    fn metalPath(w: *World, rel: []const u8) ![]const u8 {
        if (rel.len == 0) return "data";
        return std.fmt.allocPrint(w.arena.allocator(), "data/{s}", .{rel});
    }
};

const mio: io_mod = .{};

fn sortedLines(a: std.mem.Allocator, lines: *std.ArrayList([]const u8)) ![]const u8 {
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (lines.items) |l| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    return out.items;
}

fn onLinux(w: *World, op: Op, rel: []const u8, bytes: []const u8) !Answer {
    const a = w.arena.allocator();
    const p = try w.linuxPath(rel);
    const io = testing.io;
    switch (op) {
        .read => {
            const got = linux_store.read(io, a, p, .unlimited) catch |e| return .{ .said = said(e), .err = e };
            return .{ .said = .ok, .bytes = got };
        },
        .write => linux_store.write(io, a, p, bytes, .{}) catch |e| return .{ .said = said(e), .err = e },
        .append => _ = linux_store.append(io, a, p, bytes) catch |e| return .{ .said = said(e), .err = e },
        .replace => linux_store.replace(io, a, p, bytes, .{}) catch |e| return .{ .said = said(e), .err = e },
        .remove => linux_store.remove(io, a, p) catch |e| return .{ .said = said(e), .err = e },
        .list => {
            const items = linux_store.list(io, a, p) catch |e| return .{ .said = said(e), .err = e };
            var lines: std.ArrayList([]const u8) = .empty;
            for (items) |it| try lines.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ it.name, @tagName(it.kind) }));
            return .{ .said = .ok, .bytes = try sortedLines(a, &lines) };
        },
    }
    return .{ .said = .ok };
}

fn onMetal(w: *World, op: Op, rel: []const u8, bytes: []const u8) !Answer {
    const a = w.arena.allocator();
    const p = try w.metalPath(rel);
    switch (op) {
        .read => {
            const got = metal_store.read(mio, a, p, .unlimited) catch |e| return .{ .said = said(e), .err = e };
            return .{ .said = .ok, .bytes = got };
        },
        .write => metal_store.write(mio, a, p, bytes, .{}) catch |e| return .{ .said = said(e), .err = e },
        .append => _ = metal_store.append(mio, a, p, bytes) catch |e| return .{ .said = said(e), .err = e },
        .replace => metal_store.replace(mio, a, p, bytes, .{}) catch |e| return .{ .said = said(e), .err = e },
        .remove => metal_store.remove(mio, a, p) catch |e| return .{ .said = said(e), .err = e },
        .list => {
            const items = metal_store.list(mio, a, p) catch |e| return .{ .said = said(e), .err = e };
            var lines: std.ArrayList([]const u8) = .empty;
            for (items) |it| try lines.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ it.name, @tagName(it.kind) }));
            return .{ .said = .ok, .bytes = try sortedLines(a, &lines) };
        },
    }
    return .{ .said = .ok };
}

/// **THE MODEL, SPEAKING THE SEAM'S CONTRACT** (STORE.md): it is
/// gopher-metal's Store, whose answers differ from angry-gopher's store.zig
/// where the contract is the seam's: a remove of what is absent is done, a
/// folder that is absent lists nothing, and a name is checked only where a
/// call would create it, so one looked up that FAT could not hold is simply
/// not there. A write the model refuses as a bad name whose every part is a
/// name FAT holds is a write through a file. Until the model is the seam's
/// (STORE.md, open question 1), this is where the two meet.
fn onModel(w: *World, op: Op, rel: []const u8, bytes: []const u8) !Answer {
    const a = w.arena.allocator();
    const s: Store = w.model.store_();
    // A path through a file is "not a directory" at the seam, whatever the
    // operation, as both hosts answer it.
    var end: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rel, end, '/')) |slash| : (end = slash + 1) {
        if (s.read(rel[0..slash], w.model_buf)) |_| return .{ .said = .through_file } else |_| {}
    }
    switch (op) {
        .read => {
            const n = s.read(rel, w.model_buf) catch |e| return .{ .said = if (e == error.BadName) .not_found else said(e), .err = e };
            return .{ .said = .ok, .bytes = try a.dupe(u8, w.model_buf[0..n]) };
        },
        .write => s.write(rel, bytes) catch |e| return created(rel, e),
        .append => s.append(rel, bytes) catch |e| return created(rel, e),
        .replace => s.replace(rel, bytes) catch |e| return created(rel, e),
        .remove => s.remove(rel) catch |e| switch (e) {
            error.NotFound, error.BadName => {},
            else => return .{ .said = said(e), .err = e },
        },
        .list => {
            // A file listed is "not a directory" at the seam, as std.Io's
            // openDir answers on both hosts; the model lists it as nothing.
            if (s.read(rel, w.model_buf)) |_| return .{ .said = .through_file } else |_| {}
            var lines: std.ArrayList([]const u8) = .empty;
            const Ctx = struct {
                a: std.mem.Allocator,
                lines: *std.ArrayList([]const u8),
                fn call(ctx: *anyopaque, item: world.store.Item) void {
                    const c: *@This() = @ptrCast(@alignCast(ctx));
                    const line = std.fmt.allocPrint(c.a, "{s} {s}", .{ item.name, @tagName(item.kind) }) catch return;
                    c.lines.append(c.a, line) catch return;
                }
            };
            var ctx = Ctx{ .a = a, .lines = &lines };
            s.list(rel, .{ .context = &ctx, .call = Ctx.call }) catch |e| switch (e) {
                error.NotFound, error.BadName => return .{ .said = .ok, .bytes = "" },
                else => return .{ .said = said(e), .err = e },
            };
            return .{ .said = .ok, .bytes = try sortedLines(a, &lines) };
        },
    }
    return .{ .said = .ok };
}

/// What a creating call's refusal means at the seam: a bad name only if some
/// part of the path is one; otherwise the model refused a folder that is a
/// file.
fn created(rel: []const u8, e: anyerror) Answer {
    if (e == error.BadName) {
        var parts: [world.store.max_parts][]const u8 = undefined;
        if (world.store.checkPath(rel, &parts, false)) |_| return .{ .said = .through_file, .err = e } else |_| {}
    }
    return .{ .said = said(e), .err = e };
}

/// The whole tree under the data root, one line a file with its bytes'
/// hash, as each side's own `list` and `read` give it.
fn tree(w: *World, comptime side: enum { linux, metal, model }) ![]const u8 {
    const a = w.arena.allocator();
    var lines: std.ArrayList([]const u8) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(a, "");
    while (stack.pop()) |dir| {
        const listed = switch (side) {
            .linux => try onLinux(w, .list, dir, ""),
            .metal => try onMetal(w, .list, dir, ""),
            .model => try onModel(w, .list, dir, ""),
        };
        if (listed.said != .ok) continue;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, listed.bytes, "\n"), '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const sp = std.mem.lastIndexOfScalar(u8, line, ' ').?;
            const name = line[0..sp];
            if (std.mem.startsWith(u8, name, ".~")) continue; // a replace's own temporary
            const rel = if (dir.len == 0) name else try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
            if (std.mem.eql(u8, line[sp + 1 ..], "directory")) {
                try lines.append(a, try std.fmt.allocPrint(a, "{s}/", .{rel}));
                try stack.append(a, rel);
            } else {
                const got = switch (side) {
                    .linux => try onLinux(w, .read, rel, ""),
                    .metal => try onMetal(w, .read, rel, ""),
                    .model => try onModel(w, .read, rel, ""),
                };
                try lines.append(a, try std.fmt.allocPrint(a, "{s} {x}", .{ rel, std.hash.Wyhash.hash(0, got.bytes) }));
            }
        }
    }
    return sortedLines(a, &lines);
}

fn runSeed(seed: u64) !void {
    var w = try World.make(testing.allocator);
    defer w.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var bytes: [3000]u8 = undefined;
    for (0..r.intRangeAtMost(usize, 20, 80)) |step| {
        // Each step's answers and trees are compared and dropped.
        _ = w.arena.reset(.retain_capacity);
        const op = r.enumValue(Op);
        const rel = paths[r.uintLessThan(usize, paths.len)];
        const n = r.uintLessThan(usize, bytes.len);
        r.bytes(bytes[0..n]);
        const answers = [_]Answer{
            try onModel(&w, op, rel, bytes[0..n]),
            try onLinux(&w, op, rel, bytes[0..n]),
            try onMetal(&w, op, rel, bytes[0..n]),
        };
        if (!answers[0].eql(answers[1]) or !answers[0].eql(answers[2])) {
            std.debug.print("store_judge seed {d} step {d}: {s} \"{s}\": the model {s} ({?}), Linux {s} ({?}), metal {s} ({?})\n", .{
                seed,                      step,           @tagName(op),              rel,
                @tagName(answers[0].said), answers[0].err, @tagName(answers[1].said), answers[1].err,
                @tagName(answers[2].said), answers[2].err,
            });
            const a = w.arena.allocator();
            const ls = linux_store.stat(testing.io, a, try w.linuxPath(rel));
            const ms = metal_store.stat(mio, a, try w.metalPath(rel));
            std.debug.print("  stat there: Linux {any}, metal {any}\n", .{ ls, ms });
            std.debug.print("  the trees before it:\n{s}", .{try tree(&w, .model)});
            return error.Disagree;
        }
        const m = try tree(&w, .model);
        const l = try tree(&w, .linux);
        const t = try tree(&w, .metal);
        if (!std.mem.eql(u8, m, l) or !std.mem.eql(u8, m, t)) {
            std.debug.print("store_judge seed {d} step {d}, after {s} \"{s}\": the trees differ\nthe model:\n{s}Linux:\n{s}metal:\n{s}", .{ seed, step, @tagName(op), rel, m, l, t });
            return error.Disagree;
        }
    }
}

test "angry-gopher's store on Linux and on metal answers as the model, step by step" {
    for (1..41) |seed| try runSeed(seed);
}
