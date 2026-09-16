//! The clock this machine has, and the one it refuses to fake.
//!
//! `.awake` is time since boot, from the timestamp counter. `.real` is the
//! wall clock, and this machine only knows it once a host has said —
//! `setRealTime(unix_seconds)` — after which it is that plus the time since.
//! This probe checks that arithmetic. Its sibling, realunset.zig, checks the
//! refusal: asking for `.real` before anyone has said must stop the machine,
//! because the application's session expiry compares against it.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const Io = metal.io;

comptime {
    _ = metal.boot;
}

const told: i64 = 1_758_000_000; // a Unix time in September 2025
const ns = std.time.ns_per_s;

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal clock probe\n");
    Io.startClock();
    const io = Io.io();

    if (Io.realTimeIsSet()) serial.fail("the wall clock claims to be set before anyone set it");

    // .awake moves forward and never back.
    var prev = Io.Clock.now(.awake, io).nanoseconds;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const t = Io.Clock.now(.awake, io).nanoseconds;
        if (t < prev) serial.fail(".awake went backwards");
        prev = t;
    }
    serial.put("  .awake: monotonic over 1000 readings\n");

    // The other boot-relative clocks agree with .awake: one core, one process.
    for ([_]Io.Clock{ .boot, .cpu_process, .cpu_thread }) |c| {
        const a = Io.Clock.now(.awake, io).nanoseconds;
        const b = Io.Clock.now(c, io).nanoseconds;
        const d = if (b > a) b - a else a - b;
        if (d > ns) serial.fail("a boot-relative clock disagrees with .awake by over a second");
    }

    // Told the time, .real is that time plus what has passed since.
    Io.setRealTime(told);
    if (!Io.realTimeIsSet()) serial.fail("setRealTime did not take");
    const r0 = Io.Clock.now(.real, io).nanoseconds;
    const lo: i96 = @as(i96, told) * ns;
    if (r0 < lo or r0 > lo + 5 * ns) serial.fail(".real is not the time it was told");

    // ...and it advances as .awake does.
    const a0 = Io.Clock.now(.awake, io).nanoseconds;
    var spin: u64 = 0;
    while (spin < 20_000_000) : (spin += 1) asm volatile ("pause");
    const r1 = Io.Clock.now(.real, io).nanoseconds;
    const a1 = Io.Clock.now(.awake, io).nanoseconds;
    if (r1 <= r0) serial.fail(".real did not advance");
    const dr = r1 - r0;
    const da = a1 - a0;
    const skew = if (dr > da) dr - da else da - dr;
    if (skew > ns / 100) serial.fail(".real and .awake advanced by different amounts");

    // Told again, it follows the new time rather than adding to the old.
    Io.setRealTime(told + 3600);
    const r2 = Io.Clock.now(.real, io).nanoseconds;
    if (r2 < lo + 3600 * ns or r2 > lo + 3605 * ns) serial.fail("setRealTime a second time did not re-anchor .real");

    serial.put("  .real: the time it was told, advancing with .awake, re-anchored when told again\n");
    serial.put("  Duration.fromSeconds(90): ");
    serial.putDec(@intCast(@divTrunc(Io.Duration.fromSeconds(90).nanoseconds, ns)));
    serial.put(" s\n");
    if (Io.Duration.fromSeconds(90).nanoseconds != 90 * ns) serial.fail("Duration.fromSeconds is wrong");
    serial.pass();
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
