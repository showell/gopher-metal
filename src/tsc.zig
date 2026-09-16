//! The timestamp counter: a 64-bit count the CPU advances at a fixed rate from
//! reset. Monotonic and cheap to read — and its RATE is not known until it is
//! measured against something whose rate is (pit.zig).

pub fn read() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}
