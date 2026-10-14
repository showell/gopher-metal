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

/// **THE LAST 1.25 MiB OF THE LOG, FOR A STATUS PAGE TO SERVE** (log_ring.zig),
/// with secrets taken out on the way in. The port and the screen still get
/// every byte as written. `putPort` alone, the NMI handler's, does not reach
/// it.
///
/// **THE RING IS IN `.data`, ITS BYTES IN `.bss`.** probe/link.ld warns that
/// nothing in `.bss` may be assumed zero. The two loaders this machine has
/// do zero it, on every boot and every restart (RESTART.md measures it), but
/// the ring's count places every write (`next()`), so it does not lean on that: in `.data`
/// the loader writes it empty from the file. The bytes may be anything until
/// written, and nothing reads past what the ring says it holds.
var ring_bytes: [log_ring.capacity]u8 = undefined;
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
    stop(.failure, "FAIL: ", why);
}

/// `fail`, for a reason of its own in the restart record (a disk that
/// stopped answering, metal-vmm QUEUE 198.3).
pub fn failFor(reason: restart.Reason, why: []const u8) noreturn {
    stop(reason, "FAIL: ", why);
}

/// **EVERY KERNEL'S PANIC HANDLER**: a kernel's root says
/// `pub const panic = metal.serial.panic;`, and boot.zig refuses one that
/// does not. A panic ends as `fail` does: the console written out, the
/// message, then `on_fatal` (a restart, once serving) or halt.
pub const panic = std.debug.FullPanic(panicked);

fn panicked(msg: []const u8, _: ?usize) noreturn {
    stop(.panic, "PANIC: ", msg);
}

fn stop(reason: restart.Reason, label: []const u8, why: []const u8) noreturn {
    immediate();
    put(label);
    put(why);
    put("\n");
    if (on_fatal) |f| f(reason, why);
    exitQemu(1);
}

/// Moves the ring into `buf`, a region that outlives a restart
/// (restarting.zig), with what it held so far. The new ring's count of
/// bytes lost starts again (metal-vmm 150(c), decided): `lost()` is read
/// only to start a read at a whole line, and what moves already starts at
/// one.
pub fn keepIn(buf: []u8) void {
    ring = ring.moveTo(buf);
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
    // The last `captured_max` bytes of what was held and `bytes`, moved once
    // a call (metal-vmm QUEUE 203(d): a byte at a time, a full buffer moved
    // 4 KiB for every byte, a second of tier 0 in the backlog's test).
    const new = bytes[bytes.len -| captured_max..];
    const keep = @min(captured_len, captured_max - new.len);
    std.mem.copyForwards(u8, captured_buf[0..keep], captured_buf[captured_len - keep .. captured_len]);
    @memcpy(captured_buf[keep..][0..new.len], new);
    captured_len = keep + new.len;
}

pub fn captured() []const u8 {
    return captured_buf[0..captured_len];
}

pub fn clearCaptured() void {
    captured_len = 0;
}

test "a host test's capture keeps the last 4 KiB written, oldest dropped first, as a byte at a time would (metal-vmm QUEUE 203(d))" {
    const testing = std.testing;
    defer clearCaptured();
    clearCaptured();
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(testing.allocator);
    var prng: std.Random.DefaultPrng = .init(203);
    const r = prng.random();
    var buf: [9000]u8 = undefined;
    for (0..200) |_| {
        const n = if (r.boolean()) r.uintAtMost(usize, 40) else r.uintAtMost(usize, buf.len);
        for (buf[0..n]) |*b| b.* = r.int(u8);
        captureForTest(buf[0..n]);
        try model.appendSlice(testing.allocator, buf[0..n]);
        if (model.items.len > captured_max) {
            const drop = model.items.len - captured_max;
            std.mem.copyForwards(u8, model.items[0..captured_max], model.items[drop..]);
            model.shrinkRetainingCapacity(captured_max);
        }
        try testing.expectEqualSlices(u8, model.items, captured());
    }
}

test "the console's backlog: kept while deferred, drained in order, across its wrap, and written first when it fills (metal-vmm QUEUE 197.3)" {
    const testing = std.testing;
    defer {
        deferred = false;
        flushPending();
        clearCaptured();
    }
    flushPending();
    clearCaptured();
    deferred = true;
    put("abcdef");
    try testing.expectEqualStrings("", captured());
    try testing.expectEqual(@as(usize, 6), pending());
    drain(3);
    try testing.expectEqualStrings("abc", captured());
    put("gh");
    immediate();
    try testing.expectEqualStrings("abcdefgh", captured());
    try testing.expectEqual(@as(usize, 0), pending());

    // Near the end of the backlog's buffer, a put that crosses its wrap
    // comes out whole and in order.
    clearCaptured();
    deferred = true;
    const to_edge = backlog - @as(usize, @intCast(pend_written % backlog)) - 2;
    var filler: [4096]u8 = @splat('.');
    var left = to_edge;
    while (left > 0) {
        const n = @min(left, filler.len);
        put(filler[0..n]);
        drain(n);
        // The capture keeps its last 4 KiB a byte at a time: emptied as it
        // goes, it never shifts (198.11).
        clearCaptured();
        left -= n;
    }
    clearCaptured();
    put("WRAPPED");
    try testing.expectEqualStrings("", captured());
    drain(100);
    try testing.expectEqualStrings("WRAPPED", captured());

    // A backlog that fills is written out first, then the put that did not
    // fit: nothing lost, nothing out of order.
    clearCaptured();
    filler[filler.len - 1] = '!';
    var queued: usize = 0;
    while (queued + filler.len <= backlog) : (queued += filler.len) put(&filler);
    try testing.expectEqualStrings("", captured());
    // The backlog comes out here, 256 KiB through a 4 KiB capture: only
    // its end is read, and that is all the capture keeps.
    put("NEXT");
    try testing.expectEqual(@as(usize, 0), pending());
    try testing.expect(std.mem.endsWith(u8, captured(), "!NEXT"));
}
