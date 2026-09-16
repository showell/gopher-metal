//! A kernel that does one thing: bring up a virtio-blk device over MMIO and
//! read sectors off it. No Roc, no floor, no filesystem -- this exists to put
//! the driver on real (virtual) hardware and find out whether it works, before
//! anything is built on top of it.
//!
//!   qemu-system-x86_64 -M microvm -kernel kernel.elf -nographic \
//!     -drive id=d,file=<image>,format=raw,if=none \
//!     -device virtio-blk-device,drive=d \
//!     -device isa-debug-exit,iobase=0xf4,iosize=0x04 -no-reboot
//!
//! It prints what it found and what it read, then ends the guest through
//! QEMU's isa-debug-exit: 0 for a clean run, 1 for anything else, so a script
//! has a verdict without parsing.
//!
//! **THE BOOT IS THE BORING PART AND IT IS WRITTEN OUT IN FULL.** QEMU hands a
//! PVH kernel control in 32-bit protected mode with paging off. Long mode needs
//! page tables, PAE, the EFER bit and a GDT, in that order, before a single
//! line of 64-bit zig can run.

const std = @import("std");
const virtio = @import("virtio");

// ---- the PVH boot note ---------------------------------------------------

// **PVH, NOT MULTIBOOT.** QEMU's multiboot loader refuses a 64-bit ELF
// outright ("Cannot load x86-64 image, give a 32bit one"), and this kernel is
// 64-bit. PVH is the other door into the same machine and it takes an ELF of
// either width: an ELF note names a 32-bit entry point, and QEMU enters there
// in 32-bit protected mode with paging off -- the same state multiboot would
// have handed over. It is also what Firecracker and every modern microVM boot,
// so this is the more useful of the two doors anyway.
//
// The note is written in assembly because it must be a real SHT_NOTE section
// for QEMU to find it in a PT_NOTE segment, and `linksection` makes PROGBITS.
comptime {
    asm (
        \\.section .note.Xen, "a", @note
        \\.align 4
        \\.long 4                // namesz: "Xen" and its NUL
        \\.long 4                // descsz: a 32-bit entry address
        \\.long 18               // XEN_ELFNOTE_PHYS32_ENTRY
        \\.asciz "Xen"
        \\.align 4
        \\.long _start
        \\.align 4
    );
}

// ---- the serial port -----------------------------------------------------

const com1: u16 = 0x3F8;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "N{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (port),
    );
}

fn serialInit() void {
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x80);
    outb(com1 + 0, 0x01); // 115200
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x03); // 8N1
    outb(com1 + 2, 0xC7);
    outb(com1 + 4, 0x03);
}

fn put(bytes: []const u8) void {
    for (bytes) |b| {
        while (inb(com1 + 5) & 0x20 == 0) {}
        outb(com1, b);
    }
}

fn putDec(v: u64) void {
    var buf: [24]u8 = undefined;
    var n = v;
    var i: usize = buf.len;
    if (n == 0) {
        put("0");
        return;
    }
    while (n > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    put(buf[i..]);
}

fn putHex(v: u64, digits: usize) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        const shift: u6 = @intCast((digits - 1 - i) * 4);
        buf[i] = hex[@as(usize, @intCast((v >> shift) & 0xF))];
    }
    put(buf[0..digits]);
}

/// QEMU's isa-debug-exit: the guest ends with `code << 1 | 1`.
fn exitQemu(code: u8) noreturn {
    outb(0xF4, code);
    while (true) asm volatile ("hlt");
}

fn fail(why: []const u8) noreturn {
    put("FAIL: ");
    put(why);
    put("\n");
    exitQemu(1);
}

// ---- the device's memory -------------------------------------------------

/// The rings and the request, and a sector to read into. All of it is in the
/// kernel's own image, which the linker places at a fixed physical address
/// that paging maps to itself -- so `&sector` is both a pointer this code can
/// use and an address the device can write.
var blk_mem: virtio.BlockMemory align(4096) = .{};
var sector: [512]u8 align(4096) = undefined;
var scratch: [512]u8 align(4096) = undefined;

// ---- the run -------------------------------------------------------------

export fn kmain() callconv(.c) noreturn {
    serialInit();
    put("floor virtio probe\n");

    var slot: usize = 0;
    while (slot < virtio.mmio_slots) : (slot += 1) {
        const at = virtio.mmio_base + slot * virtio.mmio_stride;
        if (virtio.magicAt(at) != 0x74726976 or virtio.deviceIdAt(at) == 0) continue;
        put("  slot ");
        putDec(slot);
        put(" @0x");
        putHex(at, 8);
        put(": magic ");
        putHex(virtio.magicAt(at), 8);
        put(" version ");
        putDec(virtio.versionAt(at));
        put(" id ");
        putDec(virtio.deviceIdAt(at));
        put("\n");
    }

    const base = virtio.find(virtio.device_id_block) orelse
        fail("no virtio-blk device in any mmio slot (is -device virtio-blk-device there?)");
    put("  device at 0x");
    putHex(base, 8);
    put("\n");

    var blk = blk_mem.bring(base) catch |e| switch (e) {
        error.DeviceRefused => fail("the device refused the driver"),
        error.QueueTooSmall => fail("the device's queue is smaller than this driver's"),
        else => fail("the device would not come up"),
    };
    put("  capacity: ");
    putDec(blk.capacity);
    put(" sectors\n");

    // Sector 0 of a FAT16 volume is its boot sector: 0x55 0xAA at the end, and
    // the OEM name at offset 3. Reading it proves the transfer moved the right
    // bytes and not merely some.
    const st = blk.read(0, @intFromPtr(&sector));
    if (st != virtio.blk_s_ok) {
        put("  read status ");
        putDec(st);
        put("\n");
        fail("sector 0 did not read");
    }
    put("  sector 0 oem: ");
    put(sector[3..11]);
    put("\n  sector 0 signature: ");
    putHex(sector[510], 2);
    putHex(sector[511], 2);
    put("\n");
    if (sector[510] != 0x55 or sector[511] != 0xAA) fail("sector 0 has no boot signature");

    // A write, then a read back, on a sector past the FAT16 volume's own data
    // so nothing anyone cares about moves. This is the half that proves the
    // device is writing where we said rather than anywhere.
    const probe_lba: u64 = blk.capacity - 1;
    for (&scratch, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    const wst = blk.write(probe_lba, @intFromPtr(&scratch));
    if (wst != virtio.blk_s_ok) fail("the write was refused");
    @memset(&sector, 0);
    const rst = blk.read(probe_lba, @intFromPtr(&sector));
    if (rst != virtio.blk_s_ok) fail("the read back was refused");
    for (sector, 0..) |b, i| {
        if (b != @as(u8, @truncate(i *% 7 +% 3))) {
            put("  mismatch at byte ");
            putDec(i);
            put("\n");
            fail("what came back is not what went out");
        }
    }
    put("  wrote and read back sector ");
    putDec(probe_lba);
    put(": 512 bytes match\n");

    put("PASS\n");
    exitQemu(0);
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    put("PANIC: ");
    put(msg);
    put("\n");
    exitQemu(1);
}

// ---- long mode -----------------------------------------------------------

/// Identity paging for the low 4 GB in 2 MB pages: one PML4, one PDPT, four
/// page directories. 4 GB because the virtio window is at 0xFEB00000, which is
/// well above the first gigabyte, and because a device is handed physical
/// addresses -- identity mapping is what makes `&sector` mean the same thing to
/// this code and to the device.
///
/// The page directories are filled at compile time, since a 2 MB entry is just
/// its own address and some flags. The two above them need addresses the
/// linker chooses, so the 32-bit stub fills those five entries itself.
const pde_present_write_2mb: u64 = 0x83;

export var page_directories align(4096) linksection(".data") = blk: {
    @setEvalBranchQuota(10000);
    var t: [4][512]u64 = undefined;
    for (0..4) |i| {
        for (0..512) |j| {
            t[i][j] = @as(u64, (i * 512 + j) * 0x200000) | pde_present_write_2mb;
        }
    }
    break :blk t;
};

/// In `.data`, not `.bss`: the loader does not zero `.bss`, and a page table
/// full of whatever was in RAM is a triple fault.
export var pml4 align(4096) linksection(".data") = [_]u64{0} ** 512;
export var pdpt align(4096) linksection(".data") = [_]u64{0} ** 512;

export var stack align(16) linksection(".data") = [_]u8{0} ** (64 * 1024);

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\.code32
        \\  cli
        \\  // pml4[0] -> pdpt
        \\  movl $pdpt, %eax
        \\  orl $3, %eax
        \\  movl %eax, pml4
        \\  movl $0, pml4 + 4
        \\  // pdpt[0..3] -> the four page directories
        \\  movl $page_directories, %eax
        \\  orl $3, %eax
        \\  movl %eax, pdpt + 0
        \\  movl $0, pdpt + 4
        \\  addl $4096, %eax
        \\  movl %eax, pdpt + 8
        \\  movl $0, pdpt + 12
        \\  addl $4096, %eax
        \\  movl %eax, pdpt + 16
        \\  movl $0, pdpt + 20
        \\  addl $4096, %eax
        \\  movl %eax, pdpt + 24
        \\  movl $0, pdpt + 28
        \\  // PAE on, cr3 = pml4
        \\  movl %cr4, %eax
        \\  orl $0x20, %eax
        \\  movl %eax, %cr4
        \\  movl $pml4, %eax
        \\  movl %eax, %cr3
        \\  // EFER.LME
        \\  movl $0xC0000080, %ecx
        \\  rdmsr
        \\  orl $0x100, %eax
        \\  wrmsr
        \\  // paging + protection on: this is the moment long mode arms
        \\  movl %cr0, %eax
        \\  orl $0x80000001, %eax
        \\  movl %eax, %cr0
        \\  // the GDT pointer's base is an address the linker picked, so fill it here
        \\  movw $23, gdt_pointer
        \\  movl $gdt, %eax
        \\  movl %eax, gdt_pointer + 2
        \\  lgdt gdt_pointer
        \\  ljmp $0x08, $.Llong
        \\.code64
        \\.Llong:
        \\  movw $0x10, %ax
        \\  movw %ax, %ds
        \\  movw %ax, %es
        \\  movw %ax, %ss
        \\  movw %ax, %fs
        \\  movw %ax, %gs
        \\  leaq stack + 65520, %rsp
        \\  call kmain
        \\  hlt
    );
}

/// A flat GDT: a 64-bit code segment and a data segment, which is all long
/// mode looks at.
export var gdt align(8) linksection(".data") = [_]u64{
    0,
    0x00AF9A000000FFFF, // code: present, ring 0, executable, long
    0x00CF92000000FFFF, // data: present, ring 0, writable
};

const GdtPointer = extern struct { limit: u16, base: u32 };
/// Filled by the 32-bit stub, because the base is an address only the linker
/// knows. Three entries of eight bytes, so the limit is 23.
export var gdt_pointer linksection(".data") = GdtPointer{ .limit = 0, .base = 0 };
