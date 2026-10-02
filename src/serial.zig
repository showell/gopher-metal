//! COM1, the screen when there is one (screen.zig), and QEMU's exit door. The
//! whole of this machine's console.

const com1: u16 = 0x3F8;

const std = @import("std");
const port = @import("port.zig");
const screen = @import("screen.zig");
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

/// **A PORT NOBODY DRAINS MUST NOT HANG THE MACHINE.** A droplet's serial
/// port goes to DigitalOcean, which may or may not read it; if its
/// transmitter stays full for 100,000 reads, the port is given up on for the
/// rest of the boot and the screen carries on alone.
var serial_dead = false;
const patience: u32 = 100_000;

pub fn put(bytes: []const u8) void {
    screen.put(bytes);
    putPort(bytes);
}

/// The serial port alone, without the screen. For a handler that may have
/// interrupted `screen.put` part-way, whose state it must not touch.
pub fn putPort(bytes: []const u8) void {
    if (@import("builtin").is_test) return captureForTest(bytes);
    if (serial_dead) return;
    for (bytes) |b| {
        var waited: u32 = 0;
        while (inb(com1 + 5) & 0x20 == 0) {
            waited += 1;
            if (waited == patience) {
                serial_dead = true;
                return;
            }
        }
        outb(com1, b);
    }
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
    outb(0xF4, code);
    while (true) asm volatile ("hlt");
}

pub fn fail(why: []const u8) noreturn {
    put("FAIL: ");
    put(why);
    put("\n");
    exitQemu(1);
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
