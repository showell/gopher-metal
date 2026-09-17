//! The calendar, and nothing else: no ports, no disk, no clock of its own.
//!
//! Two things on this machine have dates that must be the same dates. The CMOS
//! chip reports one (rtc.zig), and every FAT16 directory entry carries one
//! (fat16.zig) — and the second is what makes chat's "recent activity" a real
//! answer here, because its whole model is file modification time. Both need
//! civil dates and Unix seconds to be the same instants, in both directions.
//!
//! Howard Hinnant's days_from_civil and civil_from_days, which are exact for
//! every date in range and are what angry-gopher's own timefmt.zig inverts.
//! **UTC throughout.** There is no local time on this machine: the application
//! renders Eastern from a Unix time, and never asks the filesystem or the chip
//! what time zone they think they are in.

const std = @import("std");

pub const Civil = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn isLeap(y: i32) bool {
    return (@rem(y, 4) == 0 and @rem(y, 100) != 0) or @rem(y, 400) == 0;
}

pub fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) 29 else 28,
        else => 0,
    };
}

/// Days from 1970-01-01 to the given date.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const m: i64 = month;
    const mp: i64 = if (m > 2) m - 3 else m + 9; // March = 0
    const doy: i64 = @divFloor(153 * mp + 2, 5) + @as(i64, day) - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// The inverse: the date that many days after 1970-01-01. `@divFloor`
/// throughout, so a date before the epoch is the same arithmetic rather than a
/// special case.
pub fn civilFromDays(days: i64) struct { year: i32, month: u8, day: u8 } {
    const z = days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp: i64 = @divFloor(5 * doy + 2, 153); // [0, 11], March = 0
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = @intCast(y + @as(i64, if (m <= 2) 1 else 0)),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

pub fn toUnix(c: Civil) i64 {
    return daysFromCivil(c.year, c.month, c.day) * 86400 +
        @as(i64, c.hour) * 3600 + @as(i64, c.minute) * 60 + c.second;
}

pub fn fromUnix(secs: i64) Civil {
    const days = @divFloor(secs, 86400);
    const rem = secs - days * 86400; // [0, 86399], because divFloor rounds down
    const d = civilFromDays(days);
    return .{
        .year = d.year,
        .month = d.month,
        .day = d.day,
        .hour = @intCast(@divTrunc(rem, 3600)),
        .minute = @intCast(@divTrunc(@rem(rem, 3600), 60)),
        .second = @intCast(@rem(rem, 60)),
    };
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// The expected Unix times were computed independently (Python's
// calendar.timegm), not by this code.

const testing = std.testing;

test "the epoch, both ways" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 0), toUnix(.{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }));
    const c = fromUnix(0);
    try testing.expectEqual(@as(i32, 1970), c.year);
    try testing.expectEqual(@as(u8, 1), c.month);
    try testing.expectEqual(@as(u8, 1), c.day);
    try testing.expectEqual(@as(u8, 0), c.hour);
}

test "dates that have to be right" {
    const cases = [_]struct { unix: i64, y: i32, mo: u8, d: u8, h: u8, mi: u8, s: u8 }{
        .{ .unix = 1789600050, .y = 2026, .mo = 9, .d = 16, .h = 23, .mi = 7, .s = 30 },
        .{ .unix = 1583020801, .y = 2020, .mo = 3, .d = 1, .h = 0, .mi = 0, .s = 1 }, // the day after a leap day
        .{ .unix = 1582934400, .y = 2020, .mo = 2, .d = 29, .h = 0, .mi = 0, .s = 0 }, // the leap day itself
        .{ .unix = 951782400, .y = 2000, .mo = 2, .d = 29, .h = 0, .mi = 0, .s = 0 }, // 2000 IS a leap year
        .{ .unix = 4107456000, .y = 2100, .mo = 2, .d = 28, .h = 0, .mi = 0, .s = 0 }, // 2100 is NOT
        .{ .unix = 315532800, .y = 1980, .mo = 1, .d = 1, .h = 0, .mi = 0, .s = 0 }, // the FAT epoch
        .{ .unix = 4354819199, .y = 2107, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59 }, // the last FAT date
        .{ .unix = -1, .y = 1969, .mo = 12, .d = 31, .h = 23, .mi = 59, .s = 59 }, // before the epoch
        .{ .unix = -86400, .y = 1969, .mo = 12, .d = 31, .h = 0, .mi = 0, .s = 0 },
    };
    for (cases) |c| {
        const got = fromUnix(c.unix);
        try testing.expectEqual(c.y, got.year);
        try testing.expectEqual(c.mo, got.month);
        try testing.expectEqual(c.d, got.day);
        try testing.expectEqual(c.h, got.hour);
        try testing.expectEqual(c.mi, got.minute);
        try testing.expectEqual(c.s, got.second);
        try testing.expectEqual(c.unix, toUnix(.{
            .year = c.y, .month = c.mo, .day = c.d, .hour = c.h, .minute = c.mi, .second = c.s,
        }));
    }
}

test "every day from 1980 to 2110 round-trips, and the days run consecutively" {
    var prev: ?i64 = null;
    var y: i32 = 1980;
    while (y <= 2110) : (y += 1) {
        var m: u8 = 1;
        while (m <= 12) : (m += 1) {
            var d: u8 = 1;
            while (d <= daysInMonth(y, m)) : (d += 1) {
                const days = daysFromCivil(y, m, d);
                if (prev) |p| try testing.expectEqual(p + 1, days);
                prev = days;
                const back = civilFromDays(days);
                try testing.expectEqual(y, back.year);
                try testing.expectEqual(m, back.month);
                try testing.expectEqual(d, back.day);
            }
        }
    }
}

test "every second of a day round-trips through fromUnix" {
    const midnight = daysFromCivil(2026, 9, 17) * 86400;
    var s: i64 = 0;
    while (s < 86400) : (s += 997) { // a prime stride: hits every hour and minute
        const c = fromUnix(midnight + s);
        try testing.expectEqual(midnight + s, toUnix(c));
    }
}

test "leap years by the full rule, not the every-four shortcut" {
    try testing.expect(isLeap(2024));
    try testing.expect(!isLeap(2023));
    try testing.expect(!isLeap(1900));
    try testing.expect(isLeap(2000));
    try testing.expect(!isLeap(2100));
    try testing.expectEqual(@as(u8, 29), daysInMonth(2000, 2));
    try testing.expectEqual(@as(u8, 28), daysInMonth(2100, 2));
}
