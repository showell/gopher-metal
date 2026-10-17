//! **WHEN THE LOCAL APIC IS REFUSED, AND HOW LONG A REST IS** (metal-vmm
//! QUEUE 198.2, 197.3 #10): interrupts.zig's decisions, pure, so tier 0
//! holds them. interrupts.zig reads CPUID and the MSR and does the writes;
//! only the PC-shaped machine and a droplet reach it.

/// Why the local APIC could not be used, for the log.
pub const Refusal = enum { no_apic, no_tsc_deadline, apic_elsewhere, x2apic };

/// Where this kernel expects the APIC's registers (its only mapping of them).
pub const lapic_base: u64 = 0xFEE0_0000;

/// `edx` and `ecx` from CPUID leaf 1; `apic_base`, the IA32_APIC_BASE MSR.
pub fn refusal(edx: u32, ecx: u32, apic_base: u64) ?Refusal {
    if (edx & (1 << 9) == 0) return .no_apic;
    if (ecx & (1 << 24) == 0) return .no_tsc_deadline;
    // The base is bits 12 and up, as wide as the processor's physical
    // addresses: an APIC moved above 4 GiB is elsewhere too.
    if (apic_base & 0x000F_FFFF_FFFF_F000 != lapic_base) return .apic_elsewhere;
    // In x2APIC mode the registers are not in memory at all (SDM §11.12).
    if (apic_base & (1 << 10) != 0) return .x2apic;
    return null;
}

/// One rest's length in TSC ticks, for a rest of `slice_ns`. Zero (a clock
/// slower than one tick a rest) leaves the machine unarmed: it spins, and
/// never halts without a deadline to wake it.
pub fn sliceTicks(tsc_hz: u64, slice_ns: u64) u64 {
    return tsc_hz / (1_000_000_000 / slice_ns);
}

/// **A REST'S LENGTH IN TSC TICKS, FOR ANY LENGTH** (DESIGN-sleep.md): `ns`
/// times `tsc_hz` is past u64 for a 60-hour rest at 3 GHz, so the product
/// is u128. Rounded up: `io.ticksToNs` truncates, so a deadline a tick short
/// would read as before the time it was asked for. Never 0, which disarms
/// IA32_TSC_DEADLINE; past u64, the most there is.
pub fn ticksOf(tsc_hz: u64, ns: u64) u64 {
    const product = @as(u128, ns) * tsc_hz;
    const ticks = (product + std.time.ns_per_s - 1) / std.time.ns_per_s;
    return @intCast(@max(1, @min(ticks, std.math.maxInt(u64))));
}

/// The vectors whose exception pushes an error code before the return
/// address (SDM vol. 3 §6.15, table 6-1): #DF, #TS, #NP, #SS, #GP, #PF,
/// #AC, #CP, #VC, #SX.
pub fn hasErrorCode(vector: usize) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

const std = @import("std");
const testing = std.testing;

const apic: u32 = 1 << 9;
const deadline: u32 = 1 << 24;
const enabled: u64 = 1 << 11;

test "the local APIC is refused for each reason, in order, and taken only where this kernel maps it (metal-vmm QUEUE 198.2)" {
    try testing.expectEqual(@as(?Refusal, null), refusal(apic, deadline, lapic_base | enabled));
    // The bootstrap processor bit (8) is no reason to refuse.
    try testing.expectEqual(@as(?Refusal, null), refusal(apic, deadline, lapic_base | (1 << 8)));
    try testing.expectEqual(@as(?Refusal, .no_apic), refusal(0, deadline, lapic_base));
    try testing.expectEqual(@as(?Refusal, .no_tsc_deadline), refusal(apic, 0, lapic_base));
    try testing.expectEqual(@as(?Refusal, .apic_elsewhere), refusal(apic, deadline, 0xFEC0_0000));
    try testing.expectEqual(@as(?Refusal, .x2apic), refusal(apic, deadline, lapic_base | (1 << 10)));
    // Moved above 4 GiB, with the low bits where ours are: elsewhere.
    try testing.expectEqual(@as(?Refusal, .apic_elsewhere), refusal(apic, deadline, (1 << 32) | lapic_base));
}

test "a rest is a millisecond of the clock's ticks, and a clock too slow to count one leaves the machine unarmed" {
    try testing.expectEqual(@as(u64, 2_000_000), sliceTicks(2_000_000_000, 1_000_000));
    try testing.expectEqual(@as(u64, 0), sliceTicks(999, 1_000_000));
    try testing.expectEqual(@as(u64, 1), sliceTicks(1000, 1_000_000));
}

test "a rest of 60 ms, 60 s or 60 h is its exact ticks, past what u64 multiplies (DESIGN-sleep.md)" {
    const hz: u64 = 3_000_000_000;
    try testing.expectEqual(@as(u64, 180_000_000), ticksOf(hz, 60 * std.time.ns_per_ms));
    try testing.expectEqual(@as(u64, 180_000_000_000), ticksOf(hz, 60 * std.time.ns_per_s));
    // 60 h: 2.16e14 ns times 3e9 is about 6.5e23, past u64's 1.8e19.
    try testing.expectEqual(@as(u64, 648_000_000_000_000), ticksOf(hz, 60 * std.time.ns_per_hour));
    try testing.expectEqual(ticksOf(hz, std.time.ns_per_ms), 3_000_000);
}

test "a rest's ticks round up, so the deadline never reads as before the time asked for" {
    // 2.5 GHz: 1 ns is 2.5 ticks, so 3; 7 Hz: 1 s is 7 ticks exactly.
    try testing.expectEqual(@as(u64, 3), ticksOf(2_500_000_000, 1));
    try testing.expectEqual(@as(u64, 7), ticksOf(7, std.time.ns_per_s));
    // Read back the way io.ticksToNs reads: truncated, never short of ns.
    const hz: u64 = 2_893_211_017;
    for ([_]u64{ 1, 999, 1_000_001, 60 * std.time.ns_per_s + 7, 60 * std.time.ns_per_hour + 13 }) |ns| {
        const t = ticksOf(hz, ns);
        const back: u128 = @as(u128, t) * std.time.ns_per_s / hz;
        try testing.expect(back >= ns);
        try testing.expect(back - ns < std.time.ns_per_s / hz + 1);
    }
}

test "a rest's ticks are never 0, which disarms the timer, and saturate past u64" {
    try testing.expectEqual(@as(u64, 1), ticksOf(3_000_000_000, 0));
    try testing.expectEqual(@as(u64, 1), ticksOf(0, std.time.ns_per_s));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), ticksOf(std.math.maxInt(u64), std.math.maxInt(u64)));
}

test "the exceptions that push an error code are exactly the SDM's ten" {
    var n: usize = 0;
    for (0..32) |v| {
        if (hasErrorCode(v)) n += 1;
    }
    try testing.expectEqual(@as(usize, 10), n);
    for ([_]usize{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 }) |v| try testing.expect(hasErrorCode(v));
    for ([_]usize{ 0, 1, 3, 6, 7, 9, 15, 16, 18, 19, 20, 32, 0x20 }) |v| try testing.expect(!hasErrorCode(v));
}
