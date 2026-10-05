//! The timestamp counter: a 64-bit count the CPU advances at a fixed rate from
//! reset. Monotonic and cheap to read — and its RATE is not known until it is
//! measured against something whose rate is (pit.zig).

/// **THE READ CARRIES A MARK FOR METAL-VMM**, which makes each `rdtsc` a
/// question it answers from its own clock by rewriting the two bytes in guest
/// memory. A bare `0F 31` is too short to search for: gopher.elf (2026-10-05)
/// had 87 such pairs in its text and 77 `rdtsc`s, and rewriting the other ten
/// corrupted the instructions they sat inside. So the read is preceded by
/// `mov $"mvmc", %ecx` (`B9 6D 76 6D 63`), and metal-vmm rewrites only an
/// `rdtsc` right after it. It costs a register and a cycle. A NOP would cost
/// neither, but zig's own x86 backend (Debug host tests) encodes no form of
/// `nopl` with a displacement, nor `.byte`.
pub const mark = [5]u8{ 0xB9, 'm', 'v', 'm', 'c' };

pub fn read() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile ("movl $0x636d766d, %%ecx\n\trdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .ecx = true });
    return (@as(u64, hi) << 32) | lo;
}
