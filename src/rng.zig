//! Randomness: the host's, the CPU's, and never neither.
//!
//! **UNTIL THIS FILE EXISTED THE MACHINE HAD NO ENTROPY AT ALL.** The DHCP
//! transaction id was a constant in the source and so was the TCP initial
//! sequence number. That is defensible for a probe on a private wire and
//! indefensible the moment anything mints a session token — and
//! `angry-gopher/zig-server` mints them in two places, both spelled
//! `io.random(buf)`, which is the only thing its whole password system needs
//! from this machine.
//!
//! Two independent sources, mixed, because a machine with either one working
//! should still be able to make a token:
//!
//! - **virtio-rng** is the primary. The hypervisor has a properly seeded pool
//!   and the guest does not, which is the entire reason the device exists. It
//!   is one descriptor on the same virtqueue the block and network devices use.
//! - **RDRAND** is the backstop: one instruction, no device, on every x86 since
//!   2012. Its output is whitened by the CPU and its failure mode is a clear
//!   one — the carry flag comes back zero — rather than a plausible-looking
//!   constant.
//!
//! They are mixed with SHA-256 rather than XOR'd, so that a source which is
//! broken in a structured way (all zeros, a stuck counter) cannot show through
//! into the output.
//!
//! **A DRAW THAT CANNOT FIND ENTROPY STOPS THE MACHINE.** It does not fall back
//! to the timestamp counter, and it does not return zeros. A token minted from
//! a predictable pool is worse than no token, because it looks exactly like a
//! real one.

const std = @import("std");
const virtio = @import("virtio.zig");
const serial = @import("serial.zig");

pub const device_id_entropy: u32 = 4;

/// virtio-rng has one queue and no configuration. A buffer offered to it comes
/// back filled with however many bytes the host had ready.
const queue_len: u16 = 4;
pub const Q = virtio.Queue(queue_len);

pub const Memory = struct {
    ring: Q.RingType align(16) = undefined,
    buf: [256]u8 align(16) = undefined,
};

var device: ?struct { base: usize, q: Q, mem: *Memory } = null;

/// Brings virtio-rng up if the machine has one. A machine without one is not an
/// error here; RDRAND may still answer.
pub fn attach(mem: *Memory) void {
    const base = virtio.find(device_id_entropy) orelse return;
    const st = virtio.negotiate(base, 0) catch return;
    const q = Q.setup(base, 0, &mem.ring) catch return;
    virtio.driverOk(base, st) catch return;
    device = .{ .base = base, .q = q, .mem = mem };
}

/// Asks the host for bytes. Answers how many arrived, which may be zero.
fn fromHost(out: []u8) usize {
    const d = &(device orelse return 0);
    const want = @min(out.len, d.mem.buf.len);

    d.q.ring.desc[0] = .{
        .addr = @intFromPtr(&d.mem.buf),
        .len = @intCast(want),
        .flags = virtio.desc_flag_write,
        .next = 0,
    };
    d.q.offer(0);
    d.q.notify();
    const used = d.q.wait();
    virtio.ack(d.base);

    const got = @min(@as(usize, used.len), want);
    @memcpy(out[0..got], d.mem.buf[0..got]);
    return got;
}

/// CPUID leaf 1, ECX bit 30.
fn hasRdrand() bool {
    // cpuid writes all four registers, so all four must be named even though
    // only ECX is wanted.
    var ecx: u32 = undefined;
    asm volatile (
        \\cpuid
        : [ecx] "={ecx}" (ecx),
        : [leaf] "{eax}" (@as(u32, 1)),
        : .{ .eax = true, .ebx = true, .edx = true });
    return ecx & (@as(u32, 1) << 30) != 0;
}

/// One 64-bit draw, or null. **The carry flag is the answer to "did this
/// work".** RDRAND is allowed to fail when its pool is momentarily drained,
/// and a caller that ignores the flag silently uses whatever was in the
/// register.
fn rdrand64() ?u64 {
    var value: u64 = undefined;
    var ok: u8 = undefined;
    asm volatile (
        \\rdrand %[v]
        \\setc %[ok]
        : [v] "=r" (value),
          [ok] "=r" (ok),
    );
    return if (ok != 0) value else null;
}

fn fromCpu(out: []u8) usize {
    if (!hasRdrand()) return 0;
    var at: usize = 0;
    while (at < out.len) {
        // Ten tries, which the Intel guidance suggests and which a working
        // implementation never needs more than one of.
        var tries: usize = 0;
        const v = while (tries < 10) : (tries += 1) {
            if (rdrand64()) |v| break v;
        } else return at;
        const n = @min(@as(usize, 8), out.len - at);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, v, .little);
        @memcpy(out[at..][0..n], bytes[0..n]);
        at += n;
    }
    return at;
}

/// A counter, so two draws in the same instant cannot produce the same block
/// even if both sources hand back the same bytes.
var draws: u64 = 0;

/// Fills `out` with bytes from both sources, mixed. Stops the machine if
/// neither answered.
pub fn fill(out: []u8) void {
    var at: usize = 0;
    while (at < out.len) {
        var host: [32]u8 = @splat(0);
        var cpu: [32]u8 = @splat(0);
        const from_host = fromHost(&host);
        const from_cpu = fromCpu(&cpu);

        if (from_host == 0 and from_cpu == 0) {
            serial.fail("no entropy: neither virtio-rng nor RDRAND answered, and this machine will not invent a token out of a clock");
        }

        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(host[0..from_host]);
        h.update(cpu[0..from_cpu]);
        var counter: [8]u8 = undefined;
        std.mem.writeInt(u64, &counter, draws, .little);
        h.update(&counter);
        draws +%= 1;

        var block: [32]u8 = undefined;
        h.final(&block);

        const n = @min(block.len, out.len - at);
        @memcpy(out[at..][0..n], block[0..n]);
        at += n;
    }
}

pub fn int(comptime T: type) T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    fill(&bytes);
    return std.mem.readInt(T, &bytes, .little);
}

/// What the machine found, for a host that wants to report it.
pub fn sources() struct { host: bool, cpu: bool } {
    return .{ .host = device != null, .cpu = hasRdrand() };
}
