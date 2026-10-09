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
const durable_sim = @import("durable_sim.zig");
const floor_sim = @import("floor_sim.zig");
const store_sim = @import("store_sim.zig");
const options = @import("tcp_properties_options");

var jsonl: std.ArrayList(u8) = .empty;

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

    var failed_seeds: usize = 0;
    for (1..options.seeds + 1) |seed| {
        const ok = if (sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "tcp_sim: every oracle holds for every seed", .{ .seed = seed });
        const rough_ok = if (sim.runRoughSeed(seed)) true else |_| false;
        if (!rough_ok) failed_seeds += 1;
        at.always(@src(), rough_ok, "tcp_sim: every oracle holds for every rough seed", .{ .seed = seed });
        if (seed > options.crowd_seeds) continue;
        const crowd_ok = if (sim.runCrowdSeed(seed)) true else |_| false;
        if (!crowd_ok) failed_seeds += 1;
        at.always(@src(), crowd_ok, "tcp_sim: every oracle holds for every crowd seed", .{ .seed = seed });
    }
    for (1..options.fat_seeds + 1) |seed| {
        const ok = if (fat_sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "fat_sim: every oracle holds for every seed, both FAT paths", .{ .seed = seed });
        const probed = if (fat_sim.runProbeSeed(seed)) true else |_| false;
        if (!probed) failed_seeds += 1;
        at.always(@src(), probed, "fat_sim: every oracle holds for every seed with probes", .{ .seed = seed });
    }
    for (1..options.page_seeds + 1) |seed| {
        const ok = if (page_sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "page_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.pure_seeds + 1) |seed| {
        const ok = if (pure_sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "pure_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.ready_seeds + 1) |seed| {
        const ok = if (ready_sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "ready_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.full_seeds + 1) |seed| {
        const ok = if (sim.runFullSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "tcp_sim: every oracle holds for a crowd the size of the kernel's table", .{ .seed = seed });
    }
    for (1..options.store_seeds + 1) |seed| {
        const ok = if (store_sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "store_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.floor_seeds + 1) |seed| {
        const ok = if (floor_sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "floor_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    for (1..options.durable_seeds + 1) |seed| {
        const ok = if (durable_sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "durable_sim: every oracle holds for every seed", .{ .seed = seed });
    }
    // A FAT run under a tape replays exactly, every seed to 40 at least (the
    // 40 `zig build test` ran before metal-vmm QUEUE 136 kept four there).
    for (1..@max(options.fat_seeds, 40) + 1) |seed| {
        const ok = if (fat_sim.replaysExactly(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "fat_sim: a run under a tape replays exactly", .{ .seed = seed });
    }
    // And a store run, the 20 seeds `zig build test` ran (QUEUE 136).
    for (1..21) |seed| {
        const ok = if (store_sim.replaysExactly(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "store_sim: a run under a tape replays exactly", .{ .seed = seed });
    }
    // Every sweep, whatever its size: they are the regression tests.
    for (fat_sim.regressions) |seed| {
        const ok = if (fat_sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "fat_sim: every regression seed holds", .{ .seed = seed });
    }

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
        std.debug.print("{s}floor {s}: {d} under it\n", .{ w.buffered(), options.floor, under });
    }
    try std.testing.expectEqual(@as(usize, 0), broken);
    try std.testing.expectEqual(@as(usize, 0), under);
}
