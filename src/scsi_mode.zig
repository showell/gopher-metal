//! **THE CACHING MODE PAGE, AS PURE LOGIC** (metal-vmm QUEUE 130): what
//! scsi.zig decides from a MODE SENSE answer, pulled out of the driver so it
//! is tested on the host. scsi.zig sends the commands; this reads and
//! builds their bytes, and says what the driver records.

const std = @import("std");

/// The caching page's code (SBC-3 §6.5.5) and the length its second byte
/// gives, past its two-byte head: SBC-3's 20-byte page.
pub const caching_code: u8 = 0x08;
pub const caching_length: u8 = 0x12;

/// The MODE SELECT(10) parameter list for turning the write cache off, built
/// in place over the MODE SENSE(10) answer in `page`, of which the disk sent
/// `got` bytes: the caching page moved up behind a zeroed header (no block
/// descriptors), PS cleared, WCE cleared. Its length, or null when there is
/// nothing safe to send.
///
/// **ONLY WHAT THE DISK SENT, AND ONLY THE PAGE IT MEANT** (metal-vmm QUEUE
/// 130): the page was taken as 20 bytes bounded by the scratch, not by
/// `got`, and its length byte was never looked at. A disk with a short or
/// older page (SCSI-2's is 0x0A) would have been sent the scratch's stale
/// bytes as the rest of it. Now the page must be the caching page, its
/// length 0x12, and all of it inside what the disk sent; anything else is
/// not sent, and the cache is left as the disk says (flushed as before).
pub fn selectList(page: []u8, got: usize) ?u16 {
    if (got < 8 or got > page.len) return null;
    const descriptors = (@as(usize, page[6]) << 8) | page[7];
    const p = 8 + descriptors;
    if (p + 2 > got) return null;
    if (page[p] & 0x3F != caching_code or page[p + 1] != caching_length) return null;
    const page_len: usize = 2 + @as(usize, caching_length);
    if (p + page_len > got) return null;
    std.mem.copyForwards(u8, page[8..][0..page_len], page[p..][0..page_len]);
    @memset(page[0..8], 0);
    page[8] &= 0x3F; // PS is reserved in MODE SELECT
    page[10] &= ~@as(u8, 0x04); // WCE
    return @intCast(8 + page_len);
}

/// **WHAT /admin/host AND THE BOOT LINE SAY OF THE CACHE** (metal-vmm QUEUE
/// 131, kernel-facts #11): derived, every time, from what the disk says now
/// (`write_cache`) and one bit of bring-up (whether it was on then). It was a
/// second stored fact, `cache_turned_off`, kept beside `write_cache` and
/// apart from it: a recheck that could not read the page left it saying
/// "turned off at boot" of a cache nothing could see (QUEUE 130).
pub const Report = enum {
    /// On at bring-up, and off now: boot turned it off (or a recheck after
    /// a reset turned it off again).
    turned_off,
    /// On at bring-up, and on now: it would not turn off.
    would_not_turn_off,
    /// Never on at bring-up, and off now.
    writes_through,
    /// Never on at bring-up, and on now (a reset turned it on, and it would
    /// not turn off again).
    caches,
    /// The disk will not say: flushed as if on.
    unknown,
};

pub fn report(write_cache: ?bool, on_at_bringup: bool) Report {
    const now = write_cache orelse return .unknown;
    if (on_at_bringup) return if (now) .would_not_turn_off else .turned_off;
    return if (now) .caches else .writes_through;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A MODE SENSE(10) answer: an 8-byte header, `descriptors` bytes of block
/// descriptors, then a caching page of `page_len` bytes after its two-byte
/// head, WCE set; the rest of the 512-byte scratch filled with 0xEE, as
/// stale bytes from an earlier command.
fn answer(buf: *[512]u8, descriptors: u16, code: u8, page_len: u8) usize {
    @memset(buf, 0xEE);
    @memset(buf[0..8], 0);
    buf[6] = @truncate(descriptors >> 8);
    buf[7] = @truncate(descriptors);
    const p = 8 + @as(usize, descriptors);
    @memset(buf[8..p], 0);
    buf[p] = 0x80 | code; // PS set, as a savable page says
    buf[p + 1] = page_len;
    @memset(buf[p + 2 ..][0..page_len], 0);
    buf[p + 2] = 0x04; // WCE
    return p + 2 + page_len;
}

test "a caching page as SBC-3 has it (0x12 bytes) is sent back with WCE and PS cleared, behind a zeroed header" {
    var buf: [512]u8 = undefined;
    const got = answer(&buf, 8, 0x08, 0x12);
    try testing.expectEqual(@as(?u16, 28), selectList(&buf, got));
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 8, buf[0..8]);
    try testing.expectEqual(@as(u8, 0x08), buf[8]); // PS cleared
    try testing.expectEqual(@as(u8, 0x12), buf[9]);
    try testing.expectEqual(@as(u8, 0), buf[10] & 0x04); // WCE cleared
}

test "a caching page shorter than SBC-3's (SCSI-2's 0x0A) is not sent: the list would carry stale scratch bytes (QUEUE 130)" {
    var buf: [512]u8 = undefined;
    const got = answer(&buf, 0, 0x08, 0x0A);
    try testing.expectEqual(@as(?u16, null), selectList(&buf, got));
}

test "an answer cut short of its page, or not the caching page, is not sent (QUEUE 130)" {
    var buf: [512]u8 = undefined;
    const got = answer(&buf, 0, 0x08, 0x12);
    try testing.expectEqual(@as(?u16, null), selectList(&buf, got - 1));
    try testing.expectEqual(@as(?u16, null), selectList(&buf, 7));
    _ = answer(&buf, 0, 0x0A, 0x12); // the control page
    try testing.expectEqual(@as(?u16, null), selectList(&buf, got));
}

test "the cache report is derived from what the disk says now and one bit of bring-up, never a second stored fact (metal-vmm QUEUE 131, kernel-facts #11)" {
    // On at bring-up: turned off (it says off now), or would not turn off.
    try testing.expectEqual(Report.turned_off, report(false, true));
    try testing.expectEqual(Report.would_not_turn_off, report(true, true));
    // Never on at bring-up: as it says now (a reset may have turned it on
    // and a recheck not off).
    try testing.expectEqual(Report.writes_through, report(false, false));
    try testing.expectEqual(Report.caches, report(true, false));
    // A disk that will not say, at bring-up or at a recheck after a reset
    // (QUEUE 130): unknown, never "turned off at boot".
    try testing.expectEqual(Report.unknown, report(null, true));
    try testing.expectEqual(Report.unknown, report(null, false));
}
