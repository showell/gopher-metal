//! ARP, and only the half a server needs: answering "who has this address?"
//!
//! **A MACHINE THAT DOES NOT ANSWER ARP CANNOT BE REACHED.** Before anything
//! sends us a packet it asks the wire who owns our address, and silence means
//! the packet is never built. This is twenty-eight bytes of reply and it is the
//! difference between having an address and being at it.
//!
//! There is no cache and no request side. Everything we send goes to whoever
//! sent to us first, so we already know their hardware address.

const proto = @import("proto.zig");

const packet_len: usize = 28;
const htype_ethernet: u16 = 1;
const oper_request: u16 = 1;
const oper_reply: u16 = 2;

pub const Request = struct {
    /// Who is asking, so the reply can go straight back to them.
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    /// The address they want the owner of.
    target_ip: [4]u8,
};

/// An ARP request out of an ethernet frame, or null for anything else —
/// another ethertype, a reply, a hardware or protocol pair we do not speak.
pub fn parseRequest(frame: []const u8) ?Request {
    if (frame.len < proto.eth_header_len + packet_len) return null;
    if (proto.readBe16(frame[12..14]) != proto.ethertype_arp) return null;

    const a = frame[proto.eth_header_len..];
    if (proto.readBe16(a[0..2]) != htype_ethernet) return null;
    if (proto.readBe16(a[2..4]) != proto.ethertype_ipv4) return null;
    if (a[4] != 6 or a[5] != 4) return null;
    if (proto.readBe16(a[6..8]) != oper_request) return null;

    return .{
        .sender_mac = a[8..14].*,
        .sender_ip = a[14..18].*,
        .target_ip = a[24..28].*,
    };
}

/// Writes the reply to `req` into `out`, claiming `ip` for `mac`. Answers the
/// frame length.
pub fn writeReply(out: []u8, mac: [6]u8, ip: [4]u8, req: Request) usize {
    proto.writeEth(out, req.sender_mac, mac, proto.ethertype_arp);

    const a = out[proto.eth_header_len..][0..packet_len];
    @memcpy(a[0..2], &proto.be16(htype_ethernet));
    @memcpy(a[2..4], &proto.be16(proto.ethertype_ipv4));
    a[4] = 6;
    a[5] = 4;
    @memcpy(a[6..8], &proto.be16(oper_reply));
    @memcpy(a[8..14], &mac); // we are the sender of the reply
    @memcpy(a[14..18], &ip);
    @memcpy(a[18..24], &req.sender_mac); // and they are its target
    @memcpy(a[24..28], &req.sender_ip);

    return proto.eth_header_len + packet_len;
}
