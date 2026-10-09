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

/// What the driver records of its cache, for io.durable and /admin/host.
pub const Cache = struct {
    /// Whether the disk says it caches writes; null when it would not say.
    write_cache: ?bool,
    /// Whether boot turned it off (true), tried and could not (false), or
    /// nothing is known of it (null).
    turned_off: ?bool,
};

/// After a reset, the cache sensed again and found not on (`on` false or
/// null): what is recorded. **A PAGE THAT WOULD NOT READ SAYS NOTHING OF
/// BOOT'S WORK** (metal-vmm QUEUE 130): `turned_off` stayed true, and
/// /admin/host said "turned off at boot" of a cache nothing could see. The
/// data was safe (null is flushed as if on); the line was wrong.
pub fn sensedNotOn(was: Cache, on: ?bool) Cache {
    return .{ .write_cache = on, .turned_off = if (on == null) null else was.turned_off };
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

test "a recheck that cannot read the page knows nothing of the cache: not \"turned off at boot\" (QUEUE 130)" {
    const booted: Cache = .{ .write_cache = false, .turned_off = true };
    const lost = sensedNotOn(booted, null);
    try testing.expectEqual(@as(?bool, null), lost.write_cache);
    try testing.expectEqual(@as(?bool, null), lost.turned_off);
    // Read, and still off: as boot left it.
    const still = sensedNotOn(booted, false);
    try testing.expectEqual(@as(?bool, false), still.write_cache);
    try testing.expectEqual(@as(?bool, true), still.turned_off);
}
