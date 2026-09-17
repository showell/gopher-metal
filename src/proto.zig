//! Ethernet, IPv4 and UDP: enough to put a datagram on the wire and to
//! recognise one coming back.
//!
//! Everything here is big-endian on the wire and little-endian in the machine,
//! so every multi-byte field goes through `be16`/`be32`. That is the single
//! most common way this kind of code is wrong, so there are no raw stores of a
//! multi-byte field anywhere in this file.
//!
//! This is deliberately not a network stack. There is no routing table, no
//! fragmentation, no ARP cache and no retransmission -- it is the smallest
//! thing that can carry DHCP, which is the first thing a machine needs. TCP
//! attaches here when it arrives.

pub const mac_broadcast = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
pub const ip_any = [4]u8{ 0, 0, 0, 0 };
pub const ip_broadcast = [4]u8{ 255, 255, 255, 255 };

pub const ethertype_ipv4: u16 = 0x0800;
pub const ethertype_arp: u16 = 0x0806;

pub const proto_udp: u8 = 17;
pub const proto_tcp: u8 = 6;

pub fn be16(v: u16) [2]u8 {
    return .{ @truncate(v >> 8), @truncate(v) };
}

pub fn be32(v: u32) [4]u8 {
    return .{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

pub fn readBe16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

pub fn readBe32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

/// The ones-complement sum every IP-family header uses. An odd-length buffer
/// is padded with a zero byte, which is what the RFC says and what a naive
/// loop gets wrong.
pub fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

pub const eth_header_len: usize = 14;
pub const ip_header_len: usize = 20;
pub const udp_header_len: usize = 8;
pub const udp_payload_at: usize = eth_header_len + ip_header_len + udp_header_len;

/// The pseudo-header checksum TCP (and optionally UDP) is defined over: the
/// addresses and protocol from the IP header, the segment length, and then the
/// segment itself. **TCP's checksum is not optional**, unlike UDP's over IPv4,
/// and a wrong one is dropped silently by the other end -- which looks exactly
/// like the segment never arriving.
pub fn pseudoChecksum(src_ip: [4]u8, dst_ip: [4]u8, protocol: u8, segment: []const u8) u16 {
    var sum: u32 = 0;
    sum += (@as(u32, src_ip[0]) << 8) | src_ip[1];
    sum += (@as(u32, src_ip[2]) << 8) | src_ip[3];
    sum += (@as(u32, dst_ip[0]) << 8) | dst_ip[1];
    sum += (@as(u32, dst_ip[2]) << 8) | dst_ip[3];
    sum += protocol;
    sum += @as(u32, @intCast(segment.len));

    var i: usize = 0;
    while (i + 1 < segment.len) : (i += 2) {
        sum += (@as(u32, segment[i]) << 8) | segment[i + 1];
    }
    if (i < segment.len) sum += @as(u32, segment[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

/// Writes an ethernet header at the front of `out`.
pub fn writeEth(out: []u8, dst: [6]u8, src: [6]u8, ethertype: u16) void {
    @memcpy(out[0..6], &dst);
    @memcpy(out[6..12], &src);
    @memcpy(out[12..14], &be16(ethertype));
}

/// An ethernet header and an IPv4 header into `out`, for a payload of
/// `payload_len` already in place at `eth_header_len + ip_header_len`.
/// Answers the total frame length.
///
/// The IPv4 header checksum is not optional and is computed here; what the
/// payload's own checksum should be is the caller's business.
pub fn writeIpv4(
    out: []u8,
    src_mac: [6]u8,
    dst_mac: [6]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    payload_len: usize,
) usize {
    writeEth(out, dst_mac, src_mac, ethertype_ipv4);

    const ip = out[eth_header_len..][0..ip_header_len];
    const total = ip_header_len + payload_len;
    ip[0] = 0x45; // IPv4, a 20-byte header
    ip[1] = 0; // no differentiated services
    @memcpy(ip[2..4], &be16(@intCast(total)));
    @memcpy(ip[4..6], &be16(0)); // identification
    @memcpy(ip[6..8], &be16(0x4000)); // don't fragment
    ip[8] = 64; // time to live
    ip[9] = protocol;
    @memcpy(ip[10..12], &be16(0)); // the checksum, over a zeroed checksum
    @memcpy(ip[12..16], &src_ip);
    @memcpy(ip[16..20], &dst_ip);
    @memcpy(ip[10..12], &be16(checksum(ip)));

    return eth_header_len + total;
}

/// A whole UDP-over-IPv4 datagram into `out`, payload already in place at
/// `udp_payload_at`. Answers the total frame length.
///
/// The UDP checksum is left at zero, which IPv4 permits and every stack
/// accepts.
pub fn writeUdp(
    out: []u8,
    src_mac: [6]u8,
    dst_mac: [6]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    payload_len: usize,
) usize {
    const frame_len = writeIpv4(out, src_mac, dst_mac, src_ip, dst_ip, proto_udp, udp_header_len + payload_len);

    const udp = out[eth_header_len + ip_header_len ..][0..udp_header_len];
    @memcpy(udp[0..2], &be16(src_port));
    @memcpy(udp[2..4], &be16(dst_port));
    @memcpy(udp[4..6], &be16(@intCast(udp_header_len + payload_len)));
    @memcpy(udp[6..8], &be16(0)); // no checksum, which IPv4 allows

    return frame_len;
}

/// What a received frame turned out to be, when it is a UDP datagram we could
/// make sense of.
pub const Datagram = struct {
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    payload: []const u8,
};

/// An IPv4 packet we could make sense of.
pub const Packet = struct {
    src_mac: [6]u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    payload: []const u8,
};

/// Picks an IPv4 packet out of an ethernet frame, or answers null for anything
/// else -- a different ethertype, a fragment, options in the header, a
/// truncated frame. **Every one of those is a silent null**, because on a real
/// wire most frames are not for us and a driver that complains about each one
/// is unusable.
pub fn parseIpv4(frame: []const u8) ?Packet {
    if (frame.len < eth_header_len + ip_header_len) return null;
    if (readBe16(frame[12..14]) != ethertype_ipv4) return null;

    const ip = frame[eth_header_len..];
    if (ip[0] >> 4 != 4) return null;
    const ihl = @as(usize, ip[0] & 0x0F) * 4;
    if (ihl != ip_header_len) return null; // no options here
    // A fragment is not a packet: the more-fragments bit, or a nonzero offset.
    if (readBe16(ip[6..8]) & 0x1FFF != 0 or ip[6] & 0x20 != 0) return null;

    const total = readBe16(ip[2..4]);
    if (total < ihl) return null;
    // A header damaged on the way describes nothing.
    if (checksum(ip[0..ihl]) != 0) return null;
    if (eth_header_len + total > frame.len) return null;

    return .{
        .src_mac = frame[6..12].*,
        .src_ip = ip[12..16].*,
        .dst_ip = ip[16..20].*,
        .protocol = ip[9],
        .payload = ip[ihl..total],
    };
}

/// Picks a UDP datagram out of an ethernet frame, or answers null for anything
/// else -- a different ethertype, a fragment, options in the IP header, a
/// truncated frame. **Every one of those is a silent null**, because on a real
/// wire most frames are not for us and a driver that complains about each one
/// is unusable.
pub fn parseUdp(frame: []const u8) ?Datagram {
    const pkt = parseIpv4(frame) orelse return null;
    if (pkt.protocol != proto_udp) return null;
    if (pkt.payload.len < udp_header_len) return null;

    const udp = pkt.payload;
    const udp_len = readBe16(udp[4..6]);
    if (udp_len < udp_header_len or udp_len > udp.len) return null;

    return .{
        .src_ip = pkt.src_ip,
        .dst_ip = pkt.dst_ip,
        .src_port = readBe16(udp[0..2]),
        .dst_port = readBe16(udp[2..4]),
        .payload = udp[udp_header_len..udp_len],
    };
}
