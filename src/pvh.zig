//! What the loader told us on the way in.
//!
//! **PVH HANDS THE KERNEL A MEMORY MAP, AND WE WERE THROWING IT AWAY.** The
//! entry point is reached in 32-bit protected mode with `%ebx` holding a
//! `struct hvm_start_info *` — magic, a few pointers, and (since version 1) an
//! e820-style table of what memory this machine actually has. Everything this
//! kernel allocated until now came out of fixed arrays in `.bss`, which means
//! the size of the site's heap was a number somebody typed, and `-m 512`
//! bought nothing.
//!
//! This reads the table. `src/pages.zig` turns it into memory that can be
//! handed out and given back.
//!
//! **THE TABLE IS NOT TRUSTED.** It is data from outside, read before anything
//! else runs, so every field is checked: the magic, the version, a table
//! pointer that is not null, an entry count that is not absurd, and each
//! region clipped to what a 64-bit machine can address. A region that overlaps
//! this kernel's own image is cut down rather than handed out — the loader
//! reports the RAM, not what is in it.

const std = @import("std");

pub const magic: u32 = 0x336ec578; // "xEn3"

/// The header, exactly as the PVH boot ABI lays it out.
pub const StartInfo = extern struct {
    magic: u32,
    version: u32,
    flags: u32,
    nr_modules: u32,
    modlist_paddr: u64,
    cmdline_paddr: u64,
    rsdp_paddr: u64,
    // version 1 and later
    memmap_paddr: u64,
    memmap_entries: u32,
    reserved: u32,
};

pub const MemmapEntry = extern struct {
    addr: u64,
    size: u64,
    type: u32,
    reserved: u32,

    pub const ram: u32 = 1;
};

pub const Error = error{
    /// %ebx was null: nothing was handed to us at all.
    NoStartInfo,
    /// The magic is not PVH's. Whatever that pointer is, it is not this.
    NotPvh,
    /// Version 0 has no memmap field, and no other way to ask.
    NoMemoryMap,
};

/// One usable span of RAM.
pub const Region = struct { start: u64, len: u64 };

/// The largest usable region, which is where this machine's heap goes.
///
/// **ONE REGION, NOT A LIST**, because one is what the allocator above needs
/// and because on every machine this runs on the RAM above 1 MB is a single
/// span. Taking the largest rather than the first is what makes that an
/// observation instead of an assumption: if a machine ever reports several,
/// this takes the biggest and says how much it ignored.
pub fn largestFree(entries: []const MemmapEntry, reserve: Region) Region {
    var best = Region{ .start = 0, .len = 0 };
    for (entries) |e| {
        if (e.type != MemmapEntry.ram) continue;
        for (cut(.{ .start = e.addr, .len = e.size }, reserve)) |piece| {
            if (piece.len > best.len) best = piece;
        }
    }
    return best;
}

/// How much RAM the machine reports in total, whatever we can use of it — the
/// number to compare against `-m`.
pub fn totalRam(entries: []const MemmapEntry) u64 {
    var total: u64 = 0;
    for (entries) |e| {
        if (e.type == MemmapEntry.ram) total += e.size;
    }
    return total;
}

/// `region` with `hole` removed: up to two pieces, and a zero-length piece
/// where there is nothing left. Returning both is what makes a hole in the
/// MIDDLE of a region safe — the naive version keeps the part before the hole
/// and silently drops everything after it.
pub fn cut(region: Region, hole: Region) [2]Region {
    const r_end = region.start +| region.len;
    const h_end = hole.start +| hole.len;
    if (hole.len == 0 or h_end <= region.start or hole.start >= r_end) {
        return .{ region, .{ .start = 0, .len = 0 } };
    }
    const before = Region{
        .start = region.start,
        .len = if (hole.start > region.start) hole.start - region.start else 0,
    };
    const after = Region{
        .start = if (h_end > region.start) h_end else region.start,
        .len = if (r_end > h_end) r_end - h_end else 0,
    };
    return .{ before, after };
}

/// Reads the header the loader left, checking every field it is about to use.
pub fn read(start_info: u64) Error![]const MemmapEntry {
    if (start_info == 0) return Error.NoStartInfo;
    const info: *const StartInfo = @ptrFromInt(@as(usize, @intCast(start_info)));
    if (info.magic != magic) return Error.NotPvh;
    if (info.version < 1 or info.memmap_paddr == 0 or info.memmap_entries == 0)
        return Error.NoMemoryMap;
    const table: [*]const MemmapEntry = @ptrFromInt(@as(usize, @intCast(info.memmap_paddr)));
    return table[0..info.memmap_entries];
}

/// The command line the loader was given (QEMU's `-append`), or "" when
/// there is none. It is a C string somewhere in low memory.
pub fn commandLine(start_info: u64) []const u8 {
    if (start_info == 0) return "";
    const info: *const StartInfo = @ptrFromInt(@as(usize, @intCast(start_info)));
    if (info.magic != magic or info.cmdline_paddr == 0) return "";
    const text: [*:0]const u8 = @ptrFromInt(@as(usize, @intCast(info.cmdline_paddr)));
    return std.mem.span(text);
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// `cut` and `largestFree` are the whole decision, and they run on a slice that
// the caller supplies — so the host can ask them every question that matters
// without a machine. `read` needs real addresses and is judged in QEMU, where
// probe/run.sh varies `-m` and the kernel must report what was asked for.

const testing = std.testing;

fn ram(start: u64, len: u64) MemmapEntry {
    return .{ .addr = start, .size = len, .type = MemmapEntry.ram, .reserved = 0 };
}

fn reserved(start: u64, len: u64) MemmapEntry {
    return .{ .addr = start, .size = len, .type = 2, .reserved = 0 };
}

test "a hole in the middle leaves BOTH sides" {
    const pieces = cut(.{ .start = 0, .len = 100 }, .{ .start = 40, .len = 10 });
    try testing.expectEqual(Region{ .start = 0, .len = 40 }, pieces[0]);
    try testing.expectEqual(Region{ .start = 50, .len = 50 }, pieces[1]);
}

test "a hole at either end leaves one side" {
    const at_start = cut(.{ .start = 0, .len = 100 }, .{ .start = 0, .len = 40 });
    try testing.expectEqual(@as(u64, 0), at_start[0].len);
    try testing.expectEqual(Region{ .start = 40, .len = 60 }, at_start[1]);

    const at_end = cut(.{ .start = 0, .len = 100 }, .{ .start = 60, .len = 40 });
    try testing.expectEqual(Region{ .start = 0, .len = 60 }, at_end[0]);
    try testing.expectEqual(@as(u64, 0), at_end[1].len);
}

test "a hole that misses the region changes nothing" {
    const r = Region{ .start = 1000, .len = 100 };
    try testing.expectEqual(r, cut(r, .{ .start = 0, .len = 1000 })[0]);
    try testing.expectEqual(r, cut(r, .{ .start = 1100, .len = 100 })[0]);
    try testing.expectEqual(r, cut(r, .{ .start = 1050, .len = 0 })[0]);
}

test "a hole that swallows the region leaves nothing" {
    const pieces = cut(.{ .start = 10, .len = 10 }, .{ .start = 0, .len = 100 });
    try testing.expectEqual(@as(u64, 0), pieces[0].len);
    try testing.expectEqual(@as(u64, 0), pieces[1].len);
}

test "the largest free span skips what is not RAM" {
    const entries = [_]MemmapEntry{
        ram(0, 0x9FC00), // the usual low memory
        reserved(0xF0000, 0x10000), // and the usual hole
        ram(0x100000, 512 * 1024 * 1024),
    };
    const best = largestFree(&entries, .{ .start = 0, .len = 0 });
    try testing.expectEqual(@as(u64, 0x100000), best.start);
    try testing.expectEqual(@as(u64, 512 * 1024 * 1024), best.len);
}

test "the kernel's own image is cut out of what is handed back" {
    const entries = [_]MemmapEntry{ram(0x100000, 512 * 1024 * 1024)};
    // A kernel loaded at 1 MB, 40 MB of it.
    const best = largestFree(&entries, .{ .start = 0x100000, .len = 40 * 1024 * 1024 });
    try testing.expectEqual(@as(u64, 0x100000 + 40 * 1024 * 1024), best.start);
    try testing.expectEqual(@as(u64, 512 * 1024 * 1024 - 40 * 1024 * 1024), best.len);
}

test "a kernel in the MIDDLE of RAM still leaves the bigger half" {
    const entries = [_]MemmapEntry{ram(0, 1000)};
    const best = largestFree(&entries, .{ .start = 100, .len = 100 });
    try testing.expectEqual(@as(u64, 200), best.start);
    try testing.expectEqual(@as(u64, 800), best.len);
}

test "no RAM at all is a region of nothing, not a crash" {
    const entries = [_]MemmapEntry{reserved(0, 1000)};
    try testing.expectEqual(@as(u64, 0), largestFree(&entries, .{ .start = 0, .len = 0 }).len);
    try testing.expectEqual(@as(u64, 0), largestFree(&.{}, .{ .start = 0, .len = 0 }).len);
}

test "the total is every RAM entry, including the ones too small to use" {
    const entries = [_]MemmapEntry{
        ram(0, 0x9FC00),
        reserved(0xF0000, 0x10000),
        ram(0x100000, 512 * 1024 * 1024),
    };
    try testing.expectEqual(@as(u64, 0x9FC00 + 512 * 1024 * 1024), totalRam(&entries));
}

test "a region at the top of the address space does not wrap" {
    const huge = Region{ .start = std.math.maxInt(u64) - 10, .len = 100 };
    const pieces = cut(huge, .{ .start = 0, .len = 10 });
    try testing.expectEqual(huge, pieces[0]);
}
