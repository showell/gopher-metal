//! **A TCP SEGMENT** (RFC 9293 §3.1, "Header Format"): what tcp.zig's table
//! reads from a frame and writes into one, and nothing else. Pure: no state,
//! no I/O, no clock (metal-vmm QUEUE 225, chunk 2).
//!
//! ```
//!     0                   1                   2                   3
//!     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
//!    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//!    |          Source Port          |       Destination Port        |
//!    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//!    |                        Sequence Number                        |
//!    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//!    |                    Acknowledgment Number                      |
//!    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//!    |  Data |       |C|E|U|A|P|R|S|F|                               |
//!    | Offset| Rsrvd |W|C|R|C|S|S|Y|I|            Window             |
//!    |       |       |R|E|G|K|H|T|N|N|                               |
//!    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//!    |           Checksum            |         Urgent Pointer        |
//!    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//!    |                           [Options]                           |
//!    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//!    |                                                               :
//!    :                             Data                              :
//!    :                                                               |
//!    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//! ```
//!
//! The checksum is over a pseudo-header of the two addresses, which the
//! segment does not know: the table fills it in (`proto.pseudoChecksum`).
//! URG, ECE and CWR are neither read nor sent; the urgent pointer is sent as
//! zero.

const std = @import("std");
const proto = @import("proto.zig");

/// The fixed header, without options.
pub const header_len: usize = 20;

pub const flag_fin: u8 = 0x01;
pub const flag_syn: u8 = 0x02;
pub const flag_rst: u8 = 0x04;
pub const flag_psh: u8 = 0x08;
pub const flag_ack: u8 = 0x10;

/// The control bits this TCP reads and sends.
pub const Ctl = struct {
    fin: bool = false,
    syn: bool = false,
    rst: bool = false,
    psh: bool = false,
    ack: bool = false,

    pub fn of(bits: u8) Ctl {
        return .{
            .fin = bits & flag_fin != 0,
            .syn = bits & flag_syn != 0,
            .rst = bits & flag_rst != 0,
            .psh = bits & flag_psh != 0,
            .ack = bits & flag_ack != 0,
        };
    }

    pub fn byte(c: Ctl) u8 {
        return (if (c.fin) flag_fin else 0) | (if (c.syn) flag_syn else 0) |
            (if (c.rst) flag_rst else 0) | (if (c.psh) flag_psh else 0) |
            (if (c.ack) flag_ack else 0);
    }
};

pub const Segment = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    ctl: Ctl,
    window: u16,
    /// What lies between the fixed header and the data.
    options: []const u8 = &.{},
    data: []const u8 = &.{},

    /// **A SEGMENT FROM AN IP PAYLOAD**, or null where "Data Offset" says
    /// less than the fixed header or more than the payload holds.
    pub fn parse(t: []const u8) ?Segment {
        if (t.len < header_len) return null;
        const offset = @as(usize, t[12] >> 4) * 4;
        if (offset < header_len or offset > t.len) return null;
        return .{
            .src_port = proto.readBe16(t[0..2]),
            .dst_port = proto.readBe16(t[2..4]),
            .seq = proto.readBe32(t[4..8]),
            .ack = proto.readBe32(t[8..12]),
            .ctl = Ctl.of(t[13]),
            .window = proto.readBe16(t[14..16]),
            .options = t[header_len..offset],
            .data = t[offset..],
        };
    }

    /// Its length on the wire: the header, its options, its data.
    pub fn len(s: Segment) usize {
        return header_len + s.options.len + s.data.len;
    }

    /// **THE SEGMENT INTO `t`**, which is `len()` bytes, with a zero
    /// checksum and urgent pointer: the checksum is the caller's, over the
    /// pseudo-header. `options` must be a whole number of 32-bit words.
    pub fn write(s: Segment, t: []u8) void {
        std.debug.assert(t.len == s.len() and s.options.len % 4 == 0);
        const hlen = header_len + s.options.len;
        @memcpy(t[0..2], &proto.be16(s.src_port));
        @memcpy(t[2..4], &proto.be16(s.dst_port));
        @memcpy(t[4..8], &proto.be32(s.seq));
        @memcpy(t[8..12], &proto.be32(s.ack));
        t[12] = @intCast((hlen / 4) << 4);
        t[13] = s.ctl.byte();
        @memcpy(t[14..16], &proto.be16(s.window));
        @memcpy(t[16..18], &proto.be16(0)); // the checksum, over a zeroed checksum
        @memcpy(t[18..20], &proto.be16(0)); // no urgent pointer
        @memcpy(t[header_len..hlen], s.options);
        @memcpy(t[hlen..], s.data);
    }
};

test "a segment written and parsed again is the same segment" {
    const opts = [4]u8{ 2, 4, 0x05, 0xB4 };
    const s: Segment = .{ .src_port = 80, .dst_port = 40000, .seq = 0xFFFF_FFF0, .ack = 7, .ctl = .{ .syn = true, .ack = true }, .window = 0xFFFF, .options = &opts, .data = "hi" };
    var buf: [header_len + 4 + 2]u8 = undefined;
    s.write(&buf);
    const back = Segment.parse(&buf).?;
    try std.testing.expectEqual(s.src_port, back.src_port);
    try std.testing.expectEqual(s.dst_port, back.dst_port);
    try std.testing.expectEqual(s.seq, back.seq);
    try std.testing.expectEqual(s.ack, back.ack);
    try std.testing.expectEqual(s.ctl, back.ctl);
    try std.testing.expectEqual(s.window, back.window);
    try std.testing.expectEqualSlices(u8, &opts, back.options);
    try std.testing.expectEqualStrings("hi", back.data);
    try std.testing.expectEqual(@as(u8, flag_syn | flag_ack), buf[13]);
    try std.testing.expectEqual(@as(u8, 6 << 4), buf[12]);
}

test "a data offset under the header, or past the payload, is no segment" {
    var buf: [header_len]u8 = @splat(0);
    buf[12] = 4 << 4; // 16 bytes: under the fixed header
    try std.testing.expectEqual(@as(?Segment, null), Segment.parse(&buf));
    buf[12] = 6 << 4; // 24 bytes, in a payload of 20
    try std.testing.expectEqual(@as(?Segment, null), Segment.parse(&buf));
    buf[12] = 5 << 4;
    try std.testing.expect(Segment.parse(&buf) != null);
    try std.testing.expectEqual(@as(?Segment, null), Segment.parse(buf[0..19]));
}

test "every control bit is read and written in its own place" {
    for (0..32) |b| {
        const bits: u8 = @intCast(b);
        try std.testing.expectEqual(bits, Ctl.of(bits).byte());
    }
}
