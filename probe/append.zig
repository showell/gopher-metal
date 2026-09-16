//! **THE APPEND.** Every write `angry-gopher` makes that is not a whole file is
//! this, and it is always spelled the same way:
//!
//!     var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
//!     defer file.close(io);
//!     const st = try file.stat(io);
//!     try file.writePositionalAll(io, bytes, st.size);
//!
//! — a chat message, a game action, an uploaded chunk, a puzzle move. So this
//! probe writes through exactly that, not through `fat16` underneath it.
//!
//! **THE CASES ARE THE ONES THAT CAN ACTUALLY BREAK**, and each is a different
//! path through fat16.writeInto:
//!
//!   log.txt     600 fixed-width lines, appended one at a time. At 2 KB per
//!               cluster that is fourteen clusters, so the chain is extended
//!               thirteen times rather than once — and the probe ASSERTS that,
//!               because the first version of it wrote 1,692 bytes, fitted in a
//!               single cluster, and passed with the extension deleted.
//!   small.txt   Three appends of 1, 2 and 3 bytes. All inside one sector, so
//!               each write must READ that sector before writing it — a write
//!               that skipped the read would erase back to the boundary and
//!               leave "ccc" where "abbccc" belongs. This is the case a
//!               whole-sector writer passes every other test and fails.
//!   over.txt    An overwrite INSIDE the file: offset 3 of a 10-byte file. The
//!               bytes change, the size does not.
//!   (a hole)    offset past the end must be REFUSED. FAT has no sparse files,
//!               so the gap would be whatever those clusters last held, and
//!               answering with stale bytes is worse than failing.
//!
//! **THE VERDICT IS NOT THIS PROBE'S.** `probe/run.sh` hands the volume to
//! `fsck.vfat` and then mounts it with the Linux kernel's own VFAT driver and
//! regenerates the expected 600 lines in shell. Agreeing with our own reader
//! would prove very little — a size field and a cluster chain that disagree can
//! read back perfectly through the code that wrote them.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const gpt = metal.gpt;
const fat16 = metal.fat16;
const Io = metal.io;

comptime {
    _ = metal.boot;
}

var blk_mem: virtio.BlockMemory align(4096) = .{};
var scratch: [fat16.sector_size]u8 align(4096) = undefined;
var heap: [1024 * 1024]u8 align(16) = undefined;
var line_buf: [64]u8 = undefined;
var expect: [64 * 1024]u8 = undefined;

/// 600 lines of 45 bytes is 27,000 — thirteen 2 KB clusters. Fixed width so the
/// oracle in run.sh can regenerate it with one `seq`.
const lines = 600;

/// append is the application's own three lines, verbatim.
fn append(io: anytype, path: []const u8, bytes: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, bytes, st.size);
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal append probe\n");

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");
    const vol = fat16.Volume.mount(&blk, &scratch, 0) catch
        serial.fail("this is not the FAT16 volume the probe expects");
    Io.mount(vol);

    const io = Io.io();
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const alloc = fba.allocator();

    // ── the partial-sector case, first, because it is the subtle one ────────
    append(io, "small.txt", "a") catch serial.fail("the first append to a new file failed");
    append(io, "small.txt", "bb") catch serial.fail("the second append failed");
    append(io, "small.txt", "ccc") catch serial.fail("the third append failed");
    const small = Io.Dir.cwd().readFileAlloc(io, "small.txt", alloc, .limited(64)) catch
        serial.fail("small.txt would not read back");
    if (!eql(small, "abbccc")) {
        serial.put("  small.txt reads [");
        serial.put(small);
        serial.put("] and should read [abbccc]\n");
        serial.fail("an append inside a sector erased what was already there");
    }
    serial.put("  small.txt: three appends inside one sector -> abbccc\n");

    // ── an overwrite inside the file: bytes change, size does not ───────────
    append(io, "over.txt", "0123456789") catch serial.fail("over.txt would not be written");
    {
        var file = Io.Dir.cwd().createFile(io, "over.txt", .{ .truncate = false }) catch
            serial.fail("over.txt would not open");
        file.writePositionalAll(io, "XYZ", 3) catch serial.fail("the overwrite failed");
    }
    const over = Io.Dir.cwd().readFileAlloc(io, "over.txt", alloc, .limited(64)) catch
        serial.fail("over.txt would not read back");
    if (!eql(over, "012XYZ6789")) {
        serial.put("  over.txt reads [");
        serial.put(over);
        serial.put("] and should read [012XYZ6789]\n");
        serial.fail("an overwrite inside the file wrote the wrong bytes");
    }
    serial.put("  over.txt: overwrite at 3 -> 012XYZ6789, size still 10\n");

    // ── a hole must be refused ─────────────────────────────────────────────
    {
        var file = Io.Dir.cwd().createFile(io, "over.txt", .{ .truncate = false }) catch
            serial.fail("over.txt would not open");
        if (file.writePositionalAll(io, "!", 999)) |_| {
            serial.fail("a write past the end was ACCEPTED: that leaves a hole of stale bytes");
        } else |_| {}
    }
    serial.put("  over.txt: a write past the end is refused\n");

    // ── the chain-extending case: 600 lines, appended one at a time ─────────
    var want: usize = 0;
    var i: usize = 1;
    while (i <= lines) : (i += 1) {
        const line = std.fmt.bufPrint(&line_buf, "line {d:0>4} aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", .{i}) catch
            serial.fail("could not format a line");
        append(io, "log.txt", line) catch {
            serial.put("  failed at line ");
            serial.putDec(i);
            serial.put("\n");
            serial.fail("an append failed part way through the log");
        };
        @memcpy(expect[want..][0..line.len], line);
        want += line.len;
    }

    const log = Io.Dir.cwd().readFileAlloc(io, "log.txt", alloc, .limited(expect.len)) catch
        serial.fail("log.txt would not read back");
    if (log.len != want) {
        serial.put("  log.txt is ");
        serial.putDec(log.len);
        serial.put(" bytes and should be ");
        serial.putDec(want);
        serial.put("\n");
        serial.fail("the appended log is the wrong length");
    }
    if (!eql(log, expect[0..want])) serial.fail("the appended log has the wrong bytes");

    // **THE PROBE CHECKS ITS OWN COVERAGE.** Spanning several clusters is the
    // whole point of this case, and it is a property of the line count AND the
    // volume's geometry — neither of which this file controls. Deleting the
    // chain extension from fat16.writeInto must fail here; when the log fitted
    // in one cluster it did not.
    const cluster_bytes: usize = vol.sectors_per_cluster * fat16.sector_size;
    const spanned = (want + cluster_bytes - 1) / cluster_bytes;
    if (spanned < 3) {
        serial.put("  the log spans only ");
        serial.putDec(spanned);
        serial.put(" cluster(s)\n");
        serial.fail("this probe is no longer testing chain extension: make the log longer");
    }
    serial.put("  log.txt: ");
    serial.putDec(lines);
    serial.put(" appends -> ");
    serial.putDec(want);
    serial.put(" bytes, over ");
    serial.putDec(spanned);
    serial.put(" clusters\n");

    // ── and the directories the application makes before every write ───────
    Io.Dir.cwd().createDirPath(io, "data/lynrummy/p1/lynrummy-elm/sessions/1") catch
        serial.fail("createDirPath failed");
    append(io, "data/lynrummy/p1/lynrummy-elm/sessions/1/actions.dsl", "1) draw\n") catch
        serial.fail("the first write into a fresh tree failed");
    append(io, "data/lynrummy/p1/lynrummy-elm/sessions/1/actions.dsl", "2) meld\n") catch
        serial.fail("the second write into a fresh tree failed");
    serial.put("  createDirPath: five levels, then two appends into it\n");

    readWindows(io);
    createDefaults(io, alloc);

    serial.pass();
}

/// **POSITIONAL READS, AGAINST THE BYTES WE KNOW WERE WRITTEN.** The application
/// answers an HTTP Range request with `readPositionalAll`, so a browser seeking
/// in an image lands in the middle of a chain. Each window below is compared
/// with `expect` — the buffer built from the format string, not from a read —
/// and each is chosen for the path it takes through fat16.readAt.
fn readWindows(io: anytype) void {
    const Window = struct { offset: u64, len: usize, why: []const u8 };
    const cluster: u64 = 2048;
    const windows = [_]Window{
        .{ .offset = 0, .len = 10, .why = "the first bytes" },
        .{ .offset = 505, .len = 20, .why = "across a sector boundary" },
        .{ .offset = cluster - 7, .len = 30, .why = "across a cluster boundary" },
        .{ .offset = cluster * 6 + 1, .len = 3000, .why = "deep, spanning two clusters" },
        .{ .offset = 512 * 3, .len = 512, .why = "exactly one sector" },
        .{ .offset = cluster * 2, .len = cluster, .why = "exactly one cluster" },
    };

    var file = Io.Dir.cwd().openFile(io, "log.txt", .{}) catch
        serial.fail("log.txt would not open for reading");
    defer file.close(io);
    const size = (file.stat(io) catch serial.fail("log.txt would not stat")).size;

    var buf: [4096]u8 = undefined;
    for (windows) |w| {
        const n = file.readPositionalAll(io, buf[0..w.len], w.offset) catch
            serial.fail("a positional read failed");
        if (n != w.len or !eql(buf[0..n], expect[w.offset..][0..w.len])) {
            serial.put("  read at ");
            serial.putDec(w.offset);
            serial.put(" (");
            serial.put(w.why);
            serial.put(") got ");
            serial.putDec(n);
            serial.put(" bytes\n");
            serial.fail("a positional read returned the wrong bytes");
        }
    }

    // The tail: asking past the end reads what is there, and says how much.
    const tail = file.readPositionalAll(io, buf[0..100], size - 10) catch
        serial.fail("the tail read failed");
    if (tail != 10 or !eql(buf[0..10], expect[size - 10 ..][0..10]))
        serial.fail("a read across the end did not stop at the end");

    // At the end, and past it, there is nothing — and that is not an error.
    const at_end = file.readPositionalAll(io, buf[0..10], size) catch
        serial.fail("a read at the end failed instead of answering zero");
    const past = file.readPositionalAll(io, buf[0..10], size + 5000) catch
        serial.fail("a read past the end failed instead of answering zero");
    if (at_end != 0 or past != 0) serial.fail("a read at or past the end returned bytes");

    // Reassembled in odd-sized pieces, the whole file is the whole file.
    var at: u64 = 0;
    while (at < size) {
        const n = file.readPositionalAll(io, buf[0..777], at) catch
            serial.fail("a chunked read failed");
        if (n == 0) serial.fail("a chunked read stopped before the end");
        if (!eql(buf[0..n], expect[at..][0..n])) serial.fail("a chunk had the wrong bytes");
        at += n;
    }

    // A handle opened BEFORE an append must see the new size: the application
    // opens, then something appends, then it reads.
    append(io, "log.txt", "one more\n") catch serial.fail("the late append failed");
    const late = file.readPositionalAll(io, buf[0..32], size) catch
        serial.fail("reading the late append failed");
    if (!eql(buf[0..late], "one more\n"))
        serial.fail("a handle opened before an append did not see it");

    serial.put("  readPositionalAll: 6 windows, the tail, past the end, 777-byte chunks, a late append\n");
}

/// createFile's defaults are std's: without `.truncate = false` it EMPTIES the
/// file. This machine once defaulted the other way, which no caller happened to
/// hit; this pins it.
fn createDefaults(io: anytype, alloc: std.mem.Allocator) void {
    append(io, "trunc.txt", "keep me") catch serial.fail("trunc.txt would not be written");
    {
        var f = Io.Dir.cwd().createFile(io, "trunc.txt", .{ .truncate = false }) catch
            serial.fail("createFile(.truncate = false) failed");
        f.close(io);
    }
    const kept = Io.Dir.cwd().readFileAlloc(io, "trunc.txt", alloc, .limited(64)) catch
        serial.fail("trunc.txt would not read");
    if (!eql(kept, "keep me")) serial.fail("createFile(.truncate = false) did not keep the file");

    {
        var f = Io.Dir.cwd().createFile(io, "trunc.txt", .{}) catch
            serial.fail("createFile(.{}) failed");
        f.close(io);
    }
    const emptied = Io.Dir.cwd().readFileAlloc(io, "trunc.txt", alloc, .limited(64)) catch
        serial.fail("trunc.txt would not read after truncation");
    if (emptied.len != 0) serial.fail("createFile(.{}) kept the file; std's default is to truncate");

    serial.put("  createFile: .truncate = false keeps, the default empties\n");
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
