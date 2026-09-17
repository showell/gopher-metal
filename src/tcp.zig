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
//! - **The FIN goes last**, after every queued byte. Once it is acknowledged
//!   the connection waits for the peer's FIN, acknowledges it, and closes; a
//!   peer that never sends one is let go after `fin_wait_ns`. (There is no
//!   TIME-WAIT: a FIN repeated after the close is answered with a reset.)
//! - **A segment for no connection we hold is answered with a reset**, so a
//!   peer never waits on a connection this side has forgotten.
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

/// **THE RETRANSMISSION CLOCK, MEASURED.** How long to wait before sending
/// something again is a fact about the path, and the path is measured: every
/// connection times one segment at a time and keeps RFC 6298's smoothed
/// estimate, `srtt + 4 * rttvar`. The handshake is the first sample, so even
/// the first byte of a response is sent under a measured clock.
///
/// **THE FLOOR IS NOT ABOUT THE PATH; IT IS ABOUT THE PEER'S DELAYED
/// ACKNOWLEDGEMENTS.** A peer may sit on an acknowledgement for tens of
/// milliseconds (Linux) or up to 200 (slirp, in front of QEMU). Waiting less
/// than that turns a delay into a "loss" and makes us re-send a whole window
/// for nothing, so the floor is Linux's own `TCP_RTO_MIN`. It is also the
/// first wait, before anything is measured: this machine answers Caddy over a
/// private network, not the open internet, and RFC 6298's unmeasured second is
/// a thousand times the round trip we will actually see.
///
/// Each timeout doubles the wait up to the ceiling, and the connection is
/// reset once `max_retries` have passed with nothing acknowledged.
pub const min_rto_ns: u64 = 200 * ns_per_ms;
pub const first_rto_ns: u64 = min_rto_ns;
pub const max_rto_ns: u64 = 5 * ns_per_s;
pub const max_retries: u8 = 6;
/// **HOW MANY DUPLICATE ACKNOWLEDGEMENTS MEAN A SEGMENT IS GONE** (RFC 5681).
/// A peer that receives what came after a lost segment says so at once, by
/// acknowledging the same byte again for each one. Three of those are the
/// peer telling us what the timer would only guess at a round trip later.
pub const dupacks_before_resend: u8 = 3;
/// How long a connection whose FIN was acknowledged waits for the peer's.
pub const fin_wait_ns: u64 = 30 * ns_per_s;
pub const ns_per_ms = 1_000_000;
pub const ns_per_s = 1_000_000_000;

pub const State = enum {
    /// The slot is free — unless the host still holds it (`claimed`).
    closed,
    syn_received,
    established,
    /// We have said we are done: the queue drains, then our FIN goes; once it
    /// is acknowledged and the peer's FIN has arrived, the connection is over.
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
    /// The most bytes past `una` ever on the wire. A timeout sends from `una`
    /// again, so `sent` goes back; an acknowledgement of what was sent before
    /// that is still an acknowledgement.
    high: usize = 0,
    /// Our FIN has been on the wire at least once.
    fin_ever_sent: bool = false,
    /// The oldest sequence number the peer has not acknowledged. Before the
    /// handshake completes it is our SYN's.
    una: u32 = 0,
    fin: Fin = .none,
    /// How many bytes past `una` the peer last said it has room for.
    wnd: u32 = 0,
    /// The sequence and acknowledgement numbers of the segment that last set
    /// `wnd` (RFC 9293's SND.WL1 and SND.WL2): an older segment, arriving
    /// late, does not overrule a newer one's window.
    wl1: u32 = 0,
    wl2: u32 = 0,
    /// The largest segment the peer said it takes.
    mss: u16 = default_mss,
    /// When the oldest unacknowledged thing is sent again, or a shut window
    /// probed. Null when nothing is waiting on the peer.
    rto_at: ?i96 = null,
    rto_ns: u64 = first_rto_ns,
    /// Timeouts since the peer last acknowledged anything.
    retries: u8 = 0,
    /// **THE PATH, AS MEASURED** (RFC 6298's SRTT and RTTVAR). Zero until the
    /// first sample, which the handshake provides.
    srtt_ns: u64 = 0,
    rttvar_ns: u64 = 0,
    /// The one segment being timed: when it went out, and the sequence number
    /// just past it. Null when nothing is being timed — including after a
    /// re-send, because there is then no telling which copy was answered
    /// (Karn's algorithm), so that sample is thrown away.
    timed_at: ?i96 = null,
    timed_seq: u32 = 0,
    /// Acknowledgements of the same byte in a row: the peer saying it is
    /// receiving what came after something that never arrived.
    dupacks: u8 = 0,
    /// Whether this run of duplicates has already been answered. Cleared when
    /// the peer acknowledges something new.
    resent_early: bool = false,
    /// Our FIN is acknowledged and the peer's has not come: until when to
    /// wait for it.
    fin_wait_until: ?i96 = null,

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

    /// **SND.NXT: just past the furthest thing we have ever sent.** Every
    /// segment that carries nothing — an acknowledgement, a reset — is
    /// numbered here, because that is the only number the peer is expecting.
    /// `sent` is not it: a timeout rewinds `sent` to re-send from `una`, and a
    /// segment numbered back there is behind the peer's window and is
    /// discarded (a reset) or answered with a duplicate acknowledgement.
    fn highest(self: *const Conn) u32 {
        var n = self.una +% @as(u32, @intCast(self.high));
        if (self.state == .syn_received) n +%= 1;
        if (self.fin_ever_sent and self.fin != .acknowledged) n +%= 1;
        return n;
    }

    /// Starts timing a segment, if nothing is being timed already. One sample
    /// at a time is all RFC 6298 asks for without timestamps.
    fn time(self: *Conn, now: i96, past_it: u32) void {
        if (self.timed_at != null) return;
        self.timed_at = now;
        self.timed_seq = past_it;
    }

    /// Whether `seq` is past `rcv_nxt` but inside the window we advertise.
    fn ahead(self: *const Conn, seq: u32) bool {
        const off = seq -% self.rcv_nxt;
        return off != 0 and off < @max(self.window(), 1);
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
    /// Segments sent again, whether a timer or the peer's duplicate
    /// acknowledgements asked for it.
    retransmits: u64 = 0,
    /// How many of those the peer asked for, a round trip sooner than the
    /// timer would have.
    fast_retransmits: u64 = 0,
    /// Bytes sent past a shut window to ask whether it has opened.
    probes: u64 = 0,
    /// Connections reset because the peer stopped acknowledging.
    given_up: u64 = 0,
    /// Connections let go because the peer never sent its FIN.
    fin_waits_expired: u64 = 0,
    /// Segments for no connection we hold, answered with a reset.
    strays: u64 = 0,
    /// Segments whose checksum was wrong, dropped.
    damaged: u64 = 0,
    /// Round trips measured, and the newest smoothed estimate — what this
    /// machine believes the path to its peers costs.
    samples: u64 = 0,
    measured_ns: u64 = 0,

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
        self.segment(wire, .{
            .mac = c.peer_mac,
            .ip = c.peer_ip,
            .port = c.peer_port,
        }, flags, seq, c.rcv_nxt, c.window(), payload);
    }

    const Peer = struct { mac: [6]u8, ip: [4]u8, port: u16 };

    /// Builds and sends one segment to `to`. A SYN carries our segment size.
    fn segment(self: *Table, wire: anytype, to: Peer, flags: u8, seq: u32, ack_number: u32, window: u16, payload: []const u8) void {
        const options: []const u8 = if (flags & flag_syn != 0) &mss_option else &.{};
        const len = header_len + options.len;
        const frame_len = proto.writeIpv4(
            self.out,
            self.local_mac,
            to.mac,
            self.local_ip,
            to.ip,
            proto.proto_tcp,
            len + payload.len,
        );

        const t = self.out[segment_at..][0 .. len + payload.len];
        @memcpy(t[0..2], &proto.be16(self.port));
        @memcpy(t[2..4], &proto.be16(to.port));
        @memcpy(t[4..8], &proto.be32(seq));
        @memcpy(t[8..12], &proto.be32(ack_number));
        t[12] = @intCast((len / 4) << 4);
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(window));
        @memcpy(t[16..18], &proto.be16(0)); // the checksum, over a zeroed checksum
        @memcpy(t[18..20], &proto.be16(0)); // no urgent pointer
        @memcpy(t[header_len..len], options);
        @memcpy(t[len..], payload);
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(self.local_ip, to.ip, proto.proto_tcp, t)));

        wire.send(self.out[0..frame_len]);
    }

    /// **A SEGMENT FOR NO CONNECTION WE HOLD** is answered with a reset
    /// (RFC 9293 §3.10.7.1): numbered by its acknowledgement if it has one,
    /// else acknowledging everything it carried.
    fn refuse(self: *Table, wire: anytype, to: Peer, seq: u32, ack_number: u32, flags: u8, data_len: usize) void {
        self.strays += 1;
        if (flags & flag_ack != 0) {
            self.segment(wire, to, flag_rst, ack_number, 0, 0, "");
        } else {
            var through = seq +% @as(u32, @intCast(data_len));
            if (flags & flag_syn != 0) through +%= 1;
            if (flags & flag_fin != 0) through +%= 1;
            self.segment(wire, to, flag_rst | flag_ack, 0, through, 0, "");
        }
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
        self.emit(wire, i, flag_ack, c.highest(), "");
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
        // A half-open connection is told too: a peer whose handshake we have
        // stopped answering would otherwise wait out its own SYN timer.
        if (c.state != .closed) {
            self.emit(wire, i, flag_rst | flag_ack, c.highest(), "");
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

        if (c.fin == .acknowledged) {
            // Waiting for the peer's FIN, with nothing of ours in flight.
            if (c.fin_wait_until) |until| if (now >= until) {
                self.fin_waits_expired += 1;
                self.abandon(wire, i);
            };
            return;
        }

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
            c.timed_at = null; // Karn: no telling which copy is answered
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
            const first_time = c.sent + n > c.high;
            self.emit(wire, i, flag_psh | flag_ack, c.una +% @as(u32, @intCast(c.sent)), c.tx[c.tx_start + c.sent ..][0..n]);
            c.sent += n;
            if (first_time) c.time(now, c.una +% @as(u32, @intCast(c.sent)));
            c.high = @max(c.high, c.sent);
            if (c.rto_at == null) c.rto_at = now + c.rto_ns;
        }

        if (c.fin == .queued and c.sent == c.queued()) {
            self.emit(wire, i, flag_fin | flag_ack, c.una +% @as(u32, @intCast(c.sent)), "");
            c.fin = .sent;
            c.fin_ever_sent = true;
            if (c.rto_at == null) c.rto_at = now + c.rto_ns;
        }
    }

    /// Sends everything unacknowledged again, now, without touching the
    /// backoff: the peer told us it is missing something, which is news about
    /// this connection, not evidence that the path has slowed down.
    fn resend(self: *Table, wire: anytype, i: usize, now: i96) void {
        const c = &self.conns[i];
        c.dupacks = 0;
        c.resent_early = true;
        c.sent = 0;
        if (c.fin == .sent) c.fin = .queued;
        c.timed_at = null; // Karn, the same as after a timeout
        c.rto_at = now + c.rto_ns;
        self.retransmits += 1;
        self.fast_retransmits += 1;
        self.transmitOne(wire, i, now);
    }

    /// **TAKES THE SAMPLE IF THIS ACKNOWLEDGEMENT COVERS WHAT IS BEING TIMED**,
    /// and folds it into the estimate exactly as RFC 6298 §2 says: the first
    /// sample IS the estimate, and later ones move it an eighth at a time,
    /// with the variation moving a quarter at a time.
    fn measure(self: *Table, c: *Conn, number: u32, now: i96) void {
        const at = c.timed_at orelse return;
        if (number -% c.timed_seq >= 1 << 31) return; // not there yet
        c.timed_at = null;
        const rtt: u64 = @intCast(@max(0, now - at));
        if (c.srtt_ns == 0) {
            c.srtt_ns = rtt;
            c.rttvar_ns = rtt / 2;
        } else {
            const off = if (c.srtt_ns > rtt) c.srtt_ns - rtt else rtt - c.srtt_ns;
            c.rttvar_ns = (3 * c.rttvar_ns + off) / 4;
            c.srtt_ns = (7 * c.srtt_ns + rtt) / 8;
        }
        c.rto_ns = @min(@max(c.srtt_ns + 4 * c.rttvar_ns, min_rto_ns), max_rto_ns);
        self.samples += 1;
        self.measured_ns = c.srtt_ns;
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

    /// Takes in the peer's acknowledgement and window, from a segment numbered
    /// `seq`. True once our FIN is acknowledged.
    fn acknowledge(self: *Table, c: *Conn, seq: u32, number: u32, window: u16, now: i96) bool {
        const flight = c.highest() -% c.una;
        const advance = number -% c.una;
        // An acknowledgement of something never sent, or an old one (which
        // wraps to a huge advance): neither says anything current.
        if (advance > flight) return false;
        const updated = after(seq, c.wl1) or (seq == c.wl1 and !after(c.wl2, number));
        if (updated) {
            c.wnd = window;
            c.wl1 = seq;
            c.wl2 = number;
        }
        if (advance == 0) return false;

        const bytes = @min(advance, c.queued());
        c.tx_start += bytes;
        c.sent -= @min(c.sent, bytes);
        c.high -= @min(c.high, bytes);
        if (c.tx_start == c.tx_end) {
            c.tx_start = 0;
            c.tx_end = 0;
        }
        c.una +%= advance;
        // **THE WINDOW IS MEASURED FROM `una`.** When the peer's own window
        // came with this segment it is measured from here already; when an
        // older segment carried a newer acknowledgement, the window rule
        // skipped the update, and the right edge would move forward with
        // `una` unless it is brought back by as much.
        if (!updated) c.wnd -= @min(c.wnd, advance);
        if (advance > bytes) {
            c.fin = .acknowledged;
            c.high = 0;
            c.sent = 0;
        }

        c.retries = 0;
        self.measure(c, number, now);
        if (c.srtt_ns == 0) c.rto_ns = first_rto_ns;
        c.rto_at = if (c.highest() != c.una) now + c.rto_ns else null;
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
        // A segment damaged on the way is not a segment.
        if (proto.pseudoChecksum(pkt.src_ip, pkt.dst_ip, proto.proto_tcp, t) != 0) {
            self.damaged += 1;
            return .{ .event = .nothing };
        }

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
            // **A RESET MUST NAME THE NEXT BYTE WE EXPECT** (RFC 9293, after
            // RFC 5961). One inside the window but not exactly there is
            // answered with an acknowledgement, which a genuine peer answers
            // with an exact reset; anything else is ignored.
            const i = found orelse return .{ .event = .nothing };
            const c = &self.conns[i];
            if (seq == c.rcv_nxt) return self.close(i);
            if (c.ahead(seq)) self.emit(wire, i, flag_ack, c.highest(), "");
            return .{ .event = .nothing };
        }

        // A SYN for no connection we know is the start of one — if there is a
        // slot for it. Anything else for no connection is refused.
        const i = found orelse {
            if (flags & flag_syn == 0 or flags & flag_ack != 0) {
                self.refuse(wire, .{ .mac = pkt.src_mac, .ip = pkt.src_ip, .port = src_port }, seq, number, flags, data.len);
                return .{ .event = .nothing };
            }
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
            c.wl1 = seq;
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
            // **THE HANDSHAKE IS A ROUND TRIP**, and the only one that happens
            // before we have anything to send: timing it means the first byte
            // of the first answer already goes out under a measured clock.
            c.time(now, c.una +% 1);
            return .{ .event = .nothing };
        };

        const c = &self.conns[i];

        // A repeated SYN for a connection we already answered: the SYN-ACK was
        // lost or is late. Say it again, from the same starting number. On an
        // established connection it is answered with an acknowledgement.
        if (flags & flag_syn != 0) {
            if (c.state == .syn_received) {
                self.emit(wire, i, flag_syn | flag_ack, c.una, "");
            } else self.emit(wire, i, flag_ack, c.highest(), "");
            return .{ .event = .nothing };
        }

        // Every segment after the SYN acknowledges something.
        if (flags & flag_ack == 0) return .{ .event = .nothing };

        // **A SEGMENT THAT IS NOT THE NEXT ONE IS ANSWERED, NOT TAKEN.** One
        // from behind — a repeated FIN whose acknowledgement was lost, a
        // keepalive probe — or from beyond the window gets an acknowledgement
        // and nothing else. One ahead but inside the window still says what
        // the peer has received; only its data and FIN wait.
        //
        // Its acknowledgement number still counts if it moves forward: an
        // acknowledgement is cumulative, so a newer one cannot be wrong, and a
        // peer that repeats its FIN with our FIN now acknowledged would
        // otherwise wait on a timer for nothing. (The window rule keeps an old
        // segment from setting the window.)
        const early = c.ahead(seq);
        if (seq != c.rcv_nxt and !early) {
            // **ONLY FROM BEHIND.** A segment numbered past the window we
            // advertise is not one the peer can have sent yet: taking its
            // acknowledgement would let a forged or wildly reordered segment
            // set SND.WL1 to a sequence the peer will never reach, after which
            // the window rule rejects every genuine update and the window we
            // believe in never changes again.
            const behind = (c.rcv_nxt -% seq) < (1 << 31);
            const done = behind and c.state != .syn_received and
                self.acknowledge(c, seq, number, window, now);
            self.emit(wire, i, flag_ack, c.highest(), "");
            if (done) return self.settle(i, .nothing, true, now);
            return .{ .event = .nothing };
        }
        c.heard_at = now;

        var event: Event = .nothing;
        var fin_acknowledged = false;
        if (c.state == .syn_received) {
            if (early) {
                self.emit(wire, i, flag_ack, c.highest(), "");
                return .{ .event = .nothing };
            }
            if (number != c.una +% 1) {
                // An acknowledgement of something we never sent is refused.
                self.segment(wire, .{ .mac = c.peer_mac, .ip = c.peer_ip, .port = c.peer_port }, flag_rst, number, 0, 0, "");
                return .{ .event = .nothing };
            }
            c.una = number;
            c.wnd = window;
            c.wl1 = seq;
            c.wl2 = number;
            c.rto_at = null;
            c.retries = 0;
            self.measure(c, number, now);
            if (c.srtt_ns == 0) c.rto_ns = first_rto_ns;
            c.state = .established;
            event = .opened;
            // Their ACK may carry the first data, so fall through.
        } else {
            const was = c.una;
            const held = c.wnd;
            fin_acknowledged = self.acknowledge(c, seq, number, window, now);
            // **THE PEER SAYS WHAT IS MISSING; WE DO NOT WAIT TO GUESS IT.**
            // A segment that carries nothing, acknowledges nothing new and
            // does not move the window, while something of ours is
            // unacknowledged, is the peer telling us it received what came
            // after a hole (RFC 5681). Three of them and we send again at
            // once, rather than a round trip later when the timer runs out.
            //
            // **NOT WHILE THE WINDOW IS SHUT, AND ONCE PER LOSS.** A peer with
            // no room answers every window probe with the same
            // acknowledgement, which is not news about a lost segment; and a
            // peer that repeats itself forever must not be able to hold the
            // connection open by pushing the timer out, so the next one waits
            // until something new has been acknowledged.
            const bare = data.len == 0 and flags & flag_fin == 0 and flags & flag_syn == 0;
            if (c.una != was) {
                c.dupacks = 0;
                c.resent_early = false;
            } else if (bare and c.wnd == held and c.wnd != 0 and c.highest() != c.una) {
                c.dupacks += 1;
                if (c.dupacks == dupacks_before_resend and !c.resent_early) self.resend(wire, i, now);
            }
        }

        if (early) {
            // Its data and FIN are not the next thing; ask for what is.
            if (data.len > 0 or flags & flag_fin != 0) self.emit(wire, i, flag_ack, c.highest(), "");
            return self.settle(i, event, fin_acknowledged, now);
        }

        // **IN-ORDER ONLY.** Anything else is dropped and re-acknowledged,
        // which asks for it again.
        if (data.len > 0) {
            if (c.peer_done) {
                self.emit(wire, i, flag_ack, c.highest(), "");
                return self.settle(i, event, fin_acknowledged, now);
            }
            // **WHAT FITS IS TAKEN, AND ONLY THAT IS ACKNOWLEDGED.** A peer
            // that sent past the window will send the rest again, once the
            // reader has made room.
            const n = @min(c.room(), data.len);
            @memcpy(c.rx[c.end..][0..n], data[0..n]);
            c.end += n;
            c.rcv_nxt +%= @intCast(n);
            self.emit(wire, i, flag_ack, c.highest(), "");
            if (n > 0 and event == .nothing) event = .data;
            if (n < data.len) return self.settle(i, event, fin_acknowledged, now);
        }

        if (flags & flag_fin != 0 and !c.peer_done and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt) {
            c.rcv_nxt +%= 1; // their FIN takes one
            c.peer_done = true;
            self.emit(wire, i, flag_ack, c.highest(), "");
            if (c.fin == .acknowledged) return self.close(i);
            return .{ .event = .peer_done, .index = i };
        }

        return self.settle(i, event, fin_acknowledged, now);
    }

    /// Our FIN has just been acknowledged: if the peer has finished too the
    /// connection is over, and otherwise it waits for the peer's FIN. Any other
    /// segment reports what it did.
    fn settle(self: *Table, i: usize, event: Event, fin_acknowledged: bool, now: i96) Result {
        if (!fin_acknowledged) return .{ .event = event, .index = i };
        const c = &self.conns[i];
        if (c.peer_done) return self.close(i);
        c.fin_wait_until = now + fin_wait_ns;
        return .{ .event = event, .index = i };
    }

    fn close(self: *Table, i: usize) Result {
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

/// Whether sequence number `a` comes after `b`, modulo 2^32.
fn after(a: u32, b: u32) bool {
    const d = a -% b;
    return d != 0 and d < 0x8000_0000;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
