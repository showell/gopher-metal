//! **THE TCP TABLE'S GOLDEN TRACES** (metal-vmm QUEUE 225, chunk 1;
//! docs/TWO-KERNELS.md in metal-vmm): the hash of every frame tcp_sim's
//! network carried (`traceOf`), pinned for seeds 1-200 of each peer (plain,
//! rough, a crowd, a crowd the size of the kernel's table) and for the
//! regression seeds, in `coverage/tcp-traces.txt`. The tcp.zig reshaping
//! that follows (chunks 2-4) must leave every one of them as it is, and a
//! chunk that changes what goes on the wire names the change in its commit
//! and rewrites the file.
//!
//!   zig build tcp-traces                       every pinned trace, checked
//!   zig build tcp-traces -Dtcp-traces-write    the file written again
//!
//! ReleaseSafe and a binary of its own: 803 worlds are about 5 s so, and
//! far too long for tier 0's Debug.

const std = @import("std");
const sim = @import("tcp_sim.zig");
const options = @import("tcp_traces_options");

const path = "coverage/tcp-traces.txt";
const seeds_each = 200;
/// The regression seeds `zig build test` runs plainly (tcp_sim.zig's
/// `regressions`).
const regressions = [_]u64{ 125, 1332, 23953 };

const Entry = struct { mode: sim.Mode, seed: u64 };

fn entries(buf: []Entry) []Entry {
    var n: usize = 0;
    for ([_]sim.Mode{ .plain, .rough, .crowd, .full }) |mode| {
        for (1..seeds_each + 1) |seed| {
            buf[n] = .{ .mode = mode, .seed = seed };
            n += 1;
        }
    }
    for (regressions) |seed| {
        buf[n] = .{ .mode = .plain, .seed = seed };
        n += 1;
    }
    return buf[0..n];
}

/// One entry's line: `<mode> <seed> <trace, 16 hex digits> <ok|FAILED>`.
fn line(w: *std.Io.Writer, e: Entry) !void {
    const t = try sim.traceOf(e.seed, e.mode, null);
    try w.print("{t} {d} {x:0>16} {s}\n", .{ e.mode, e.seed, t.trace, if (t.ok) "ok" else "FAILED" });
}

test "the golden traces: every pinned world sends the same frames" {
    var buf: [4 * seeds_each + regressions.len]Entry = undefined;
    const all = entries(&buf);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll(
        \\# **THE TCP TABLE'S GOLDEN TRACES** (src/tcp_traces.zig; metal-vmm
        \\# QUEUE 225, chunk 1): `<peer> <seed> <trace> <verdict>`, the hash of
        \\# every frame tcp_sim's network carried. Written by
        \\# `zig build tcp-traces -Dtcp-traces-write`; a commit that changes a
        \\# line says why.
        \\
    );
    for (all) |e| try line(&out.writer, e);
    const io = std.testing.io;
    if (options.write) {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
        std.debug.print("wrote {s}: {d} traces\n", .{ path, all.len });
        return;
    }
    const pinned = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(pinned);
    var want = std.mem.splitScalar(u8, pinned, '\n');
    var got = std.mem.splitScalar(u8, out.written(), '\n');
    var differ: usize = 0;
    while (true) {
        const a = want.next();
        const b = got.next();
        if (a == null and b == null) break;
        const wa = a orelse "(none)";
        const gb = b orelse "(none)";
        if (!std.mem.eql(u8, wa, gb)) {
            differ += 1;
            if (differ <= 10) std.debug.print("trace changed:\n  pinned {s}\n  now    {s}\n", .{ wa, gb });
        }
    }
    if (differ > 0) {
        std.debug.print("{d} lines of {s} differ: a change on the wire, or `-Dtcp-traces-write` and say why\n", .{ differ, path });
        return error.TestUnexpectedResult;
    }
}
