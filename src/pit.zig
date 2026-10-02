//! The i8254 interval timer, used for one thing: measuring how fast the
//! timestamp counter runs.
//!
//! The TSC is monotonic and cheap, but its rate is the CPU's business, and this
//! machine used to ASSUME two gigahertz. On this box the real rate is 2,494 MHz
//! (the host kernel's own calibration), so every duration — a keepalive, the
//! time since the wall clock was set — ran 25% fast. The PIT counts at a known
//! 1,193,182 Hz; counting TSC ticks across a known number of PIT ticks gives
//! the rate.
//!
//! **CHANNEL 0, READ BACK — NOT THE TEXTBOOK CHANNEL 2.** The usual method gates
//! channel 2 through port 0x61 and watches its output there. Port 0x61 belongs
//! to the PC speaker circuit, and QEMU's `microvm` has none: the port reads
//! 0xFF. So channel 0 is set counting down and its count is LATCHED and read
//! back at two moments. That needs no gate and no interrupt — this machine has
//! none wired, and runs with them disabled, so channel 0's terminal-count
//! interrupt is never delivered.

const std = @import("std");
const port = @import("port.zig");
const tsc = @import("tsc.zig");

pub const input_hz: u64 = 1_193_182;

const ch0_data: u16 = 0x40;
const command: u16 = 0x43;

/// Channel 0, low byte then high byte, mode 2 (rate generator), binary.
const ch0_mode2: u8 = 0b0011_0100;
/// Channel 0, counter latch: freezes the count for the next two reads.
const ch0_latch: u8 = 0b0000_0000;
/// Channel 0, mode 0 (one-shot), used to park it afterwards.
const ch0_mode0: u8 = 0b0011_0000;

/// How many PIT ticks one measurement spans: about 34 ms. Well inside the
/// 65,535-tick period, so a measurement never sees the count wrap.
pub const span: u16 = 40_000;

pub const Error = error{
    /// The count never moved: there is no timer at these ports.
    NoTimer,
    /// It moved, but the rates it implies disagree or are not a CPU's.
    Implausible,
};

fn count() u16 {
    port.outb(command, ch0_latch);
    const lo = port.inb(ch0_data);
    const hi = port.inb(ch0_data);
    return @as(u16, hi) << 8 | lo;
}

/// One measurement: TSC ticks per second over `span` PIT ticks.
fn measure() Error!u64 {
    // Start counting from the top, so the whole span fits before the wrap.
    port.outb(command, ch0_mode2);
    port.outb(ch0_data, 0xFF);
    port.outb(ch0_data, 0xFF);

    // Wait for the count to MOVE at all. A running PIT changes it within a
    // microsecond; absent hardware reads a constant (0xFFFF) forever, and that
    // must be an answer rather than a hang.
    const first = count();
    var polls: u32 = 0;
    var c0 = first;
    while (c0 == first) : (polls += 1) {
        if (polls > 100_000) return error.NoTimer;
        c0 = count();
    }
    const t0 = tsc.read();

    while (true) {
        const c = count();
        if (c > c0) return error.Implausible; // wrapped: the span was too long
        if (c0 - c >= span) {
            const t1 = tsc.read();
            return (t1 - t0) * input_hz / (c0 - c);
        }
    }
}

/// TSC ticks per second, from rounds of measurements, after one that is
/// thrown away. Under emulation the first pass through this code is slower
/// than the rest, and it read 0.06% low where the others were within 0.005%.
///
/// **ONE INTERRUPTED MEASUREMENT IS NOT A BROKEN CLOCK.** This took three
/// measurements and stopped the boot if they spread by more than 1%. Under
/// KVM the host can pause the guest in the middle of one (the TSC runs on,
/// the PIT runs on, and the count is read late), and one boot in about 120
/// on the droplet machine stopped with "the clocks would not come up"
/// (QUEUE.md item 67). Now each round takes `per_round` measurements, a
/// measurement that wrapped is dropped rather than fatal, and the rate is
/// the median of the tightest three that agree within 1% (`settle`); up to
/// `rounds` rounds are tried before the answer is Implausible. A timer that
/// is not there is still NoTimer at once.
///
/// Afterwards channel 0 is parked in one-shot mode with its count run out, so
/// nothing keeps generating interrupt edges for whoever enables interrupts
/// next.
pub const rounds = 5;
pub const per_round = 5;

pub fn calibrate() Error!u64 {
    defer park();
    _ = measure() catch |e| switch (e) {
        error.NoTimer => return e,
        error.Implausible => {},
    };
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var got: [per_round]u64 = undefined;
        var n: usize = 0;
        for (0..per_round) |_| {
            got[n] = measure() catch |e| switch (e) {
                error.NoTimer => return e,
                error.Implausible => continue, // wrapped: a pause longer than the span's slack
            };
            n += 1;
        }
        if (settle(got[0..n])) |hz| return hz;
    }
    return error.Implausible;
}

/// The rate a round agrees on: of the three adjacent measurements (in order
/// of rate) that agree most closely, their median, if they agree within 1%
/// and it is a CPU's; null otherwise. Sorts `samples` in place.
pub fn settle(samples: []u64) ?u64 {
    if (samples.len < 3) return null;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var best: ?usize = null;
    var i: usize = 0;
    while (i + 3 <= samples.len) : (i += 1) {
        const spread = samples[i + 2] - samples[i];
        if (best == null or spread < samples[best.? + 2] - samples[best.?]) best = i;
    }
    const at = best.?;
    const median = samples[at + 1];
    if (!plausible(median)) return null;
    if (samples[at + 2] - samples[at] > median / 100) return null;
    return median;
}

fn park() void {
    port.outb(command, ch0_mode0);
    port.outb(ch0_data, 1);
    port.outb(ch0_data, 0);
}

/// Between 10 MHz and 100 GHz: anything outside that is a measurement of
/// something other than a CPU.
pub fn plausible(hz: u64) bool {
    return hz >= 10_000_000 and hz <= 100_000_000_000;
}

test "a round agrees on the tightest three, and one interrupted measurement does not spoil it" {
    const t = std.testing;
    var agree = [_]u64{ 2_494_000_000, 2_494_100_000, 2_493_900_000, 2_494_050_000, 2_493_950_000 };
    try t.expectEqual(@as(?u64, 2_493_950_000), settle(&agree));
    // A pause in the middle of one: that one reads 40% high, or low.
    var high = [_]u64{ 2_494_000_000, 3_500_000_000, 2_494_100_000, 2_493_900_000, 2_494_050_000 };
    try t.expectEqual(@as(?u64, 2_494_050_000), settle(&high)); // the tightest: .000, .050, .100
    var low = [_]u64{ 1_200_000_000, 2_494_000_000, 2_494_100_000, 2_493_900_000 };
    try t.expectEqual(@as(?u64, 2_494_000_000), settle(&low));
    // Two of five interrupted: the other three still agree.
    var two = [_]u64{ 3_000_000_000, 2_494_000_000, 4_000_000_000, 2_494_100_000, 2_493_900_000 };
    try t.expectEqual(@as(?u64, 2_494_000_000), settle(&two));
}

test "a round that does not agree, or is not a CPU's, or is too short, settles nothing" {
    const t = std.testing;
    var scattered = [_]u64{ 1_000_000_000, 2_000_000_000, 3_000_000_000, 4_000_000_000, 5_000_000_000 };
    try t.expectEqual(@as(?u64, null), settle(&scattered));
    var slow = [_]u64{ 1_000_000, 1_000_000, 1_000_000 };
    try t.expectEqual(@as(?u64, null), settle(&slow));
    var two = [_]u64{ 2_494_000_000, 2_494_000_000 };
    try t.expectEqual(@as(?u64, null), settle(&two));
    // Exactly 1% apart agrees; just past it does not.
    var edge = [_]u64{ 2_000_000_000, 2_010_000_000, 2_020_100_000 };
    try t.expectEqual(@as(?u64, 2_010_000_000), settle(&edge));
    var past = [_]u64{ 2_000_000_000, 2_010_000_000, 2_020_200_000 };
    try t.expectEqual(@as(?u64, null), settle(&past));
}
