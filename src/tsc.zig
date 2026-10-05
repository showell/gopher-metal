//! The timestamp counter: a 64-bit count the CPU advances at a fixed rate from
//! reset. Monotonic and cheap to read — and its RATE is not known until it is
//! measured against something whose rate is (pit.zig).

/// **THE READ CARRIES A MARK FOR METAL-VMM**, which makes each `rdtsc` a
/// question it answers from its own clock by rewriting the two bytes in guest
/// memory. A bare `0F 31` is too short to search for: today's gopher.elf has
/// 87 such pairs in its text and 77 `rdtsc`s, and rewriting the other ten
/// corrupted the instructions they sat inside. So the read is preceded by a
/// 7-byte NOP whose displacement spells "mvmc" (`0F 1F 80 6D 76 6D 63`), and
/// metal-vmm rewrites only an `rdtsc` that follows it. Elsewhere it is a NOP.
pub const mark = [7]u8{ 0x0F, 0x1F, 0x80, 'm', 'v', 'm', 'c' };

pub fn read() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile ("nopl 0x636d766d(%%rax)\n\trdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}
