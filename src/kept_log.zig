//! **THE LOG THAT OUTLIVES A RESTART** (RESTART.md, QUEUE.md item 16).
//!
//! `serial.ring` lives in `.bss`, which both loaders zero on every boot, so
//! a restart loses it. RAM past the kernel survives a restart, by every method
//! this machine uses (RESTART.md, measured). So a host that wants the last
//! boot's log hands this a region there (`region_bytes`, kept out of the page
//! allocator), and the ring writes into it.
//!
//! **TWO SLOTS, ALTERNATING BY BOOT.** Each is a header page and the ring's
//! bytes. A boot reads both headers and takes the valid one with the higher
//! boot number as the boot before it, kept read-only. It writes its own log
//! into the other slot, so the next boot's log never overwrites the one it is
//! there to explain.
//!
//! **A HEADER IS CHECKED, NOT TRUSTED.** On a cold boot the region holds
//! whatever RAM held: zeros on a fresh VM, 0xA5 on droplet.sh's DIRTY=1, the
//! BIOS's leftovers elsewhere. A header needs its magic, a checksum over its
//! fields, and a head and a count that fit its slot. Anything else reads as no
//! log. The bytes need no check: the header says how many there are, and they
//! were redacted when they were written.
//!
//! **A HEADER IS WRITTEN WHEN THE BOOT ENDS ON PURPOSE** (`seal`, from the
//! restart path), not on every log line. A boot that never seals (a hang, an
//! external reset, a power cut) leaves no header in its slot: `open` clears
//! the slot's header at boot for that reason. So the next boot shows the boot
//! before it as missing, rather than showing an older log as if it were that
//! one.

const std = @import("std");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
const log_ring = @import("log_ring.zig");

pub const slot_bytes = 64 * 1024;
const header_bytes = 4096;
const slot_stride = header_bytes + slot_bytes;
pub const region_bytes = 2 * slot_stride;

const magic: u64 = 0x474D_4B45_5054_4C47; // "GLTPEKMG"

const Header = extern struct {
    magic: u64,
    boot: u64,
    head: u64,
    total: u64,
    check: u64,

    fn sum(h: Header) u64 {
        return (h.magic ^ 0x9E37_79B9_7F4A_7C15) +% h.boot *% 0x100_0000_01B3 +%
            std.math.rotl(u64, h.head, 17) +% std.math.rotl(u64, h.total, 41);
    }

    fn valid(h: Header) bool {
        // The head is the count modulo the slot, always (metal-vmm B36): a
        // header that says otherwise is not one this machine wrote.
        return h.magic == magic and h.check == h.sum() and h.head < slot_bytes and
            h.head == h.total % slot_bytes;
    }
};

/// A boot's log, read-only: the boot it was, and its bytes as a ring.
pub const Previous = struct {
    boot: u64,
    ring: log_ring.Ring,

    /// Its log, oldest first, from the first whole line once any was lost.
    pub fn read(p: *const Previous, out: []u8) []u8 {
        return p.ring.read(out);
    }

    /// Its last line, without the newline: what it ended on.
    pub fn lastLine(p: *const Previous, out: []u8) []const u8 {
        var text = p.read(out);
        while (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
        const from = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |i| i + 1 else 0;
        return text[from..];
    }
};

pub const Kept = struct {
    region: []u8,
    /// The slot this boot writes.
    slot: u1,
    /// This boot's number: one past the previous one's, or 1.
    boot: u64,
    previous: ?Previous,

    /// This boot's ring's bytes.
    pub fn bytes(k: *const Kept) []u8 {
        return slotBytes(k.region, k.slot);
    }

    /// Writes this boot's header from `ring`, which writes into `bytes()`:
    /// the next boot will find this log. Called on the way to a restart.
    pub fn seal(k: *const Kept, ring: *const log_ring.Ring) void {
        var h = Header{ .magic = magic, .boot = k.boot, .head = ring.next(), .total = ring.total, .check = 0 };
        h.check = h.sum();
        headerAt(k.region, k.slot).* = h;
    }
};

fn headerAt(region: []u8, slot: u1) *align(1) Header {
    return @ptrCast(region[@as(usize, slot) * slot_stride ..][0..@sizeOf(Header)]);
}

fn slotBytes(region: []u8, slot: u1) []u8 {
    return region[@as(usize, slot) * slot_stride + header_bytes ..][0..slot_bytes];
}

/// Reads both slots of `region` (`region_bytes` long), and sets this boot up
/// in the one that does not hold the boot before it.
pub fn open(region: []u8) Kept {
    std.debug.assert(region.len >= region_bytes);
    var best: ?u1 = null;
    for ([_]u1{ 0, 1 }) |s| {
        const h = headerAt(region, s).*;
        if (!h.valid()) {
            if (h.magic == magic)
                props.reachable(@src(), "kept log: a header with the magic but a bad check or shape is not trusted", null)
            else
                props.reachable(@src(), "kept log: a slot with no header holds no log", null);
            continue;
        }
        if (best) |b| {
            props.reachable(@src(), "kept log: both slots are sealed, and the later boot is the previous", null);
            if (h.boot > headerAt(region, b).boot) best = s;
        } else best = s;
    }
    const previous: ?Previous = if (best) |b| blk: {
        const h = headerAt(region, b).*;
        break :blk .{ .boot = h.boot, .ring = .{ .buf = slotBytes(region, b), .total = h.total } };
    } else null;
    const slot: u1 = if (best) |b| ~b else 0;
    if (best == null) props.reachable(@src(), "kept log: no boot before this one is found", null);
    if (best) |b| props.always(@src(), slot != b, "kept log: a boot never writes over the log of the boot before it", null);
    // Until this boot seals, its slot says nothing (see the file's comment).
    headerAt(region, slot).magic = 0;
    return .{
        .region = region,
        .slot = slot,
        .boot = if (previous) |p| p.boot +% 1 else 1,
        .previous = previous,
    };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

fn newRegion(fill: u8) ![]u8 {
    const r = try testing.allocator.alloc(u8, region_bytes);
    @memset(r, fill);
    return r;
}

/// One boot: open, log `text` into this boot's slot through a ring, and seal
/// it (or not). Answers what open said.
fn boot(region: []u8, text: []const u8, sealed: bool) Kept {
    const k = open(region);
    var ring = log_ring.Ring.init(k.bytes());
    ring.write(text);
    if (sealed) k.seal(&ring);
    return k;
}

test "a cold region, of zeros, 0xA5 or noise, holds no previous log, and the boot is the first" {
    for ([_]u8{ 0x00, 0xA5, 0xFF }) |fill| {
        const r = try newRegion(fill);
        defer testing.allocator.free(r);
        const k = open(r);
        try testing.expectEqual(@as(?Previous, null), k.previous);
        try testing.expectEqual(@as(u64, 1), k.boot);
    }
    const r = try newRegion(0);
    defer testing.allocator.free(r);
    var prng = std.Random.DefaultPrng.init(3);
    prng.random().bytes(r);
    try testing.expectEqual(@as(?Previous, null), open(r).previous);
}

test "each boot reads the one before it, which ended with its reason, and writes the other slot" {
    const r = try newRegion(0xA5);
    defer testing.allocator.free(r);
    const one = boot(r, "boot one\nRESTART: a panic: index out of bounds\n", true);
    const two = boot(r, "boot two\nRESTART: a failure: the stack guard was written\n", true);
    try testing.expect(one.slot != two.slot);
    try testing.expectEqual(@as(u64, 1), two.previous.?.boot);
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings("RESTART: a panic: index out of bounds", two.previous.?.lastLine(&out));
    const three = open(r);
    try testing.expectEqual(@as(u64, 2), three.previous.?.boot);
    try testing.expectEqual(@as(u64, 3), three.boot);
    try testing.expectEqualStrings("RESTART: a failure: the stack guard was written", three.previous.?.lastLine(&out));
    // And it writes the slot boot one used, not boot two's.
    try testing.expectEqual(one.slot, three.slot);
}

test "a boot that never sealed leaves no log: the next one finds the boot before, by its own number" {
    const r = try newRegion(0);
    defer testing.allocator.free(r);
    _ = boot(r, "boot one\n", true);
    _ = boot(r, "boot two, which hung\n", false);
    const three = open(r);
    // Boot two's slot says nothing (open cleared its header, and it never
    // sealed), so the log found is boot one's, and it is called boot one.
    try testing.expectEqual(@as(u64, 1), three.previous.?.boot);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("boot one", three.previous.?.lastLine(&out));
}

test "a long log keeps its end, from a whole line" {
    const r = try newRegion(0);
    defer testing.allocator.free(r);
    const k = open(r);
    var ring = log_ring.Ring.init(k.bytes());
    var line: [64]u8 = undefined;
    for (0..20_000) |i| ring.write(try std.fmt.bufPrint(&line, "line {d}\n", .{i}));
    ring.write("RESTART: the end\n");
    k.seal(&ring);
    const next = open(r);
    const p = next.previous.?;
    const out = try testing.allocator.alloc(u8, slot_bytes);
    defer testing.allocator.free(out);
    const text = p.read(out);
    try testing.expect(std.mem.startsWith(u8, text, "line "));
    try testing.expect(std.mem.endsWith(u8, text, "line 19999\nRESTART: the end\n"));
}

test "a header that does not check is no log: its checksum, its head, its count" {
    const r = try newRegion(0);
    defer testing.allocator.free(r);
    const k = boot(r, "something\n", true);
    const h = headerAt(r, k.slot);
    const good = h.*;
    h.boot += 1; // the checksum no longer holds
    try testing.expectEqual(@as(?Previous, null), open(r).previous);
    h.* = good;
    h.head = slot_bytes; // a head past its slot, checksum fixed up
    h.check = h.sum();
    try testing.expectEqual(@as(?Previous, null), open(r).previous);
    h.* = good;
    h.total = 5; // fewer bytes than the head says were written
    h.check = h.sum();
    try testing.expectEqual(@as(?Previous, null), open(r).previous);
    h.* = good;
    // A head past its slot with a count that agrees with it: only the head's
    // own bound refuses it, and reading it would run past the slot.
    h.head = slot_bytes;
    h.total = slot_bytes;
    h.check = h.sum();
    try testing.expectEqual(@as(?Previous, null), open(r).previous);
    h.* = good;
    // A ring that has wrapped, its head not where its count puts it
    // (metal-vmm B36): the head is always the count modulo the slot.
    h.total = slot_bytes + 7;
    h.head = 3;
    h.check = h.sum();
    try testing.expectEqual(@as(?Previous, null), open(r).previous);
    h.* = good;
    h.magic +%= 1; // not our header, though its checksum is fixed up
    h.check = h.sum();
    try testing.expectEqual(@as(?Previous, null), open(r).previous);
}
