//! The TCP table's tests: a fake peer on the other end of a recording wire.
//! Every test drives the table with the frames a real client would send and
//! reads back the frames the table sent, checking the sequence numbers a real
//! client would check.

const std = @import("std");
const proto = @import("proto.zig");
const tcp = @import("tcp.zig");

const Conn = tcp.Conn;
const Table = tcp.Table;
const Result = tcp.Result;
const Event = tcp.Event;
const State = tcp.State;
const header_len = tcp.header_len;
const segment_at = tcp.segment_at;
const flag_fin = tcp.flag_fin;
const flag_syn = tcp.flag_syn;
const flag_rst = tcp.flag_rst;
const flag_psh = tcp.flag_psh;
const flag_ack = tcp.flag_ack;
const mss_option = tcp.mss_option;
const parseMss = tcp.parseMss;
const first_rto_ns = tcp.first_rto_ns;
const max_retries = tcp.max_retries;
const ns_per_ms = tcp.ns_per_ms;
const ns_per_s = tcp.ns_per_s;

const testing = std.testing;

const server_ip = [4]u8{ 10, 0, 2, 15 };
const server_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
const client_mac = [6]u8{ 0x52, 0x55, 0x0a, 0, 2, 2 };

/// The wire, recording what the table sent.
const Wire = struct {
    frames: [128][1600]u8 = undefined,
    lens: [128]usize = undefined,
    count: usize = 0,

    pub fn send(self: *Wire, frame: []const u8) void {
        @memcpy(self.frames[self.count][0..frame.len], frame);
        self.lens[self.count] = frame.len;
        self.count += 1;
    }

    const Seg = struct { dst_port: u16, seq: u32, ack: u32, flags: u8, window: u16, options: []const u8, payload: []const u8 };

    fn last(self: *Wire) Seg {
        return self.at(self.count - 1);
    }

    fn at(self: *Wire, k: usize) Seg {
        const pkt = proto.parseIpv4(self.frames[k][0..self.lens[k]]).?;
        const t = pkt.payload;
        const offset = @as(usize, t[12] >> 4) * 4;
        return .{
            .dst_port = proto.readBe16(t[2..4]),
            .seq = proto.readBe32(t[4..8]),
            .ack = proto.readBe32(t[8..12]),
            .flags = t[13],
            .window = proto.readBe16(t[14..16]),
            .options = t[header_len..offset],
            .payload = t[offset..],
        };
    }

    /// The segments sent since `from`, with their payload lengths.
    fn sizesSince(self: *Wire, from: usize, buf: []usize) []usize {
        for (from..self.count, 0..) |k, n| buf[n] = self.at(k).payload.len;
        return buf[0 .. self.count - from];
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
    window: u16 = 8192,
    /// The segment size its SYN says, if it says one.
    mss: ?u16 = null,

    fn frame(self: *const Peer, buf: []u8, flags: u8, seq: u32, data: []const u8) []const u8 {
        var options: [4]u8 = undefined;
        const olen: usize = if (flags & flag_syn != 0 and self.mss != null) 4 else 0;
        if (olen > 0) options = .{ 2, 4, @intCast(self.mss.? >> 8), @intCast(self.mss.? & 0xFF) };
        const len = header_len + olen;
        const frame_len = proto.writeIpv4(buf, client_mac, server_mac, self.ip, server_ip, proto.proto_tcp, len + data.len);
        const t = buf[segment_at..][0 .. len + data.len];
        @memcpy(t[0..2], &proto.be16(self.port));
        @memcpy(t[2..4], &proto.be16(80));
        @memcpy(t[4..8], &proto.be32(seq));
        @memcpy(t[8..12], &proto.be32(self.ack));
        t[12] = @intCast((len / 4) << 4);
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(self.window));
        @memcpy(t[16..20], &[_]u8{ 0, 0, 0, 0 });
        @memcpy(t[header_len..len], options[0..olen]);
        @memcpy(t[len..], data);
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(self.ip, server_ip, proto.proto_tcp, t)));
        return buf[0..frame_len];
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

    /// Acknowledges everything up to `number`, with the peer's window.
    fn ackUpTo(self: *Peer, table: *Table, wire: *Wire, number: u32, now: i96) Result {
        self.ack = number;
        var buf: [1600]u8 = undefined;
        return table.handle(wire, self.frame(&buf, flag_ack, self.seq, ""), now);
    }

    /// Acknowledges every byte the server has sent so far.
    fn ackAll(self: *Peer, table: *Table, wire: *Wire, now: i96) Result {
        const s = wire.last();
        const end = s.seq +% @as(u32, @intCast(s.payload.len)) +% @as(u32, if (s.flags & flag_fin != 0) 1 else 0);
        return self.ackUpTo(table, wire, end, now);
    }
};

const Fixture = struct {
    conns: [4]Conn = undefined,
    rx: [4][64]u8 = undefined,
    tx: [4][2048]u8 = undefined,
    out: [1600]u8 = undefined,
    wire: Wire = .{},
    table: Table = undefined,

    fn init(self: *Fixture) void {
        for (&self.conns, &self.rx, &self.tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
        self.table = Table.init(server_ip, server_mac, 80, &self.conns, &self.out, fakeIsn);
    }
};

const ms: i96 = ns_per_ms;
/// The first wait before sending again, whatever it is set to.
const rto: i96 = first_rto_ns;

/// A payload whose every byte says where it is.
fn pattern(buf: []u8) []u8 {
    for (buf, 0..) |*b, k| b.* = @truncate(k *% 7 +% k / 256);
    return buf;
}

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

    f.table.abandon(&f.wire, slots[2]);
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
    var b: [16]u8 = undefined;
    var c = Conn{ .rx = &b, .tx = &.{} };
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

test "the peer's FIN leaves what it sent to be read, and we can still answer" {
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
    try testing.expectEqual(@as(usize, 19), f.table.queue(i, "HTTP/1.1 200 OK\r\n\r\n"));
    f.table.transmit(&f.wire, 4);
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\n\r\n", f.wire.last().payload);
}

test "our FIN, then theirs acknowledging it, closes it and frees the slot" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    f.table.finish(i);
    f.table.transmit(&f.wire, 2);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    p.ack = f.wire.last().seq +% 1;
    const r = p.fin(&f.table, &f.wire, 3);
    try testing.expectEqual(Event.closed, r.event);
    try testing.expectEqual(p.seq +% 1, f.wire.last().ack); // their FIN answered
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

test "our FIN acknowledged first: the connection waits for theirs, acknowledges it, and closes" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    f.table.finish(i);
    f.table.transmit(&f.wire, 2);
    try testing.expectEqual(Event.nothing, p.ackAll(&f.table, &f.wire, 3).event);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    try testing.expectEqual(tcp.Fin.acknowledged, f.table.conns[i].fin);
    // Nothing more of ours goes out while it waits.
    const sent = f.wire.count;
    f.table.transmit(&f.wire, 3 + 10 * rto);
    try testing.expectEqual(sent, f.wire.count);

    const r = p.fin(&f.table, &f.wire, 4);
    try testing.expectEqual(Event.closed, r.event);
    try testing.expectEqual(flag_ack, f.wire.last().flags);
    try testing.expectEqual(p.seq +% 1, f.wire.last().ack); // their FIN acknowledged
    try testing.expectEqual(p.ack, f.wire.last().seq);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

test "a peer that never sends its FIN is let go after the wait" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    f.table.finish(i);
    f.table.transmit(&f.wire, 0);
    _ = p.ackAll(&f.table, &f.wire, 1);
    f.table.transmit(&f.wire, 1 + tcp.fin_wait_ns - 1);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    f.table.transmit(&f.wire, 1 + tcp.fin_wait_ns);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u64, 1), f.table.fin_waits_expired);
}

test "their FIN repeated before we close is acknowledged again, and after, reset" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    try testing.expectEqual(Event.peer_done, p.fin(&f.table, &f.wire, 1).event);
    const first_ack = f.wire.last();
    // Our acknowledgement was lost; they say it again.
    const sent = f.wire.count;
    try testing.expectEqual(Event.nothing, p.fin(&f.table, &f.wire, 2).event);
    try testing.expectEqual(sent + 1, f.wire.count);
    try testing.expectEqual(first_ack.ack, f.wire.last().ack);

    f.table.finish(i);
    f.table.transmit(&f.wire, 3);
    p.seq +%= 1;
    try testing.expectEqual(Event.closed, p.ackAll(&f.table, &f.wire, 4).event);
    // Closed and forgotten: their FIN once more is refused.
    p.seq -%= 1;
    _ = p.fin(&f.table, &f.wire, 5);
    try testing.expectEqual(flag_rst, f.wire.last().flags);
    try testing.expectEqual(p.ack, f.wire.last().seq);
}

test "their FIN before our FIN is acknowledged leaves the connection closing" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    f.table.finish(i);
    f.table.transmit(&f.wire, 2);
    const r = p.fin(&f.table, &f.wire, 3); // acknowledges only the SYN
    try testing.expectEqual(Event.peer_done, r.event);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    p.seq +%= 1;
    try testing.expectEqual(Event.closed, p.ackUpTo(&f.table, &f.wire, p.ack +% 1, 4).event);
}

test "a segment for no connection is answered with a reset; a stray reset is not" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .ack = 777 };
    var buf: [1600]u8 = undefined;
    // With an acknowledgement: the reset is numbered by it.
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, p.frame(&buf, flag_ack, 1, "hello"), 1).event);
    try testing.expectEqual(@as(usize, 1), f.wire.count);
    try testing.expectEqual(flag_rst, f.wire.last().flags);
    try testing.expectEqual(@as(u32, 777), f.wire.last().seq);
    try testing.expectEqual(@as(u16, 40000), f.wire.last().dst_port);
    try testing.expect(f.wire.checksumOk(0));
    // Without one: the reset acknowledges what the segment carried, its FIN too.
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_fin, 50, "abc"), 1);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u32, 54), f.wire.last().ack);
    // A reset is never answered.
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, p.frame(&buf, flag_rst, 1, ""), 1).event);
    try testing.expectEqual(@as(usize, 2), f.wire.count);
    try testing.expectEqual(@as(u64, 2), f.table.strays);
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
    @memcpy(other[segment_at + 2 .. segment_at + 4], &proto.be16(8080));
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, other[0..frame.len], 1).event);
    // Garbage.
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, "not a frame", 1).event);
    try testing.expectEqual(@as(usize, 0), f.table.inUse());
}

// ── the send side ────────────────────────────────────────────────────────────

test "the SYN-ACK says our segment size, and the peer's sizes what we send" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .mss = 100 };
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_syn, p.seq, ""), 1);
    try testing.expectEqualSlices(u8, &mss_option, f.wire.last().options);
    try testing.expect(f.wire.checksumOk(f.wire.count - 1));
    p.seq +%= 1;
    p.ack = f.wire.last().seq +% 1;
    const i = f.table.handle(&f.wire, p.frame(&buf, flag_ack, p.seq, ""), 1).index;

    var body: [250]u8 = undefined;
    try testing.expectEqual(@as(usize, 250), f.table.queue(i, pattern(&body)));
    const from = f.wire.count;
    f.table.transmit(&f.wire, 2);
    var sizes: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 100, 100, 50 }, f.wire.sizesSince(from, &sizes));
    try testing.expectEqualSlices(u8, body[200..], f.wire.last().payload);
    try testing.expectEqual(p.ack +% 200, f.wire.last().seq);
}

test "a peer that names no segment size is sent 536 bytes at a time" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var body: [1200]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    const from = f.wire.count;
    f.table.transmit(&f.wire, 2);
    var sizes: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 536, 536, 128 }, f.wire.sizesSince(from, &sizes));
}

test "only what the window allows goes out, and an acknowledgement lets more go" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 100 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var body: [250]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));

    var from = f.wire.count;
    f.table.transmit(&f.wire, 2);
    var sizes: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{100}, f.wire.sizesSince(from, &sizes));
    from = f.wire.count;
    f.table.transmit(&f.wire, 3);
    try testing.expectEqual(from, f.wire.count); // the window is full

    // Forty bytes acknowledged: forty more may go.
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 40, 4);
    f.table.transmit(&f.wire, 5);
    try testing.expectEqualSlices(usize, &.{40}, f.wire.sizesSince(from, &sizes));
    try testing.expectEqualSlices(u8, body[100..140], f.wire.last().payload);
    try testing.expectEqual(@as(usize, 210), f.table.conns[i].queued());
}

test "an acknowledgement of nothing sent, or an old one, changes nothing" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    const first = p.ack;
    _ = f.table.queue(i, "hello");
    f.table.transmit(&f.wire, 2);

    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, first +% 6, 3); // one past what was sent
    try testing.expectEqual(@as(usize, 5), f.table.conns[i].queued());
    try testing.expectEqual(@as(u32, 8192), f.table.conns[i].wnd);
    _ = p.ackUpTo(&f.table, &f.wire, first -% 1, 3); // before the start
    try testing.expectEqual(@as(usize, 5), f.table.conns[i].queued());
    try testing.expectEqual(@as(u32, 8192), f.table.conns[i].wnd);

    _ = p.ackUpTo(&f.table, &f.wire, first +% 5, 4);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued());
    try testing.expectEqual(@as(?i96, null), f.table.conns[i].rto_at);
}

test "what is not acknowledged in time is sent again, oldest first, and the wait doubles" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [700]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    f.table.transmit(&f.wire, 0); // 536 + 164
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 100, 50 * ms); // the timer restarts from here

    var from = f.wire.count;
    f.table.transmit(&f.wire, 50 * ms + rto - 1);
    try testing.expectEqual(from, f.wire.count); // not yet
    f.table.transmit(&f.wire, 50 * ms + rto);
    var sizes: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 536, 64 }, f.wire.sizesSince(from, &sizes));
    try testing.expectEqualSlices(u8, body[100..636], f.wire.at(from).payload);
    try testing.expectEqual(p.ack, f.wire.at(from).seq);
    try testing.expectEqual(@as(u64, 1), f.table.retransmits);

    from = f.wire.count;
    f.table.transmit(&f.wire, 50 * ms + 3 * rto - 1);
    try testing.expectEqual(from, f.wire.count); // the wait is twice as long now
    f.table.transmit(&f.wire, 50 * ms + 3 * rto);
    try testing.expectEqual(from + 2, f.wire.count);

    // Progress resets the wait.
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 600, 100 * ms + 3 * rto);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued());
    try testing.expectEqual(@as(u8, 0), f.table.conns[i].retries);
    try testing.expectEqual(first_rto_ns, f.table.conns[i].rto_ns);
}

test "a peer that never answers is reset after the last timeout" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "anyone there?");
    var now: i96 = 0;
    f.table.transmit(&f.wire, now);
    var sends: usize = 1;
    while (f.table.conns[i].state != .closed) {
        now += 1 * ms;
        const before = f.wire.count;
        f.table.transmit(&f.wire, now);
        if (f.wire.count > before and f.table.conns[i].state != .closed) sends += 1;
        try testing.expect(now < 120 * ns_per_s);
    }
    try testing.expectEqual(@as(usize, 1 + max_retries), sends);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(u64, 1), f.table.given_up);
    // Each wait doubles up to the ceiling, and the last one runs out too.
    var total: i96 = 0;
    var wait: i96 = rto;
    for (0..max_retries + 1) |_| {
        total += wait;
        wait = @min(wait * 2, tcp.max_rto_ns);
    }
    try testing.expectEqual(total, now);
}

test "a shut window is probed, and the rest goes when it opens" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 0 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "0123456789");
    var from = f.wire.count;
    f.table.transmit(&f.wire, 0);
    try testing.expectEqual(from, f.wire.count); // no room
    f.table.transmit(&f.wire, rto);
    try testing.expectEqualStrings("0", f.wire.last().payload); // the probe
    try testing.expectEqual(@as(u64, 1), f.table.probes);

    // The peer took the byte and has room now.
    p.window = 100;
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 1, rto + 10 * ms);
    from = f.wire.count;
    f.table.transmit(&f.wire, rto + 10 * ms);
    try testing.expectEqualStrings("123456789", f.wire.last().payload);
    try testing.expectEqual(from + 1, f.wire.count);
}

test "a window that stays shut is given up on" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 0 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "nobody is reading");
    var now: i96 = 0;
    while (f.table.conns[i].state != .closed) : (now += 10 * ms) {
        f.table.transmit(&f.wire, now);
        // The peer answers every probe, still with no room.
        if (f.wire.count > 0 and f.wire.last().payload.len > 0) _ = p.ackUpTo(&f.table, &f.wire, p.ack, now);
        try testing.expect(now < 60 * ns_per_s);
    }
    try testing.expectEqual(@as(u64, 1), f.table.given_up);
}

test "our FIN waits for the queue, and only its own acknowledgement closes" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 100 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [150]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    f.table.finish(i);
    try testing.expectEqual(@as(usize, 0), f.table.queue(i, "too late"));
    f.table.transmit(&f.wire, 1);
    try testing.expectEqual(flag_psh | flag_ack, f.wire.last().flags); // no FIN yet

    // Every byte so far acknowledged is not the FIN acknowledged.
    try testing.expectEqual(Event.nothing, p.ackAll(&f.table, &f.wire, 2).event);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    f.table.transmit(&f.wire, 3);
    try testing.expectEqual(@as(usize, 50), f.wire.at(f.wire.count - 2).payload.len);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    try testing.expectEqual(p.ack +% 50, f.wire.last().seq);
    try testing.expectEqual(Event.nothing, p.ackUpTo(&f.table, &f.wire, p.ack +% 50, 4).event);
    try testing.expectEqual(State.closing, f.table.conns[i].state);
    try testing.expectEqual(tcp.Fin.sent, f.table.conns[i].fin);
    try testing.expectEqual(Event.nothing, p.ackUpTo(&f.table, &f.wire, p.ack +% 1, 5).event);
    try testing.expectEqual(tcp.Fin.acknowledged, f.table.conns[i].fin);
    try testing.expectEqual(Event.closed, p.fin(&f.table, &f.wire, 6).event);
}

test "a lost FIN is sent again" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    f.table.finish(i);
    f.table.transmit(&f.wire, 0);
    const fin = f.wire.last();
    f.table.transmit(&f.wire, rto);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    try testing.expectEqual(fin.seq, f.wire.last().seq);
    _ = p.ackAll(&f.table, &f.wire, rto + 10 * ms);
    try testing.expectEqual(Event.closed, p.fin(&f.table, &f.wire, rto + 20 * ms).event);
}

test "a lost SYN-ACK is sent again by the timer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    const first = f.wire.last();
    f.table.transmit(&f.wire, rto - 1);
    try testing.expectEqual(@as(usize, 1), f.wire.count);
    f.table.transmit(&f.wire, rto);
    try testing.expectEqual(first.seq, f.wire.last().seq);
    try testing.expectEqual(flag_syn | flag_ack, f.wire.last().flags);
}

test "an ACK with the wrong number does not complete the handshake" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    const r = f.table.handle(&f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    _ = r;
    p.seq +%= 1;
    p.ack = f.wire.last().seq +% 2;
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, p.frame(&buf, flag_ack, p.seq, ""), 0).event);
    try testing.expectEqual(State.syn_received, f.table.conns[0].state);
}

test "a full queue takes only what fits, and acknowledged bytes make room" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [3000]u8 = undefined;
    _ = pattern(&body);
    try testing.expectEqual(@as(usize, 2048), f.table.queue(i, &body));
    try testing.expectEqual(@as(usize, 0), f.table.queue(i, body[2048..]));
    f.table.transmit(&f.wire, 0);
    _ = p.ackUpTo(&f.table, &f.wire, p.ack +% 1000, 1);
    try testing.expectEqual(@as(usize, 952), f.table.queue(i, body[2048..]));
    try testing.expectEqual(@as(usize, 2000), f.table.conns[i].queued());

    // What goes out next is still the stream in order: all 2048 of the first
    // queueing were on the wire, and the rest follows them.
    _ = p.ackAll(&f.table, &f.wire, 2);
    try testing.expectEqual(@as(usize, 952), f.table.conns[i].queued());
    var sent: usize = 2048;
    while (f.table.conns[i].queued() > 0) {
        const from = f.wire.count;
        f.table.transmit(&f.wire, 3);
        for (from..f.wire.count) |k| {
            const s = f.wire.at(k);
            try testing.expectEqualSlices(u8, body[sent..][0..s.payload.len], s.payload);
            sent += s.payload.len;
        }
        _ = p.ackAll(&f.table, &f.wire, 3);
        f.wire.count = 0;
    }
    try testing.expectEqual(@as(usize, 3000), sent);
}

test "nothing is queued before the handshake completes" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    try testing.expectEqual(@as(usize, 0), f.table.queue(0, "early"));
}

test "abandoning a connection tells the peer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    f.table.abandon(&f.wire, i);
    try testing.expectEqual(flag_rst | flag_ack, f.wire.last().flags);
    try testing.expectEqual(p.ack, f.wire.last().seq);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
}

test "segment-size options are read past padding and other options" {
    try testing.expectEqual(@as(?u16, 1460), parseMss(&.{ 1, 1, 4, 2, 2, 4, 5, 180 }));
    try testing.expectEqual(@as(?u16, null), parseMss(&.{ 0, 2, 4, 5, 180 }));
    try testing.expectEqual(@as(?u16, null), parseMss(&.{ 2, 4, 5 }));
    try testing.expectEqual(@as(?u16, null), parseMss(&.{ 3, 0 }));
    try testing.expectEqual(@as(?u16, null), parseMss(&.{}));
}

// ── what the RFC review found ────────────────────────────────────────────────

test "a keepalive probe is acknowledged, and does not count as hearing from the peer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var buf: [1600]u8 = undefined;
    const sent = f.wire.count;
    // A keepalive: one before the next byte expected, and no data.
    const r = f.table.handle(&f.wire, p.frame(&buf, flag_ack, p.seq -% 1, ""), 50);
    try testing.expectEqual(Event.nothing, r.event);
    try testing.expectEqual(sent + 1, f.wire.count);
    try testing.expectEqual(flag_ack, f.wire.last().flags);
    try testing.expectEqual(p.seq, f.wire.last().ack);
    try testing.expectEqual(@as(i96, 1), f.table.conns[i].heard_at);
}

test "a reset counts only at the next byte expected; one inside the window draws an acknowledgement" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 1);
    var buf: [1600]u8 = undefined;
    var sent = f.wire.count;
    // Far outside the window: ignored, without a word.
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, p.frame(&buf, flag_rst, p.seq +% 100_000, ""), 2).event);
    try testing.expectEqual(sent, f.wire.count);
    // Inside it but not exact: a challenge.
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, p.frame(&buf, flag_rst, p.seq +% 10, ""), 2).event);
    try testing.expectEqual(sent + 1, f.wire.count);
    try testing.expectEqual(p.seq, f.wire.last().ack);
    try testing.expectEqual(State.established, f.table.conns[i].state);
    // Exact: the connection is over.
    sent = f.wire.count;
    try testing.expectEqual(Event.closed, f.table.handle(&f.wire, p.frame(&buf, flag_rst, p.seq, ""), 3).event);
    try testing.expectEqual(sent, f.wire.count);
}

test "a late acknowledgement does not overrule a newer one's window" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 4000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [300]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    f.table.transmit(&f.wire, 1);
    const first = p.ack;
    _ = p.ackUpTo(&f.table, &f.wire, first +% 100, 2); // newer, window 4000
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, first, 3); // older, window 0, arriving late
    try testing.expectEqual(@as(u32, 4000), f.table.conns[i].wnd);
}

test "an acknowledgement of bytes sent before a timeout still counts after it" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000, .window = 2000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [1000]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    f.table.transmit(&f.wire, 0);
    const first = p.ack;
    // The window shuts, the timer runs out, and one byte goes as a probe.
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, first, 1);
    f.table.transmit(&f.wire, rto);
    try testing.expectEqual(@as(usize, 1), f.table.conns[i].sent);
    // The peer's acknowledgement of all 1000 bytes is still good.
    p.window = 2000;
    _ = p.ackUpTo(&f.table, &f.wire, first +% 1000, rto + 1);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued());
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].sent);
    try testing.expectEqual(first +% 1000, f.table.conns[i].una);
    try testing.expectEqual(@as(?i96, null), f.table.conns[i].rto_at);
}

test "a handshake ACK of something we never sent is refused with a reset" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    p.seq +%= 1;
    p.ack = f.wire.last().seq +% 99;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_ack, p.seq, ""), 0);
    try testing.expectEqual(flag_rst, f.wire.last().flags);
    try testing.expectEqual(p.ack, f.wire.last().seq);
    try testing.expectEqual(State.syn_received, f.table.conns[0].state);
}

test "a segment with a wrong checksum is dropped" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var buf: [1600]u8 = undefined;
    const frame = p.frame(&buf, flag_psh | flag_ack, p.seq, "hello");
    buf[frame.len - 1] ^= 0xFF; // damage the payload
    const sent = f.wire.count;
    try testing.expectEqual(Event.nothing, f.table.handle(&f.wire, frame, 1).event);
    try testing.expectEqual(sent, f.wire.count);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].pending().len);
    try testing.expectEqual(@as(u64, 1), f.table.damaged);
}

test "a SYN on an established connection draws an acknowledgement, not a new connection" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    _ = try p.connect(&f.table, &f.wire, 0);
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_syn, 99, ""), 1);
    try testing.expectEqual(flag_ack, f.wire.last().flags);
    try testing.expectEqual(@as(usize, 1), f.table.inUse());
}

test "data ahead of what is expected still carries its acknowledgement" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "answer");
    f.table.transmit(&f.wire, 0);
    p.ack +%= 6;
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_psh | flag_ack, p.seq +% 5, "later"), 1);
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued()); // "answer" acknowledged
    try testing.expectEqual(@as(usize, 0), f.table.conns[i].pending().len); // "later" not taken
    try testing.expectEqual(p.seq, f.wire.last().ack);
}

test "their FIN first, then again with ours acknowledged, closes at once" {
    // Seen from QEMU's network: the repeated FIN is numbered before what we
    // now expect, and its acknowledgement of our FIN must still count.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    try testing.expectEqual(Event.peer_done, p.fin(&f.table, &f.wire, 1).event);
    f.table.finish(i);
    f.table.transmit(&f.wire, 2);
    try testing.expectEqual(flag_fin | flag_ack, f.wire.last().flags);
    p.ack = f.wire.last().seq +% 1;
    // The same FIN again, numbered as before, now acknowledging ours.
    try testing.expectEqual(Event.closed, p.fin(&f.table, &f.wire, 3).event);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
}

test "what we send after going back is still numbered at the furthest we sent" {
    // **SND.NXT IS NOT THE RETRANSMISSION POINTER.** A timeout rewinds what to
    // send next; it does not un-send anything. A peer whose window shut can
    // only be probed one byte at a time, so the rewound pointer stays near
    // `una` — and a reset numbered there is behind the peer's window, which
    // discards it and leaves the peer waiting forever on a connection we have
    // already thrown away.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    var body: [100]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    f.table.transmit(&f.wire, 1);
    try testing.expectEqual(@as(usize, 100), f.wire.last().payload.len);
    const una = f.table.conns[i].una;

    // The peer stops reading: it acknowledges nothing new and shuts its window.
    p.window = 0;
    _ = p.ackUpTo(&f.table, &f.wire, una, 2);

    var t: i96 = 2;
    var k: usize = 0;
    while (k <= max_retries) : (k += 1) {
        t += 6 * ns_per_s;
        f.table.transmit(&f.wire, t);
    }
    try testing.expect(f.table.given_up == 1);
    try testing.expectEqual(State.closed, f.table.conns[i].state);
    const rst = f.wire.last();
    try testing.expectEqual(flag_rst | flag_ack, rst.flags);
    try testing.expectEqual(una +% 100, rst.seq); // where the peer's window begins
}

test "a segment beyond the window carries nothing, not even its acknowledgement" {
    // Taking the acknowledgement of a segment the peer cannot have sent yet
    // would set SND.WL1 past anything it will ever send, and then the window
    // rule refuses every real update that follows.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = f.table.queue(i, "ten bytes!");
    f.table.transmit(&f.wire, 1);
    const una = f.table.conns[i].una;
    const wl1 = f.table.conns[i].wl1;

    p.ack = una +% 10; // it claims to have the lot
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_ack, p.seq +% 100_000, ""), 2);

    try testing.expectEqual(una, f.table.conns[i].una);
    try testing.expectEqual(wl1, f.table.conns[i].wl1);
    try testing.expectEqual(@as(usize, 10), f.table.conns[i].queued());
    try testing.expectEqual(flag_ack, f.wire.last().flags);
}

test "an older segment with a newer acknowledgement moves the window's edge too" {
    // The window rule keeps the old segment from setting the window, but its
    // acknowledgement still moves `una` — and the window is measured from
    // `una`, so the edge has to come back by as much.
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    const i = try p.connect(&f.table, &f.wire, 0);
    _ = p.write(&f.table, &f.wire, "GET /\r\n\r\n", 1);
    var body: [50]u8 = undefined;
    _ = f.table.queue(i, pattern(&body));
    f.table.transmit(&f.wire, 2);
    const before = f.table.conns[i].wnd;

    p.ack = f.table.conns[i].una +% 50;
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_ack, p.seq -% 20, ""), 3);

    try testing.expectEqual(@as(usize, 0), f.table.conns[i].queued());
    try testing.expectEqual(before - 50, f.table.conns[i].wnd);
}

test "giving up on a handshake tells the peer, instead of leaving it on a timer" {
    var f: Fixture = .{};
    f.init();
    var p = Peer{ .ip = .{ 10, 0, 2, 2 }, .port = 40000 };
    var buf: [1600]u8 = undefined;
    _ = f.table.handle(&f.wire, p.frame(&buf, flag_syn, p.seq, ""), 0);
    const synack = f.wire.last();
    try testing.expectEqual(flag_syn | flag_ack, synack.flags);

    var t: i96 = 0;
    var k: usize = 0;
    while (k <= max_retries) : (k += 1) {
        t += 6 * ns_per_s;
        f.table.transmit(&f.wire, t);
    }
    const rst = f.wire.last();
    try testing.expect(rst.flags & flag_rst != 0);
    try testing.expectEqual(synack.seq +% 1, rst.seq);
    try testing.expectEqual(State.closed, f.table.conns[0].state);
    try testing.expect(f.table.given_up == 1);
}
