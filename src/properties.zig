//! **THE COVERAGE PROPERTIES, OVER MANY SEEDS** (COVERAGE.md): the TCP
//! table's in tcp_sim.zig, the FAT's in fat_sim.zig, the page cache's in
//! page_sim.zig, and the other pure modules' in pure_sim.zig.
//!
//!   zig build properties                  TCP seeds 1..100, FAT 1..20, pages 1..100
//!   zig build properties -Dseeds=5000 -Dfat-seeds=1000     more
//!   zig build properties -Dcrowd-seeds=500  fewer crowds (all by default)
//!   zig build properties -Dsdk-jsonl=out/sdk.jsonl
//!                                         also the JSONL, to a file
//!   zig build properties -Dfloor=coverage/floor-sim.txt
//!                                         and a MISS on the floor fails it
//!                                         (the long tier: long.sh)
//!
//! Each simulator runs each seed as it does under `zig build test`, but a
//! seed whose oracle fails is a broken `always` here, named with its seed,
//! and the sweep goes on. At the end the catalog is judged: every assertion in
//! tcp.zig, disk_fat.zig, the simulators and here, the ones never satisfied
//! first.
//!
//! **A FAILING `sometimes` IS NOT A TCP BUG.** It says no seed reached that
//! case: the simulator's scenarios do not cover it, and the table's code
//! there is untested by them; the report calls it a MISS. That is what this
//! report is for. The step fails only on a FAIL: an `always` seen false or
//! an `unreachable` reached.

const std = @import("std");
const at = @import("coverage");
const sim = @import("tcp_sim.zig");
const fat_sim = @import("fat_sim.zig");
const page_sim = @import("page_sim.zig");
const pure_sim = @import("pure_sim.zig");
const ready_sim = @import("ready_sim.zig");
const drain_sim = @import("drain_sim.zig");
const durable_sim = @import("durable_sim.zig");
const floor_sim = @import("floor_sim.zig");
const store_sim = @import("store_sim.zig");
const options = @import("tcp_properties_options");
const failed_seeds_file = @import("failed_seeds.zig");

var jsonl: std.ArrayList(u8) = .empty;

/// **WHERE THE SWEEP'S TIME GOES** (metal-vmm QUEUE 224.1): each simulator's
/// runs, events (sim_events.zig) and seconds, summed over its seeds, and its
/// nanoseconds an event, printed at the end with the whole run's seconds,
/// so the long tier can tell the build's time from the run's (long.sh).
const Sim = enum { tcp_plain, tcp_rough, tcp_crowd, fat, page, pure, ready, drain, tcp_full, store, floor, durable, fat_replays, store_replays, regressions, failed_before };
var spent = std.EnumArray(Sim, u64).initFill(0);
var runs = std.EnumArray(Sim, u64).initFill(0);
/// Each simulator's natural unit, as sim_events.zig lists them.
var events = std.EnumArray(Sim, u64).initFill(0);
const ev = @import("sim_events.zig");

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn awake() u64 {
    return @intCast(std.Io.Clock.now(.awake, std.testing.io).nanoseconds);
}

/// `run(seed)` timed into `sim`'s total: whether every oracle held.
fn timed(sim_: Sim, comptime run: anytype, seed: u64) bool {
    const from = awake();
    const counted = ev.count;
    defer {
        spent.getPtr(sim_).* += awake() - from;
        runs.getPtr(sim_).* += 1;
        events.getPtr(sim_).* += ev.count - counted;
        if (options.trace_reach) traceReach(sim_, seed);
    }
    return if (run(seed)) true else |_| false;
}

/// **WHO REACHES EACH FLOOR LINE, AND BY WHICH SEED** (metal-vmm QUEUE 224,
/// Steve's "challenge needing to do that much work"; `-Dtrace-reach`): after
/// each run, the sites whose passes it moved, so each floor line can say
/// which simulators reach it and the first seed each did. A walk of the
/// catalog a run: for measuring, not for the long tier.
const no_seed = std.math.maxInt(u64);
var passes_seen: []u32 = &.{};
var first_pass: []std.EnumArray(Sim, u64) = &.{};

fn traceReach(sim_: Sim, seed: u64) void {
    if (passes_seen.len == 0) {
        const n = at.catalog().count();
        passes_seen = std.heap.page_allocator.alloc(u32, n) catch @panic("out of memory for the reach trace");
        first_pass = std.heap.page_allocator.alloc(std.EnumArray(Sim, u64), n) catch @panic("out of memory for the reach trace");
        @memset(passes_seen, 0);
        @memset(first_pass, .initFill(no_seed));
    }
    var it = at.catalog();
    var i: usize = 0;
    while (it.next()) |site| : (i += 1) {
        if (site.passes == passes_seen[i]) continue;
        passes_seen[i] = site.passes;
        const first = first_pass[i].getPtr(sim_);
        if (first.* == no_seed) first.* = seed;
    }
}

/// Each floor line, with the simulators that reach it and the first seed
/// each did: `reach: <line> | tcp_plain@3 store@120`.
fn printReach(floor: []const u8) void {
    var lines = std.mem.splitScalar(u8, floor, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var who = std.EnumArray(Sim, u64).initFill(no_seed);
        var it = at.catalog();
        var i: usize = 0;
        while (it.next()) |site| : (i += 1) {
            if (!std.mem.eql(u8, std.mem.span(site.message), line)) continue;
            for (std.enums.values(Sim)) |k| who.set(k, @min(who.get(k), first_pass[i].get(k)));
        }
        std.debug.print("reach: {s} |", .{line});
        for (std.enums.values(Sim)) |k| if (who.get(k) != no_seed) std.debug.print(" {t}@{d}", .{ k, who.get(k) });
        std.debug.print("\n", .{});
    }
}

fn keep(line: []const u8) void {
    jsonl.appendSlice(std.testing.allocator, line) catch @panic("out of memory for the JSONL");
}

test "the properties over a sweep of seeds" {
    at.reset();
    defer jsonl.deinit(std.testing.allocator);
    if (options.sdk_jsonl.len > 0) at.sink = keep;
    defer at.sink = null;
    // A seed's failed oracle is a broken `always` named with its seed, counted
    // and reported at the end; it must not stop the sweep at the first.
    at.on_broken = null;
    defer at.on_broken = at.failTest;
    at.declare();

    const began = awake();
    var failed_seeds: usize = 0;
    for (1..options.seeds + 1) |seed| {
        const ok = timed(.tcp_plain, sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "tcp_sim: every oracle holds for every seed", .{ .seed = seed });
        const rough_ok = timed(.tcp_rough, sim.runRoughSeed, seed);
        if (!rough_ok) failed_seeds += 1;
        at.always(@src(), rough_ok, "tcp_sim: every oracle holds for every rough seed", .{ .seed = seed });
        if (seed > options.crowd_seeds) continue;
        const crowd_ok = timed(.tcp_crowd, sim.runCrowdSeed, seed);
        if (!crowd_ok) failed_seeds += 1;
        at.always(@src(), crowd_ok, "tcp_sim: every oracle holds for every crowd seed", .{ .seed = seed });
    }
    for (1..options.fat_seeds + 1) |seed| {
        const ok = timed(.fat, fat_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "fat_sim: every oracle holds for every seed, both FAT paths", .{ .seed = seed });
        const probed = timed(.fat, fat_sim.runProbeSeed, seed);
        if (!probed) failed_seeds += 1;
        at.always(@src(), probed, "fat_sim: every oracle holds for every seed with probes", .{ .seed = seed });
    }
    for (1..options.page_seeds + 1) |seed| {
        const ok = timed(.page, page_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "page_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.pure_seeds + 1) |seed| {
        const ok = timed(.pure, pure_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "pure_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.ready_seeds + 1) |seed| {
        const ok = timed(.ready, ready_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "ready_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.drain_seeds + 1) |seed| {
        const ok = timed(.drain, drain_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "drain_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.full_seeds + 1) |seed| {
        const ok = timed(.tcp_full, sim.runFullSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "tcp_sim: every oracle holds for a crowd the size of the kernel's table", .{ .seed = seed });
    }
    for (1..options.store_seeds + 1) |seed| {
        const ok = timed(.store, store_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "store_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.floor_seeds + 1) |seed| {
        const ok = timed(.floor, floor_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "floor_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.durable_seeds + 1) |seed| {
        const ok = timed(.durable, durable_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "durable_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    // **A RUN UNDER A TAPE REPLAYS EXACTLY: A FEW** (Steve, 2026-10-16: "cut
    // the replays to a few"). They check the harness's replay, not the FAT
    // or store code, and -Dtrace-reach found no floor line only they reach
    // (1,000 TCP and 300 FAT seeds): four FAT tapes and two store tapes, the
    // replays `zig build test` keeps and three more, where the 40 and 20
    // before were 42 s of the run (metal-vmm QUEUE B38, 224).
    for (1..5) |seed| {
        const ok = timed(.fat_replays, fat_sim.replaysExactly, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "fat_sim: a run under a tape replays exactly", .{ .seed = seed });
    }
    for (1..3) |seed| {
        const ok = timed(.store_replays, store_sim.replaysExactly, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "store_sim: a run under a tape replays exactly", .{ .seed = seed });
    }
    // **EVERY SEED THAT ONCE BROKE AN ORACLE** (coverage/seeds-that-failed.txt,
    // metal-vmm QUEUE 224.3), whatever the counts above.
    {
        const io = std.testing.io;
        const text = try std.Io.Dir.cwd().readFileAlloc(io, "coverage/seeds-that-failed.txt", std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(text);
        var entries = failed_seeds_file.Entries.init(text);
        while (try entries.next()) |e| {
            const which = std.meta.stringToEnum(Sim, e.simulator) orelse {
                std.debug.print("coverage/seeds-that-failed.txt: no simulator {s}\n", .{e.simulator});
                return error.NoSuchSimulator;
            };
            const ok = switch (which) {
                .tcp_plain => timed(.failed_before, sim.runSeed, e.seed),
                .tcp_rough => timed(.failed_before, sim.runRoughSeed, e.seed),
                .tcp_crowd => timed(.failed_before, sim.runCrowdSeed, e.seed),
                .tcp_full => timed(.failed_before, sim.runFullSeed, e.seed),
                .fat => both: {
                    const plain = timed(.failed_before, fat_sim.runSeed, e.seed);
                    const probed = timed(.failed_before, fat_sim.runProbeSeed, e.seed);
                    break :both plain and probed;
                },
                .page => timed(.failed_before, page_sim.runSeed, e.seed),
                .pure => timed(.failed_before, pure_sim.runSeed, e.seed),
                .ready => timed(.failed_before, ready_sim.runSeed, e.seed),
                .drain => timed(.failed_before, drain_sim.runSeed, e.seed),
                .store => timed(.failed_before, store_sim.runSeed, e.seed),
                .floor => timed(.failed_before, floor_sim.runSeed, e.seed),
                .durable => timed(.failed_before, durable_sim.runSeed, e.seed),
                .fat_replays, .store_replays, .regressions, .failed_before => {
                    std.debug.print("coverage/seeds-that-failed.txt: {s} is not a simulator's seeds\n", .{e.simulator});
                    return error.NoSuchSimulator;
                },
            };
            if (!ok) failed_seeds += 1;
            at.always(@src(), ok, "every seed that once broke an oracle holds", .{ .seed = e.seed });
        }
    }
    // Every sweep, whatever its size: they are the regression tests.
    for (fat_sim.regressions) |seed| {
        const ok = timed(.regressions, fat_sim.runSeed, seed);
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "fat_sim: every regression seed holds", .{ .seed = seed });
    }

    // Each simulator's seconds, then the run's (long.sh takes the build's
    // as its lap less this).
    // Against the floor of about 1 µs an event (metal-vmm QUEUE 224.1).
    for (std.enums.values(Sim)) |k| {
        const per = if (events.get(k) == 0) 0 else spent.get(k) / events.get(k);
        std.debug.print("time: sim {t} {d} runs, {d} events, {d:.1} s, {d} ns/event\n", .{ k, runs.get(k), events.get(k), seconds(spent.get(k)), per });
    }
    std.debug.print("time: sim run {d:.1} s\n", .{seconds(awake() - began)});

    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const failing = try at.report(&w);
    std.debug.print("\n{d} TCP seeds, each plain and rough, the first {d} crowded too, {d} FAT seeds, {d} page cache seeds and {d} pure module seeds; {d} runs failed an oracle\n{s}", .{ options.seeds, @min(options.seeds, options.crowd_seeds), options.fat_seeds, options.page_seeds, options.pure_seeds, failed_seeds, w.buffered() });

    if (options.sdk_jsonl.len > 0) {
        const io = std.testing.io;
        if (std.fs.path.dirname(options.sdk_jsonl)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = options.sdk_jsonl, .data = jsonl.items });
        std.debug.print("wrote {s}\n", .{options.sdk_jsonl});
    }

    // Only the properties that say something is wrong fail the step.
    var it = at.catalog();
    var broken: usize = 0;
    while (it.next()) |s| {
        if (s.broken()) broken += 1;
    }
    std.debug.print("{d} properties not satisfied, {d} of them broken invariants\n", .{ failing, broken });

    var under: usize = 0;
    if (options.floor.len > 0) {
        const io = std.testing.io;
        const text = try std.Io.Dir.cwd().readFileAlloc(io, options.floor, std.testing.allocator, .unlimited);
        defer std.testing.allocator.free(text);
        w = .fixed(&buf);
        under = try at.checkFloor(text, &w);
        if (options.trace_reach) printReach(text);
        std.debug.print("{s}floor {s}: {d} under it\n", .{ w.buffered(), options.floor, under });
    }
    try std.testing.expectEqual(@as(usize, 0), broken);
    try std.testing.expectEqual(@as(usize, 0), under);
}
