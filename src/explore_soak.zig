//! **THE SOAK** (`zig build soak`): the seed explorer left running on the
//! simulators, as Antithesis runs a system, with blind runs beside it as the
//! control. A tool, not a gate; it is meant to run overnight, detached.
//!
//! No round starts once `-Dsoak-hours` have passed. Each round, for each simulator in `-Dsoak-sims` (fat, store, tcp), runs
//! one exploration per column, all from the round's explorer seed and with
//! the same budget (`-Dsoak-runs`), each from a clean catalog:
//!   - **blind**: every run a fresh seed, as `properties` sweeps;
//!   - **moments**: the explorer returning to moments (`moment = 0.3`);
//!   - **bandit**: the explorer with its moves picked by Thompson sampling.
//! After each round it prints, per simulator, how many of the simulator's own
//! properties each column left unreached, the ones only some columns
//! reached, and, cumulatively, how many rounds each column reached each
//! property in. Every failure is printed with how to reproduce it: an
//! exploration repeats exactly, so the simulator, the column, the explorer
//! seed and the run's number are the whole recipe, with the commits of this
//! repo and the SDK (`tools/soak.sh` writes them at the top of its log).

const std = @import("std");
const coverage = @import("coverage");
const explore = @import("explore");
const fat_sim = @import("fat_sim.zig");
const store_sim = @import("store_sim.zig");
const tcp_sim = @import("tcp_sim.zig");
const options = @import("soak_options");

const Sim = struct {
    name: []const u8,
    run: explore.RunFn,
    /// The files whose properties are the simulator's own.
    files: []const []const u8,
};

fn runFat(tape: *explore.Tape) anyerror!void {
    _ = try fat_sim.runWith(tape);
}

fn runStore(tape: *explore.Tape) anyerror!void {
    try store_sim.runWith(tape);
}

fn runTcp(tape: *explore.Tape) anyerror!void {
    try tcp_sim.runWith(tape);
}

const all_sims = [_]Sim{
    .{ .name = "fat", .run = runFat, .files = &.{ "fat16.zig", "fat_sim.zig" } },
    .{ .name = "store", .run = runStore, .files = &.{ "store_sim.zig", "fat16.zig", "store.zig" } },
    .{ .name = "tcp", .run = runTcp, .files = &.{ "tcp.zig", "tcp_sim.zig", "tcp_check.zig" } },
};

const Column = struct { name: []const u8, options: explore.Options };
const columns = [_]Column{
    .{ .name = "blind", .options = .{ .budget = 0, .seed = 0, .blind = 1.0 } },
    .{ .name = "moments", .options = .{ .budget = 0, .seed = 0, .moment = 0.3, .warmup = 8 } },
    .{ .name = "bandit", .options = .{ .budget = 0, .seed = 0, .bandit = true, .warmup = 8 } },
};

/// A Sometimes or Reachable site in one of the simulator's own files.
fn counted(site: *const coverage.Site, sim: Sim) bool {
    const k = site.kind.basic();
    if (k != .sometimes and k != .reachable) return false;
    const file = std.fs.path.basename(std.mem.span(site.file));
    for (sim.files) |f| if (std.mem.eql(u8, file, f)) return true;
    return false;
}

/// Per simulator, per counted site (catalog order), the rounds each column
/// reached it in.
const Tally = struct {
    sites: std.ArrayList(*coverage.Site) = .empty,
    reached: std.ArrayList([columns.len]u32) = .empty,
};

test "the soak" {
    const gpa = std.heap.page_allocator;
    const io = std.testing.io;
    var tallies: [all_sims.len]Tally = @splat(.{});
    std.debug.print("\nthe soak: up to {d} rounds or {d} hours, {d} runs per column, simulators {s}\n", .{ options.rounds, options.hours, options.runs, options.sims });
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..options.rounds) |round| {
        // No round starts past the deadline: the box is wanted in the morning.
        if (start.untilNow(io, .awake).toSeconds() >= @as(i64, options.hours) * 3600) {
            std.debug.print("the soak stops: {d} hours are up\n", .{options.hours});
            break;
        }
        const seed: u64 = options.seed + round;
        for (all_sims, &tallies) |sim, *tally| {
            if (std.mem.indexOf(u8, options.sims, sim.name) == null) continue;
            if (tally.sites.items.len == 0) {
                var it = coverage.catalog();
                while (it.next()) |site| if (counted(site, sim)) {
                    try tally.sites.append(gpa, site);
                    try tally.reached.append(gpa, @splat(0));
                };
            }
            const n = tally.sites.items.len;
            // This round's reach, per column and site.
            const now = try gpa.alloc([columns.len]bool, n);
            defer gpa.free(now);
            var missed: [columns.len]u32 = @splat(0);
            var ms: [columns.len]i64 = @splat(0);
            var novel: [columns.len][4]u32 = undefined;
            for (columns, 0..) |col, c| {
                coverage.reset();
                var o = col.options;
                o.budget = options.runs;
                o.seed = seed;
                const t0 = std.Io.Timestamp.now(io, .awake);
                var report = try explore.explore(gpa, sim.run, o);
                defer report.deinit(gpa);
                ms[c] = t0.untilNow(io, .awake).toMilliseconds();
                novel[c] = report.novel_by_move;
                for (tally.sites.items, 0..) |site, i| {
                    now[i][c] = site.passes > 0;
                    if (!now[i][c]) missed[c] += 1;
                }
                if (report.drifted > 0)
                    std.debug.print("  {s} {s}: {d} runs drifted from the tape they replayed: the simulator is not a function of its tape\n", .{ sim.name, col.name, report.drifted });
                for (report.failures.items) |*f| {
                    std.debug.print("  FAILURE {s}_sim, column {s}, explorer seed {d}: a run failed its oracle (tape seed {d}, {d} fills, drifted {}, unfaithful {});", .{ sim.name, col.name, seed, f.seed, f.position(), f.drifted, f.unfaithful });
                    for (f.choices.items[0..@min(f.choices.items.len, 12)]) |ch| std.debug.print(" [{s} = {d}]", .{ ch.name, ch.chosen });
                    var again = explore.Tape.branch(gpa, f, f.position(), 12345, null);
                    defer again.deinit();
                    const replayed = if (sim.run(&again)) |_| "passes" else |_| "fails again";
                    std.debug.print("\n    replayed whole: {s}\n", .{replayed});
                }
            }
            std.debug.print("round {d}, {s}_sim, explorer seed {d}, {d} counted: unreached", .{ round, sim.name, seed, n });
            for (columns, missed, ms) |col, m, t| std.debug.print("  {s} {d} ({d} s)", .{ col.name, m, @divTrunc(t, 1000) });
            std.debug.print("\n  new-to-the-catalog finds by move (blind branch flip moment):", .{});
            for (columns, novel) |col, nv| std.debug.print("  {s} {any}", .{ col.name, nv });
            std.debug.print("\n", .{});
            for (tally.sites.items, now, tally.reached.items) |site, row, *acc| {
                for (row, acc) |hit, *a| a.* += @intFromBool(hit);
                const all = std.mem.allEqual(bool, &row, true);
                const none = std.mem.allEqual(bool, &row, false);
                if (all or none) continue;
                std.debug.print("   ", .{});
                for (row) |hit| std.debug.print(" {s}", .{if (hit) "+" else "."});
                std.debug.print("  {s}\n", .{std.mem.span(site.message)});
            }
        }
        std.debug.print("after {d} rounds, the properties some column missed in some round (rounds reached: blind, moments, bandit):\n", .{round + 1});
        for (all_sims, tallies) |sim, tally| {
            for (tally.sites.items, tally.reached.items) |site, acc| {
                if (std.mem.allEqual(u32, &acc, @intCast(round + 1))) continue;
                std.debug.print("  {s:<5} {d:>3} {d:>3} {d:>3}  {s}\n", .{ sim.name, acc[0], acc[1], acc[2], std.mem.span(site.message) });
            }
        }
    }
}
