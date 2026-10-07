//! **THE SEED EXPLORER ON A SIMULATOR, AGAINST BLIND SEEDS** (zig-coverage-sdk's
//! explore.zig; essays notes/the-seed-explorer.md, notes/steering-by-design.md).
//!
//!   zig build explore                          fat_sim, budgets 20 and 100
//!   zig build explore -Dexplore-budgets=20,100,300 -Dexplore-seed=2
//!
//! For each budget it runs the simulator that many times blind (each run a
//! fresh tape, as `properties` runs seeds) and that many times under the
//! explorer, from a clean catalog each time, and prints, for the simulator's
//! own properties: how many each left unreached, the named targets, and
//! which properties only one of the two reached, and any run whose oracle
//! failed.

const std = @import("std");
const coverage = @import("coverage");
const explore = @import("explore");
const fat_sim = @import("fat_sim.zig");
const store_sim = @import("store_sim.zig");
const options = @import("explore_options");

/// The properties blind seeds reach only at `long.sh`'s 300 FAT seeds.
const targets = [_][]const u8{
    "fat: a FAT32 entry's first cluster is past 65535",
    "fat: a run of sectors fails to read",
};

fn runFat(tape: *explore.Tape) anyerror!void {
    _ = try fat_sim.runWith(tape);
}

fn runStore(tape: *explore.Tape) anyerror!void {
    try store_sim.runWith(tape);
}

const sim_is_store = std.mem.eql(u8, options.sim, "store");
const runSim: explore.RunFn = if (sim_is_store) runStore else runFat;

/// The properties the simulator is for: FAT's, or the Store's and the FAT
/// under it.
fn ours(site: *const coverage.Site) bool {
    const file = std.mem.span(site.file);
    if (sim_is_store) return std.mem.endsWith(u8, file, "store_sim.zig") or std.mem.endsWith(u8, file, "fat16.zig");
    return std.mem.endsWith(u8, file, "fat16.zig") or std.mem.endsWith(u8, file, "fat_sim.zig");
}

const Tally = struct {
    reached: std.StringHashMap(void),
    missed: u32 = 0,
    total: u32 = 0,
    failures: u32 = 0,
    report: explore.Report,

    fn take(gpa: std.mem.Allocator, report: explore.Report) !Tally {
        var t: Tally = .{ .reached = .init(gpa), .report = report };
        var it = coverage.catalog();
        while (it.next()) |site| {
            if (!ours(site)) continue;
            if (site.kind.basic() != .sometimes and site.kind.basic() != .reachable) continue;
            t.total += 1;
            if (site.passes > 0) try t.reached.put(std.mem.span(site.message), {}) else t.missed += 1;
        }
        t.failures = @intCast(report.failures.items.len);
        return t;
    }

    fn deinit(t: *Tally, gpa: std.mem.Allocator) void {
        t.reached.deinit();
        t.report.deinit(gpa);
    }
};

fn runOnce(gpa: std.mem.Allocator, budget: u32, seed: u64, blind: f32, aim: bool) !Tally {
    coverage.reset();
    var report = try explore.explore(gpa, runSim, .{ .budget = budget, .seed = seed, .blind = blind, .flip = options.flip, .aim = aim });
    // **A RUN THAT DRIFTED IS NOT A STEERED RUN** (CC's review, metal-vmm
    // QUEUE 94): a simulator whose draws are not its tape's makes a
    // benchmark of luck, so none is reported.
    if (report.drifted > 0) {
        std.debug.print("  {d} runs drifted from the tape they replayed: the simulator is not a function of its tape\n", .{report.drifted});
        report.deinit(gpa);
        return error.Drifted;
    }
    for (report.failures.items) |f| {
        std.debug.print("  a run failed its oracle: tape seed {d}, {d} fills, replayed {d} (drifted {}):", .{ f.seed, f.position(), f.replay_upto, f.drifted });
        for (f.choices.items) |c| std.debug.print(" [{s} = {d}]", .{ c.name, c.chosen });
        std.debug.print("\n", .{});
        var again = explore.Tape.branch(gpa, &f, f.position(), 12345, null);
        defer again.deinit();
        const replayed = if (runSim(&again)) |_| "passes" else |_| "fails again";
        std.debug.print("    replayed whole: {s}\n", .{replayed});
    }
    return Tally.take(gpa, report);
}

test "the explorer against blind seeds" {
    const gpa = std.testing.allocator;
    var budgets = std.mem.tokenizeScalar(u8, options.budgets, ',');
    std.debug.print("\n{s}_sim: blind runs against the explorer (seed {d}, blind share {d:.2}, flip share {d:.2})\n", .{ options.sim, options.seed, options.blind, options.flip });
    while (budgets.next()) |text| {
        const budget = try std.fmt.parseInt(u32, text, 10);
        var blind = try runOnce(gpa, budget, options.seed, 1.0, false);
        defer blind.deinit(gpa);
        var random_flips = try runOnce(gpa, budget, options.seed, options.blind, false);
        defer random_flips.deinit(gpa);
        var steered = try runOnce(gpa, budget, options.seed, options.blind, true);
        defer steered.deinit(gpa);

        std.debug.print("\nbudget {d}: unreached of {d}: blind {d}, the explorer with random flips {d}, with aimed flips {d}; failures {d}, {d}, {d}; decisions taken first by the aimed explorer {d}\n", .{
            budget,         blind.total,           blind.missed,     random_flips.missed,      steered.missed,
            blind.failures, random_flips.failures, steered.failures, steered.report.decisions,
        });
        std.debug.print("  explorer runs by move: blind {d}, branch {d}, flip {d}; new by move: {d}, {d}, {d}; corpus {d}\n", .{
            steered.report.by_move[0],     steered.report.by_move[1],     steered.report.by_move[2],
            steered.report.new_by_move[0], steered.report.new_by_move[1], steered.report.new_by_move[2],
            steered.report.corpus,
        });
        if (!sim_is_store) {
            for (targets) |t| {
                std.debug.print("  target \"{s}\": blind {s}, explorer {s}\n", .{ t, if (blind.reached.contains(t)) "reached" else "missed", if (steered.reached.contains(t)) "reached" else "missed" });
            }
        }
        var it = steered.reached.keyIterator();
        while (it.next()) |k| if (!blind.reached.contains(k.*)) std.debug.print("  only the explorer: {s}\n", .{k.*});
        var bt = blind.reached.keyIterator();
        while (bt.next()) |k| if (!steered.reached.contains(k.*)) std.debug.print("  only blind: {s}\n", .{k.*});
        if (options.list_missed) {
            var cat = coverage.catalog();
            while (cat.next()) |site| {
                if (!ours(site) or (site.kind.basic() != .sometimes and site.kind.basic() != .reachable)) continue;
                const m = std.mem.span(site.message);
                if (!blind.reached.contains(m) and !steered.reached.contains(m))
                    std.debug.print("  missed by both: {s}  ({s}:{d})\n", .{ m, std.fs.path.basename(std.mem.span(site.file)), site.line });
            }
        }
    }
}
