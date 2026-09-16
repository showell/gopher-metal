//! TCP, for a server that takes one connection at a time and answers one
//! request on it.
//!
//! **THIS IS DELIBERATELY THE SMALL TCP.** No congestion control, no
//! retransmission, no out-of-order reassembly, no keep-alive, one connection.
//! That is not laziness about the general case — it is the shape the thing
//! above it already has. `angry-gopher/zig-server`'s own comment says keep-alive
//! is deliberately off and its accept loop is single-threaded, so a connection
//! here is: accept, read a request, write a response, close.
//!
//! The two simplifications that make it small are worth naming, because each
//! is a real assumption about the wire:
//!
//! - **In-order only.** A segment whose sequence is not exactly what we expect
//!   is dropped and re-acknowledged, which asks the peer to send it again. On a
//!   private network between two machines that is rare; over the open internet
//!   it would be a performance disaster. This box sits behind Caddy on a
//!   private network, which is the whole reason that trade is allowed.
//! - **No retransmit timer.** If something we send is lost, the connection
//!   stalls rather than recovering. The same argument applies, and the day it
//!   stops applying is the day this file grows a clock.

const proto = @import("proto.zig");
const net = @import("net.zig");

pub const header_len: usize = 20;
const payload_at: usize = proto.eth_header_len + proto.ip_header_len + header_len;

const flag_fin: u8 = 0x01;
const flag_syn: u8 = 0x02;
const flag_rst: u8 = 0x04;
const flag_psh: u8 = 0x08;
const flag_ack: u8 = 0x10;

/// What we tell the peer we can take. One buffer's worth, since we read a
/// whole request before answering.
const window: u16 = 8192;

pub const State = enum {
    listen,
    syn_received,
    established,
    /// We have sent our FIN and are waiting for the peer to finish.
    closing,
    closed,
};

/// What `handle` decided a frame meant.
pub const Event = enum {
    /// Nothing for us, or nothing worth telling the caller.
    nothing,
    /// The handshake completed.
    opened,
    /// `received` grew.
    data,
    /// The connection is over; the listener is back to listening.
    closed,
};

pub const Listener = struct {
    local_ip: [4]u8,
    local_mac: [6]u8,
    port: u16,

    state: State = .listen,
    peer_ip: [4]u8 = proto.ip_any,
    peer_mac: [6]u8 = proto.mac_broadcast,
    peer_port: u16 = 0,

    /// The next sequence number we will send, and the next we expect.
    snd_nxt: u32 = 0,
    rcv_nxt: u32 = 0,

    /// What the peer has sent us on this connection so far.
    received: []u8,
    received_len: usize = 0,

    /// Scratch for one outgoing frame.
    out: []u8,

    pub fn init(ip: [4]u8, mac: [6]u8, port: u16, received: []u8, out: []u8) Listener {
        return .{ .local_ip = ip, .local_mac = mac, .port = port, .received = received, .out = out };
    }

    fn reset(self: *Listener) void {
        self.state = .listen;
        self.received_len = 0;
        self.peer_port = 0;
    }

    /// Builds and sends one segment. `payload` is already at `payload_at` in
    /// `self.out` when `payload_len` is nonzero.
    fn emit(self: *Listener, nic: *net.Net, flags: u8, payload_len: usize) void {
        const frame_len = proto.writeIpv4(
            self.out,
            self.local_mac,
            self.peer_mac,
            self.local_ip,
            self.peer_ip,
            proto.proto_tcp,
            header_len + payload_len,
        );

        const t = self.out[proto.eth_header_len + proto.ip_header_len ..][0 .. header_len + payload_len];
        @memcpy(t[0..2], &proto.be16(self.port));
        @memcpy(t[2..4], &proto.be16(self.peer_port));
        @memcpy(t[4..8], &proto.be32(self.snd_nxt));
        @memcpy(t[8..12], &proto.be32(self.rcv_nxt));
        t[12] = (header_len / 4) << 4; // data offset, no options
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(window));
        @memcpy(t[16..18], &proto.be16(0)); // the checksum, over a zeroed checksum
        @memcpy(t[18..20], &proto.be16(0)); // no urgent pointer
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(self.local_ip, self.peer_ip, proto.proto_tcp, t)));

        nic.send(self.out[0..frame_len]);

        // SYN and FIN each take one sequence number, as if they were a byte.
        if (flags & (flag_syn | flag_fin) != 0) self.snd_nxt +%= 1;
        self.snd_nxt +%= @intCast(payload_len);
    }

    /// Sends `bytes` on the open connection. The caller keeps it under one
    /// segment's worth; there is no segmentation here.
    pub fn send(self: *Listener, nic: *net.Net, bytes: []const u8) void {
        if (self.state != .established) return;
        @memcpy(self.out[payload_at..][0..bytes.len], bytes);
        self.emit(nic, flag_psh | flag_ack, bytes.len);
    }

    /// Says we are done sending. The connection closes when the peer agrees.
    pub fn finish(self: *Listener, nic: *net.Net) void {
        if (self.state != .established) return;
        self.emit(nic, flag_fin | flag_ack, 0);
        self.state = .closing;
    }

    /// Feeds one received frame in. Answers what it meant.
    pub fn handle(self: *Listener, nic: *net.Net, frame: []const u8) Event {
        const pkt = proto.parseIpv4(frame) orelse return .nothing;
        if (pkt.protocol != proto.proto_tcp) return .nothing;
        if (!eql(&pkt.dst_ip, &self.local_ip)) return .nothing;
        if (pkt.payload.len < header_len) return .nothing;

        const t = pkt.payload;
        const dst_port = proto.readBe16(t[2..4]);
        if (dst_port != self.port) return .nothing;

        const src_port = proto.readBe16(t[0..2]);
        const seq = proto.readBe32(t[4..8]);
        const flags = t[13];
        const offset = @as(usize, t[12] >> 4) * 4;
        if (offset < header_len or offset > t.len) return .nothing;
        const data = t[offset..];

        if (flags & flag_rst != 0) {
            if (self.state != .listen and src_port == self.peer_port) {
                self.reset();
                return .closed;
            }
            return .nothing;
        }

        // A SYN with no connection open is the start of one. A SYN while one is
        // open is someone else knocking, and is ignored rather than answered:
        // this listener takes one connection at a time.
        if (self.state == .listen) {
            if (flags & flag_syn == 0) return .nothing;
            self.peer_ip = pkt.src_ip;
            self.peer_mac = pkt.src_mac;
            self.peer_port = src_port;
            self.rcv_nxt = seq +% 1; // their SYN takes one
            // An initial sequence number only has to be unlike the last
            // connection's on this pair, and nothing here has a clock.
            self.snd_nxt = 0x4D45_5441;
            self.state = .syn_received;
            self.emit(nic, flag_syn | flag_ack, 0);
            return .nothing;
        }

        if (src_port != self.peer_port or !eql(&pkt.src_ip, &self.peer_ip)) return .nothing;

        if (self.state == .syn_received) {
            if (flags & flag_ack == 0) return .nothing;
            self.state = .established;
            // Their ACK may carry the first data, so fall through.
        }

        var event: Event = .nothing;

        // **IN-ORDER ONLY.** Anything else is dropped and re-acknowledged,
        // which asks for it again.
        if (data.len > 0) {
            if (seq != self.rcv_nxt) {
                self.emit(nic, flag_ack, 0);
                return .nothing;
            }
            const room = self.received.len - self.received_len;
            const n = @min(room, data.len);
            @memcpy(self.received[self.received_len..][0..n], data[0..n]);
            self.received_len += n;
            self.rcv_nxt +%= @intCast(n);
            self.emit(nic, flag_ack, 0);
            event = .data;
        }

        if (flags & flag_fin != 0 and seq +% @as(u32, @intCast(data.len)) == self.rcv_nxt) {
            self.rcv_nxt +%= 1; // their FIN takes one
            if (self.state == .established) {
                // They are done first: acknowledge, say we are done too.
                self.emit(nic, flag_fin | flag_ack, 0);
            } else {
                self.emit(nic, flag_ack, 0);
            }
            self.reset();
            return .closed;
        }

        if (self.state == .closing and flags & flag_ack != 0 and data.len == 0) {
            // They have acknowledged our FIN but not sent theirs. Nothing more
            // is coming on this connection that we care about.
            self.reset();
            return .closed;
        }

        if (event == .nothing and self.state == .established) return .opened;
        return event;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
