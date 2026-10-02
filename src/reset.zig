//! **HOW THIS MACHINE RESETS ITSELF**: three ways, measured in RESTART.md.
//! The reset control register and the keyboard controller restart QEMU's `pc`
//! machine (the droplet's); only the triple fault restarts `microvm`. A
//! restart tries all three in that order, as Linux does, each followed by a
//! pause long enough for it to land.

const port = @import("port.zig");

pub const Method = struct { name: []const u8, run: *const fn () void };

pub const methods = [_]Method{
    .{ .name = "the reset control register (0xCF9)", .run = resetControlRegister },
    .{ .name = "the keyboard controller (0xFE to 0x64)", .run = keyboardController },
    .{ .name = "a triple fault", .run = tripleFault },
};

/// Every method in turn. A triple fault cannot fail to happen, so this does
/// not return.
pub fn now() noreturn {
    asm volatile ("cli");
    for (methods) |m| {
        m.run();
        pause();
    }
    while (true) asm volatile ("hlt");
}

/// PIIX3's Reset Control Register: bit 1 asks for a hard reset, bit 2 makes
/// it happen. Writing 0x02 then 0x06 is the documented sequence.
fn resetControlRegister() void {
    port.outb(0xCF9, 0x02);
    port.outb(0xCF9, 0x06);
}

/// The 8042's "pulse output line 0", which is wired to the CPU's reset.
fn keyboardController() void {
    var waited: u32 = 0;
    while (port.inb(0x64) & 0x02 != 0 and waited < 100_000) : (waited += 1) {}
    port.outb(0x64, 0xFE);
}

/// An interrupt table with nothing in it, then an exception: the exception
/// cannot be delivered, nor the double fault that follows, and the third
/// fault resets the processor.
fn tripleFault() void {
    const Pointer = packed struct { limit: u16, base: u64 };
    const empty = Pointer{ .limit = 0, .base = 0 };
    asm volatile (
        \\lidt (%[p])
        \\int3
        :
        : [p] "r" (&empty),
        : .{ .memory = true });
}

/// Gives a reset a moment to land: on hardware the reset is not
/// instantaneous after the write.
pub fn pause() void {
    var i: u32 = 0;
    while (i < 50_000_000) : (i += 1) asm volatile ("pause");
}
