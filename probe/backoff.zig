//! **THE RESTART, END TO END** (RESTART.md, QUEUE.md item 16).
//!
//! It runs the restart path itself (`restarting.zig`) on QEMU's `pc`
//! machine, the droplet's, without -no-reboot. Each boot:
//!
//!   1. **Reports what it found** (`restarting.begin`): the kept log of the
//!      boot before, and the CMOS restart record.
//!   2. **Checks them.** After the first boot, the record must count the
//!      restarts so far, and the boot before's log must end with the reason
//!      it restarted for.
//!   3. **Marks itself serving, then fails on purpose,** which must restart
//!      the machine, not halt it.
//!
//! After four restarts in a row the back-off must say 60 s. The probe waits a
//! second for each minute it says, so a run is quick, and measures that it
//! did. Then it serves again: it forgets the record and passes.
//!
//! A failure in the checks halts: it happens before `serving()`, so it is a
//! refusal at boot, which halts, which is the other half of the design.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const Io = metal.io;
const restarting = metal.restarting;

comptime {
    _ = metal.boot;
}

fn wallNow() ?i64 {
    if (!Io.realTimeIsSet()) return null;
    return @intCast(@divFloor(Io.Clock.now(.real, Io.io()).nanoseconds, std.time.ns_per_s));
}

/// How many restarts in a row the run makes before it must wait.
const restarts_before_waiting = 4;

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal backoff probe\n");
    _ = metal.wallclock.start() catch serial.fail("the clocks would not come up");
    const found = restarting.begin(wallNow);
    const restarts: u8 = if (found.record) |r| r.count else 0;

    if (restarts > 0) {
        var line: [metal.kept_log.slot_bytes]u8 = undefined;
        var want: [64]u8 = undefined;
        const reason = std.fmt.bufPrint(&want, "RESTART: a failure: on purpose, while serving: restart {d}", .{restarts}) catch unreachable;
        const p = found.previous orelse serial.fail("restarted, and the boot before left no kept log");
        if (!std.mem.eql(u8, p.lastLine(&line), reason)) serial.fail("the boot before's kept log does not end with the reason it restarted for");
        serial.put("  ok: the boot before's log ends with its reason, and the record counts ");
        serial.putDec(restarts);
        serial.put("\n");
    }

    if (restarts < restarts_before_waiting) {
        if (found.wait_seconds != 0) serial.fail("the back-off waited before the fourth restart in a row");
        restarting.serving();
        var why: [64]u8 = undefined;
        serial.fail(std.fmt.bufPrint(&why, "on purpose, while serving: restart {d}", .{restarts + 1}) catch unreachable);
    }

    if (found.wait_seconds != 60) serial.fail("after four restarts in a row the back-off is not 60 s");
    // One second for each minute the back-off says.
    const start = Io.awakeNs().?;
    const until = start + @divTrunc(@as(i96, found.wait_seconds) * std.time.ns_per_s, 60);
    while (Io.awakeNs().? < until) asm volatile ("pause");
    const waited_ms = @divTrunc(Io.awakeNs().? - start, std.time.ns_per_ms);
    serial.put("  waited ");
    serial.putDec(@intCast(waited_ms));
    serial.put(" ms for the back-off's 60 s, a second a minute\n");
    if (waited_ms < 1000) serial.fail("the back-off did not wait");
    restarting.forget();
    serial.put("  serving again after 4 restarts in a row, the last after its back-off\n");
    serial.pass();
}

pub const panic = metal.serial.panic;
