//! **WHAT A DISK NEEDS BEFORE OUTPUT LEAVES THE MACHINE** (metal-vmm QUEUE
//! item 59): the decision `virtio.Block.flush` makes, pulled out of the I/O
//! it does, so `durable_sim.zig` can drive it over any interleaving of
//! writes, responses and flush outcomes. The I/O stays behind in `Block`:
//! `scsi.synchronize` is called only when `step` says so.
//!
//! The rule it serves (`io.durable`): nothing joins a send queue while a
//! write before it is unflushed. `Stream.sendAll` and `serviceStreams` call
//! `io.durable` before they queue a byte, and `io.durable` asks each disk's
//! `Block.flush`, which asks `step` here.

const std = @import("std");

/// One disk, as the decision sees it.
pub const Disk = struct {
    /// A write has been answered since the last flush that succeeded.
    unflushed: bool = false,
    /// What the disk said of its write cache (MODE SENSE's WCE): true,
    /// false, or nothing said, which is treated as true.
    write_cache: ?bool = null,
    /// Whether it can be told to synchronize: a SCSI disk. A virtio-blk
    /// disk cannot, and needs not: this driver never negotiates
    /// VIRTIO_BLK_F_FLUSH, so the device promises write-through (virtio 1.2
    /// §5.2.5.1). A disk in memory, for host tests, cannot either.
    asks: bool = false,
};

pub const Step = enum {
    /// Nothing written since the last good flush: nothing to do.
    none,
    /// Durable already, by the disk's own word: it writes through.
    clear,
    /// Send SYNCHRONIZE CACHE, and settle with what it answered.
    synchronize,
};

/// **WHAT TO DO FOR THIS DISK BEFORE OUTPUT.** A disk that said it writes
/// through is believed: a disk that lies about it loses writes whatever is
/// sent, and asking one that does not cache costs a command per response.
pub fn step(d: Disk) Step {
    if (!d.unflushed) return .none;
    if (!d.asks or d.write_cache == false) return .clear;
    return .synchronize;
}

/// The outcome of `s`, applied: the disk is flushed unless a synchronize
/// failed, and then it is tried again before the next output. Answers
/// whether it failed.
pub fn settle(d: *Disk, s: Step, ok: bool) bool {
    switch (s) {
        .none => return false,
        .clear => {
            d.unflushed = false;
            return false;
        },
        .synchronize => {
            if (ok) d.unflushed = false;
            return !ok;
        },
    }
}

const testing = std.testing;

test "nothing written, nothing done; written through, cleared; cached or not said, synchronized" {
    try testing.expectEqual(Step.none, step(.{ .asks = true, .write_cache = true }));
    try testing.expectEqual(Step.clear, step(.{ .unflushed = true }));
    try testing.expectEqual(Step.clear, step(.{ .unflushed = true, .asks = true, .write_cache = false }));
    try testing.expectEqual(Step.synchronize, step(.{ .unflushed = true, .asks = true, .write_cache = true }));
    try testing.expectEqual(Step.synchronize, step(.{ .unflushed = true, .asks = true }));
}

test "a failed synchronize leaves the disk unflushed, to be tried again" {
    var d = Disk{ .unflushed = true, .asks = true };
    try testing.expect(settle(&d, step(d), false));
    try testing.expectEqual(Step.synchronize, step(d));
    try testing.expect(!settle(&d, step(d), true));
    try testing.expectEqual(Step.none, step(d));
}
