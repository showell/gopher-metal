//! **EVERY SEED THAT ONCE BROKE AN ORACLE, ALWAYS RUN** (metal-vmm QUEUE
//! 224.3): `coverage/seeds-that-failed.txt`, which `zig build properties`
//! reads and runs whatever its seed counts are, so a sweep cut to the seeds
//! that reach its floor still runs every seed that ever found a bug. One
//! entry a line, `<simulator> <seed>`, the simulator as properties.zig
//! names it (`fat`, `tcp_plain`, ...); `#` starts a comment.

const std = @import("std");

pub const Entry = struct { simulator: []const u8, seed: u64 };

/// The entries of `text`, a line at a time.
pub const Entries = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn init(text: []const u8) Entries {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    /// The next entry, or null at the end; a line that is not one is an
    /// error, never skipped.
    pub fn next(e: *Entries) error{NotAnEntry}!?Entry {
        while (e.lines.next()) |raw| {
            const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
            if (line.len == 0) continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const simulator = words.next() orelse return error.NotAnEntry;
            const seed = std.fmt.parseInt(u64, words.next() orelse return error.NotAnEntry, 10) catch return error.NotAnEntry;
            if (words.next() != null) return error.NotAnEntry;
            return .{ .simulator = simulator, .seed = seed };
        }
        return null;
    }
};

test "the seeds that failed: an entry a line, comments and blank lines skipped, a line that is not one refused" {
    var e = Entries.init("# a heading\n\nfat 93   # a short transfer\n  tcp_plain 23953\n");
    try std.testing.expectEqualDeep(Entry{ .simulator = "fat", .seed = 93 }, (try e.next()).?);
    try std.testing.expectEqualDeep(Entry{ .simulator = "tcp_plain", .seed = 23953 }, (try e.next()).?);
    try std.testing.expectEqual(null, try e.next());
    for ([_][]const u8{ "fat\n", "fat x\n", "fat 1 2\n", "93\n" }) |bad| {
        var b = Entries.init(bad);
        try std.testing.expectError(error.NotAnEntry, b.next());
    }
}
