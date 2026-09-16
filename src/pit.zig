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

/// TSC ticks per second: the median of three measurements, after one that is
/// thrown away. Under emulation the first pass through this code is slower
/// than the rest, and it read 0.06% low where the others were within 0.005%.
///
/// Afterwards channel 0 is parked in one-shot mode with its count run out, so
/// nothing keeps generating interrupt edges for whoever enables interrupts
/// next.
pub fn calibrate() Error!u64 {
    _ = try measure();
    var r: [3]u64 = undefined;
    for (&r) |*v| v.* = try measure();
    park();

    // A sort of three.
    if (r[0] > r[1]) swap(&r[0], &r[1]);
    if (r[1] > r[2]) swap(&r[1], &r[2]);
    if (r[0] > r[1]) swap(&r[0], &r[1]);
    const median = r[1];

    if (!plausible(median)) return error.Implausible;
    // Three measurements of one rate agree closely; if they do not, something
    // other than the PIT and the TSC was being measured.
    if (r[2] - r[0] > median / 100) return error.Implausible;
    return median;
}

fn park() void {
    port.outb(command, ch0_mode0);
    port.outb(ch0_data, 1);
    port.outb(ch0_data, 0);
}

fn swap(a: *u64, b: *u64) void {
    const t = a.*;
    a.* = b.*;
    b.* = t;
}

/// Between 10 MHz and 100 GHz: anything outside that is a measurement of
/// something other than a CPU.
pub fn plausible(hz: u64) bool {
    return hz >= 10_000_000 and hz <= 100_000_000_000;
}
