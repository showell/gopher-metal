//! **RESTS AND WHAT ENDED THEM** (metal-vmm QUEUE 193, gap 11). No interrupt
//! or wake was counted, so a device that interrupted endlessly looked like a
//! busy processor that "rests between frames". Each rest is noted here with
//! what ended it.
//!
//! **WHAT ENDED IT IS READ OFF THE HANDLERS, NOT THE CLOCK** (DESIGN-sleep.md,
//! round 4's open item). The timer and the network card each have a handler
//! that counts (interrupts.zig's stubs), and a rest compares the counts from
//! before the halt and after. Comparing the time woken with the deadline
//! instead sorted a timer KVM delivered a hair early as a device's, which
//! blinded the count of missed wakes, and one that fired between the halt and
//! the clock's read the other way.

/// What ended a rest.
pub const Ended = enum {
    /// The timer's handler ran, and the card's did not.
    deadline,
    /// The card's handler ran: a frame, or a send taken back (whatever else
    /// ran with it).
    device,
    /// Neither: an NMI, a spurious vector, or a halt that returned with no
    /// interrupt of ours.
    other,
};

/// From the timer's and the card's counts before the halt and after (each
/// counter may wrap).
pub fn ended(timer_before: u64, timer_after: u64, wake_before: u64, wake_after: u64) Ended {
    if (wake_after -% wake_before != 0) return .device;
    if (timer_after -% timer_before != 0) return .deadline;
    return .other;
}

pub const Rests = struct {
    rests: u64 = 0,
    woken_by_device: u64 = 0,
    /// Ended by neither handler.
    woken_by_other: u64 = 0,

    pub fn note(self: *Rests, how: Ended) void {
        self.rests +%= 1;
        switch (how) {
            .deadline => {},
            .device => self.woken_by_device +%= 1,
            .other => self.woken_by_other +%= 1,
        }
    }
};

const testing = @import("std").testing;

test "a rest is ended by whichever handler ran: the card's over the timer's, and neither is its own kind" {
    try testing.expectEqual(Ended.deadline, ended(4, 5, 9, 9));
    try testing.expectEqual(Ended.device, ended(4, 4, 9, 10));
    // Both: a frame came as the deadline did, and the frame is the news.
    try testing.expectEqual(Ended.device, ended(4, 5, 9, 10));
    try testing.expectEqual(Ended.other, ended(4, 4, 9, 9));
    // Across a counter's wrap.
    const most = @import("std").math.maxInt(u64);
    try testing.expectEqual(Ended.deadline, ended(most, 0, 3, 3));
    try testing.expectEqual(Ended.device, ended(1, 1, most, 0));
}

test "a rest is counted, with what ended it (metal-vmm QUEUE 193, gap 11)" {
    var r: Rests = .{};
    r.note(.device);
    r.note(.deadline);
    r.note(.deadline);
    r.note(.other);
    try testing.expectEqual(Rests{ .rests = 4, .woken_by_device = 1, .woken_by_other = 1 }, r);
}
