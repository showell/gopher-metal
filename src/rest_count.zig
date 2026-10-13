//! **RESTS AND WHAT ENDED THEM** (metal-vmm QUEUE 193, gap 11). No interrupt
//! or wake was counted, so a device that interrupted endlessly looked like a
//! busy processor that "rests between frames". `interrupts.rest` notes each
//! rest here with its deadline and the time it woke: woken before the
//! deadline is a device's interrupt (a frame, a taken buffer, or a storm);
//! at or past it, the slice's timer.

pub const Rests = struct {
    rests: u64 = 0,
    woken_by_device: u64 = 0,

    pub fn note(self: *Rests, deadline: u64, woke: u64) void {
        self.rests +%= 1;
        // Before the deadline, read across a wrap of the counter.
        if (@as(i64, @bitCast(woke -% deadline)) < 0) self.woken_by_device +%= 1;
    }
};

const testing = @import("std").testing;

test "a rest is counted, and one ended before its deadline is a device's wake (metal-vmm QUEUE 193, gap 11)" {
    var r: Rests = .{};
    r.note(1000, 400);
    r.note(1000, 1000);
    r.note(1000, 1300);
    // Across a wrap of the TSC: before the deadline, then past it.
    r.note(5, 0xFFFF_FFFF_FFFF_FFF0);
    r.note(0xFFFF_FFFF_FFFF_FFF0, 3);
    try testing.expectEqual(@as(u64, 5), r.rests);
    try testing.expectEqual(@as(u64, 2), r.woken_by_device);
}
