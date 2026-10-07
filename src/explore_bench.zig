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
const options = @import("explore_options");

/// The properties blind seeds reach only at `long.sh`'s 300 FAT seeds.
const targets = [_][]const u8{
    "fat: a FAT32 entry's first cluster is past 65535",
    "fat: a run of sectors fails to read",
};

fn runFat(tape: *explore.Tape) anyerror!void {
    _ = try fat_sim.runWith(tape);
}

/// The FAT's properties: what this simulator is for.
fn ours(site: *const coverage.Site) bool {
    const file = std.mem.span(site.file);
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

fn runOnce(gpa: std.mem.Allocator, budget: u32, seed: u64, blind: f32) !Tally {
    coverage.reset();
    const report = try explore.explore(gpa, runFat, .{ .budget = budget, .seed = seed, .blind = blind, .flip = options.flip });
    for (report.failures.items) |f| {
        std.debug.print("  a run failed its oracle: tape seed {d}, {d} fills, replayed {d} (drifted {}):", .{ f.seed, f.position(), f.replay_upto, f.drifted });
        for (f.choices.items) |c| std.debug.print(" [{s} = {d}]", .{ c.name, c.chosen });
        std.debug.print("\n", .{});
        var again = explore.Tape.branch(gpa, &f, f.position(), 12345, null);
        defer again.deinit();
        const replayed = if (fat_sim.runWith(&again)) |_| "passes" else |_| "fails again";
        std.debug.print("    replayed whole: {s}\n", .{replayed});
    }
    return Tally.take(gpa, report);
}

test "the explorer against blind seeds" {
    const gpa = std.testing.allocator;
    var budgets = std.mem.tokenizeScalar(u8, options.budgets, ',');
    std.debug.print("\nfat_sim: blind runs against the explorer (seed {d}, blind share {d:.2}, flip share {d:.2})\n", .{ options.seed, options.blind, options.flip });
    while (budgets.next()) |text| {
        const budget = try std.fmt.parseInt(u32, text, 10);
        var blind = try runOnce(gpa, budget, options.seed, 1.0);
        defer blind.deinit(gpa);
        var steered = try runOnce(gpa, budget, options.seed, options.blind);
        defer steered.deinit(gpa);

        std.debug.print("\nbudget {d}: blind leaves {d} of {d} unreached, the explorer {d}; failures {d} and {d}\n", .{ budget, blind.missed, blind.total, steered.missed, blind.failures, steered.failures });
        std.debug.print("  explorer runs by move: blind {d}, branch {d}, flip {d}; new by move: {d}, {d}, {d}; corpus {d}\n", .{
            steered.report.by_move[0],     steered.report.by_move[1],     steered.report.by_move[2],
            steered.report.new_by_move[0], steered.report.new_by_move[1], steered.report.new_by_move[2],
            steered.report.corpus,
        });
        for (targets) |t| {
            std.debug.print("  target \"{s}\": blind {s}, explorer {s}\n", .{ t, if (blind.reached.contains(t)) "reached" else "missed", if (steered.reached.contains(t)) "reached" else "missed" });
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
