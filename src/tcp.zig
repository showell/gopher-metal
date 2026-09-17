//! TCP for a server that holds many connections and answers one request on each.
//!
//! **A TABLE OF CONNECTIONS, NOT ONE.** Chat holds connections open for as long
//! as a tab is open, so the machine holds many at once. It still ANSWERS one
//! request at a time; the others wait in the table instead of at the door.
//!
//! **BOTH DIRECTIONS ARE STATE MACHINES THE LOOP TURNS.** Arriving frames are
//! fed to `handle`; what we have to say is put in each connection's send queue
//! with `queue`, and `transmit` — called on every turn of the loop — puts on
//! the wire whatever the peer has room for, sends again whatever was not
//! acknowledged in time, and gives up on a peer that has stopped answering.
//! Nothing here waits.
//!
//! **THE SEND SIDE KEEPS ITS PROMISES TO THE PEER.**
//!
//! - **The window.** Nothing is sent beyond what the peer last said it has
//!   room for. A peer that says zero is probed with one byte when the timer
//!   runs out, so a window that reopens is noticed even if its announcement
//!   was lost.
//! - **The segment size.** The SYN-ACK says ours, and the peer's SYN says its;
//!   a peer that says nothing is sent 536-byte segments, as the RFC requires.
//! - **Retransmission.** Bytes stay in the queue until they are acknowledged.
//!   If the oldest is not acknowledged within the timeout, everything from it
//!   on is sent again and the timeout doubles.
//! - **Giving up.** After `max_retries` timeouts with no progress the
//!   connection is reset. That is how a peer that vanished without a FIN is
//!   noticed, and also how one that stops reading is let go: its window stays
//!   shut, the probes make no progress, and the count runs out.
//! - **The FIN goes last**, after every queued byte, and only an
//!   acknowledgement of the FIN itself closes the connection.
//!
//! **STILL THE SMALL TCP**, allowed because this box sits behind Caddy on a
//! private network: no congestion control, no fast retransmit, no selective
//! acknowledgement, no window scaling, and received segments are taken in
//! order only — anything else is dropped and re-acknowledged, which asks the
//! peer to send it again.
//!
//! **PURE, SO IT IS TESTED ON THE HOST.** Nothing here reaches for a device.
//! Frames go out through whatever `wire` the caller hands in (anything with a
//! `send([]const u8)`), the initial sequence number comes from a function the
//! caller supplies, and the time is a number the caller passes. The kernel
//! passes the NIC, the entropy pool and its clock; the tests pass a recorder,
//! a counter and a fake.

const proto = @import("proto.zig");

pub const header_len: usize = 20;
pub const segment_at: usize = proto.eth_header_len + proto.ip_header_len;

pub const flag_fin: u8 = 0x01;
pub const flag_syn: u8 = 0x02;
pub const flag_rst: u8 = 0x04;
pub const flag_psh: u8 = 0x08;
pub const flag_ack: u8 = 0x10;

/// What a peer that says nothing about segment size may be sent (RFC 9293).
pub const default_mss: u16 = 536;
/// What we say we can take: an ethernet frame's worth, which the NIC's receive
/// buffers hold with room to spare.
pub const our_mss: u16 = 1460;
pub const mss_option = [4]u8{ 2, 4, our_mss >> 8, our_mss & 0xFF };

/// **THE RETRANSMISSION CLOCK.** Nothing here measures round-trip times, so
/// the first wait is the one RFC 6298 gives a sender that has not measured:
/// one second. (Linux's 200 ms is a floor under a measured estimate, and a
/// peer that delays its acknowledgements by up to 200 ms — slirp does — makes
/// it a race.) Each timeout doubles the wait up to the ceiling, and the
/// connection is reset once `max_retries` have passed with nothing
/// acknowledged — about 27 seconds of silence in all.
pub const first_rto_ns: u64 = 1 * ns_per_s;
pub const max_rto_ns: u64 = 5 * ns_per_s;
pub const max_retries: u8 = 6;
pub const ns_per_ms = 1_000_000;
pub const ns_per_s = 1_000_000_000;

pub const State = enum {
    /// The slot is free — unless the host still holds it (`claimed`).
    closed,
    syn_received,
    established,
    /// We have said we are done: the queue drains, then our FIN goes, and the
    /// connection ends when the FIN is acknowledged.
    closing,
};

/// Where our FIN is.
pub const Fin = enum { none, queued, sent, acknowledged };

/// One connection.
pub const Conn = struct {
    state: State = .closed,
    peer_ip: [4]u8 = proto.ip_any,
    peer_mac: [6]u8 = proto.mac_broadcast,
    peer_port: u16 = 0,

    /// The next sequence number we expect from the peer.
    rcv_nxt: u32 = 0,

    /// **WHAT THE PEER HAS SENT AND NOBODY HAS READ YET: `rx[start..end]`.**
    /// The reader consumes from the front, and the space it frees is what the
    /// window advertises.
    rx: []u8,
    start: usize = 0,
    end: usize = 0,

    /// **WHAT WE HAVE TO SAY AND THE PEER HAS NOT ACKNOWLEDGED:
    /// `tx[tx_start..tx_end]`.** The first `sent` of those bytes are on the
    /// wire; the rest wait for room in the peer's window. `tx[tx_start]` is
    /// the byte numbered `una`.
    tx: []u8,
    tx_start: usize = 0,
    tx_end: usize = 0,
    sent: usize = 0,
    /// The oldest sequence number the peer has not acknowledged. Before the
    /// handshake completes it is our SYN's.
    una: u32 = 0,
    fin: Fin = .none,
    /// How many bytes past `una` the peer last said it has room for.
    wnd: u32 = 0,
    /// The largest segment the peer said it takes.
    mss: u16 = default_mss,
    /// When the oldest unacknowledged thing is sent again, or a shut window
    /// probed. Null when nothing is waiting on the peer.
    rto_at: ?i96 = null,
    rto_ns: u64 = first_rto_ns,
    /// Timeouts since the peer last acknowledged anything.
    retries: u8 = 0,

    /// The peer has sent its FIN: nothing more is coming, but what already
    /// arrived is still there to be read.
    peer_done: bool = false,

    /// **HELD BY THE HOST.** A slot the host is serving is never handed to a
    /// new connection, even after this one ends — otherwise a reader part-way
    /// through a request could find a stranger's bytes in its buffer.
    claimed: bool = false,

    /// When the handshake started and when the peer was last heard from, in
    /// the caller's clock. The host uses them to serve oldest first and to let
    /// go of a connection that has gone quiet.
    opened_at: i96 = 0,
    heard_at: i96 = 0,
    /// Arrival order, which breaks ties between connections opened in the same
    /// clock tick.
    serial: u64 = 0,

    /// The bytes waiting to be read.
    pub fn pending(self: *const Conn) []u8 {
        return self.rx[self.start..self.end];
    }

    /// Marks `n` pending bytes as read. The buffer is compacted once the front
    /// is more than half consumed, so the window grows back as a request is
    /// read rather than only when the connection ends.
    pub fn consume(self: *Conn, n: usize) void {
        self.start += @min(n, self.end - self.start);
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        } else if (self.start > self.rx.len / 2) {
            const len = self.end - self.start;
            std.mem.copyForwards(u8, self.rx[0..len], self.rx[self.start..self.end]);
            self.start = 0;
            self.end = len;
        }
    }

    /// Free space at the end of the receive buffer, which is what arriving
    /// bytes can be put into and what the window advertises.
    pub fn room(self: *const Conn) usize {
        return self.rx.len - self.end;
    }

    /// Bytes we have queued that the peer has not acknowledged.
    pub fn queued(self: *const Conn) usize {
        return self.tx_end - self.tx_start;
    }

    /// How much more can be queued.
    pub fn queueRoom(self: *const Conn) usize {
        return self.tx.len - self.queued();
    }

    /// Is this connection still one we can talk to?
    pub fn open(self: *const Conn) bool {
        return self.state == .established or self.state == .syn_received;
    }

    /// The sequence number of the next thing we would send for the first
    /// time: after the SYN, the bytes on the wire, and the FIN if it is out.
    fn nxt(self: *const Conn) u32 {
        var n = self.una +% @as(u32, @intCast(self.sent));
        if (self.state == .syn_received) n +%= 1;
        if (self.fin == .sent) n +%= 1;
        return n;
    }

    fn reset(self: *Conn) void {
        const rx = self.rx;
        const tx = self.tx;
        const claimed = self.claimed;
        self.* = .{ .rx = rx, .tx = tx, .claimed = claimed };
    }

    fn window(self: *const Conn) u16 {
        return @intCast(@min(self.room(), 0xFFFF));
    }
};

pub const Result = struct {
    event: Event,
    /// Which connection it concerns; meaningless for `.nothing`.
    index: usize = 0,
};

/// What `handle` decided a frame meant.
pub const Event = enum {
    /// Nothing for the caller.
    nothing,
    /// A handshake completed.
    opened,
    /// A connection's pending bytes grew.
    data,
    /// The peer is done sending (its FIN arrived); what it sent is still
    /// pending.
    peer_done,
    /// A connection is over.
    closed,
};

pub const Table = struct {
    local_ip: [4]u8,
    local_mac: [6]u8,
    port: u16,
    conns: []Conn,
    /// Scratch for one outgoing frame.
    out: []u8,
    /// Where an initial sequence number comes from. It must be unpredictable
    /// on the wire: a guessable one lets an off-path attacker inject into a
    /// connection. The kernel passes the entropy pool.
    isn: *const fn () u32,

    arrivals: u64 = 0,
    /// SYNs dropped because every slot was taken — what Linux does when its
    /// accept queue is full. The peer retries; the count says it happened.
    refused: u64 = 0,
    /// Timeouts that sent something again.
    retransmits: u64 = 0,
    /// Bytes sent past a shut window to ask whether it has opened.
    probes: u64 = 0,
    /// Connections reset because the peer stopped acknowledging.
    given_up: u64 = 0,

    pub fn init(ip: [4]u8, mac: [6]u8, port: u16, conns: []Conn, out: []u8, isn: *const fn () u32) Table {
        return .{ .local_ip = ip, .local_mac = mac, .port = port, .conns = conns, .out = out, .isn = isn };
    }

    /// How many slots hold a connection or are held by the host.
    pub fn inUse(self: *const Table) usize {
        var n: usize = 0;
        for (self.conns) |c| {
            if (c.state != .closed or c.claimed) n += 1;
        }
        return n;
    }

    fn find(self: *Table, ip: [4]u8, port: u16) ?usize {
        for (self.conns, 0..) |c, i| {
            if (c.state != .closed and c.peer_port == port and eql(&c.peer_ip, &ip)) return i;
        }
        return null;
    }

    fn free(self: *Table) ?usize {
        for (self.conns, 0..) |c, i| {
            if (c.state == .closed and !c.claimed) return i;
        }
        return null;
    }

    /// Builds and sends one segment on connection `i`, numbered `seq`. A SYN
    /// carries our segment size.
    fn emit(self: *Table, wire: anytype, i: usize, flags: u8, seq: u32, payload: []const u8) void {
        const c = &self.conns[i];
        const options: []const u8 = if (flags & flag_syn != 0) &mss_option else &.{};
        const len = header_len + options.len;
        const frame_len = proto.writeIpv4(
            self.out,
            self.local_mac,
            c.peer_mac,
            self.local_ip,
            c.peer_ip,
            proto.proto_tcp,
            len + payload.len,
        );

        const t = self.out[segment_at..][0 .. len + payload.len];
        @memcpy(t[0..2], &proto.be16(self.port));
        @memcpy(t[2..4], &proto.be16(c.peer_port));
        @memcpy(t[4..8], &proto.be32(seq));
        @memcpy(t[8..12], &proto.be32(c.rcv_nxt));
        t[12] = @intCast((len / 4) << 4);
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(c.window()));
        @memcpy(t[16..18], &proto.be16(0)); // the checksum, over a zeroed checksum
        @memcpy(t[18..20], &proto.be16(0)); // no urgent pointer
        @memcpy(t[header_len..len], options);
        @memcpy(t[len..], payload);
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(self.local_ip, c.peer_ip, proto.proto_tcp, t)));

        wire.send(self.out[0..frame_len]);
    }

    /// Puts as much of `bytes` in connection `i`'s send queue as fits, and says
    /// how much that was. Nothing is sent until `transmit`. Nothing is taken
    /// on a connection that is not established, or once our FIN is queued.
    pub fn queue(self: *Table, i: usize, bytes: []const u8) usize {
        const c = &self.conns[i];
        if (c.state != .established or c.fin != .none) return 0;
        if (c.tx_end + bytes.len > c.tx.len and c.tx_start > 0) {
            const len = c.queued();
            std.mem.copyForwards(u8, c.tx[0..len], c.tx[c.tx_start..c.tx_end]);
            c.tx_start = 0;
            c.tx_end = len;
        }
        const n = @min(bytes.len, c.tx.len - c.tx_end);
        @memcpy(c.tx[c.tx_end..][0..n], bytes[0..n]);
        c.tx_end += n;
        return n;
    }

    /// Tells the peer how much room there is now. The reader calls it after
    /// consuming, so a peer that had filled the window learns it can go on
    /// without waiting for its own probe.
    pub fn ack(self: *Table, wire: anytype, i: usize) void {
        const c = &self.conns[i];
        if (c.state != .established and c.state != .closing) return;
        self.emit(wire, i, flag_ack, c.nxt(), "");
    }

    /// Says we are done sending. The FIN follows the last queued byte; the
    /// connection closes when the peer acknowledges it, or when the host stops
    /// waiting and abandons it.
    pub fn finish(self: *Table, i: usize) void {
        const c = &self.conns[i];
        if (c.state != .established) return;
        c.fin = .queued;
        c.state = .closing;
    }

    /// Gives up on connection `i`, telling the peer with a reset: a peer still
    /// waiting for the rest of an answer should not wait forever.
    pub fn abandon(self: *Table, wire: anytype, i: usize) void {
        const c = &self.conns[i];
        if (c.state == .established or c.state == .closing) {
            self.emit(wire, i, flag_rst | flag_ack, c.nxt(), "");
        }
        c.reset();
    }

    /// The host is serving connection `i`: its slot is not to be reused.
    pub fn claim(self: *Table, i: usize) void {
        self.conns[i].claimed = true;
    }

    /// The host is done with connection `i`. Whatever state it is in, the slot
    /// is free once it is closed.
    pub fn release(self: *Table, i: usize) void {
        self.conns[i].claimed = false;
    }

    /// One turn of the send side for every connection.
    pub fn transmit(self: *Table, wire: anytype, now: i96) void {
        for (self.conns, 0..) |c, i| {
            if (c.state == .closed) continue;
            self.transmitOne(wire, i, now);
        }
    }

    fn transmitOne(self: *Table, wire: anytype, i: usize, now: i96) void {
        const c = &self.conns[i];
        const expired = if (c.rto_at) |at| now >= at else false;

        if (c.state == .syn_received) {
            // The SYN-ACK was lost, or its answer was.
            if (!expired) return;
            if (!backoff(c, now)) return self.giveUp(wire, i);
            self.retransmits += 1;
            self.emit(wire, i, flag_syn | flag_ack, c.una, "");
            return;
        }

        var probe = false;
        if (expired) {
            if (!backoff(c, now)) return self.giveUp(wire, i);
            // **GO BACK.** Everything from the oldest unacknowledged byte on is
            // sent again; the peer drops what it already has.
            c.sent = 0;
            if (c.fin == .sent) c.fin = .queued;
            self.retransmits += 1;
            probe = true;
        }

        while (c.queued() > c.sent) {
            const usable = if (c.wnd > c.sent) c.wnd - c.sent else 0;
            var n = @min(c.queued() - c.sent, usable, c.mss);
            if (n == 0) {
                // **A SHUT WINDOW IS PROBED WHEN THE TIMER RUNS OUT.** One byte
                // past the window: the peer's answer carries its window again.
                if (!probe) {
                    if (c.rto_at == null) c.rto_at = now + c.rto_ns;
                    break;
                }
                self.probes += 1;
                n = 1;
            }
            probe = false;
            self.emit(wire, i, flag_psh | flag_ack, c.una +% @as(u32, @intCast(c.sent)), c.tx[c.tx_start + c.sent ..][0..n]);
            c.sent += n;
            if (c.rto_at == null) c.rto_at = now + c.rto_ns;
        }

        if (c.fin == .queued and c.sent == c.queued()) {
            self.emit(wire, i, flag_fin | flag_ack, c.una +% @as(u32, @intCast(c.sent)), "");
            c.fin = .sent;
            if (c.rto_at == null) c.rto_at = now + c.rto_ns;
        }
    }

    /// One more timeout: false once they have run out.
    fn backoff(c: *Conn, now: i96) bool {
        if (c.retries >= max_retries) return false;
        c.retries += 1;
        c.rto_ns = @min(c.rto_ns * 2, max_rto_ns);
        c.rto_at = now + c.rto_ns;
        return true;
    }

    fn giveUp(self: *Table, wire: anytype, i: usize) void {
        self.given_up += 1;
        self.abandon(wire, i);
    }

    /// Takes in the peer's acknowledgement and window. True once our FIN is
    /// acknowledged.
    fn acknowledge(c: *Conn, number: u32, window: u16, now: i96) bool {
        const flight = c.nxt() -% c.una;
        const advance = number -% c.una;
        // An acknowledgement of something never sent, or an old one (which
        // wraps to a huge advance): neither says anything current.
        if (advance > flight) return false;
        c.wnd = window;
        if (advance == 0) return false;

        const bytes = @min(advance, c.sent);
        c.tx_start += bytes;
        c.sent -= bytes;
        if (c.tx_start == c.tx_end) {
            c.tx_start = 0;
            c.tx_end = 0;
        }
        c.una +%= advance;
        if (advance > bytes) c.fin = .acknowledged;

        c.retries = 0;
        c.rto_ns = first_rto_ns;
        c.rto_at = if (c.nxt() != c.una) now + c.rto_ns else null;
        return c.fin == .acknowledged;
    }

    /// Feeds one received frame in. `now` is the caller's clock.
    pub fn handle(self: *Table, wire: anytype, frame: []const u8, now: i96) Result {
        const pkt = proto.parseIpv4(frame) orelse return .{ .event = .nothing };
        if (pkt.protocol != proto.proto_tcp) return .{ .event = .nothing };
        if (!eql(&pkt.dst_ip, &self.local_ip)) return .{ .event = .nothing };
        if (pkt.payload.len < header_len) return .{ .event = .nothing };

        const t = pkt.payload;
        if (proto.readBe16(t[2..4]) != self.port) return .{ .event = .nothing };

        const src_port = proto.readBe16(t[0..2]);
        const seq = proto.readBe32(t[4..8]);
        const number = proto.readBe32(t[8..12]);
        const flags = t[13];
        const window = proto.readBe16(t[14..16]);
        const offset = @as(usize, t[12] >> 4) * 4;
        if (offset < header_len or offset > t.len) return .{ .event = .nothing };
        const data = t[offset..];

        const found = self.find(pkt.src_ip, src_port);

        if (flags & flag_rst != 0) {
            const i = found orelse return .{ .event = .nothing };
            self.conns[i].reset();
            return .{ .event = .closed, .index = i };
        }

        // A SYN for no connection we know is the start of one — if there is a
        // slot for it.
        const i = found orelse {
            if (flags & flag_syn == 0) return .{ .event = .nothing };
            const slot = self.free() orelse {
                self.refused += 1;
                return .{ .event = .nothing };
            };
            const c = &self.conns[slot];
            c.reset();
            c.peer_ip = pkt.src_ip;
            c.peer_mac = pkt.src_mac;
            c.peer_port = src_port;
            c.rcv_nxt = seq +% 1; // their SYN takes one
            c.una = self.isn();
            c.mss = @min(parseMss(t[header_len..offset]) orelse default_mss, our_mss);
            c.wnd = window;
            c.state = .syn_received;
            c.opened_at = now;
            c.heard_at = now;
            c.rto_at = now + c.rto_ns;
            self.arrivals += 1;
            c.serial = self.arrivals;
            self.emit(wire, slot, flag_syn | flag_ack, c.una, "");
            return .{ .event = .nothing };
        };

        const c = &self.conns[i];
        c.heard_at = now;

        // A repeated SYN for a connection we already answered: the SYN-ACK was
        // lost or is late. Say it again, from the same starting number.
        if (flags & flag_syn != 0) {
            if (c.state == .syn_received) self.emit(wire, i, flag_syn | flag_ack, c.una, "");
            return .{ .event = .nothing };
        }

        // Every segment after the SYN acknowledges something.
        if (flags & flag_ack == 0) return .{ .event = .nothing };

        var event: Event = .nothing;
        var fin_acknowledged = false;
        if (c.state == .syn_received) {
            if (number != c.una +% 1) return .{ .event = .nothing };
            c.una = number;
            c.wnd = window;
            c.rto_at = null;
            c.retries = 0;
            c.rto_ns = first_rto_ns;
            c.state = .established;
            event = .opened;
            // Their ACK may carry the first data, so fall through.
        } else {
            fin_acknowledged = acknowledge(c, number, window, now);
        }

        // **IN-ORDER ONLY.** Anything else is dropped and re-acknowledged,
        // which asks for it again.
        if (data.len > 0) {
            if (seq != c.rcv_nxt or c.peer_done) {
                self.emit(wire, i, flag_ack, c.nxt(), "");
                return self.settle(i, event, fin_acknowledged);
            }
            // **WHAT FITS IS TAKEN, AND ONLY THAT IS ACKNOWLEDGED.** A peer
            // that sent past the window will send the rest again, once the
            // reader has made room.
            const n = @min(c.room(), data.len);
            @memcpy(c.rx[c.end..][0..n], data[0..n]);
            c.end += n;
            c.rcv_nxt +%= @intCast(n);
            self.emit(wire, i, flag_ack, c.nxt(), "");
            if (n > 0 and event == .nothing) event = .data;
            if (n < data.len) return self.settle(i, event, fin_acknowledged);
        }

        if (flags & flag_fin != 0 and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt) {
            c.rcv_nxt +%= 1; // their FIN takes one
            c.peer_done = true;
            self.emit(wire, i, flag_ack, c.nxt(), "");
            if (!fin_acknowledged) return .{ .event = .peer_done, .index = i };
        }

        return self.settle(i, event, fin_acknowledged);
    }

    /// A connection whose FIN the peer has acknowledged is over; any other
    /// reports what the frame did.
    fn settle(self: *Table, i: usize, event: Event, fin_acknowledged: bool) Result {
        if (!fin_acknowledged) return .{ .event = event, .index = i };
        self.conns[i].reset();
        return .{ .event = .closed, .index = i };
    }
};

/// The maximum segment size a SYN's options carry, if they carry one.
pub fn parseMss(options: []const u8) ?u16 {
    var k: usize = 0;
    while (k < options.len) {
        switch (options[k]) {
            0 => return null, // end of options
            1 => k += 1, // padding
            else => {
                if (k + 1 >= options.len) return null;
                const len = options[k + 1];
                if (len < 2 or k + len > options.len) return null;
                if (options[k] == 2 and len == 4) return proto.readBe16(options[k + 2 .. k + 4]);
                k += len;
            },
        }
    }
    return null;
}

const std = @import("std");

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
