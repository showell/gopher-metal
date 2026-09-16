//! **THIS KERNEL MUST FAIL.** It asks for the wall clock without anyone having
//! told the machine the time, and the only right answer is to stop.
//!
//! The application's session expiry is `now - issued > max_age`. Answering
//! `.real` with time-since-boot makes `now` a few seconds and that difference
//! enormously negative, so every session — however old — would pass. probe/
//! run.sh asserts that this kernel panics, and with the message that names the
//! fix; a clean exit here is the failure.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const Io = metal.io;

comptime {
    _ = metal.boot;
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal realunset probe: asking for .real without being told\n");
    Io.startClock(metal.pit.calibrate() catch serial.fail("the PIT would not calibrate the TSC"));
    const t = Io.Clock.now(.real, Io.io());
    serial.put("  .real answered ");
    serial.putDec(@intCast(@divTrunc(t.nanoseconds, std.time.ns_per_s)));
    serial.put(" s instead of refusing\n");
    serial.pass();
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
