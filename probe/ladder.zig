//! **THE LADDER: ONE OPERATION, MANY TIMES, AT A FLAT COST.**
//!
//! The chat server's own answer time grows over a long run — about 7 ms at the
//! start of a soak and 115 ms near the end — while the number of device
//! requests per route stays flat. Something underneath gets slower as it is
//! used. This kernel looks for it one layer at a time: each rung repeats a
//! single operation and prints what each tenth of the run cost per operation.
//! A well-behaved rung prints ten numbers that do not climb. The first rung
//! that climbs is where the growth lives, and everything below it is an axiom.
//!
//! The rungs, bottom up:
//!
//!   cpu            SHA-256 of 4 KB: the processor, and the clock measuring it
//!   alloc          three allocations and three frees through std's allocator
//!                  on this machine's pages
//!   read_same      one disk sector read, the same one each time
//!   write_same     one disk sector written, the same one each time
//!   write_spread   one disk sector written, a new one each time — the image
//!                  file on the host grows under it
//!   append         512 bytes appended to one file, the way the application
//!                  appends
//!   replace        a small file rewritten whole, the way the message count is
//!
//! **THE VERDICT IS NOT THIS KERNEL'S.** It prints numbers; `probe/run.sh
//! ladder` decides whether they are flat. The machine's command line says how
//! long each rung runs (`scale=N` multiplies every rung's count), so the same
//! kernel answers quickly first and at length once it has earned it.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const fat16 = metal.fat16;
const pages = metal.pages;
const pvh = metal.pvh;
const Io = metal.io;

comptime {
    _ = metal.boot;
}

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

/// The allocator the server's long-lived heap uses, configured the same way.
var gpa: std.heap.DebugAllocator(.{
    .backing_allocator_zeroes = false,
    .stack_trace_frames = 0,
    .thread_safe = false,
    .safety = false,
    .page_size = pages.page_size,
}) = .{};

var blk_mem: virtio.BlockMemory align(4096) = .{};
var scratch: [fat16.sector_size]u8 align(4096) = undefined;
var sector: [fat16.sector_size]u8 align(4096) = undefined;
var block: [4096]u8 = undefined;
var chunk: [512]u8 = undefined;

/// The first sector past the FAT volume: run.sh makes the volume 32 MB and the
/// disk 64 MB, so everything from here on is the ladder's to write.
const raw_first: u64 = 65536;

/// Each rung is timed in this many equal parts.
const tenths = 10;

/// What each rung's count is multiplied by, from `scale=N` on the command line.
fn scaleFromCommandLine() usize {
    var words = std.mem.tokenizeScalar(u8, metal.boot.commandLine(), ' ');
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "scale=")) {
            return std.fmt.parseInt(usize, word["scale=".len..], 10) catch
                serial.fail("the command line's scale= is not a number");
        }
    }
    return 1;
}

/// Runs `op` `count` times and prints the cost per operation of each tenth of
/// the run, in nanoseconds, with the disk requests each tenth made.
fn rung(name: []const u8, count: usize, blk: *virtio.Block, context: anytype, comptime op: fn (@TypeOf(context), usize) void) void {
    const per = @max(count / tenths, 1);
    var spent: [tenths]i96 = @splat(0);
    var requests: [tenths]u64 = @splat(0);
    for (0..tenths) |t| {
        const requests_before = blk.requests;
        const began = now();
        for (0..per) |k| op(context, t * per + k);
        spent[t] = now() - began;
        requests[t] = blk.requests - requests_before;
    }
    serial.put("rung ");
    serial.put(name);
    serial.put(": ");
    serial.putDec(per * tenths);
    serial.put(" ops; ns per op by tenth:");
    for (spent) |ns| {
        serial.put(" ");
        serial.putDec(@intCast(@divTrunc(ns, @as(i96, @intCast(per)))));
    }
    serial.put("; disk requests by tenth:");
    for (requests) |r| {
        serial.put(" ");
        serial.putDec(r);
    }
    serial.put("\n");
}

fn now() i96 {
    return Io.awakeNs() orelse serial.fail("the clock was not started");
}

// ── the operations ──────────────────────────────────────────────────────────

fn cpu(_: void, _: usize) void {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&block, &out, .{});
    std.mem.doNotOptimizeAway(out);
}

fn alloc(a: std.mem.Allocator, _: usize) void {
    const small = a.alloc(u8, 64) catch serial.fail("alloc: no memory");
    const middle = a.alloc(u8, 1000) catch serial.fail("alloc: no memory");
    const large = a.alloc(u8, 5000) catch serial.fail("alloc: no memory");
    small[0] = 1;
    middle[0] = 2;
    large[0] = 3;
    a.free(middle);
    a.free(small);
    a.free(large);
}

fn readSame(blk: *virtio.Block, _: usize) void {
    if (blk.read(raw_first, @intFromPtr(&sector)) != virtio.blk_s_ok) serial.fail("read_same: the read failed");
}

fn writeSame(blk: *virtio.Block, _: usize) void {
    if (blk.write(raw_first, @intFromPtr(&sector)) != virtio.blk_s_ok) serial.fail("write_same: the write failed");
}

fn writeSpread(blk: *virtio.Block, k: usize) void {
    const lba = raw_first + 1 + k;
    if (lba >= blk.capacity) serial.fail("write_spread: the rung ran off the end of the disk");
    if (blk.write(lba, @intFromPtr(&sector)) != virtio.blk_s_ok) serial.fail("write_spread: the write failed");
}

/// The application's append, verbatim (see probe/append.zig).
fn append(io: Io, _: usize) void {
    var file = Io.Dir.cwd().createFile(io, "append.bin", .{ .truncate = false }) catch
        serial.fail("append: the file would not open");
    defer file.close(io);
    const st = file.stat(io) catch serial.fail("append: no stat");
    file.writePositionalAll(io, &chunk, st.size) catch serial.fail("append: the write failed");
}

fn replace(io: Io, k: usize) void {
    var text: [32]u8 = undefined;
    const data = std.fmt.bufPrint(&text, "{d} {d}\n", .{ k, k * 512 }) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = "count.txt", .data = data }) catch
        serial.fail("replace: the write failed");
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal ladder\n");

    const scale = scaleFromCommandLine();
    serial.put("  scale ");
    serial.putDec(scale);
    serial.put("\n");

    const hz = metal.pit.calibrate() catch serial.fail("the PIT would not calibrate the TSC");
    Io.startClock(hz);

    const entries = metal.boot.memoryMap() catch serial.fail("the loader described no memory");
    const carved = pages.bring(pvh.largestFree(entries, metal.boot.image()));
    if (carved.pages_total == 0) serial.fail("no usable region of RAM");

    const base = virtio.find(virtio.device_id_block) orelse serial.fail("no virtio-blk device");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");
    var vol = fat16.Volume.mount(&blk, &scratch, 0) catch serial.fail("the disk does not start with a FAT16 volume");
    const fat = pages.allocator.alloc(u8, vol.fatBytes()) catch serial.fail("no memory to hold the FAT");
    vol.cacheFat(fat) catch serial.fail("the FAT could not be held in memory");
    Io.mount(vol);
    const io = Io.io();

    for (&block, 0..) |*b, k| b.* = @truncate(k *% 7);
    @memset(&chunk, 'a');
    @memset(&sector, 0x5A);

    rung("cpu", 500 * scale, &blk, {}, cpu);
    rung("alloc", 20_000 * scale, &blk, gpa.allocator(), alloc);
    rung("read_same", 2000 * scale, &blk, &blk, readSame);
    rung("write_same", 2000 * scale, &blk, &blk, writeSame);
    rung("write_spread", @min(2000 * scale, 60_000), &blk, &blk, writeSpread);
    rung("append", 1000 * scale, &blk, io, append);
    rung("replace", 1000 * scale, &blk, io, replace);

    if (gpa.deinit() == .leak) serial.fail("the allocator rung leaked");
    serial.pass();
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
