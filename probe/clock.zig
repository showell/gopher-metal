//! This machine's clocks, from its own hardware — judged against the host.
//!
//! What it prints, run.sh checks against numbers this program cannot see:
//!
//!   tsc_hz   the PIT-measured rate of the timestamp counter. Under QEMU's
//!            emulation the guest's TSC IS the host's, so the host kernel's
//!            own "tsc: Detected … MHz" is the oracle.
//!   unix     the RTC's time, read at a seconds edge. The host's `date +%s`
//!            taken before and after the boot bounds it.
//!
//! What it checks itself:
//!
//!   - .awake never goes backwards;
//!   - the measured rate agrees with a SECOND, independent device: the time
//!     .awake reports between two RTC seconds edges is one second;
//!   - the chip's four register formats — BCD or binary, 12- or 24-hour —
//!     all decode to the same moment, so decode()'s modes are exercised
//!     against the device and not only on the host;
//!   - .real is the time it was told, advances with .awake, and re-anchors
//!     when told again.
//!
//! Its sibling realunset.zig must PANIC: .real before anyone has set it.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const rtc = metal.rtc;
const tsc = metal.tsc;
const Io = metal.io;

comptime {
    _ = metal.boot;
}

const ns = std.time.ns_per_s;

fn capture(at: *u64) void {
    at.* = tsc.read();
}

/// Says what the RTC wait saw, then stops: a missed edge is only useful with
/// the reason attached.
fn missed(e: rtc.DeviceError, why: []const u8) noreturn {
    const m = rtc.last_miss;
    serial.put("  rtc: ");
    serial.put(@errorName(e));
    serial.put(" after ");
    serial.putDec(m.polls);
    serial.put(" polls, ");
    serial.putDec(m.updating);
    serial.put(" mid-update, seconds ");
    serial.putDec(m.first_seconds);
    serial.put(" -> ");
    serial.putDec(m.last_seconds);
    serial.put("\n");
    serial.fail(why);
}

fn decodeOrFail(raw: rtc.Raw) rtc.Civil {
    return rtc.decode(raw) catch |e| {
        serial.put("  decode: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the RTC's reading would not decode");
    };
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal clock probe\n");
    const io = Io.io();

    if (Io.clockIsStarted()) serial.fail("the clock claims a rate before anyone measured one");
    if (Io.realTimeIsSet()) serial.fail("the wall clock claims to be set before anyone set it");

    // ── the rate ────────────────────────────────────────────────────────────
    const hz = metal.pit.calibrate() catch |e| {
        serial.put("  pit: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the PIT would not calibrate the TSC");
    };
    Io.startClock(hz);
    rtc.useClock(hz);
    serial.put("tsc_hz ");
    serial.putDec(hz);
    serial.put("\n");

    var prev = Io.Clock.now(.awake, io).nanoseconds;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const t = Io.Clock.now(.awake, io).nanoseconds;
        if (t < prev) serial.fail(".awake went backwards");
        prev = t;
    }
    for ([_]Io.Clock{ .boot, .cpu_process, .cpu_thread }) |c| {
        const a = Io.Clock.now(.awake, io).nanoseconds;
        const b = Io.Clock.now(c, io).nanoseconds;
        if (@abs(b - a) > ns) serial.fail("a boot-relative clock disagrees with .awake");
    }
    serial.put("  .awake: monotonic over 1000 readings\n");

    // ── the rate, against a second device ───────────────────────────────────
    var e0: u64 = 0;
    var e1: u64 = 0;
    _ = rtc.readAtEdge(&e0, capture) catch |e| missed(e, "no first RTC edge");
    const r1 = rtc.readAtEdge(&e1, capture) catch |e| missed(e, "no second RTC edge");
    const edge_ns: i128 = @divTrunc(@as(i128, e1 - e0) * ns, hz);
    serial.put("  one RTC second measured as ");
    serial.putDec(@intCast(edge_ns));
    serial.put(" ns of .awake\n");
    if (edge_ns < ns - ns / 100 or edge_ns > ns + ns / 100)
        serial.fail("the PIT-measured rate and the RTC disagree by more than 1%");

    // ── the wall clock, at an edge ──────────────────────────────────────────
    const c = decodeOrFail(r1);
    const unix = rtc.toUnix(c);
    serial.put("unix ");
    serial.putDec(@intCast(unix));
    serial.put("\n");
    serial.put("civil ");
    serial.putDec(@intCast(c.year));
    serial.put("-");
    serial.putDec(c.month);
    serial.put("-");
    serial.putDec(c.day);
    serial.put(" ");
    serial.putDec(c.hour);
    serial.put(":");
    serial.putDec(c.minute);
    serial.put(":");
    serial.putDec(c.second);
    serial.put("\n");

    Io.setRealTimeAt(unix, e1);
    const real_now = Io.Clock.now(.real, io).nanoseconds;
    const lo: i96 = @as(i96, unix) * ns;
    if (real_now < lo or real_now > lo + 2 * ns) serial.fail(".real is not the RTC time it was anchored to");

    // ── the anchor is the EDGE, not the moment it was set ───────────────────
    // Take an edge, let half a second pass, then anchor with the edge's TSC:
    // .real must already be half a second past the RTC's reading. Anchoring at
    // "now" instead would be off by exactly the delay, which is the error
    // setRealTimeAt exists to remove.
    {
        var edge: u64 = 0;
        const r = rtc.readAtEdge(&edge, capture) catch |e| missed(e, "no RTC edge for the anchor check");
        const at_edge = rtc.toUnix(decodeOrFail(r));
        const waited = Io.Clock.now(.awake, io).nanoseconds;
        while (Io.Clock.now(.awake, io).nanoseconds - waited < ns / 2) asm volatile ("pause");
        Io.setRealTimeAt(at_edge, edge);
        const late = Io.Clock.now(.real, io).nanoseconds - @as(i96, at_edge) * ns;
        if (late < ns / 2 or late > ns / 2 + ns / 10)
            serial.fail("setRealTimeAt did not anchor .real at the edge it was given");
    }
    serial.put("  .real anchored at the RTC edge, not at the moment it was set\n");

    // ── the four register formats ────────────────────────────────────────────
    const original = rtc.format();
    var at: u64 = 0;
    const base = rtc.readAtEdge(&at, capture) catch |e| missed(e, "no RTC edge for the format check");
    const want = rtc.toUnix(decodeOrFail(base));
    const formats = [_]rtc.Format{
        .{ .binary = false, .hour24 = true },
        .{ .binary = false, .hour24 = false },
        .{ .binary = true, .hour24 = true },
        .{ .binary = true, .hour24 = false },
    };
    for (formats) |f| {
        rtc.setFormat(f);
        const got = rtc.format();
        if (got.binary != f.binary or got.hour24 != f.hour24) serial.fail("the RTC would not change format");
        const raw = rtc.read() catch serial.fail("the RTC would not read");
        const t = rtc.toUnix(decodeOrFail(raw));
        // Read right after an edge, so all four land in the same second.
        if (t != want) {
            serial.put("  format binary=");
            serial.putDec(@intFromBool(f.binary));
            serial.put(" hour24=");
            serial.putDec(@intFromBool(f.hour24));
            serial.put(" decoded ");
            serial.putDec(@intCast(t));
            serial.put(", want ");
            serial.putDec(@intCast(want));
            serial.put("\n");
            serial.fail("two register formats decoded to different times");
        }
    }
    rtc.setFormat(original);
    serial.put("  four RTC formats (BCD/binary x 12/24-hour) decode to one moment\n");

    // ── the arithmetic, with a time the probe chose ─────────────────────────
    const told: i64 = 1_758_000_000;
    Io.setRealTime(told);
    const t0 = Io.Clock.now(.real, io).nanoseconds;
    const told_ns: i96 = @as(i96, told) * ns;
    if (t0 < told_ns or t0 > told_ns + ns) serial.fail(".real is not the time it was told");

    const a0 = Io.Clock.now(.awake, io).nanoseconds;
    var spin: u64 = 0;
    while (spin < 20_000_000) : (spin += 1) asm volatile ("pause");
    const t1 = Io.Clock.now(.real, io).nanoseconds;
    const a1 = Io.Clock.now(.awake, io).nanoseconds;
    if (t1 <= t0) serial.fail(".real did not advance");
    if (@abs((t1 - t0) - (a1 - a0)) > ns / 100) serial.fail(".real and .awake advanced by different amounts");

    Io.setRealTime(told + 3600);
    const t2 = Io.Clock.now(.real, io).nanoseconds;
    if (t2 < told_ns + 3600 * ns or t2 > told_ns + 3601 * ns) serial.fail("setRealTime a second time did not re-anchor .real");
    if (Io.Duration.fromSeconds(90).nanoseconds != 90 * ns) serial.fail("Duration.fromSeconds is wrong");
    serial.put("  .real: the time it was told, advancing with .awake, re-anchored when told again\n");

    serial.pass();
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
