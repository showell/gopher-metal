//! **WHERE A RESPONSE'S BYTES GO WHEN A SPILL IS BEHIND THEM** (metal-vmm
//! QUEUE 198.1, 197.3 #5): stream.zig's `sendAll`, its decision pure, so
//! tier 0 holds it (stream.zig imports io and the driver, and no unit test
//! reaches it).

/// Before the bytes go anywhere.
pub const Start = enum {
    /// The connection is gone: the write fails, and the log says so.
    gone,
    /// Nothing waits in the spill: to the send queue first.
    queue,
    /// Bytes wait in the spill: these go behind them, in order.
    behind_spill,
};

pub fn start(spill_pending: usize, established: bool) Start {
    // Gone is gone whatever waits: bytes appended to a spill nobody will
    // drain were a write reported sent, and the log said "ok".
    if (!established) return .gone;
    return if (spill_pending == 0) .queue else .behind_spill;
}

/// What the send queue did not take: kept in the spill, if this spill's
/// `cap` and every spill's `limit` together allow it; else the spill is
/// drained first and the rest waits for room.
pub fn keeps(used: usize, cap: usize, all_spilled: usize, limit: usize, rest: usize) bool {
    return used + rest <= cap and all_spilled + rest <= limit;
}

const std = @import("std");
const testing = std.testing;

test "a write behind a spill on a connection that is gone fails: it is not kept for nobody and called sent (metal-vmm QUEUE 198.1)" {
    try testing.expectEqual(Start.gone, start(4096, false));
    try testing.expectEqual(Start.behind_spill, start(4096, true));
    try testing.expectEqual(Start.gone, start(0, false));
    try testing.expectEqual(Start.queue, start(0, true));
}

test "the spill keeps what fits its own cap and every spill's limit, both inclusive, and nothing past either" {
    try testing.expect(keeps(0, 100, 0, 1000, 100));
    try testing.expect(!keeps(1, 100, 0, 1000, 100));
    try testing.expect(keeps(0, 100, 900, 1000, 100));
    try testing.expect(!keeps(0, 100, 901, 1000, 100));
    try testing.expect(keeps(50, 100, 50, 1000, 0));
}
