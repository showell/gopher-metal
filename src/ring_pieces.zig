//! **WHERE A RUN OF A BYTE RING LIES** (metal-vmm B36): a ring of `cap`
//! bytes indexed by a position that only counts up (a `u64` never wraps in
//! practice), and a run of `len` bytes from position `start` lies in at most
//! two contiguous pieces of the buffer: from `start % cap` to the end, and
//! from the buffer's start. The log ring (log_ring.zig) and the console's
//! backlog (serial.zig) each split at that seam by hand; this is the one
//! split, tested for every small ring.

pub const Piece = struct {
    at: usize,
    len: usize,

    pub fn of(p: Piece, buf: []const u8) []const u8 {
        return buf[p.at..][0..p.len];
    }

    pub fn into(p: Piece, buf: []u8) []u8 {
        return buf[p.at..][0..p.len];
    }
};

/// The run of `len` bytes from position `start` in a ring of `cap`, as two
/// pieces, the second empty unless the run wraps. `len` is at most `cap`.
pub fn pieces(cap: usize, start: u64, len: usize) [2]Piece {
    std.debug.assert(cap > 0 and len <= cap);
    const at: usize = @intCast(start % cap);
    const first = @min(len, cap - at);
    return .{ .{ .at = at, .len = first }, .{ .at = 0, .len = len - first } };
}

// ---- tests --------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "every run of every ring up to 9 bytes: the pieces hold exactly its positions, in order, and the second is empty unless it wraps" {
    var cap: usize = 1;
    while (cap <= 9) : (cap += 1) {
        var start: u64 = 0;
        while (start <= 3 * cap) : (start += 1) {
            var len: usize = 0;
            while (len <= cap) : (len += 1) {
                const p = pieces(cap, start, len);
                try testing.expectEqual(len, p[0].len + p[1].len);
                // Walked in order, the pieces are (start + i) % cap.
                var i: usize = 0;
                for (p) |piece| {
                    var k: usize = 0;
                    while (k < piece.len) : (k += 1) {
                        try testing.expectEqual(@as(usize, @intCast((start + i) % cap)), piece.at + k);
                        i += 1;
                    }
                }
                const wraps = (start % cap) + len > cap;
                try testing.expectEqual(wraps, p[1].len > 0);
                try testing.expect(p[0].at + p[0].len <= cap and p[1].at + p[1].len <= cap);
            }
        }
    }
}

test "the pieces slice a buffer" {
    const buf = "abcdefgh";
    const p = pieces(buf.len, 6, 4); // g h | a b
    try testing.expectEqualStrings("gh", p[0].of(buf));
    try testing.expectEqualStrings("ab", p[1].of(buf));
}
