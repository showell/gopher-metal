//! **THE MACHINE'S CONFIG, SPELLED** (metal-vmm QUEUE 197.3): the numbers
//! and the volume serial `gopher.conf` names, read here and nowhere else, so
//! tier 0 holds what was judged by nothing (probe/gopher.zig's readConfig
//! boots only under a judge, and no judge boots a bad config).

const std = @import("std");

/// A decimal count: digits only. std's parseInt also takes a sign and `_`
/// between digits, which no config means.
pub fn number(comptime T: type, value: []const u8) !T {
    if (value.len == 0) return error.InvalidCharacter;
    for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidCharacter;
    return std.fmt.parseInt(T, value, 10);
}

/// `92DE-8831`, as `blkid` spells a FAT serial, or null.
pub fn serial(text: []const u8) ?u32 {
    if (text.len != 9 or text[4] != '-') return null;
    // Hex digits only: std's parseInt takes a sign and `_` too.
    for (text, 0..) |c, k| if (k != 4 and !std.ascii.isHex(c)) return null;
    const high = std.fmt.parseInt(u16, text[0..4], 16) catch return null;
    const low = std.fmt.parseInt(u16, text[5..9], 16) catch return null;
    return (@as(u32, high) << 16) | low;
}

/// A serial as `blkid` spells it.
pub fn serialText(text: *[9]u8, n: u32) []const u8 {
    const digits = "0123456789ABCDEF";
    for (0..8) |k| {
        const at = if (k < 4) k else k + 1;
        text[at] = digits[@as(u4, @truncate(n >> @intCast(28 - 4 * k)))];
    }
    text[4] = '-';
    return text;
}

const testing = std.testing;

test "a config number is digits and nothing else: no sign, no underscore, not empty" {
    try testing.expectEqual(@as(u64, 120), try number(u64, "120"));
    for ([_][]const u8{ "", "+1", "-1", "1_000", " 1", "1 ", "0x10", "1e3" }) |v|
        try testing.expectError(error.InvalidCharacter, number(u64, v));
    try testing.expectError(error.Overflow, number(u8, "256"));
}

test "a volume serial is four hex digits, a dash, four more: no sign or underscore taken (metal-vmm QUEUE 197.3)" {
    try testing.expectEqual(@as(?u32, 0x92DE8831), serial("92DE-8831"));
    try testing.expectEqual(@as(?u32, 0x92DE8831), serial("92de-8831"));
    for ([_][]const u8{ "+2DE-8831", "92_E-8831", "92DE-+831", "92DE-88_1", "92DE8831", "92DE-883", "92DE-88311", "-2DE-8831", "92DE 8831", "" }) |v|
        try testing.expectEqual(@as(?u32, null), serial(v));
    var text: [9]u8 = undefined;
    try testing.expectEqualStrings("92DE-8831", serialText(&text, 0x92DE8831));
    try testing.expectEqualStrings("0000-0000", serialText(&text, 0));
    // Every serial it writes, it reads back.
    for ([_]u32{ 0, 1, 0xFFFF_FFFF, 0x0001_0000, 0x92DE8831 }) |n|
        try testing.expectEqual(@as(?u32, n), serial(serialText(&text, n)));
}
