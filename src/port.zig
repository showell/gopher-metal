//! x86 port I/O: the eight-bit bus the PC's oldest devices still sit on —
//! the serial port, the CMOS clock, the interval timer.
//!
//! **A HOST TEST HAS NO PORTS.** Its process may not touch them, and LLVM
//! will not even compile the `N{dx}` constraint for a hosted target, so in a
//! test build each of these stops the test, saying so. A host test reaches
//! one only through a path that would end the machine (`serial.fail`), and
//! that is a failed test there too.

pub fn outb(port: u16, value: u8) void {
    if (@import("builtin").is_test) @panic("port I/O in a host test");
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    if (@import("builtin").is_test) @panic("port I/O in a host test");
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (port),
    );
}

pub fn outw(port: u16, value: u16) void {
    if (@import("builtin").is_test) @panic("port I/O in a host test");
    asm volatile ("outw %[v], %[p]"
        :
        : [v] "{ax}" (value),
          [p] "N{dx}" (port),
    );
}

pub fn inw(port: u16) u16 {
    if (@import("builtin").is_test) @panic("port I/O in a host test");
    return asm volatile ("inw %[p], %[r]"
        : [r] "={ax}" (-> u16),
        : [p] "N{dx}" (port),
    );
}

pub fn outl(port: u16, value: u32) void {
    if (@import("builtin").is_test) @panic("port I/O in a host test");
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (value),
          [p] "N{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    if (@import("builtin").is_test) @panic("port I/O in a host test");
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "N{dx}" (port),
    );
}
