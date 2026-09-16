//! COM1, and QEMU's exit door. The whole of this machine's console.

const com1: u16 = 0x3F8;

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (port),
    );
}

pub fn init() void {
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x80);
    outb(com1 + 0, 0x01); // 115200
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x03); // 8N1
    outb(com1 + 2, 0xC7);
    outb(com1 + 4, 0x03);
}

pub fn put(bytes: []const u8) void {
    for (bytes) |b| {
        while (inb(com1 + 5) & 0x20 == 0) {}
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
