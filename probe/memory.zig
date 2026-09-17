//! **THE MACHINE'S RAM, DISCOVERED AND THEN HANDED OUT.**
//!
//! Everything this kernel allocated used to come out of fixed arrays in
//! `.bss` — the size of the site's heap was a number somebody typed, and
//! `-m 512` bought nothing. The PVH loader has been handing us a memory map
//! all along, in `%ebx`, and this reads it.
//!
//! Three questions, in order:
//!
//!   1. **How much memory does this machine have?** run.sh boots this with
//!      different `-m` and requires the answer to follow — an outside judge,
//!      because QEMU knows what it was told and we do not.
//!   2. **Can it hand out every page and take them all back?** Twice, so the
//!      second round proves the first round's pages really came back.
//!   3. **Does a server's churn plateau?** Sixty rounds of allocate-and-free
//!      through std's general-purpose allocator on top of these pages. A high
//!      water mark that stops rising is a machine that can stay up.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const pvh = metal.pvh;
const pages = metal.pages;
const boot = metal.boot;

comptime {
    _ = metal.boot;
}

/// **NO STACK TRACES: THIS MACHINE HAS NO UNWINDER AND NO DEBUG INFO.** Saying
/// so is not a workaround — it is true, and it is what keeps std's own general
/// purpose allocator from dragging in `std.Io.Threaded` (which wants
/// `getrandom`, `mmap` and an errno) to capture a trace of zero frames.
/// **THIS IS THE SEAM**: std asks the root file for the machine's page
/// allocator, and from here on `std.heap.page_allocator` is this machine's RAM
/// — so std's own general-purpose allocator needs nothing passed to it.
pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = pages.allocator;
    };
};

pub const std_options: std.Options = .{
    .page_size_max = 4096,
    .page_size_min = 4096,
    .allow_stack_tracing = false,
};

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal memory probe\n");

    const entries = boot.memoryMap() catch |e| {
        serial.put("  memory map: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the loader described no memory, so this machine has none it may use");
    };

    serial.put("  memmap entries ");
    serial.putDec(entries.len);
    serial.put("\n  total ram ");
    serial.putDec(pvh.totalRam(entries));
    serial.put("\n");

    const img = boot.image();
    serial.put("  kernel image ");
    serial.putDec(img.start);
    serial.put(" .. ");
    serial.putDec(img.start + img.len);
    serial.put("\n");

    const region = pvh.largestFree(entries, img);
    serial.put("  usable region ");
    serial.putDec(region.start);
    serial.put(" len ");
    serial.putDec(region.len);
    serial.put("\n");
    if (region.len == 0) serial.fail("no usable region of RAM");
    if (region.start < img.start + img.len and region.start + region.len > img.start)
        serial.fail("the usable region overlaps this kernel's own image");

    const carved = pages.bring(region);
    const heap = &pages.global;
    serial.put("  pages ");
    serial.putDec(carved.pages_total);
    serial.put("\n");
    if (carved.pages_total == 0) serial.fail("the region held no pages");

    // ── every page, twice ───────────────────────────────────────────────────
    const alloc = pages.allocator;
    const total = heap.stats().pages_total;
    var round: usize = 0;
    while (round < 2) : (round += 1) {
        var got: usize = 0;
        while (alloc.rawAlloc(pages.page_size, .fromByteUnits(pages.page_size), 0)) |p| {
            // Touch both ends: a page that is not really there faults here
            // rather than silently.
            p[0] = 0xA5;
            p[pages.page_size - 1] = 0x5A;
            got += 1;
        }
        if (got != total) {
            serial.put("  round got ");
            serial.putDec(got);
            serial.put(" of ");
            serial.putDec(total);
            serial.put("\n");
            serial.fail("a round could not take every page, so the last round did not give them all back");
        }
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const p: [*]u8 = @ptrFromInt(heap.base + i * pages.page_size);
            alloc.rawFree(p[0..pages.page_size], .fromByteUnits(pages.page_size), 0);
        }
        if (heap.stats().pages_taken != 0) serial.fail("pages were freed and the heap still holds them");
    }
    serial.put("  every one of the ");
    serial.putDec(total);
    serial.put(" pages taken and given back, twice\n");

    // ── a server's churn, through std's own allocator ───────────────────────
    // Nothing is passed to it: its backing allocator IS std.heap.page_allocator,
    // which is this machine's, because the root file said so.
    var gpa: std.heap.DebugAllocator(.{
        .backing_allocator_zeroes = false,
        .stack_trace_frames = 0,
        .thread_safe = false,
        .safety = false,
        .page_size = pages.page_size,
    }) = .{};
    const a = gpa.allocator();

    // The peak so far is "every page at once", from the round above. What the
    // churn does is a different question, so it starts from here.
    heap.resetPeak();

    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var held: std.ArrayList([]u8) = .empty;
    var settled: usize = 0;
    round = 0;
    while (round < 60) : (round += 1) {
        var n: usize = 0;
        while (n < 300) : (n += 1) {
            const buf = a.alloc(u8, 1 + rand.uintLessThan(usize, 4000)) catch
                serial.fail("the heap ran out during the churn");
            @memset(buf, 0x5A);
            held.append(a, buf) catch serial.fail("the held list would not grow");
        }
        n = 0;
        while (n < 300 and held.items.len > 0) : (n += 1) {
            a.free(held.swapRemove(rand.uintLessThan(usize, held.items.len)));
        }
        if (round == 9) settled = heap.stats().pages_high_water;
    }
    const finished = heap.stats().pages_high_water;
    serial.put("  churn: 18000 allocations, peak ");
    serial.putDec(settled * pages.page_size);
    serial.put(" bytes after 10 rounds, ");
    serial.putDec(finished * pages.page_size);
    serial.put(" after 60\n");
    if (finished > settled + settled / 4)
        serial.fail("the peak kept climbing: this machine cannot reuse what it frees");

    for (held.items) |buf| a.free(buf);
    held.deinit(a);
    // std's allocator keeps its own table of large allocations, in pages from
    // here; it gives those back in deinit, so ask afterwards.
    if (gpa.deinit() != .ok) serial.fail("std's allocator reports a leak of its own");
    if (heap.stats().pages_taken != 0) {
        serial.put("  still held: ");
        serial.putDec(heap.stats().pages_taken);
        serial.put(" pages\n");
        serial.fail("the churn did not give everything back");
    }

    serial.put("  the heap is empty again, and std's allocator finds no leak\n");
    serial.pass();
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
