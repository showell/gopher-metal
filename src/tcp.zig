//! TCP for a server that holds many connections and answers one request on each.
//!
//! **A TABLE OF CONNECTIONS, NOT ONE.** This file used to hold exactly one: a
//! SYN that arrived while a connection was open was ignored, so one client that
//! connected and said nothing held the whole site until a timer let it go. Chat
//! makes that the normal case — every conversation tab holds three connections
//! open for as long as it is open — so the machine has to hold many at once.
//! It still ANSWERS one request at a time; what changed is that the others wait
//! in a table instead of at the door.
//!
//! **STILL THE SMALL TCP.** No congestion control, no retransmission, no
//! out-of-order reassembly, no keep-alive. Each is a real assumption about the
//! wire, and each is allowed only because this box sits behind Caddy on a
//! private network:
//!
//! - **In-order only.** A segment whose sequence is not exactly the next one
//!   expected is dropped and re-acknowledged, which asks the peer to send it
//!   again.
//! - **No retransmit timer.** If something we send is lost, that connection
//!   stalls rather than recovering.
//!
//! **PURE, SO IT IS TESTED ON THE HOST.** Nothing here reaches for a device.
//! Frames go out through whatever `wire` the caller hands in (anything with a
//! `send([]const u8)`), the initial sequence number comes from a function the
//! caller supplies, and the time is a number the caller passes. The kernel
//! passes the NIC, the entropy pool and its clock; the tests pass a recorder,
//! a counter and a fake.

const proto = @import("proto.zig");

pub const header_len: usize = 20;
const payload_at: usize = proto.eth_header_len + proto.ip_header_len + header_len;

const flag_fin: u8 = 0x01;
const flag_syn: u8 = 0x02;
const flag_rst: u8 = 0x04;
const flag_psh: u8 = 0x08;
const flag_ack: u8 = 0x10;

pub const State = enum {
    /// The slot is free — unless the host still holds it (`claimed`).
    closed,
    syn_received,
    established,
    /// We have sent our FIN and are waiting for the peer to finish.
    closing,
};

/// One connection.
pub const Conn = struct {
    state: State = .closed,
    peer_ip: [4]u8 = proto.ip_any,
    peer_mac: [6]u8 = proto.mac_broadcast,
    peer_port: u16 = 0,

    /// The next sequence number we will send, and the next we expect.
    snd_nxt: u32 = 0,
    rcv_nxt: u32 = 0,

    /// **WHAT THE PEER HAS SENT AND NOBODY HAS READ YET: `rx[start..end]`.**
    /// The reader consumes from the front, and the space it frees is what the
    /// window advertises. This used to be a buffer that only ever filled, so a
    /// request larger than it was silently cut short.
    rx: []u8,
    start: usize = 0,
    end: usize = 0,

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

    /// Free space at the end of the buffer, which is what arriving bytes can
    /// be put into and what the window advertises.
    pub fn room(self: *const Conn) usize {
        return self.rx.len - self.end;
    }

    /// Is this connection still one we can talk to?
    pub fn open(self: *const Conn) bool {
        return self.state == .established or self.state == .syn_received;
    }

    fn reset(self: *Conn) void {
        const rx = self.rx;
        const claimed = self.claimed;
        self.* = .{ .rx = rx, .claimed = claimed };
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

    /// Builds and sends one segment on connection `i`. A payload is already at
    /// `payload_at` in `self.out` when `payload_len` is nonzero.
    fn emit(self: *Table, wire: anytype, i: usize, flags: u8, payload_len: usize) void {
        const c = &self.conns[i];
        const frame_len = proto.writeIpv4(
            self.out,
            self.local_mac,
            c.peer_mac,
            self.local_ip,
            c.peer_ip,
            proto.proto_tcp,
            header_len + payload_len,
        );

        const t = self.out[proto.eth_header_len + proto.ip_header_len ..][0 .. header_len + payload_len];
        @memcpy(t[0..2], &proto.be16(self.port));
        @memcpy(t[2..4], &proto.be16(c.peer_port));
        @memcpy(t[4..8], &proto.be32(c.snd_nxt));
        @memcpy(t[8..12], &proto.be32(c.rcv_nxt));
        t[12] = (header_len / 4) << 4; // data offset, no options
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(c.window()));
        @memcpy(t[16..18], &proto.be16(0)); // the checksum, over a zeroed checksum
        @memcpy(t[18..20], &proto.be16(0)); // no urgent pointer
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(self.local_ip, c.peer_ip, proto.proto_tcp, t)));

        wire.send(self.out[0..frame_len]);

        // SYN and FIN each take one sequence number, as if they were a byte.
        if (flags & (flag_syn | flag_fin) != 0) c.snd_nxt +%= 1;
        c.snd_nxt +%= @intCast(payload_len);
    }

    /// Sends `bytes` on connection `i`. The caller keeps it under one
    /// segment's worth; there is no segmentation here.
    pub fn send(self: *Table, wire: anytype, i: usize, bytes: []const u8) void {
        if (self.conns[i].state != .established) return;
        @memcpy(self.out[payload_at..][0..bytes.len], bytes);
        self.emit(wire, i, flag_psh | flag_ack, bytes.len);
    }

    /// Tells the peer how much room there is now. The reader calls it after
    /// consuming, so a peer that had filled the window learns it can go on
    /// without waiting for its own probe.
    pub fn ack(self: *Table, wire: anytype, i: usize) void {
        if (self.conns[i].state != .established) return;
        self.emit(wire, i, flag_ack, 0);
    }

    /// Says we are done sending. The connection closes when the peer agrees,
    /// or when the host stops waiting and abandons it.
    pub fn finish(self: *Table, wire: anytype, i: usize) void {
        if (self.conns[i].state != .established) return;
        self.emit(wire, i, flag_fin | flag_ack, 0);
        self.conns[i].state = .closing;
    }

    /// Gives up on connection `i` without a word to the peer.
    pub fn abandon(self: *Table, i: usize) void {
        self.conns[i].reset();
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
        const flags = t[13];
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
            c.snd_nxt = self.isn();
            c.state = .syn_received;
            c.opened_at = now;
            c.heard_at = now;
            self.arrivals += 1;
            c.serial = self.arrivals;
            self.emit(wire, slot, flag_syn | flag_ack, 0);
            return .{ .event = .nothing };
        };

        const c = &self.conns[i];
        c.heard_at = now;

        // A repeated SYN for a connection we already answered: the SYN-ACK was
        // lost or is late. Say it again, from the same starting number.
        if (flags & flag_syn != 0) {
            if (c.state == .syn_received) {
                c.snd_nxt -%= 1;
                self.emit(wire, i, flag_syn | flag_ack, 0);
            }
            return .{ .event = .nothing };
        }

        var event: Event = .nothing;
        if (c.state == .syn_received) {
            if (flags & flag_ack == 0) return .{ .event = .nothing };
            c.state = .established;
            event = .opened;
            // Their ACK may carry the first data, so fall through.
        }

        // **IN-ORDER ONLY.** Anything else is dropped and re-acknowledged,
        // which asks for it again.
        if (data.len > 0) {
            if (seq != c.rcv_nxt or c.peer_done) {
                self.emit(wire, i, flag_ack, 0);
                return .{ .event = event, .index = i };
            }
            // **WHAT FITS IS TAKEN, AND ONLY THAT IS ACKNOWLEDGED.** A peer
            // that sent past the window will send the rest again, once the
            // reader has made room.
            const n = @min(c.room(), data.len);
            @memcpy(c.rx[c.end..][0..n], data[0..n]);
            c.end += n;
            c.rcv_nxt +%= @intCast(n);
            self.emit(wire, i, flag_ack, 0);
            if (n > 0 and event == .nothing) event = .data;
            if (n < data.len) return .{ .event = event, .index = i };
        }

        if (flags & flag_fin != 0 and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt) {
            c.rcv_nxt +%= 1; // their FIN takes one
            if (c.state == .closing) {
                // We had already said we were done: this completes it.
                self.emit(wire, i, flag_ack, 0);
                c.reset();
                return .{ .event = .closed, .index = i };
            }
            c.peer_done = true;
            self.emit(wire, i, flag_ack, 0);
            return .{ .event = .peer_done, .index = i };
        }

        if (c.state == .closing and flags & flag_ack != 0 and data.len == 0) {
            // They acknowledged our FIN. Nothing more is coming on this
            // connection that we care about.
            c.reset();
            return .{ .event = .closed, .index = i };
        }

        return .{ .event = event, .index = i };
    }
};

const std = @import("std");

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// ══ TESTS ════════════════════════════════════════════════════════════════════
//
// A fake peer on the other end of a recording wire. Every test drives the
// table with the frames a real client would send and reads back the frames the
// table sent, checking the sequence numbers a real client would check.

const testing = std.testing;

const server_ip = [4]u8{ 10, 0, 2, 15 };
const server_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
const client_mac = [6]u8{ 0x52, 0x55, 0x0a, 0, 2, 2 };

/// The wire, recording what the table sent.
const Wire = struct {
    frames: [64][1600]u8 = undefined,
    lens: [64]usize = undefined,
    count: usize = 0,

    pub fn send(self: *Wire, frame: []const u8) void {
        @memcpy(self.frames[self.count][0..frame.len], frame);
        self.lens[self.count] = frame.len;
        self.count += 1;
    }

    const Seg = struct { dst_port: u16, seq: u32, ack: u32, flags: u8, window: u16, payload: []const u8 };

    fn last(self: *Wire) Seg {
        return self.at(self.count - 1);
    }

    fn at(self: *Wire, k: usize) Seg {
        const pkt = proto.parseIpv4(self.frames[k][0..self.lens[k]]).?;
        const t = pkt.payload;
        return .{
            .dst_port = proto.readBe16(t[2..4]),
            .seq = proto.readBe32(t[4..8]),
            .ack = proto.readBe32(t[8..12]),
            .flags = t[13],
            .window = proto.readBe16(t[14..16]),
            .payload = t[header_len..],
        };
    }

    /// The checksum a real peer would verify, recomputed.
    fn checksumOk(self: *Wire, k: usize) bool {
        const pkt = proto.parseIpv4(self.frames[k][0..self.lens[k]]).?;
        return proto.pseudoChecksum(pkt.src_ip, pkt.dst_ip, proto.proto_tcp, pkt.payload) == 0;
    }
};

var next_isn: u32 = 1000;
fn fakeIsn() u32 {
    next_isn +%= 1000;
    return next_isn;
}

/// One client: an address, a port, and the sequence numbers it keeps.
const Peer = struct {
    ip: [4]u8,
    port: u16,
    seq: u32 = 5000,
    ack: u32 = 0,

    fn frame(self: *const Peer, buf: []u8, flags: u8, seq: u32, data: []const u8) []const u8 {
        const len = proto.writeIpv4(buf, client_mac, server_mac, self.ip, server_ip, proto.proto_tcp, header_len + data.len);
        const t = buf[proto.eth_header_len + proto.ip_header_len ..][0 .. header_len + data.len];
        @memcpy(t[0..2], &proto.be16(self.port));
        @memcpy(t[2..4], &proto.be16(80));
        @memcpy(t[4..8], &proto.be32(seq));
        @memcpy(t[8..12], &proto.be32(self.ack));
        t[12] = (header_len / 4) << 4;
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(8192));
        @memcpy(t[16..20], &[_]u8{ 0, 0, 0, 0 });
        @memcpy(t[header_len..], data);
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(self.ip, server_ip, proto.proto_tcp, t)));
        return buf[0..len];
    }

    /// SYN, then the ACK of the server's SYN-ACK. Returns the slot.
    fn connect(self: *Peer, table: *Table, wire: *Wire, now: i96) !usize {
        var buf: [1600]u8 = undefined;
        _ = table.handle(wire, self.frame(&buf, flag_syn, self.seq, ""), now);
        const synack = wire.last();
        try testing.expectEqual(flag_syn | flag_ack, synack.flags);
        try testing.expectEqual(self.seq +% 1, synack.ack);
        self.seq +%= 1;
        self.ack = synack.seq +% 1;
        const r = table.handle(wire, self.frame(&buf, flag_ack, self.seq, ""), now);
        try testing.expectEqual(Event.opened, r.event);
        return r.index;
    }

    fn write(self: *Peer, table: *Table, wire: *Wire, bytes: []const u8, now: i96) Result {
        var buf: [1600]u8 = undefined;
        const r = table.handle(wire, self.frame(&buf, flag_psh | flag_ack, self.seq, bytes), now);
        const reply = wire.last();
        self.seq = reply.ack; // what the server says it has
        return r;
    }

    fn fin(self: *Peer, table: *Table, wire: *Wire, now: i96) Result {
        var buf: [1600]u8 = undefined;
        return table.handle(wire, self.frame(&buf, flag_fin | flag_ack, self.seq, ""), now);
    }
};

const Fixture = struct {
    conns: [4]Conn = undefined,
    bufs: [4][64]u8 = undefined,
    out: [1600]u8 = undefined,
    wire: Wire = .{},
    table: Table = undefined,

    fn init(self: *Fixture) void {
        for (&self.conns, &self.bufs) |*c, *b| c.* = .{ .rx = b };
        self.table = Table.init(server_ip, server_mac, 80, &self.conns, &self.out, fakeIsn);
    }
};

test "a handshake, a request, and the bytes are there to read" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    const r = p.write(&f.table, &f.wire, "GET / HTTP/1.1\r\n\r\n", 2);
    try testing.expectEqual(Event.data, r.event);
    try testing.expectEqual(i, r.index);
    try testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", f.table.conns[i].pending());
    try testing.expect(f.wire.checksumOk(f.wire.count - 1));
    try testing.expectEqual(@as(i96, 1), f.table.conns[i].opened_at);
    try testing.expectEqual(@as(i96, 2), f.table.conns[i].heard_at);
}

test "two connections at once each keep their own bytes" {
    var f: Fixture = .{};
    f.init();
    var a = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var b = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40001 };
    const ia = try a.connect(&f.table, &f.wire, 1);
    const ib = try b.connect(&f.table, &f.wire, 2);
    try testing.expect(ia != ib);
    _ = a.write(&f.table, &f.wire, "from a ", 3);
    _ = b.write(&f.table, &f.wire, "from b", 4);
    _ = a.write(&f.table, &f.wire, "again", 5);
    try testing.expectEqualStrings("from a again", f.table.conns[ia].pending());
    try testing.expectEqualStrings("from b", f.table.conns[ib].pending());
    // Arrival order is kept, for serving the oldest first.
    try testing.expect(f.table.conns[ia].serial < f.table.conns[ib].serial);
}

test "the same port from another address is another connection" {
    var f: Fixture = .{};
    f.init();
    var a = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var b = Peer{ .ip = .{ 10, 0, 2, 3 }, .port = 40000 };
    const ia = try a.connect(&f.table, &f.wire, 1);
    const ib = try b.connect(&f.table, &f.wire, 1);
    try testing.expect(ia != ib);
}

test "a full table drops the SYN and counts it, and a freed slot is used again" {
    var f: Fixture = .{};
    f.init();
    var peers: [5]Peer = undefined;
    for (&peers, 0..) |*p, k| p.* = .{ .ip = .{ 10, 0, 2, 2 }, .port = @intCast(41000 + k) };
    var slots: [4]usize = undefined;
    for (peers[0..4], &slots) |*p, *s| s.* = try p.connect(&f.table, &f.wire, 1);

    var buf: [1600]u8 = undefined;
    const sent = f.wire.count;
    _ = f.table.handle(&f.wire, peers[4].frame(&buf, flag_syn, peers[4].seq, ""), 2);
    try testing.expectEqual(sent, f.wire.count); // nothing answered
    try testing.expectEqual(@as(u64, 1), f.table.refused);

    f.table.abandon(slots[2]);
    const again = try peers[4].connect(&f.table, &f.wire, 3);
    try testing.expectEqual(slots[2], again);
}

test "a slot the host holds is not given to a stranger, even after it closes" {
    var f: Fixture = .{};
    f.init();
    var peers: [5]Peer = undefined;
    for (&peers, 0..) |*p, k| p.* = .{ .ip = .{ 10, 0, 2, 2 }, .port = @intCast(42000 + k) };
    var slots: [4]usize = undefined;
    for (peers[0..4], &slots) |*p, *s| s.* = try p.connect(&f.table, &f.wire, 1);

    f.table.claim(slots[0]);
    // The peer resets the connection the host is part-way through serving.
    var buf: [1600]u8 = undefined;
    const r = f.table.handle(&f.wire, peers[0].frame(&buf, flag_rst, peers[0].seq, ""), 2);
    try testing.expectEqual(Event.closed, r.event);
    try testing.expectEqual(State.closed, f.table.conns[slots[0]].state);

    // A new SYN finds no free slot: the closed one is still the host's.
    _ = f.table.handle(&f.wire, peers[4].frame(&buf, flag_syn, peers[4].seq, ""), 3);
    try testing.expectEqual(@as(u64, 1), f.table.refused);

    f.table.release(slots[0]);
    try testing.expectEqual(slots[0], try peers[4].connect(&f.table, &f.wire, 4));
}

test "the window is the room left, and reading gives it back" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    try testing.expectEqual(@as(u16, 64), f.wire.last().window);

    _ = p.write(&f.table, &f.wire, "0123456789" ** 4, 2);
    try testing.expectEqual(@as(u16, 24), f.wire.last().window);

    f.table.conns[i].consume(40);
    f.table.ack(&f.wire, i);
    try testing.expectEqual(@as(u16, 64), f.wire.last().window);
}

test "a segment bigger than the room is taken in part, and the rest arrives after a read" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    const body = "abcdefghij" ** 10; // 100 bytes into a 64-byte buffer

    var buf: [1600]u8 = undefined;
    const start = p.seq;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_psh | flag_ack, start, body), 2);
    try testing.expectEqual(start +% 64, f.wire.last().ack); // only what fitted
    try testing.expectEqualStrings(body[0..64], f.table.conns[i].pending());

    // The peer sends the rest again from where the ACK said.
    f.table.conns[i].consume(64);
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_psh | flag_ack, start +% 64, body[64..]), 3);
    try testing.expectEqual(start +% 100, f.wire.last().ack);
    try testing.expectEqualStrings(body[64..], f.table.conns[i].pending());
}

test "consuming part of a request compacts the buffer once the front is half gone" {
    var c = Conn{ .rx = undefined };
    var b: [16]u8 = undefined;
    c.rx = &b;
    @memcpy(b[0..12], "abcdefghijkl");
    c.end = 12;
    c.consume(3);
    try testing.expectEqual(@as(usize, 3), c.start); // not yet past half
    try testing.expectEqualStrings("defghijkl", c.pending());
    c.consume(6);
    try testing.expectEqual(@as(usize, 0), c.start); // compacted
    try testing.expectEqualStrings("jkl", c.pending());
    try testing.expectEqual(@as(usize, 13), c.room());
    c.consume(3);
    try testing.expectEqual(@as(usize, 16), c.room());
    c.consume(5); // more than there is is just all of it
    try testing.expectEqual(@as(usize, 0), c.pending().len);
}

test "a segment out of order is dropped and the right one asked for again" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_psh | flag_ack, p.seq +% 5, "later"), 2);
    try testing.expectEqual(p.seq, f.wire.last().ack);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].pending().len);
}

test "the peer's FIN leaves what it sent to be read" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    _ = p.write(&f.table, &f.wire, "GET / HTTP/1.1\r\n\r\n", 2);
    const r = p.fin(&f.table, &f.wire, 3);
    try testing.expectEqual(Event.peer_done, r.event);
    try testing.expect(f.table.conns[i].peer_done);
    try testing.expectEqualStrings("GET / HTTP/1.1\r\n\r\n", f.table.conns[i].pending());
    try testing.expectEqual(p.seq +% 1, f.wire.last().ack); // their FIN acknowledged
    // We can still answer, and then close.
    f.table.send(&f.wire, i, "HTTP/1.1 200 OK\r\n\r\n");
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n\r\n", f.wire.last().payload);
}

test "our FIN, then theirs, closes it and frees the slot" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    f.table.finish(&f.wire, i);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    const r = p.fin(&f.table, &f.wire, 2);
    try testing.expectEqual(Event.closed, r.event);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

test "our FIN, then just their ACK, also closes it" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    f.table.finish(&f.wire, i);
    p.ack = f.wire.last().seq +% 1;
    var buf: [1600]u8 = undefined;
    const r = f.table.handle(&f.wire, p.frame(&buf, flag_ack, p.seq, ""), 2);
    try testing.expectEqual(Event.closed, r.event);
}

test "a segment for no connection, and a stray RST, are ignored" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, p.frame(&buf, flag_ack, 1, "hello"), 1).event);
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, p.frame(&buf, flag_rst, 1, ""), 1).event);
    try testing.expectEqual(@as(usize, 0), f.wire.count);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

test "a repeated SYN is answered again, from the same starting number" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_syn, p.seq, ""), 1);
    const first = f.wire.last();
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_syn, p.seq, ""), 2);
    const second = f.wire.last();
    try testing.expectEqual(first.seq, second.seq);
    try testing.expectEqual(flag_syn | flag_ack, second.flags);
    try testing.expectEqual(@as(usize, 1), f.table.inUse()); // not a second connection
}

test "every initial sequence number comes from the supplied source" {
    var f: Fixture = .{};
    f.init();
    var a = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var b = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40001 };
    _ = try a.connect(&f.table, &f.wire, 1);
    const first = a.ack -% 1;
    _ = try b.connect(&f.table, &f.wire, 1);
    const second = b.ack -% 1;
    try testing.expectEqual(first +% 1000, second);
}

test "a frame that is not ours changes nothing" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    const frame = p.frame(&buf, flag_syn, 1, "");
    // Another port.
    var other: [1600]u8 = undefined;
    @memcpy(other[0..frame.len], frame);
    const tcp_at = proto.eth_header_len + proto.ip_header_len;
    @memcpy(other[tcp_at + 2 .. tcp_at + 4], &proto.be16(8080));
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, other[0..frame.len], 1).event);
    // Garbage.
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, "not a frame", 1).event);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}
