//! **THE TCP TABLE'S TEST PROPERTIES, OVER MANY SEEDS** (src/antithesis.zig).
//!
//!   zig build properties                  seeds 1..500
//!   zig build properties -Dseeds=5000     more
//!   zig build properties -Dsdk-jsonl=out/sdk.jsonl
//!                                         also the Antithesis wire, to a file
//!
//! tcp_sim.zig runs each seed as it does under `zig build test`, but a seed
//! whose oracle fails is a broken `always` here, named with its seed, and the
//! sweep goes on. At the end the catalog is judged: every assertion in
//! tcp.zig and here, with the ones never satisfied first.
//!
//! **A FAILING `sometimes` IS NOT A TCP BUG.** It says no seed reached that
//! case: the simulator's scenarios do not cover it, and the table's code
//! there is untested by them; the report calls it a MISS. That is what this
//! report is for. The step fails only on a FAIL: an `always` seen false or
//! an `unreachable` reached.

const std = @import("std");
const at = @import("antithesis.zig");
const sim = @import("tcp_sim.zig");
const options = @import("tcp_properties_options");

var jsonl: std.ArrayList(u8) = .empty;

fn keep(line: []const u8) void {
    jsonl.appendSlice(std.testing.allocator, line) catch @panic("out of memory for the JSONL");
}

test "tcp: the table's properties over a sweep of seeds" {
    at.reset();
    defer jsonl.deinit(std.testing.allocator);
    if (options.sdk_jsonl.len > 0) at.sink = keep;
    defer at.sink = null;
    at.declare();

    var failed_seeds: usize = 0;
    for (1..options.seeds + 1) |seed| {
        const ok = if (sim.runSeed(seed)) true else |_| false;
        if (!ok) failed_seeds += 1;
        at.always(@src(), ok, "tcp_sim: every oracle holds for every seed", .{ .seed = seed });
    }

    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const failing = try at.report(&w);
    std.debug.print("\n{d} seeds, {d} failed an oracle\n{s}", .{ options.seeds, failed_seeds, w.buffered() });

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
    try std.testing.expectEqual(@as(usize, 0), broken);
}
