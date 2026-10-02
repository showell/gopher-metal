//! **RESTARTING, THE KERNEL HALF** (RESTART.md, QUEUE.md item 16). The pure
//! half, the record and the back-off, is `restart.zig`; this reads and writes
//! CMOS, keeps the log past the kernel, and resets the machine.
//!
//! A host uses it in three steps:
//!
//!   1. **Reserve** `reserved()` from the page allocator: the kernel's image
//!      and, past it, the kept log's region.
//!   2. **`begin(clock)`** once the wall clock is up: the log moves into the
//!      kept region, the boot before this one and the restart record are
//!      reported, and the answer says how long to wait before serving.
//!   3. **`serving()`** where the main loop starts. From there on,
//!      `serial.fail`, a panic, and a CPU exception (which ends in
//!      `serial.fail`) restart the machine instead of halting it. Before it,
//!      a fatal error is a refusal at boot, and still halts.
//!
//! The NMI handler is untouched: it logs and carries on.

const std = @import("std");
const serial = @import("serial.zig");
const port = @import("port.zig");
const boot = @import("boot.zig");
const pvh = @import("pvh.zig");
const restart = @import("restart.zig");
const kept_log = @import("kept_log.zig");
const reset = @import("reset.zig");

// In `.data`, not `.bss`: what decides a restart must not lean on how a
// loader treated `.bss`.
var kept: ?kept_log.Kept linksection(".data") = null;
var clock: ?*const fn () ?i64 linksection(".data") = null;

/// The kept log's region: the first page boundary past the kernel's image.
pub fn keptRegion() pvh.Region {
    const image = boot.image();
    const start = std.mem.alignForward(u64, image.start + image.len, 4096);
    return .{ .start = start, .len = kept_log.region_bytes };
}

/// The kernel's image and the kept log's region past it: what the page
/// allocator must not hand out.
pub fn reserved() pvh.Region {
    const image = boot.image();
    const k = keptRegion();
    return .{ .start = image.start, .len = k.start + k.len - image.start };
}

fn cmosRead() [restart.record_len]u8 {
    var b: [restart.record_len]u8 = undefined;
    for (&b, 0..) |*c, i| {
        port.outb(0x70, 0x80 | (restart.cmos_record + @as(u8, @intCast(i))));
        c.* = port.inb(0x71);
    }
    return b;
}

fn cmosWrite(b: [restart.record_len]u8) void {
    for (b, 0..) |c, i| {
        port.outb(0x70, 0x80 | (restart.cmos_record + @as(u8, @intCast(i))));
        port.outb(0x71, c);
    }
}

/// What `begin` found.
pub const Boot = struct {
    record: ?restart.Record,
    previous: ?kept_log.Previous,
    /// How long to wait before serving: `restart.backoffSeconds`.
    wait_seconds: u32,
};

/// Moves the log into the kept region, reports the boot before this one and
/// the restart record, and answers how long to wait before serving. `now`
/// answers the wall clock in Unix seconds, or null when it is not known; the
/// restart path asks it for the time of a restart.
pub fn begin(now: *const fn () ?i64) Boot {
    const region = keptRegion();
    const bytes: [*]u8 = @ptrFromInt(region.start);
    const k = kept_log.open(bytes[0..region.len]);
    serial.keepIn(k.bytes());
    kept = k;
    clock = now;

    serial.put("  restart: this is boot ");
    serial.putDec(k.boot);
    serial.put(" of the kept log; the boot before it ");
    var line: [kept_log.slot_bytes]u8 = undefined;
    if (k.previous) |p| {
        serial.put("(");
        serial.putDec(p.boot);
        serial.put(") ended: ");
        serial.put(p.lastLine(&line));
        serial.put("\n");
    } else serial.put("left no log\n");

    const record = restart.Record.decode(cmosRead());
    var wait: u32 = 0;
    if (record) |r| {
        wait = restart.backoffSeconds(r.count);
        serial.put("  restarted after ");
        serial.put(r.reason.text());
        serial.put(" (restart ");
        serial.putDec(r.count);
        serial.put(" in a row)");
        if (wait > 0) {
            serial.put("; waiting ");
            serial.putDec(wait);
            serial.put(" s before serving");
        }
        serial.put("\n");
    }
    return .{ .record = record, .previous = k.previous, .wait_seconds = wait };
}

/// From here on, a fatal error restarts the machine.
pub fn serving() void {
    serial.on_fatal = fatal;
}

/// Forgets the restart record: a run that ends on purpose (a probe) leaves no
/// count behind for the next one.
pub fn forget() void {
    cmosWrite(@splat(0));
}

/// **THE RESTART PATH.** Something has already gone wrong, so it leans on as
/// little as it can: interrupts off, no allocation, plain stores and port
/// writes. A fault inside it triple-faults, which restarts anyway.
///
/// **THE RECORD FIRST.** The back-off is for a crash loop, and the failure
/// being handled may be in the very paths a report goes through: the
/// serial port, the screen, the ring, the clock. So the record is written
/// before any of them is touched, with the time unknown (which only ever
/// waits longer), then again with the time once the clock has answered.
/// A fault while reporting still resets, but now with the restart counted
/// (REVIEW-restart-fat32.md R1).
fn fatal(reason: restart.Reason, why: []const u8) noreturn {
    asm volatile ("cli");
    serial.on_fatal = null; // a failure in here halts rather than loops
    const previous = restart.Record.decode(cmosRead());
    cmosWrite(restart.recordRestart(previous, null, reason).encode());
    const now = restart.minutesSince2020(if (clock) |c| c() else null);
    cmosWrite(restart.recordRestart(previous, now, reason).encode());
    serial.put("RESTART: ");
    serial.put(reason.text());
    serial.put(": ");
    serial.put(why);
    serial.put("\n");
    if (kept) |*k| k.seal(&serial.ring);
    // A reset on real hardware need not write back the caches; the sealed
    // header is in one.
    asm volatile ("wbinvd" ::: .{ .memory = true });
    reset.now();
}
