//! The CMOS real-time clock — the MC146818 every PC has had since the AT, and
//! the only thing on this machine that knows what time it is.
//!
//! **WHY IT IS HERE.** angry-gopher asks for `Clock.now(.real, io)` in nine
//! places, and one of them is session expiry: `now - issued > max_age`. Until
//! this machine can answer that honestly it refuses to answer at all (io.zig).
//! This is where the honest answer comes from.
//!
//! Two halves, kept apart on purpose:
//!
//!   - the DEVICE half reads registers through ports 0x70/0x71, and has to
//!     dodge the chip's once-a-second update;
//!   - the PURE half turns what it read into Unix seconds — BCD or binary,
//!     12-hour or 24, the century register or not — and is tested on the host,
//!     because every one of those modes is a way to be silently an hour or a
//!     century wrong.
//!
//! **ITS RESOLUTION IS ONE SECOND.** A reading taken at an arbitrary moment is
//! up to a second behind. `readAtEdge` waits for the seconds register to change
//! and reads just after it does, which is how a host anchors the wall clock to
//! within the polling delay rather than within a second.

const port = @import("port.zig");
const tsc = @import("tsc.zig");
const calendar = @import("civil.zig");

const index_port: u16 = 0x70;
const data_port: u16 = 0x71;

/// Setting bit 7 of the index disables NMIs while a register is selected. The
/// convention every driver follows; the chip itself shares that bit.
const nmi_disable: u8 = 0x80;

const reg_seconds: u8 = 0x00;
const reg_minutes: u8 = 0x02;
const reg_hours: u8 = 0x04;
const reg_day: u8 = 0x07;
const reg_month: u8 = 0x08;
const reg_year: u8 = 0x09;
const reg_status_a: u8 = 0x0A;
const reg_status_b: u8 = 0x0B;
/// Where QEMU, and the ACPI default, keep the century. Not every chip has one,
/// which decode() allows for.
const reg_century: u8 = 0x32;

/// Status A, bit 7: an update is in progress, and the time registers are not
/// to be trusted until it clears.
const update_in_progress: u8 = 0x80;
/// Status B, bit 2: the registers are binary rather than BCD.
const binary_mode: u8 = 0x04;
/// Status B, bit 1: 24-hour rather than 12-hour.
const hour24_mode: u8 = 0x02;
/// In 12-hour mode, the high bit of the hours register means PM.
const pm_bit: u8 = 0x80;

/// The registers as read, before any interpretation.
pub const Raw = struct {
    seconds: u8,
    minutes: u8,
    hours: u8,
    day: u8,
    month: u8,
    year: u8,
    century: u8,
    status_b: u8,

    fn eql(a: Raw, b: Raw) bool {
        return a.seconds == b.seconds and a.minutes == b.minutes and a.hours == b.hours and
            a.day == b.day and a.month == b.month and a.year == b.year and
            a.century == b.century and a.status_b == b.status_b;
    }
};

// ── the device ───────────────────────────────────────────────────────────────

fn readReg(reg: u8) u8 {
    port.outb(index_port, nmi_disable | reg);
    return port.inb(data_port);
}

fn updating() bool {
    return readReg(reg_status_a) & update_in_progress != 0;
}

fn snapshot() Raw {
    return .{
        .seconds = readReg(reg_seconds),
        .minutes = readReg(reg_minutes),
        .hours = readReg(reg_hours),
        .day = readReg(reg_day),
        .month = readReg(reg_month),
        .year = readReg(reg_year),
        .century = readReg(reg_century),
        .status_b = readReg(reg_status_b),
    };
}

pub const DeviceError = error{ NoChip, NeverSettled, NoEdge, Stuck };

/// **A PORT WITH NOTHING BEHIND IT READS 0xFF**, and 0xFF in register A has
/// the update-in-progress bit set — so a missing chip used to look exactly like
/// one forever mid-update. No real register A holds it (its divider field would
/// be the invalid 111), so it is named for what it is.
fn present() bool {
    return readReg(reg_status_a) != 0xFF;
}

/// **EVERY WAIT ON THE CHIP IS A MEASURED DURATION.** These were spin counts —
/// "two billion spins, just over a second, generously counted" — which is true
/// only where a spin is cheap. Under KVM every register read is two port
/// writes that exit to the emulator, a spin costs thousands of times more, and
/// "a second" became hours: the machine hung at boot. The rate is known by the
/// time anything here is called (the PIT measured it), so the bounds are in
/// seconds of timestamp counter, and a host that has not said the rate panics.
var ticks_per_second: u64 = 0;

pub fn useClock(tsc_hz: u64) void {
    ticks_per_second = tsc_hz;
}

fn deadline(ms: u64) u64 {
    if (ticks_per_second == 0)
        @panic("an RTC wait before rtc.useClock: a wait this machine cannot measure is a wait it cannot bound");
    return tsc.read() +% ticks_per_second * ms / 1000;
}

fn past(when: u64) bool {
    return tsc.read() > when;
}

/// **BETWEEN POLLS, TOUCH NOTHING.** A `pause` spin never leaves the guest; a
/// port read always does. Under KVM, QEMU emulates this chip holding its one
/// big lock, and it clears the update-in-progress bit from a timer that needs
/// that same lock — so a guest polling the port flat out kept the bit set
/// forever, and the machine hung at boot. Polling every quarter of a
/// millisecond leaves the emulator room to run, and is also how a real chip
/// wants to be treated. It costs the edge's anchor that much precision.
const poll_us: u64 = 250;

fn nap(us: u64) void {
    const until = tsc.read() +% ticks_per_second * us / 1_000_000;
    while (tsc.read() < until) asm volatile ("pause");
}

/// **WHAT A MISSED EDGE SAW**, for a host to print: a hang says nothing, and
/// this says whether the seconds never moved, the chip never finished an
/// update, or the polling was simply too slow to look.
pub const Miss = struct {
    polls: u64 = 0,
    updating: u64 = 0,
    first_seconds: u8 = 0,
    last_seconds: u8 = 0,
};
pub var last_miss: Miss = .{};

/// A consistent reading: wait out any update, then read until two consecutive
/// readings agree. An update can begin between the check and the reads, and
/// the only defence the chip offers is to read again.
pub fn read() DeviceError!Raw {
    if (!present()) return error.NoChip;
    const until = deadline(1000);
    while (!past(until)) {
        try waitNotUpdating();
        const a = snapshot();
        try waitNotUpdating();
        const b = snapshot();
        if (a.eql(b)) return a;
    }
    return error.NeverSettled;
}

/// An update takes about two milliseconds. Half a second of it is a chip that
/// is not updating but broken, and that is an answer rather than a hang.
fn waitNotUpdating() DeviceError!void {
    const until = deadline(500);
    while (updating()) {
        if (past(until)) return error.Stuck;
        nap(poll_us);
    }
}

/// A reading taken just after the seconds register changed — the moment the
/// time it reports became true. `onEdge` is called at that moment, before the
/// rest of the registers are read, so a host can capture the timestamp
/// counter as close to the edge as the polling allows.
pub fn readAtEdge(context: anytype, comptime onEdge: fn (@TypeOf(context)) void) DeviceError!Raw {
    const start = (try read()).seconds;
    // A second is the longest an edge can take; two and a half allows for
    // arriving just after one.
    const until = deadline(2500);
    var miss = Miss{ .first_seconds = start, .last_seconds = start };
    while (!past(until)) {
        miss.polls += 1;
        if (updating()) {
            miss.updating += 1;
        } else {
            const now = readReg(reg_seconds);
            miss.last_seconds = now;
            if (now != start) {
                onEdge(context);
                return read();
            }
        }
        nap(poll_us);
    }
    last_miss = miss;
    return error.NoEdge;
}

/// The two format choices status B holds. The chip renders every time
/// register in whatever format B currently says, so changing it changes what
/// the next read returns — which is how the clock probe exercises decode()'s
/// four modes against the device rather than only on the host.
pub const Format = struct { binary: bool, hour24: bool };

pub fn format() Format {
    const b = readReg(reg_status_b);
    return .{ .binary = b & binary_mode != 0, .hour24 = b & hour24_mode != 0 };
}

pub fn setFormat(f: Format) void {
    var b = readReg(reg_status_b);
    b = if (f.binary) b | binary_mode else b & ~binary_mode;
    b = if (f.hour24) b | hour24_mode else b & ~hour24_mode;
    port.outb(index_port, nmi_disable | reg_status_b);
    port.outb(data_port, b);
}

// ── the pure half ────────────────────────────────────────────────────────────

/// The calendar is civil.zig's, because the FAT16 directory entries this
/// machine writes carry the same dates and must agree with this chip.
pub const Civil = calendar.Civil;
pub const daysFromCivil = calendar.daysFromCivil;
pub const toUnix = calendar.toUnix;
const isLeap = calendar.isLeap;
const daysInMonth = calendar.daysInMonth;

pub const DecodeError = error{ BadBcd, OutOfRange };

fn fromBcd(v: u8) DecodeError!u8 {
    const hi = v >> 4;
    const lo = v & 0x0F;
    if (hi > 9 or lo > 9) return error.BadBcd;
    return hi * 10 + lo;
}

/// What the registers mean, in the modes status B says they are in. Every
/// field is range-checked: a chip with a flat battery reads as garbage, and
/// garbage must not become a plausible date.
pub fn decode(raw: Raw) DecodeError!Civil {
    const binary = raw.status_b & binary_mode != 0;
    const hour24 = raw.status_b & hour24_mode != 0;
    const conv = struct {
        fn f(is_binary: bool, v: u8) DecodeError!u8 {
            return if (is_binary) v else fromBcd(v);
        }
    }.f;

    const pm = !hour24 and (raw.hours & pm_bit != 0);
    var hour = try conv(binary, if (hour24) raw.hours else raw.hours & ~pm_bit);
    if (!hour24) {
        // 12-hour clocks count 12, 1, 2 … 11; midnight is 12 AM and noon 12 PM.
        if (hour < 1 or hour > 12) return error.OutOfRange;
        if (pm and hour != 12) hour += 12;
        if (!pm and hour == 12) hour = 0;
    }

    const yy = try conv(binary, raw.year);
    // A century register that decodes to 19..21 is believed. Anything else —
    // no register at all, or a chip that leaves it zero — means the 2000s,
    // which is the only century this code will run in.
    const century: i32 = blk: {
        const c = conv(binary, raw.century) catch break :blk 20;
        break :blk if (c >= 19 and c <= 21) c else 20;
    };

    const civil = Civil{
        .year = century * 100 + yy,
        .month = try conv(binary, raw.month),
        .day = try conv(binary, raw.day),
        .hour = hour,
        .minute = try conv(binary, raw.minutes),
        .second = try conv(binary, raw.seconds),
    };
    if (yy > 99) return error.OutOfRange;
    if (civil.month < 1 or civil.month > 12) return error.OutOfRange;
    if (civil.day < 1 or civil.day > daysInMonth(civil.year, civil.month)) return error.OutOfRange;
    if (civil.hour > 23 or civil.minute > 59 or civil.second > 59) return error.OutOfRange;
    return civil;
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// The pure half only; `zig build test` runs these on the host. The expected
// Unix times were computed independently (Python's calendar.timegm), not by
// this code.

const std = @import("std");
const testing = std.testing;

/// A raw reading in BCD, 24-hour — what QEMU's chip reports by default.
fn bcd24(century: u8, year: u8, month: u8, day: u8, hour: u8, minute: u8, second: u8) Raw {
    const b = struct {
        fn f(v: u8) u8 {
            return (v / 10) << 4 | (v % 10);
        }
    }.f;
    return .{
        .century = b(century), .year = b(year), .month = b(month), .day = b(day),
        .hours = b(hour), .minutes = b(minute), .seconds = b(second),
        .status_b = hour24_mode,
    };
}

test "the epoch, and dates whose Unix times are known" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const cases = [_]struct { c: Civil, unix: i64 }{
        .{ .c = .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }, .unix = 0 },
        .{ .c = .{ .year = 2000, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }, .unix = 946684800 },
        .{ .c = .{ .year = 2000, .month = 2, .day = 29, .hour = 12, .minute = 0, .second = 0 }, .unix = 951825600 },
        .{ .c = .{ .year = 2000, .month = 3, .day = 1, .hour = 0, .minute = 0, .second = 0 }, .unix = 951868800 },
        .{ .c = .{ .year = 2020, .month = 2, .day = 29, .hour = 23, .minute = 59, .second = 58 }, .unix = 1583020798 },
        .{ .c = .{ .year = 2024, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 }, .unix = 1735689599 },
        .{ .c = .{ .year = 2026, .month = 9, .day = 17, .hour = 0, .minute = 0, .second = 0 }, .unix = 1789603200 },
        .{ .c = .{ .year = 2038, .month = 1, .day = 19, .hour = 3, .minute = 14, .second = 8 }, .unix = 2147483648 },
        .{ .c = .{ .year = 2100, .month = 3, .day = 1, .hour = 0, .minute = 0, .second = 0 }, .unix = 4107542400 },
    };
    for (cases) |k| try testing.expectEqual(k.unix, toUnix(k.c));
}

test "consecutive days are 86400 seconds apart across month, leap-day and year edges" {
    var y: i32 = 1999;
    while (y <= 2101) : (y += 1) {
        var m: u8 = 1;
        var prev: ?i64 = null;
        while (m <= 12) : (m += 1) {
            var d: u8 = 1;
            while (d <= daysInMonth(y, m)) : (d += 1) {
                const t = daysFromCivil(y, m, d);
                if (prev) |p| try testing.expectEqual(p + 1, t);
                prev = t;
            }
        }
        // ...and into the next year.
        try testing.expectEqual(prev.? + 1, daysFromCivil(y + 1, 1, 1));
    }
}

test "leap years: 2000 and 2024 are, 1900 and 2100 are not" {
    try testing.expect(isLeap(2000));
    try testing.expect(isLeap(2024));
    try testing.expect(!isLeap(1900));
    try testing.expect(!isLeap(2100));
    try testing.expect(!isLeap(2026));
}

test "decode: BCD, 24-hour, with a century register" {
    const c = try decode(bcd24(20, 26, 9, 17, 14, 5, 9));
    try testing.expectEqual(Civil{ .year = 2026, .month = 9, .day = 17, .hour = 14, .minute = 5, .second = 9 }, c);
    try testing.expectEqual(@as(i64, 1789603200 + 14 * 3600 + 5 * 60 + 9), toUnix(c));
}

test "decode: binary mode reads the registers as plain numbers" {
    var r = Raw{ .century = 20, .year = 26, .month = 9, .day = 17, .hours = 14, .minutes = 5, .seconds = 9, .status_b = binary_mode | hour24_mode };
    try testing.expectEqual(@as(u8, 14), (try decode(r)).hour);
    // The same bytes read as BCD would be a different time — 0x0E is not BCD.
    r.status_b = hour24_mode;
    try testing.expectError(error.BadBcd, decode(r));
}

test "decode: 12-hour mode — midnight, noon, and the PM bit" {
    const cases = [_]struct { hours: u8, want: u8 }{
        .{ .hours = 0x12, .want = 0 }, // 12 AM is midnight
        .{ .hours = 0x01, .want = 1 },
        .{ .hours = 0x11, .want = 11 },
        .{ .hours = 0x92, .want = 12 }, // 12 PM is noon
        .{ .hours = 0x81, .want = 13 },
        .{ .hours = 0x91, .want = 23 },
    };
    for (cases) |k| {
        var r = bcd24(20, 26, 9, 17, 0, 0, 0);
        r.status_b = 0; // BCD, 12-hour
        r.hours = k.hours;
        try testing.expectEqual(k.want, (try decode(r)).hour);
    }
    // Hour zero does not exist on a 12-hour clock.
    var bad = bcd24(20, 26, 9, 17, 0, 0, 0);
    bad.status_b = 0;
    bad.hours = 0x00;
    try testing.expectError(error.OutOfRange, decode(bad));
}

test "decode: the century register is believed only when it is plausible" {
    var r = bcd24(19, 99, 12, 31, 23, 59, 59);
    try testing.expectEqual(@as(i32, 1999), (try decode(r)).year);
    r.century = 0x00; // no century register
    try testing.expectEqual(@as(i32, 2099), (try decode(r)).year);
    r.century = 0x45; // nonsense
    try testing.expectEqual(@as(i32, 2099), (try decode(r)).year);
    r.century = 0xFF; // not BCD at all
    try testing.expectEqual(@as(i32, 2099), (try decode(r)).year);
}

test "decode: garbage is refused, not turned into a date" {
    const bad = [_]Raw{
        bcd24(20, 26, 13, 1, 0, 0, 0), // month 13
        bcd24(20, 26, 0, 1, 0, 0, 0), // month 0
        bcd24(20, 26, 2, 30, 0, 0, 0), // February 30th
        bcd24(20, 25, 2, 29, 0, 0, 0), // February 29th in a non-leap year
        bcd24(20, 26, 4, 31, 0, 0, 0), // April 31st
        bcd24(20, 26, 1, 0, 0, 0, 0), // day 0
        bcd24(20, 26, 1, 1, 24, 0, 0), // hour 24
        bcd24(20, 26, 1, 1, 0, 60, 0), // minute 60
        bcd24(20, 26, 1, 1, 0, 0, 60), // second 60
    };
    for (bad) |r| try testing.expectError(error.OutOfRange, decode(r));

    var flat = bcd24(20, 26, 1, 1, 0, 0, 0);
    flat.seconds = 0xFF; // a flat battery reads as all ones
    try testing.expectError(error.BadBcd, decode(flat));
    // ...and so does the leap day that IS valid.
    _ = try decode(bcd24(20, 24, 2, 29, 0, 0, 0));
}
