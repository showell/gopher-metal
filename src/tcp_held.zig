//! **SEGMENTS HELD FOR LATER** (RFC 9293 §3.10.7.4, SHLD-31; metal-vmm
//! QUEUE 226): what arrived ahead of a hole, kept until the hole is filled.
//! Pure: no I/O, no clock, no bytes. The bytes themselves are already in
//! the receive buffer, each at its own place past RCV.NXT (`Conn.rx`, past
//! `end`), which is inside the window we advertise, so the window never
//! promises room the queue lacks; this holds only where they are.
//!
//! RFC 9293 §3.10.7.4, first check, quoted from `docs/rfc/rfc9293.txt`:
//!
//! > o  In the following it is assumed that the segment is the
//! >    idealized segment that begins at RCV.NXT and does not exceed
//! >    the window.  One could tailor actual segments to fit this
//! >    assumption by trimming off any portions that lie outside the
//! >    window (including SYN and FIN) and only processing further
//! >    if the segment then begins at RCV.NXT.  Segments with higher
//! >    beginning sequence numbers SHOULD be held for later
//! >    processing (SHLD-31).
//!
//! A piece is named by its offset past RCV.NXT and its length. Pieces that
//! touch or overlap are merged, so a byte is held once and delivered once.

const std = @import("std");

/// **HOW MANY HOLES' WORTH**: four separate pieces a connection. Each is
/// two u32s, so the queue costs a connection 32 bytes and a FIN's offset,
/// 8 KB across gopher.zig's 256 slots: the bytes are the buffer's own.
pub const max_pieces = 4;

pub const Piece = struct { off: u32, len: u32 };

/// What `add` did with a piece.
pub const Add = enum {
    /// Held, on its own or merged with pieces it touches.
    held,
    /// Every byte of it was held already: a repeat.
    repeat,
    /// It touches no piece, and `max_pieces` are held: not held, and its
    /// sender sends it again (counted, `Table.held_refused_full`).
    full,
};

pub const Held = struct {
    pieces: [max_pieces]Piece = undefined,
    n: u8 = 0,
    /// A FIN held past RCV.NXT, at this offset: taken when every byte
    /// before it has been.
    fin_at: ?u32 = null,

    pub fn empty(self: *const Held) bool {
        return self.n == 0 and self.fin_at == null;
    }

    /// One past the last byte held, as an offset past RCV.NXT: how far past
    /// `end` the receive buffer holds bytes that are the queue's.
    pub fn extent(self: *const Held) u32 {
        var most: u32 = 0;
        for (self.pieces[0..self.n]) |p| most = @max(most, p.off + p.len);
        return most;
    }

    /// **HOLDS `len` BYTES AT `off` PAST RCV.NXT** (`off` > 0: the byte at
    /// RCV.NXT is taken, not held), merged with every piece it touches or
    /// overlaps. The pieces stay sorted by offset and apart.
    pub fn add(self: *Held, off: u32, len: u32) Add {
        std.debug.assert(off > 0 and len > 0);
        var lo = off;
        var hi = off + len;
        var covered = false;
        var touching: u8 = 0;
        for (self.pieces[0..self.n]) |p| {
            if (p.off <= lo and hi <= p.off + p.len) covered = true;
            if (p.off <= hi and lo <= p.off + p.len) touching += 1;
        }
        if (covered) return .repeat;
        if (touching == 0 and self.n == max_pieces) return .full;
        // Merge every touching piece into [lo, hi), keeping the rest.
        var kept: [max_pieces]Piece = undefined;
        var k: u8 = 0;
        for (self.pieces[0..self.n]) |p| {
            if (p.off <= hi and lo <= p.off + p.len) {
                lo = @min(lo, p.off);
                hi = @max(hi, p.off + p.len);
            } else {
                kept[k] = p;
                k += 1;
            }
        }
        // Insert in order.
        var at: u8 = 0;
        while (at < k and kept[at].off < lo) at += 1;
        var i: u8 = k;
        while (i > at) : (i -= 1) kept[i] = kept[i - 1];
        kept[at] = .{ .off = lo, .len = hi - lo };
        self.n = k + 1;
        @memcpy(self.pieces[0..self.n], kept[0..self.n]);
        return .held;
    }

    /// **RCV.NXT ADVANCED BY `by` BYTES** taken in order: every offset moves
    /// back by `by`, what is now behind RCV.NXT is let go (it was taken), and
    /// the piece that now starts at or before RCV.NXT is delivered. Answers
    /// how many bytes past the new RCV.NXT that piece makes contiguous: the
    /// caller takes them too, and calls again if it wants (no other piece
    /// can start at RCV.NXT, since pieces are apart).
    pub fn advance(self: *Held, by: u32) u32 {
        var kept: [max_pieces]Piece = undefined;
        var k: u8 = 0;
        var deliver: u32 = 0;
        for (self.pieces[0..self.n]) |p| {
            const end = p.off + p.len;
            if (end <= by) continue; // wholly taken already
            if (p.off <= by) {
                // It starts at or before the new RCV.NXT: its rest follows.
                deliver = end - by;
                continue;
            }
            kept[k] = .{ .off = p.off - by, .len = p.len };
            k += 1;
        }
        // What is delivered moves RCV.NXT on again.
        var moved: u8 = 0;
        for (kept[0..k]) |p| {
            kept[moved] = .{ .off = p.off - deliver, .len = p.len };
            moved += 1;
        }
        self.n = moved;
        @memcpy(self.pieces[0..self.n], kept[0..self.n]);
        if (self.fin_at) |f| self.fin_at = f -| (by + deliver);
        return deliver;
    }

    /// The FIN held is now at RCV.NXT: every byte before it is taken.
    pub fn finReached(self: *const Held) bool {
        return if (self.fin_at) |f| f == 0 and self.n == 0 else false;
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn pieces(h: *const Held) []const Piece {
    return h.pieces[0..h.n];
}

test "add: pieces are held apart and in order, merged where they touch or overlap" {
    const Row = struct { off: u32, len: u32, want: Add, after: []const Piece };
    const rows = [_]Row{
        .{ .off = 100, .len = 50, .want = .held, .after = &.{.{ .off = 100, .len = 50 }} },
        .{ .off = 300, .len = 10, .want = .held, .after = &.{ .{ .off = 100, .len = 50 }, .{ .off = 300, .len = 10 } } },
        .{ .off = 10, .len = 5, .want = .held, .after = &.{ .{ .off = 10, .len = 5 }, .{ .off = 100, .len = 50 }, .{ .off = 300, .len = 10 } } },
        // Touching the end of one: merged.
        .{ .off = 150, .len = 20, .want = .held, .after = &.{ .{ .off = 10, .len = 5 }, .{ .off = 100, .len = 70 }, .{ .off = 300, .len = 10 } } },
        // Inside one: a repeat.
        .{ .off = 110, .len = 30, .want = .repeat, .after = &.{ .{ .off = 10, .len = 5 }, .{ .off = 100, .len = 70 }, .{ .off = 300, .len = 10 } } },
        // Bridging two: one piece.
        .{ .off = 160, .len = 145, .want = .held, .after = &.{ .{ .off = 10, .len = 5 }, .{ .off = 100, .len = 210 } } },
        .{ .off = 500, .len = 1, .want = .held, .after = &.{ .{ .off = 10, .len = 5 }, .{ .off = 100, .len = 210 }, .{ .off = 500, .len = 1 } } },
        .{ .off = 700, .len = 1, .want = .held, .after = &.{ .{ .off = 10, .len = 5 }, .{ .off = 100, .len = 210 }, .{ .off = 500, .len = 1 }, .{ .off = 700, .len = 1 } } },
        // A fifth apart: full, nothing changes.
        .{ .off = 900, .len = 1, .want = .full, .after = &.{ .{ .off = 10, .len = 5 }, .{ .off = 100, .len = 210 }, .{ .off = 500, .len = 1 }, .{ .off = 700, .len = 1 } } },
        // But one that touches a piece is still held, when full.
        .{ .off = 501, .len = 199, .want = .held, .after = &.{ .{ .off = 10, .len = 5 }, .{ .off = 100, .len = 210 }, .{ .off = 500, .len = 201 } } },
    };
    var h: Held = .{};
    for (rows, 0..) |r, k| {
        testing.expectEqual(r.want, h.add(r.off, r.len)) catch |e| {
            std.debug.print("row {d}\n", .{k});
            return e;
        };
        try testing.expectEqualSlices(Piece, r.after, pieces(&h));
    }
    try testing.expectEqual(@as(u32, 701), h.extent());
}

test "advance: what is taken goes, the piece at the new RCV.NXT is delivered, the rest move back" {
    var h: Held = .{};
    _ = h.add(100, 50); // 100..150
    _ = h.add(300, 10); // 300..310
    // 100 bytes taken in order: the first piece now starts at RCV.NXT.
    try testing.expectEqual(@as(u32, 50), h.advance(100));
    try testing.expectEqualSlices(Piece, &.{.{ .off = 150, .len = 10 }}, pieces(&h));
    // 40 more taken, overlapping nothing held: no delivery.
    try testing.expectEqual(@as(u32, 0), h.advance(40));
    try testing.expectEqualSlices(Piece, &.{.{ .off = 110, .len = 10 }}, pieces(&h));
    // A segment that runs into the piece: its rest is delivered, no more.
    try testing.expectEqual(@as(u32, 5), h.advance(115));
    try testing.expect(h.empty());
}

test "a FIN held is reached only when every byte before it is taken" {
    var h: Held = .{};
    _ = h.add(10, 20); // 10..30, its FIN at 30
    h.fin_at = 30;
    try testing.expect(!h.finReached());
    try testing.expectEqual(@as(u32, 20), h.advance(10));
    try testing.expect(h.finReached());
    var g: Held = .{};
    g.fin_at = 50; // a bare FIN ahead
    _ = g.advance(49);
    try testing.expect(!g.finReached());
    _ = g.advance(1);
    try testing.expect(g.finReached());
}
