//! **THE MACHINE'S RAM, HANDED OUT A PAGE AT A TIME — AND TAKEN BACK.**
//!
//! This is the seam. On Linux the general-purpose allocator sits on
//! `std.heap.page_allocator`, which is `mmap`; the kernel owns the RAM and
//! hands out pages, and everything above it is std's. This machine had no
//! equivalent, so the site's long-lived heap was a `FixedBufferAllocator` over
//! a fixed array — a bump allocator, whose `free` does nothing except in the
//! one case where the block being freed was the last one handed out.
//!
//! That is the difference between a demo and something that can stay up: a
//! server that cannot reuse memory has a clock on it, however little it leaks.
//!
//! So this is the page allocator, and `std.heap.DebugAllocator` — std's own
//! general-purpose allocator, with its size-class buckets, its reuse and its
//! double-free detection — goes on top of it with `backing_allocator` pointed
//! here. The heavy lifting stays in std, which is tested by people who are not
//! us; what this machine has to supply is exactly what Linux supplies, no more.
//!
//! **A BITMAP, NOT A FREE LIST.** One bit per page, living in the front of the
//! region it describes, so nothing here is a fixed array and the size of the
//! heap is the size of the machine. A page's length is not recorded anywhere:
//! `std.mem.Allocator` hands `free` the same slice it was given, so the length
//! comes back with it. Next-fit from a rotating cursor keeps the common case —
//! allocate, free, allocate — from re-scanning the whole bitmap.
//!
//! **NOTHING HERE IS SILENT.** Freeing a page that is already free, or one
//! outside the region, is a bug that would otherwise hand the same memory to
//! two owners and corrupt whichever wrote second. Both panic, which on this
//! machine prints and stops it — the same mechanism as any other panic, rather
//! than a second way to fail.

const std = @import("std");
const pvh = @import("pvh.zig");

const Alignment = std.mem.Alignment;

pub const page_size: usize = 4096;

pub const Pages = struct {
    /// The first page handed out, page-aligned, past the bitmap.
    base: usize = 0,
    /// How many pages there are from `base`.
    count: usize = 0,
    /// One bit per page; bit set means taken.
    bitmap: []u8 = &.{},
    /// Where the next search starts.
    cursor: usize = 0,
    /// The most pages ever taken at once — what says whether the machine is
    /// actually reusing memory or merely has not run out yet.
    high_water: usize = 0,
    taken: usize = 0,

    /// Carves a region into a bitmap and the pages it describes.
    ///
    /// **THE BITMAP COMES OUT OF THE REGION ITSELF.** One bit per 4096 bytes
    /// costs 1/32768th of the memory — 16 KB to describe 512 MB — so the cost
    /// of describing the heap is paid by the heap.
    pub fn init(region: pvh.Region) Pages {
        const start = std.mem.alignForward(u64, region.start, page_size);
        if (region.len == 0 or start >= region.start +| region.len) return .{};
        const usable = region.start + region.len - start;
        const total_pages: usize = @intCast(usable / page_size);
        if (total_pages < 2) return .{};

        // Pages for the bitmap: one bit each, rounded up to whole pages.
        const bitmap_bytes = (total_pages + 7) / 8;
        const bitmap_pages = (bitmap_bytes + page_size - 1) / page_size;
        if (bitmap_pages >= total_pages) return .{};

        const bitmap: []u8 = @as([*]u8, @ptrFromInt(@as(usize, @intCast(start))))[0..bitmap_bytes];
        @memset(bitmap, 0);
        return .{
            .base = @as(usize, @intCast(start)) + bitmap_pages * page_size,
            .count = total_pages - bitmap_pages,
            .bitmap = bitmap,
            .cursor = 0,
        };
    }

    pub fn allocator(self: *Pages) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub const Stats = struct {
        pages_total: usize,
        pages_taken: usize,
        pages_high_water: usize,
        bytes_total: usize,
        bytes_taken: usize,
    };

    /// Forgets the peak, so a measurement can start from here. The peak is the
    /// only number that is about a span of time rather than about now.
    pub fn resetPeak(self: *Pages) void {
        self.high_water = self.taken;
    }

    pub fn stats(self: *const Pages) Stats {
        return .{
            .pages_total = self.count,
            .pages_taken = self.taken,
            .pages_high_water = self.high_water,
            .bytes_total = self.count * page_size,
            .bytes_taken = self.taken * page_size,
        };
    }

    fn isTaken(self: *const Pages, i: usize) bool {
        return self.bitmap[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) != 0;
    }

    fn set(self: *Pages, i: usize, on: bool) void {
        const mask = @as(u8, 1) << @intCast(i & 7);
        if (on) self.bitmap[i >> 3] |= mask else self.bitmap[i >> 3] &= ~mask;
    }

    fn pagesFor(len: usize) usize {
        return (len + page_size - 1) / page_size;
    }

    fn indexOf(self: *const Pages, ptr: [*]u8) ?usize {
        const addr = @intFromPtr(ptr);
        if (addr < self.base) return null;
        const off = addr - self.base;
        if (off % page_size != 0) return null;
        const i = off / page_size;
        return if (i < self.count) i else null;
    }

    /// Are `n` pages from `i` all free and inside the region?
    fn freeRun(self: *const Pages, i: usize, n: usize) bool {
        if (i + n > self.count) return false;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (self.isTaken(i + k)) return false;
        }
        return true;
    }

    fn claim(self: *Pages, i: usize, n: usize) void {
        var k: usize = 0;
        while (k < n) : (k += 1) self.set(i + k, true);
        self.taken += n;
        if (self.taken > self.high_water) self.high_water = self.taken;
    }

    fn release(self: *Pages, i: usize, n: usize) void {
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (!self.isTaken(i + k))
                @panic("a page was freed twice: two owners would now hold the same memory");
            self.set(i + k, false);
        }
        self.taken -= n;
    }

    /// The first page of a run of `n` free pages whose ADDRESS suits
    /// `alignment`, searched from the cursor and wrapping exactly once.
    ///
    /// **THE ALIGNMENT IS OF THE ADDRESS, NOT OF THE INDEX.** The first
    /// version strode through indices that were multiples of the alignment and
    /// checked the address afterwards; where the region itself did not start on
    /// that boundary, no index it ever looked at qualified, and a 64 KB-aligned
    /// request failed with a heap that was almost entirely free. So the first
    /// candidate is computed from the address, and the stride goes from there.
    ///
    /// And the wrap is counted in CANDIDATES rather than in pages examined —
    /// the first version could exhaust its budget on candidates too near the
    /// end to hold `n` pages and report that a mostly empty heap was full.
    fn find(self: *Pages, n: usize, alignment: Alignment) ?usize {
        if (n == 0 or n > self.count) return null;
        const want = @max(page_size, alignment.toByteUnits());
        const step = want / page_size;
        const first_addr = std.mem.alignForward(usize, self.base, want);
        const first = (first_addr - self.base) / page_size;
        if (first >= self.count) return null;

        const candidates = (self.count - first + step - 1) / step;
        const from = if (self.cursor <= first) 0 else (self.cursor - first + step - 1) / step;
        var c: usize = 0;
        while (c < candidates) : (c += 1) {
            const i = first + ((from + c) % candidates) * step;
            if (i + n <= self.count and self.freeRun(i, n)) return i;
        }
        return null;
    }
};

/// **THE MACHINE'S ONE PAGE HEAP.**
///
/// `std.heap.page_allocator` is defined as `root.os.heap.page_allocator` when
/// the root file declares one — zig's own hook for a target that has to supply
/// its own. So a kernel here writes
///
///     pub const os = struct {
///         pub const heap = struct {
///             pub const page_allocator = metal.pages.allocator;
///         };
///     };
///
/// and from then on every allocator in std is on this machine's RAM, with
/// nothing passed down by hand. That is the same arrangement Linux has: there
/// `page_allocator` is mmap, and the general-purpose allocator above it is
/// std's either way.
///
/// It starts empty, and every allocation fails until the kernel has read the
/// memory map and called `bring` — which is the honest state of a machine that
/// has not yet found its RAM.
pub var global: Pages = .{};

pub const allocator = std.mem.Allocator{ .ptr = &global, .vtable = &vtable };

/// Gives the machine's RAM to the page heap. Answers what it got.
pub fn bring(region: pvh.Region) Pages.Stats {
    global = Pages.init(region);
    return global.stats();
}

pub fn stats() Pages.Stats {
    return global.stats();
}

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const self: *Pages = @ptrCast(@alignCast(ctx));
    if (len == 0) return null;
    const n = Pages.pagesFor(len);
    const i = self.find(n, alignment) orelse return null;
    self.claim(i, n);
    self.cursor = (i + n) % @max(1, self.count);
    return @ptrFromInt(self.base + i * page_size);
}

/// Grows or shrinks where it stands. Growing works when the pages after it are
/// free — which, page-granular, is most of the time for the last thing handed
/// out, and is what lets an ArrayList grow without copying.
fn resize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    const self: *Pages = @ptrCast(@alignCast(ctx));
    if (new_len == 0) return false;
    const i = self.indexOf(memory.ptr) orelse return false;
    const have = Pages.pagesFor(memory.len);
    const want = Pages.pagesFor(new_len);
    if (want == have) return true;
    if (want < have) {
        self.release(i + want, have - want);
        return true;
    }
    if (!self.freeRun(i + have, want - have)) return false;
    self.claim(i + have, want - have);
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    // Moving is the caller's business: it knows whether the bytes have to come
    // along. In place or not at all.
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    const self: *Pages = @ptrCast(@alignCast(ctx));
    if (memory.len == 0) return;
    const i = self.indexOf(memory.ptr) orelse
        @panic("a pointer that did not come from this heap was freed to it");
    self.release(i, Pages.pagesFor(memory.len));
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// All of this runs on the host: the allocator is told which memory it owns, so
// a heap-allocated buffer stands in for the machine's RAM and every question
// can be asked here rather than in QEMU.
//
// **std's OWN CONTRACT TESTS RUN FIRST.** `std.heap.testAllocator` and its
// three siblings are what zig checks its own allocators with; passing them is
// what entitles std's general-purpose allocator to sit on top of this one.

const testing = std.testing;

/// A stand-in for the machine's RAM.
const Ram = struct {
    memory: []align(page_size) u8,
    pages: Pages,

    fn init(bytes: usize) !Ram {
        const memory = try testing.allocator.alignedAlloc(u8, .fromByteUnits(page_size), bytes);
        // NOT zeroed: the loader does not zero RAM, and neither does this.
        @memset(memory, 0xCD);
        var r = Ram{ .memory = memory, .pages = undefined };
        r.pages = Pages.init(.{ .start = @intFromPtr(memory.ptr), .len = bytes });
        return r;
    }

    fn deinit(self: *Ram) void {
        testing.allocator.free(self.memory);
    }
};

test "std's own allocator contract, on top of these pages" {
    var ram = try Ram.init(4 * 1024 * 1024);
    defer ram.deinit();
    const a = ram.pages.allocator();
    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
    // And everything it took, it gave back.
    try testing.expectEqual(@as(usize, 0), ram.pages.stats().pages_taken);
}

test "std's general-purpose allocator runs on these pages, and stops growing" {
    // **THE SEAM ITSELF, AND THE QUESTION THAT DECIDES DEPLOYABILITY.** The
    // site's long-lived heap becomes std's DebugAllocator over these pages.
    // Sixty rounds of "allocate three hundred, free three hundred at random" is
    // a server's shape — a working set that churns. If the high-water mark
    // plateaus, the machine can run indefinitely; if it climbs, it has a clock
    // on it however little it leaks, which is what a bump allocator has.
    var ram = try Ram.init(64 * 1024 * 1024);
    defer ram.deinit();
    var gpa: std.heap.DebugAllocator(.{
        .backing_allocator_zeroes = false,
        .stack_trace_frames = 0,
        .thread_safe = false,
        .safety = false,
    }) = .{ .backing_allocator = ram.pages.allocator() };
    const a = gpa.allocator();

    ram.pages.resetPeak();
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var held: std.ArrayList([]u8) = .empty;
    var settled: usize = 0;
    for (0..60) |round| {
        for (0..300) |_| {
            const buf = try a.alloc(u8, 1 + rand.uintLessThan(usize, 4000));
            @memset(buf, 0x5A);
            try held.append(a, buf);
        }
        var k: usize = 0;
        while (k < 300 and held.items.len > 0) : (k += 1) {
            a.free(held.swapRemove(rand.uintLessThan(usize, held.items.len)));
        }
        if (round == 9) settled = ram.pages.stats().pages_high_water;
    }
    const finished = ram.pages.stats().pages_high_water;

    // Some rise after the tenth round is fragmentation settling, not growth; a
    // quarter of the plateau is generous and still nowhere near linear. Fifty
    // more rounds of a heap that never reused anything would be ten times this.
    try testing.expect(finished <= settled + settled / 4);

    for (held.items) |buf| a.free(buf);
    held.deinit(a);
    // std's allocator holds its own table of large allocations in pages from
    // here, and gives them back in deinit — so the heap is empty AFTER that.
    try testing.expectEqual(std.heap.Check.ok, gpa.deinit());
    try testing.expectEqual(@as(usize, 0), ram.pages.stats().pages_taken);
}

test "a page handed out is page-aligned, and no two overlap" {
    var ram = try Ram.init(1024 * 1024);
    defer ram.deinit();
    const a = ram.pages.allocator();
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(testing.allocator);
    for (0..32) |_| {
        const buf = try a.alloc(u8, 5000); // two pages
        try testing.expectEqual(@as(usize, 0), @intFromPtr(buf.ptr) % page_size);
        const first = @intFromPtr(buf.ptr) / page_size;
        for (0..2) |k| {
            try testing.expect(!seen.contains(first + k)); // never handed out twice
            try seen.put(testing.allocator, first + k, {});
        }
    }
}

test "memory freed is memory that can be had again" {
    var ram = try Ram.init(256 * 1024);
    defer ram.deinit();
    const a = ram.pages.allocator();
    const total = ram.pages.stats().pages_total;

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var got: std.ArrayList([]u8) = .empty;
        defer got.deinit(testing.allocator);
        while (a.alloc(u8, page_size)) |buf| {
            try got.append(testing.allocator, buf);
        } else |_| {}
        // Every page, every round — which cannot happen if freeing is a no-op.
        try testing.expectEqual(total, got.items.len);
        for (got.items) |buf| a.free(buf);
        try testing.expectEqual(@as(usize, 0), ram.pages.stats().pages_taken);
    }
    // 20 rounds of taking all of it, and the most ever held at once is all of
    // it: the bump allocator this replaces would have run out in round two.
    try testing.expectEqual(total, ram.pages.stats().pages_high_water);
}

test "a hole between two taken pages is used again" {
    var ram = try Ram.init(256 * 1024);
    defer ram.deinit();
    const a = ram.pages.allocator();
    var blocks: [16][]u8 = undefined;
    for (&blocks) |*b| b.* = try a.alloc(u8, page_size);
    for (0..blocks.len) |i| {
        if (i % 2 == 0) a.free(blocks[i]);
    }
    const taken = ram.pages.stats().pages_taken;
    for (0..blocks.len) |i| {
        if (i % 2 == 0) blocks[i] = try a.alloc(u8, page_size);
    }
    // The odd ones are still held, so the even ones must have come from the
    // holes: nothing new was needed.
    try testing.expectEqual(taken + blocks.len / 2, ram.pages.stats().pages_taken);
    for (blocks) |b| a.free(b);
}

test "running out is an answer, not a crash — and it recovers" {
    var ram = try Ram.init(64 * 1024);
    defer ram.deinit();
    const a = ram.pages.allocator();
    const total = ram.pages.stats().pages_total;
    const all = try a.alloc(u8, total * page_size);
    try testing.expectEqual(@as(?[]u8, null), a.alloc(u8, 1) catch null);
    a.free(all);
    const again = try a.alloc(u8, total * page_size);
    a.free(again);
}

test "an alignment larger than a page is honored" {
    var ram = try Ram.init(1024 * 1024);
    defer ram.deinit();
    const a = ram.pages.allocator();
    // Take one page first so the aligned run cannot simply be the first one.
    const pin = try a.alloc(u8, 1);
    for (0..8) |_| {
        const buf = try a.alignedAlloc(u8, .fromByteUnits(64 * 1024), 100);
        try testing.expectEqual(@as(usize, 0), @intFromPtr(buf.ptr) % (64 * 1024));
    }
    a.free(pin);
}

test "growing in place succeeds only when the next pages are free" {
    var ram = try Ram.init(256 * 1024);
    defer ram.deinit();
    const a = ram.pages.allocator();
    var first = try a.alloc(u8, page_size);
    const blocker = try a.alloc(u8, page_size);
    // The page after `first` belongs to `blocker`, so there is nowhere to grow.
    try testing.expect(!a.resize(first, page_size * 2));
    a.free(blocker);
    try testing.expect(a.resize(first, page_size * 2));
    first.len = page_size * 2;
    // Shrinking always works, and gives the pages back.
    const before = ram.pages.stats().pages_taken;
    try testing.expect(a.resize(first, page_size));
    try testing.expectEqual(before - 1, ram.pages.stats().pages_taken);
}

test "a soak: the bytes in a block are the bytes that block was given" {
    // **THE CHECK THAT CATCHES HANDING THE SAME MEMORY TO TWO OWNERS.** Every
    // block is filled with a byte that identifies it and re-read before it is
    // freed; if a page is ever handed out twice, one of the two writes wins and
    // the other block reads back wrong.
    var ram = try Ram.init(2 * 1024 * 1024);
    defer ram.deinit();
    const a = ram.pages.allocator();

    var prng = std.Random.DefaultPrng.init(0x50A4);
    const rand = prng.random();
    const Held = struct { buf: []u8, tag: u8 };
    var held: std.ArrayList(Held) = .empty;
    defer held.deinit(testing.allocator);

    var tag: u8 = 1;
    for (0..4000) |_| {
        if (held.items.len > 0 and rand.boolean()) {
            const i = rand.uintLessThan(usize, held.items.len);
            const h = held.swapRemove(i);
            for (h.buf) |b| try testing.expectEqual(h.tag, b);
            a.free(h.buf);
        } else {
            const len = 1 + rand.uintLessThan(usize, 12 * 1024);
            const buf = a.alloc(u8, len) catch continue;
            tag = tag +% 1;
            if (tag == 0) tag = 1;
            @memset(buf, tag);
            try held.append(testing.allocator, .{ .buf = buf, .tag = tag });
        }
    }
    for (held.items) |h| {
        for (h.buf) |b| try testing.expectEqual(h.tag, b);
        a.free(h.buf);
    }
    try testing.expectEqual(@as(usize, 0), ram.pages.stats().pages_taken);
    // 4000 operations never needed more than the region holds.
    try testing.expect(ram.pages.stats().pages_high_water <= ram.pages.stats().pages_total);
}

test "the bitmap is paid for out of the region it describes" {
    var ram = try Ram.init(1024 * 1024);
    defer ram.deinit();
    const s = ram.pages.stats();
    // 256 pages need 32 bytes of bitmap, which is one page.
    try testing.expectEqual(@as(usize, 255), s.pages_total);
    try testing.expect(ram.pages.base >= @intFromPtr(ram.memory.ptr) + page_size);
}

test "a region too small to describe is no region at all" {
    var pages = Pages.init(.{ .start = 0x100000, .len = 0 });
    try testing.expectEqual(@as(usize, 0), pages.stats().pages_total);
    try testing.expectEqual(@as(?[*]u8, null), pages.allocator().rawAlloc(1, .@"1", 0));

    var one = Pages.init(.{ .start = 0x100000, .len = page_size });
    try testing.expectEqual(@as(usize, 0), one.stats().pages_total);
}
