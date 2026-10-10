//! COM1, the screen when there is one (screen.zig), and QEMU's exit door. The
//! whole of this machine's console.

const com1: u16 = 0x3F8;

const std = @import("std");
const port = @import("port.zig");
const screen = @import("screen.zig");
const log_ring = @import("log_ring.zig");
const ring_pieces = @import("ring_pieces.zig");
const restart = @import("restart.zig");
const serial_gate = @import("serial_gate.zig");
pub const outb = port.outb;
pub const inb = port.inb;

pub fn init() void {
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x80);
    outb(com1 + 0, 0x01); // 115200
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x03); // 8N1
    outb(com1 + 2, 0xC7);
    outb(com1 + 4, 0x03);
    screen.attach();
}

/// **A PORT NOBODY DRAINS MUST NOT HANG THE MACHINE** (serial_gate.zig). A
/// droplet's serial port goes to DigitalOcean, which may or may not read it;
/// if its transmitter stays full for 100,000 reads, the port is skipped,
/// one status read per write, until it drains, and then told how much of the
/// log it missed. The screen and the ring have every byte meanwhile.
var gate: serial_gate.Gate = .{};
const patience: u32 = 100_000;

const Com1 = struct {
    /// **A 16550's TRANSMIT FIFO HOLDS 16** (enabled by `init`: FCR 0xC7).
    /// The status bit `ready` reads says the FIFO is empty, so that many may
    /// follow it, sent in one instruction: one exit for sixteen bytes on a
    /// hypervisor, where a status read and a write a byte was two each.
    pub const burst = 16;
    pub fn ready(_: Com1) bool {
        return inb(com1 + 5) & 0x20 != 0;
    }
    pub fn write(_: Com1, b: u8) void {
        outb(com1, b);
    }
    pub fn writeBurst(_: Com1, bytes: []const u8) void {
        port.outsb(com1, bytes);
    }
};

/// **THE LAST 64 KiB OF THE LOG, FOR A STATUS PAGE TO SERVE** (log_ring.zig),
/// with secrets taken out on the way in. The port and the screen still get
/// every byte as written. `putPort` alone, the NMI handler's, does not reach
/// it.
///
/// **THE RING IS IN `.data`, ITS BYTES IN `.bss`.** probe/link.ld warns that
/// nothing in `.bss` may be assumed zero. The two loaders this machine has
/// do zero it, on every boot and every restart (RESTART.md measures it), but
/// the ring's head indexes memory, so it does not lean on that: in `.data`
/// the loader writes it empty from the file. The bytes may be anything until
/// written, and nothing reads past what the ring says it holds.
var ring_bytes: [64 * 1024]u8 = undefined;
pub var ring: log_ring.Ring linksection(".data") = .{ .buf = &ring_bytes };

pub fn put(bytes: []const u8) void {
    ring.write(bytes);
    if (deferred and pending() + bytes.len <= pend.len) {
        const p = ring_pieces.pieces(pend.len, pend_written, bytes.len);
        @memcpy(p[0].into(&pend), bytes[0..p[0].len]);
        @memcpy(p[1].into(&pend), bytes[p[0].len..]);
        pend_written += bytes.len;
        return;
    }
    // Not deferring, or the backlog is full: what waits goes first, so the
    // order on the screen and the port is the order written.
    flushPending();
    screen.put(bytes);
    putPort(bytes);
}

/// **THE CONSOLE, OUT OF THE WAY OF THE REQUESTS.** Every byte written to the
/// screen or the port is a trip out to the hypervisor, and a request's log
/// (about 300 bytes) cost about 7 ms on the port and as much again on the
/// screen, during which the machine served no one: the next request waited,
/// and the connection that had been answered was not even closed. While
/// `deferred`, `put` writes the ring at once (the status page sees it) and
/// keeps the screen's and the port's copy here; the host drains it with
/// `drain` when it has nothing else to do.
///
/// **NOTHING IS LOST, AND A FAILURE IS NEVER LATE.** A backlog that fills is
/// written out first, then the rest directly, as before; `fail`, a panic and
/// the exit door write the whole backlog before their own message.
pub var deferred: bool = false;
/// The most the console may fall behind before `put` writes out directly.
pub const backlog = 256 * 1024;
var pend: [backlog]u8 = undefined;
/// **TWO POSITIONS THAT ONLY COUNT UP** (metal-vmm B36): bytes ever put in
/// the backlog, and ever drained out of it. What waits is the difference,
/// and where it lies is `ring_pieces.pieces`.
var pend_written: u64 = 0;
var pend_drained: u64 = 0;

/// Bytes waiting for the screen and the port.
pub fn pending() usize {
    return @intCast(pend_written - pend_drained);
}

/// Writes at most `budget` waiting bytes to the screen and the port.
pub fn drain(budget: usize) void {
    const n = @min(budget, pending());
    for (ring_pieces.pieces(pend.len, pend_drained, n)) |piece| {
        const chunk = piece.of(&pend);
        if (chunk.len == 0) continue;
        screen.put(chunk);
        putPort(chunk);
        pend_drained += chunk.len;
    }
}

/// Writes every waiting byte.
pub fn flushPending() void {
    drain(pending());
}

/// Stops deferring, and writes what waits: before anything that must be seen
/// now (a failure, a panic, the end).
pub fn immediate() void {
    deferred = false;
    flushPending();
}

/// The serial port alone, without the screen. For a handler that may have
/// interrupted `screen.put` part-way, whose state it must not touch.
pub fn putPort(bytes: []const u8) void {
    if (@import("builtin").is_test) return captureForTest(bytes);
    gate.send(bytes, Com1{}, patience);
}

pub fn putDec(v: u64) void {
    var buf: [24]u8 = undefined;
    var n = v;
    var i: usize = buf.len;
    if (n == 0) return put("0");
    while (n > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    put(buf[i..]);
}

pub fn putHex(v: u64, digits: usize) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        const shift: u6 = @intCast((digits - 1 - i) * 4);
        buf[i] = hex[@as(usize, @intCast((v >> shift) & 0xF))];
    }
    put(buf[0..digits]);
}

/// Four decimal octets, for an address a human has to read.
pub fn putIp(a: [4]u8) void {
    for (a, 0..) |b, i| {
        if (i > 0) put(".");
        putDec(b);
    }
}

pub fn putMac(a: [6]u8) void {
    for (a, 0..) |b, i| {
        if (i > 0) put(":");
        putHex(b, 2);
    }
}

/// QEMU's isa-debug-exit: the guest ends with `code << 1 | 1`, so 0 arrives as
/// 1 and 1 arrives as 3. The run script maps them back.
pub fn exitQemu(code: u8) noreturn {
    immediate();
    outb(0xF4, code);
    while (true) asm volatile ("hlt");
}

/// **WHAT A FATAL ERROR DOES ONCE THE MACHINE IS SERVING** (restarting.zig).
/// Null, the default and the whole of boot, means halt: a refusal at boot is a
/// fact a restart would meet again. Set, `fail` and a host's panic handler end
/// there instead, and the machine restarts.
pub var on_fatal: ?*const fn (restart.Reason, []const u8) noreturn linksection(".data") = null;

pub fn fail(why: []const u8) noreturn {
    immediate();
    put("FAIL: ");
    put(why);
    put("\n");
    if (on_fatal) |f| f(.failure, why);
    exitQemu(1);
}

/// Moves the ring into `buf`, a region that outlives a restart
/// (restarting.zig), with what it held so far.
pub fn keepIn(buf: []u8) void {
    var held: [64 * 1024]u8 = undefined;
    const text = ring.read(&held);
    ring = log_ring.Ring.init(buf);
    ring.write(text);
}

pub fn pass() noreturn {
    put("PASS\n");
    exitQemu(0);
}

/// **WHAT A HOST TEST WOULD HAVE SEEN ON THE PORT.** A host test has no
/// serial port, and its process may not touch I/O ports, so in a test build
/// `putPort` writes here instead: the last `captured_max` bytes, oldest
/// dropped first. A test reads it with `captured()` and empties it with
/// `clearCaptured()`.
const captured_max = 4096;
var captured_buf: [captured_max]u8 = undefined;
var captured_len: usize = 0;

fn captureForTest(bytes: []const u8) void {
    for (bytes) |b| {
        if (captured_len == captured_max) {
            std.mem.copyForwards(u8, captured_buf[0 .. captured_max - 1], captured_buf[1..]);
            captured_len -= 1;
        }
        captured_buf[captured_len] = b;
        captured_len += 1;
    }
}

pub fn captured() []const u8 {
    return captured_buf[0..captured_len];
}

pub fn clearCaptured() void {
    captured_len = 0;
}
