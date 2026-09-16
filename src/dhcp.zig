//! A DHCP client: DISCOVER, OFFER, REQUEST, ACK.
//!
//! This is the first protocol a machine with no operating system needs, and it
//! is a good first one to write: it is short, it is request/response, and
//! there is a server on the other side of QEMU's user-mode networking that
//! answers it without anything being configured.
//!
//! It is also the same exchange Cobblestone's `dhcp-acquire` performs through
//! the Roc machine, which makes the two directly comparable -- one written in
//! zig against a virtio NIC, one in Roc against an emulated NE2000, both
//! ending in a lease. That was the point of doing this one first.
//!
//! What it does NOT do: renew, rebind, decline, or handle a NAK. A lease here
//! is taken once and kept until the machine stops.

const proto = @import("proto.zig");
const net = @import("net.zig");

const port_server: u16 = 67;
const port_client: u16 = 68;

const op_request: u8 = 1;
const op_reply: u8 = 2;
const htype_ethernet: u8 = 1;

/// The four bytes that say the options area is DHCP and not plain BOOTP.
const magic_cookie = [4]u8{ 0x63, 0x82, 0x53, 0x63 };

const opt_subnet_mask: u8 = 1;
const opt_router: u8 = 3;
const opt_dns: u8 = 6;
const opt_requested_ip: u8 = 50;
const opt_message_type: u8 = 53;
const opt_server_id: u8 = 54;
const opt_param_list: u8 = 55;
const opt_end: u8 = 255;

const msg_discover: u8 = 1;
const msg_offer: u8 = 2;
const msg_request: u8 = 3;
const msg_ack: u8 = 5;
const msg_nak: u8 = 6;

/// The fixed part of a BOOTP message, before the options.
const bootp_len: usize = 236;

pub const Lease = struct {
    address: [4]u8 = proto.ip_any,
    mask: [4]u8 = proto.ip_any,
    router: [4]u8 = proto.ip_any,
    dns: [4]u8 = proto.ip_any,
    server: [4]u8 = proto.ip_any,
};

pub const Error = error{ NoOffer, NoAck, Refused };

/// Fills the BOOTP fixed fields and the cookie, and answers where options
/// start.
fn writeBootp(p: []u8, xid: u32, mac: [6]u8, broadcast: bool) usize {
    @memset(p[0..bootp_len], 0);
    p[0] = op_request;
    p[1] = htype_ethernet;
    p[2] = 6; // hardware address length
    p[3] = 0; // hops
    @memcpy(p[4..8], &proto.be32(xid));
    // **THE BROADCAST FLAG MATTERS.** We have no address yet, so a server that
    // replies by unicast would have to ARP for an address we cannot answer to.
    // Asking it to broadcast its reply is what makes the exchange work at all.
    @memcpy(p[10..12], &proto.be16(if (broadcast) 0x8000 else 0));
    @memcpy(p[28..34], &mac); // chaddr
    @memcpy(p[236..240], &magic_cookie);
    return 240;
}

fn option(p: []u8, at: usize, code: u8, value: []const u8) usize {
    p[at] = code;
    p[at + 1] = @intCast(value.len);
    @memcpy(p[at + 2 ..][0..value.len], value);
    return at + 2 + value.len;
}

/// Walks the options area looking for one code. Answers its value, or null.
/// A malformed option list ends the walk rather than running off the end.
fn findOption(payload: []const u8, want: u8) ?[]const u8 {
    if (payload.len < 240) return null;
    var at: usize = 240;
    while (at < payload.len) {
        const code = payload[at];
        if (code == opt_end) return null;
        if (code == 0) { // pad
            at += 1;
            continue;
        }
        if (at + 1 >= payload.len) return null;
        const len = payload[at + 1];
        if (at + 2 + len > payload.len) return null;
        if (code == want) return payload[at + 2 ..][0..len];
        at += 2 + len;
    }
    return null;
}

fn messageType(payload: []const u8) ?u8 {
    const v = findOption(payload, opt_message_type) orelse return null;
    return if (v.len == 1) v[0] else null;
}

fn ipOption(payload: []const u8, code: u8) [4]u8 {
    const v = findOption(payload, code) orelse return proto.ip_any;
    return if (v.len >= 4) v[0..4].* else proto.ip_any;
}

/// A reply to our exchange: the right transaction, addressed to our port, and
/// a BOOTP reply rather than someone else's request.
fn replyFor(payload: []const u8, xid: u32, mac: [6]u8) bool {
    if (payload.len < 240) return false;
    if (payload[0] != op_reply) return false;
    if (proto.readBe32(payload[4..8]) != xid) return false;
    return std_mem_eql(payload[28..34], &mac);
}

fn std_mem_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Sends one message and waits for a reply of `want` type, giving up after
/// `spins` turns of the receive queue. Answers the payload, copied into
/// `reply`, because the frame it arrived in goes back to the device.
fn exchange(
    nic: *net.Net,
    frame: []u8,
    frame_len: usize,
    xid: u32,
    want: u8,
    reply: []u8,
    spins: usize,
) ?usize {
    nic.send(frame[0..frame_len]);

    var spun: usize = 0;
    while (spun < spins) : (spun += 1) {
        const got = nic.poll() orelse {
            asm volatile ("pause");
            continue;
        };
        defer nic.recycle(got.id);

        const dg = proto.parseUdp(got.frame) orelse continue;
        if (dg.dst_port != port_client or dg.src_port != port_server) continue;
        if (!replyFor(dg.payload, xid, nic.mac)) continue;
        const t = messageType(dg.payload) orelse continue;
        if (t == msg_nak) return null;
        if (t != want) continue;

        const n = @min(dg.payload.len, reply.len);
        @memcpy(reply[0..n], dg.payload[0..n]);
        return n;
    }
    return null;
}

/// The whole exchange. `frame` and `reply` are scratch the caller owns;
/// `frame` must be at least a frame long and `reply` at least 576 bytes.
pub fn acquire(nic: *net.Net, xid: u32, frame: []u8, reply: []u8) Error!Lease {
    const spins: usize = 20_000_000;

    // DISCOVER
    var at = writeBootp(frame[proto.udp_payload_at..], xid, nic.mac, true);
    const p = frame[proto.udp_payload_at..];
    at = option(p, at, opt_message_type, &.{msg_discover});
    at = option(p, at, opt_param_list, &.{ opt_subnet_mask, opt_router, opt_dns });
    p[at] = opt_end;
    at += 1;

    var len = proto.writeUdp(frame, nic.mac, proto.mac_broadcast, proto.ip_any, proto.ip_broadcast, port_client, port_server, at);
    const offer_len = exchange(nic, frame, len, xid, msg_offer, reply, spins) orelse return Error.NoOffer;
    const offer = reply[0..offer_len];

    var lease = Lease{
        .address = offer[16..20].*, // yiaddr
        .mask = ipOption(offer, opt_subnet_mask),
        .router = ipOption(offer, opt_router),
        .dns = ipOption(offer, opt_dns),
        .server = ipOption(offer, opt_server_id),
    };

    // REQUEST: name the address offered and the server that offered it, so a
    // second server on the wire knows its own offer was declined.
    at = writeBootp(p, xid, nic.mac, true);
    at = option(p, at, opt_message_type, &.{msg_request});
    at = option(p, at, opt_requested_ip, &lease.address);
    at = option(p, at, opt_server_id, &lease.server);
    p[at] = opt_end;
    at += 1;

    len = proto.writeUdp(frame, nic.mac, proto.mac_broadcast, proto.ip_any, proto.ip_broadcast, port_client, port_server, at);
    const ack_len = exchange(nic, frame, len, xid, msg_ack, reply, spins) orelse return Error.NoAck;
    const ack = reply[0..ack_len];

    // The ACK is the authority, not the offer: a server may hand over
    // something other than what it offered.
    lease.address = ack[16..20].*;
    if (findOption(ack, opt_subnet_mask) != null) lease.mask = ipOption(ack, opt_subnet_mask);
    if (findOption(ack, opt_router) != null) lease.router = ipOption(ack, opt_router);
    if (findOption(ack, opt_dns) != null) lease.dns = ipOption(ack, opt_dns);
    if (findOption(ack, opt_server_id) != null) lease.server = ipOption(ack, opt_server_id);

    return lease;
}
