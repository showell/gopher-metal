//! **THE TABLE AGAINST A SIMULATED NETWORK AND A PEER WE DID NOT DERIVE FROM
//! IT** (TCP_TESTING.md §3).
//!
//! Each run is one seed. The seed chooses a scenario:
//!
//! - how big the request and the answer are;
//! - how the network loses, duplicates, delays, reorders and corrupts
//!   frames, in both directions;
//! - how slowly each side reads, and for how long it stalls;
//! - whether the client closes its half early;
//! - whether it vanishes part-way.
//!
//! Then three parties run on one virtual clock, a millisecond at a time:
//!
//! - **The table** (`tcp.zig`), exactly as the kernel runs it.
//! - **A host** that does what `probe/gopher.zig` and `stream.zig` do with a
//!   connection. It reads the request at its own pace, stalling now and
//!   then, and announces a reopened window as `streamFn` does (or, by the
//!   seed, does not). It queues the answer as room allows and finishes. It
//!   lets go of a connection that makes no progress for `idle_ns`.
//! - **A client** written from RFC 9293 and RFC 1122, not by turning
//!   `tcp.zig` around: a model that shared the table's misreadings would
//!   agree with its bugs. It has:
//!   - its own retransmission timer, which goes back to SND.UNA on a timeout;
//!   - delayed acknowledgements: every second segment, or after 40 ms or
//!     200 ms by the seed (Linux and slirp);
//!   - a persist timer that probes a shut window and backs off to 60 s;
//!   - receiver-side silly-window avoidance;
//!   - RFC 9293's acceptability test, and its handling of each state.
//!
//! **THE ORACLES**, any of which fails the run with its seed:
//!
//! - **Invariants:** tcp_check.zig's, after every step the table takes.
//! - **Exactly once, in order:** every byte the host reads is the next byte
//!   of the request, and every byte the client takes is the next byte of the
//!   answer.
//! - **Completion:** a client that did not vanish gets the whole answer and
//!   our FIN, the host reads the whole request, nobody gives up or resets,
//!   all of it within `completion_bound_ns` of the start. This is the oracle
//!   that catches liveness bugs ("it recovers, eventually, after a minute"),
//!   which the next one alone would allow.
//! - **Quiescence:** by `horizon_ns` every slot of the table is closed,
//!   whatever the client did. A connection still held then is held by
//!   nothing.
//!
//! Frames are lost only before `lossy_until`. After that the path is clean,
//! so a run that does not complete is a bug, not bad luck. A lossy phase can
//! still, very rarely, lose one frame `max_retries` + 1 times running. A seed
//! that fails that way is reported with the table's give-up count, and it is
//! the run to look at first.

const std = @import("std");
const proto = @import("proto.zig");
const tcp = @import("tcp.zig");
const invariants = @import("tcp_check.zig");

const ns_per_ms: i96 = 1_000_000;
const ns_per_s: i96 = 1_000_000_000;

/// One turn of the loop: what the kernel's 1 ms rest makes its slowest turn.
const tick_ns: i96 = ns_per_ms;
/// Every run ends here. Past every bound the table and the host keep: a
/// vanished client is noticed within `idle_ns`, given up on within about
/// 35 s, and waited for at most `fin_wait_ns`.
const horizon_ns: i96 = 150 * ns_per_s;
/// A client that does not vanish has its whole answer by then.
const completion_bound_ns: i96 = 60 * ns_per_s;
/// The host's patience, as `stream.default_idle_ns`.
const idle_ns: i96 = 10 * ns_per_s;

const server_ip = [4]u8{ 10, 0, 2, 15 };
const server_mac = [6]u8{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 };
const client_ip = [4]u8{ 10, 0, 2, 2 };
const client_mac = [6]u8{ 0x52, 0x55, 0x0a, 0, 2, 2 };
const client_port: u16 = 40000;

/// The table's buffers, small, so that windows shut and queues fill.
const rx_bytes = 4096;
const tx_bytes = 8192;
/// The client's receive buffer: what it advertises when it has read
/// everything.
const client_buffer: usize = 4096;
/// The segment size the client says, and sends.
const client_mss: u32 = 1000;

fn requestByte(k: usize) u8 {
    return @truncate(k *% 7 +% 1);
}

fn answerByte(k: usize) u8 {
    return @truncate(k *% 13 +% 5);
}

/// Sequence numbers, modulo 2^32.
fn seqLt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}
fn seqLe(a: u32, b: u32) bool {
    return a == b or seqLt(a, b);
}

fn randNs(rng: std.Random, max_ns: i96) i96 {
    if (max_ns <= 0) return 0;
    return @intCast(rng.uintLessThan(u64, @intCast(max_ns)));
}

// ── what a seed chooses ─────────────────────────────────────────────────────

const Scenario = struct {
    request_len: usize,
    answer_len: usize,
    /// The chance that a frame is lost, either way, before `lossy_until`.
    loss: f64,
    lossy_until: i96,
    duplicate: f64,
    corrupt: f64,
    /// One way, and a random extra on top of it, which is what reorders.
    delay_ns: i96,
    jitter_ns: i96,
    /// How long the client sits on an acknowledgement.
    delayed_ack_ns: i96,
    /// The client sends its FIN right after its request.
    half_close: bool,
    /// The host's reads and the client's reads stall for up to this long.
    host_stall_ns: i96,
    client_stall_ns: i96,
    /// The client stops existing, without a word, at this time.
    vanish_at: ?i96,
    /// The host tells the table it made room, as `streamFn` does; otherwise
    /// the table has to notice by itself.
    host_announces: bool,
    /// **DETERMINISTIC LOSS, FOR THE SWEEP** (QUEUE.md item 96): drop the
    /// frame at this 0-based index among all frames the table sends the client,
    /// once. Null for the random scenarios, which lose by `loss`.
    drop_nth_to_client: ?u64 = null,

    /// A fixed scenario for the item-96 sweep: a few-KB answer the host closes
    /// after, clean except for one dropped frame to the client, with ACKs
    /// delayed and frames reordered (jitter). This is the shape the lost-frame
    /// `IncompleteRead` was seen in, made deterministic.
    fn fixed(answer_len: usize, drop_nth: ?u64, announces: bool) Scenario {
        return .{
            .request_len = 200,
            .answer_len = answer_len,
            .loss = 0,
            .lossy_until = 0,
            .duplicate = 0,
            .corrupt = 0,
            .delay_ns = 500_000,
            .jitter_ns = 3 * ns_per_ms, // reorders frames of the same moment
            .delayed_ack_ns = 40 * ns_per_ms,
            .half_close = false,
            .host_stall_ns = 0,
            .client_stall_ns = 0,
            .vanish_at = null,
            .host_announces = announces,
            .drop_nth_to_client = drop_nth,
        };
    }

    fn choose(rng: std.Random) Scenario {
        const lossiness = rng.uintLessThan(u8, 3);
        return .{
            .request_len = rng.intRangeAtMost(usize, 1, 20_000),
            .answer_len = rng.intRangeAtMost(usize, 0, 60_000),
            .loss = ([_]f64{ 0, 0.03, 0.1 })[lossiness],
            .lossy_until = 3 * ns_per_s,
            .duplicate = if (rng.boolean()) 0.02 else 0,
            .corrupt = if (rng.boolean()) 0.01 else 0,
            .delay_ns = @intCast(rng.intRangeAtMost(u64, 100_000, 5_000_000)),
            .jitter_ns = if (rng.boolean()) 3 * ns_per_ms else 0,
            .delayed_ack_ns = if (rng.boolean()) 40 * ns_per_ms else 200 * ns_per_ms,
            .half_close = rng.boolean(),
            // Long enough for the client's persist timer to back off, short
            // enough that the host's own patience is not what ends it.
            .host_stall_ns = randNs(rng, 8 * ns_per_s),
            // Short of the table's zero-window give-up (about 16 s), which
            // is what lets go of a client that stops reading for good.
            .client_stall_ns = randNs(rng, 5 * ns_per_s),
            .vanish_at = if (rng.uintLessThan(u8, 4) == 0) randNs(rng, 20 * ns_per_s) else null,
            .host_announces = rng.boolean(),
        };
    }
};

// ── the network ─────────────────────────────────────────────────────────────

const Packet = struct {
    at: i96,
    to_table: bool,
    len: usize,
    bytes: [1600]u8,
};

const Network = struct {
    queue: [256]Packet = undefined,
    count: usize = 0,
    sent: u64 = 0,
    lost: u64 = 0,
    duplicated: u64 = 0,
    corrupted: u64 = 0,
    /// Frames dropped because too many were in flight: a router's queue.
    overflowed: u64 = 0,
    /// Frames the table has sent the client, for `drop_nth_to_client`.
    to_client: u64 = 0,

    fn send(self: *Network, rng: std.Random, sc: *const Scenario, now: i96, to_table: bool, frame: []const u8) void {
        self.sent += 1;
        // The deterministic drop (item 96): one chosen frame to the client,
        // whatever the clock. Counted as lost, like any other.
        if (!to_table) {
            const nth = self.to_client;
            self.to_client += 1;
            if (sc.drop_nth_to_client == nth) {
                self.lost += 1;
                return;
            }
        }
        if (now < sc.lossy_until and rng.float(f64) < sc.loss) {
            self.lost += 1;
            return;
        }
        const copies: usize = if (rng.float(f64) < sc.duplicate) 2 else 1;
        if (copies == 2) self.duplicated += 1;
        for (0..copies) |_| {
            if (self.count == self.queue.len) {
                self.overflowed += 1;
                return;
            }
            const p = &self.queue[self.count];
            self.count += 1;
            p.at = now + sc.delay_ns + randNs(rng, sc.jitter_ns + 1);
            p.to_table = to_table;
            p.len = frame.len;
            @memcpy(p.bytes[0..frame.len], frame);
            // One byte of the TCP segment changed: its checksum always
            // notices a single byte.
            if (frame.len > tcp.segment_at and rng.float(f64) < sc.corrupt) {
                self.corrupted += 1;
                p.bytes[tcp.segment_at + rng.uintLessThan(usize, frame.len - tcp.segment_at)] ^= 0x5A;
            }
        }
    }

    /// The earliest frame due by `now`, taken out of the queue into `out`.
    fn take(self: *Network, now: i96, out: *[1600]u8) ?struct { to_table: bool, frame: []const u8 } {
        var best: ?usize = null;
        for (self.queue[0..self.count], 0..) |*p, k| {
            if (p.at > now) continue;
            if (best == null or p.at < self.queue[best.?].at) best = k;
        }
        const k = best orelse return null;
        const p = &self.queue[k];
        const len = p.len;
        const to_table = p.to_table;
        @memcpy(out[0..len], p.bytes[0..len]);
        self.queue[k] = self.queue[self.count - 1];
        self.count -= 1;
        return .{ .to_table = to_table, .frame = out[0..len] };
    }
};

// ── the client, from RFC 9293 ───────────────────────────────────────────────

const ClientState = enum { syn_sent, established, fin_wait_1, fin_wait_2, closing, time_wait, close_wait, last_ack, closed };

const Client = struct {
    state: ClientState = .syn_sent,
    /// From `vanish_at` on it neither sends nor hears.
    gone: bool = false,
    /// It was reset, or reset the connection itself, before the end.
    aborted: bool = false,

    iss: u32,
    snd_una: u32,
    snd_nxt: u32,
    /// The furthest it has ever sent: an acknowledgement up to here counts,
    /// even after a timeout sent `snd_nxt` back.
    snd_max: u32,
    snd_wnd: u32 = 0,
    snd_wl1: u32 = 0,
    snd_wl2: u32 = 0,
    /// Its FIN follows the request: from the start if it closes early, else
    /// once the table's FIN has come.
    fin_wanted: bool = false,
    irs: u32 = 0,
    rcv_nxt: u32 = 0,
    /// The table's FIN has arrived.
    peer_fin: bool = false,

    rto_ns: i96 = base_rto_ns,
    rto_at: ?i96 = null,
    retries: u8 = 0,
    persist_ns: i96 = base_rto_ns,
    persist_at: ?i96 = null,
    probes: u64 = 0,
    /// In-order segments taken and not yet acknowledged.
    ack_owed: u8 = 0,
    delack_at: ?i96 = null,
    told_wnd: u32 = 0,

    /// Bytes of the answer taken, and of those not yet read by its
    /// application.
    received: usize = 0,
    unread: usize = 0,
    stall_until: i96 = 0,
    time_wait_until: ?i96 = null,
    done_at: ?i96 = null,

    /// Bytes ahead of a hole, by their offset from RCV.NXT, waiting for it
    /// to fill; and where the table's FIN is, once one has been seen.
    held: [client_buffer]u8 = undefined,
    held_mask: [client_buffer]bool = @splat(false),
    fin_at: ?u32 = null,

    const base_rto_ns: i96 = 300 * ns_per_ms;
    const max_rto_ns: i96 = 8 * ns_per_s;
    const max_persist_ns: i96 = 60 * ns_per_s;
    const max_retries: u8 = 12;
    const time_wait_ns: i96 = 2 * ns_per_s;

    fn init(iss: u32) Client {
        return .{ .iss = iss, .snd_una = iss, .snd_nxt = iss, .snd_max = iss };
    }

    /// Whether anything is held past a hole.
    fn holding(self: *const Client) bool {
        return std.mem.indexOfScalar(bool, &self.held_mask, true) != null;
    }

    fn window(self: *const Client) u32 {
        return @intCast(@min(client_buffer - self.unread, 0xFFFF));
    }

    /// Bytes of the request sent so far, at `snd_nxt`.
    fn requestSent(self: *const Client, sim: *const Sim) usize {
        const n: usize = self.snd_nxt -% (self.iss +% 1);
        return @min(n, sim.sc.request_len);
    }

    fn finSeq(self: *const Client, sim: *const Sim) u32 {
        return self.iss +% 1 +% @as(u32, @intCast(sim.sc.request_len));
    }

    fn finSent(self: *const Client, sim: *const Sim) bool {
        return self.fin_wanted and seqLt(self.finSeq(sim), self.snd_nxt);
    }

    fn emit(self: *Client, sim: *Sim, flags: u8, seq: u32, data: []const u8) void {
        var buf: [1600]u8 = undefined;
        const options: []const u8 = if (flags & tcp.flag_syn != 0) &[_]u8{ 2, 4, client_mss >> 8, client_mss & 0xFF } else &.{};
        const len = tcp.header_len + options.len;
        const frame_len = proto.writeIpv4(&buf, client_mac, server_mac, client_ip, server_ip, proto.proto_tcp, len + data.len);
        const t = buf[tcp.segment_at..][0 .. len + data.len];
        const wnd = self.window();
        @memcpy(t[0..2], &proto.be16(client_port));
        @memcpy(t[2..4], &proto.be16(80));
        @memcpy(t[4..8], &proto.be32(seq));
        @memcpy(t[8..12], &proto.be32(if (flags & tcp.flag_ack != 0) self.rcv_nxt else 0));
        t[12] = @intCast((len / 4) << 4);
        t[13] = flags;
        @memcpy(t[14..16], &proto.be16(@intCast(wnd)));
        @memcpy(t[16..20], &[_]u8{ 0, 0, 0, 0 });
        @memcpy(t[tcp.header_len..len], options);
        @memcpy(t[len..], data);
        @memcpy(t[16..18], &proto.be16(proto.pseudoChecksum(client_ip, server_ip, proto.proto_tcp, t)));
        if (flags & tcp.flag_ack != 0) {
            // Every acknowledgement it sends pays what it owed.
            self.ack_owed = 0;
            self.delack_at = null;
            self.told_wnd = wnd;
        }
        sim.net.send(sim.rng, &sim.sc, sim.now, true, buf[0..frame_len]);
    }

    fn sendAck(self: *Client, sim: *Sim) void {
        self.emit(sim, tcp.flag_ack, self.snd_nxt, "");
    }

    fn open(self: *Client, sim: *Sim) void {
        self.fin_wanted = sim.sc.half_close;
        self.emit(sim, tcp.flag_syn, self.iss, "");
        self.snd_nxt = self.iss +% 1;
        self.snd_max = self.snd_nxt;
        self.rto_at = sim.now + self.rto_ns;
    }

    fn abort(self: *Client, sim: *Sim) void {
        self.emit(sim, tcp.flag_rst, self.snd_nxt, "");
        self.aborted = true;
        self.finish(sim);
    }

    fn finish(self: *Client, sim: *Sim) void {
        self.state = .closed;
        self.rto_at = null;
        self.persist_at = null;
        self.delack_at = null;
        if (self.done_at == null) self.done_at = sim.now;
    }

    /// Sends what the window allows, then the FIN if it is due.
    fn output(self: *Client, sim: *Sim) void {
        if (self.state != .established and self.state != .close_wait and
            self.state != .fin_wait_1 and self.state != .last_ack and self.state != .closing) return;
        const n_req = sim.sc.request_len;
        while (true) {
            if (self.finSent(sim)) return;
            const sent = self.requestSent(sim);
            if (sent < n_req) {
                const flight = self.snd_nxt -% self.snd_una;
                if (flight >= self.snd_wnd) {
                    // A shut window with nothing in flight: only the persist
                    // timer will learn that it has opened (RFC 9293 §3.8.6.1).
                    if (self.snd_wnd == 0 and flight == 0 and self.persist_at == null)
                        self.persist_at = sim.now + self.persist_ns;
                    return;
                }
                const n = @min(n_req - sent, self.snd_wnd - flight, client_mss);
                var data: [client_mss]u8 = undefined;
                for (data[0..n], sent..) |*b, k| b.* = requestByte(k);
                self.emit(sim, tcp.flag_psh | tcp.flag_ack, self.snd_nxt, data[0..n]);
                self.advance(sim, @intCast(n));
                continue;
            }
            if (!self.fin_wanted) return;
            self.emit(sim, tcp.flag_fin | tcp.flag_ack, self.snd_nxt, "");
            self.advance(sim, 1);
            self.state = switch (self.state) {
                .established => .fin_wait_1,
                .close_wait => .last_ack,
                else => self.state, // a FIN sent again
            };
            return;
        }
    }

    fn advance(self: *Client, sim: *Sim, n: u32) void {
        self.snd_nxt +%= n;
        if (seqLt(self.snd_max, self.snd_nxt)) self.snd_max = self.snd_nxt;
        if (self.rto_at == null) self.rto_at = sim.now + self.rto_ns;
    }

    /// One turn: its application reads, its timers run, it sends.
    fn turn(self: *Client, sim: *Sim) void {
        if (self.gone or self.state == .closed) return;
        if (sim.sc.vanish_at) |at| if (sim.now >= at) {
            self.gone = true;
            if (self.done_at == null) self.done_at = sim.now;
            return;
        };

        // Its application reads what has arrived, at its own pace.
        if (self.unread > 0 and sim.now >= self.stall_until) {
            if (sim.rng.uintLessThan(u32, 2000) == 0) {
                self.stall_until = sim.now + randNs(sim.rng, sim.sc.client_stall_ns);
            } else {
                self.unread -= sim.rng.intRangeAtMost(usize, 1, self.unread);
                // Receiver-side silly-window avoidance: a window update once
                // it has grown by a segment or half the buffer.
                const grown = self.window() -| self.told_wnd;
                if (self.state != .syn_sent and grown >= @min(client_mss, client_buffer / 2)) self.sendAck(sim);
            }
        }

        if (self.time_wait_until) |until| if (sim.now >= until) return self.finish(sim);
        if (self.delack_at) |at| if (sim.now >= at) self.sendAck(sim);

        if (self.rto_at) |at| if (sim.now >= at) {
            self.retries += 1;
            if (self.retries > max_retries) return self.abort(sim);
            self.rto_ns = @min(self.rto_ns * 2, max_rto_ns);
            self.rto_at = sim.now + self.rto_ns;
            if (self.state == .syn_sent) {
                self.emit(sim, tcp.flag_syn, self.iss, "");
            } else {
                // Go back: everything from SND.UNA is sent again. If the
                // window is shut nothing goes, and the persist timer, which
                // does not count toward giving up, takes over.
                self.snd_nxt = self.snd_una;
                self.output(sim);
                if (self.snd_nxt == self.snd_una) self.rto_at = null;
            }
        };

        if (self.persist_at) |at| if (sim.now >= at) {
            // One byte of new data past the shut window (RFC 9293 §3.8.6.1).
            // It is not counted as sent: if the table takes it, its
            // acknowledgement says so.
            const sent = self.requestSent(sim);
            if (self.snd_wnd == 0 and sent < sim.sc.request_len and self.snd_nxt == self.snd_una) {
                self.probes += 1;
                const probe = [1]u8{requestByte(sent)};
                self.emit(sim, tcp.flag_psh | tcp.flag_ack, self.snd_nxt, &probe);
                if (seqLt(self.snd_max, self.snd_nxt +% 1)) self.snd_max = self.snd_nxt +% 1;
                self.persist_ns = @min(self.persist_ns * 2, max_persist_ns);
                self.persist_at = sim.now + self.persist_ns;
            } else self.persist_at = null;
        };

        self.output(sim);
    }

    /// A frame from the table.
    fn receive(self: *Client, sim: *Sim, frame: []const u8) void {
        if (self.gone or self.state == .closed) return;
        const pkt = proto.parseIpv4(frame) orelse return;
        const t = pkt.payload;
        if (pkt.protocol != proto.proto_tcp or t.len < tcp.header_len) return;
        if (proto.readBe16(t[2..4]) != client_port) return;
        if (proto.pseudoChecksum(pkt.src_ip, pkt.dst_ip, proto.proto_tcp, t) != 0) return;
        const seq = proto.readBe32(t[4..8]);
        const ack = proto.readBe32(t[8..12]);
        const flags = t[13];
        const wnd: u32 = proto.readBe16(t[14..16]);
        const offset = @as(usize, t[12] >> 4) * 4;
        if (offset < tcp.header_len or offset > t.len) return;
        const data = t[offset..];

        if (self.state == .syn_sent) {
            if (flags & tcp.flag_ack != 0 and ack != self.iss +% 1) return;
            if (flags & tcp.flag_rst != 0) {
                if (flags & tcp.flag_ack != 0) {
                    self.aborted = true;
                    self.finish(sim);
                }
                return;
            }
            if (flags & tcp.flag_syn == 0 or flags & tcp.flag_ack == 0) return;
            self.irs = seq;
            self.rcv_nxt = seq +% 1;
            self.snd_una = ack;
            self.snd_wnd = wnd;
            self.snd_wl1 = seq;
            self.snd_wl2 = ack;
            self.state = .established;
            self.rto_at = null;
            self.retries = 0;
            self.rto_ns = base_rto_ns;
            self.sendAck(sim);
            self.output(sim);
            return;
        }

        // **THE ACCEPTABILITY TEST** (RFC 9293 §3.10.7.4, first).
        var seg_len: u32 = @intCast(data.len);
        if (flags & tcp.flag_syn != 0) seg_len += 1;
        if (flags & tcp.flag_fin != 0) seg_len += 1;
        const rcv_wnd = self.window();
        const acceptable = if (seg_len == 0)
            (if (rcv_wnd == 0) seq == self.rcv_nxt else (seq -% self.rcv_nxt) < rcv_wnd)
        else
            rcv_wnd > 0 and ((seq -% self.rcv_nxt) < rcv_wnd or
                ((seq +% seg_len -% 1) -% self.rcv_nxt) < rcv_wnd);
        if (!acceptable) {
            if (flags & tcp.flag_rst == 0) self.sendAck(sim);
            return;
        }

        // Second, the reset.
        if (flags & tcp.flag_rst != 0) {
            if (seq != self.rcv_nxt) return self.sendAck(sim); // RFC 5961's challenge
            // In the closing states a reset is only an early end (RFC 9293
            // §3.10.7.4); before them it is an abort.
            switch (self.state) {
                .closing, .last_ack, .time_wait => {},
                else => self.aborted = true,
            }
            return self.finish(sim);
        }
        // Fourth, a SYN in the window: a challenge ACK, and nothing else.
        if (flags & tcp.flag_syn != 0) return self.sendAck(sim);
        // Fifth, the acknowledgement.
        if (flags & tcp.flag_ack == 0) return;
        if (seqLt(self.snd_max, ack)) return self.sendAck(sim); // of something never sent
        if (seqLt(self.snd_una, ack)) {
            self.snd_una = ack;
            if (seqLt(self.snd_nxt, self.snd_una)) self.snd_nxt = self.snd_una;
            self.retries = 0;
            self.rto_ns = base_rto_ns;
            self.rto_at = if (self.snd_nxt != self.snd_una) sim.now + self.rto_ns else null;
            if (self.fin_wanted and ack == self.finSeq(sim) +% 1) {
                switch (self.state) {
                    .fin_wait_1 => self.state = .fin_wait_2,
                    .closing => {
                        self.state = .time_wait;
                        self.time_wait_until = sim.now + time_wait_ns;
                    },
                    .last_ack => return self.finish(sim),
                    else => {},
                }
            }
        }
        if (seqLt(self.snd_wl1, seq) or (self.snd_wl1 == seq and seqLe(self.snd_wl2, ack))) {
            self.snd_wnd = wnd;
            self.snd_wl1 = seq;
            self.snd_wl2 = ack;
            if (wnd > 0) {
                self.persist_at = null;
                self.persist_ns = base_rto_ns;
            }
        }

        // Seventh, the text. Segments ahead of a hole are held, as Linux
        // holds them (RFC 9293 makes it a MAY), and a hole is reported, and
        // its filling acknowledged, at once (RFC 5681 §4.2).
        if (flags & tcp.flag_fin != 0) self.fin_at = seq +% @as(u32, @intCast(data.len));
        var at_once = false;
        if (data.len > 0) {
            const takes = self.state == .established or self.state == .fin_wait_1 or self.state == .fin_wait_2;
            if (!takes) {
                // Text after the table's FIN: it should never come.
                sim.fault("the table sent text after its FIN");
                return;
            }
            // Where the segment's bytes go, relative to RCV.NXT: a segment
            // that straddles it has its old part skipped.
            var skip: usize = 0;
            var at: usize = 0;
            if (seqLt(seq, self.rcv_nxt)) {
                skip = self.rcv_nxt -% seq;
            } else at = seq -% self.rcv_nxt;
            const room = self.window();
            const had_hole = self.holding();
            if (at > 0) at_once = true; // out of order: a duplicate ACK now
            for (data[@min(skip, data.len)..], at..) |b, pos| {
                if (pos >= room) break;
                self.held[pos] = b;
                self.held_mask[pos] = true;
            }
            var n: usize = 0;
            while (n < room and self.held_mask[n]) n += 1;
            if (n > 0) {
                for (self.held[0..n], self.received..) |b, k| {
                    if (k >= sim.sc.answer_len or b != answerByte(k)) {
                        sim.fault("the client took a byte that is not the next byte of the answer");
                        return;
                    }
                }
                self.received += n;
                self.unread += n;
                self.rcv_nxt +%= @intCast(n);
                std.mem.copyForwards(u8, self.held[0 .. client_buffer - n], self.held[n..]);
                std.mem.copyForwards(bool, self.held_mask[0 .. client_buffer - n], self.held_mask[n..]);
                @memset(self.held_mask[client_buffer - n ..], false);
                if (had_hole or self.holding()) at_once = true; // a hole filled, or one left
            }
            if (data.len > skip and skip + (room -| at) < data.len) at_once = true; // some did not fit
            self.ack_owed += 1;
            if (at_once or self.ack_owed >= 2) {
                self.sendAck(sim);
            } else if (self.delack_at == null) {
                self.delack_at = sim.now + sim.sc.delayed_ack_ns;
            }
        }

        // Eighth, the FIN, once everything before it has been taken.
        if (self.fin_at) |fin_seq| {
            if (!self.peer_fin and fin_seq == self.rcv_nxt) {
                self.rcv_nxt +%= 1;
                self.peer_fin = true;
                switch (self.state) {
                    .established => {
                        self.state = .close_wait;
                        self.fin_wanted = true;
                    },
                    .fin_wait_1 => self.state = .closing,
                    .fin_wait_2 => {
                        self.state = .time_wait;
                        self.time_wait_until = sim.now + time_wait_ns;
                    },
                    else => {},
                }
                self.sendAck(sim);
            } else if (!self.peer_fin and flags & tcp.flag_fin != 0) {
                // A FIN ahead of a hole: say what is missing.
                self.sendAck(sim);
            }
        }
        self.output(sim);
    }
};

// ── the host ────────────────────────────────────────────────────────────────

const Host = struct {
    slot: ?usize = null,
    consumed: usize = 0,
    queued: usize = 0,
    finished: bool = false,
    let_go: bool = false,
    stall_until: i96 = 0,
    last_progress: i96 = 0,
    seen_una: u32 = 0,

    /// One turn, between the network's arrivals and the table's `transmit`.
    fn turn(self: *Host, sim: *Sim) void {
        const table = &sim.table;
        var wire = TableWire{ .sim = sim };
        if (self.slot == null) {
            for (table.conns, 0..) |held, k| {
                if (held.state == .established) {
                    self.slot = k;
                    self.last_progress = sim.now;
                    table.claim(k);
                    break;
                }
            } else return;
        }
        const i = self.slot.?;
        const c = &table.conns[i];
        if (self.finished or self.let_go) return;
        if (c.state == .closed) {
            // Reset under us: the host's part is over.
            self.let_go = true;
            table.release(i);
            return;
        }

        if (self.consumed < sim.sc.request_len) {
            if (sim.now < self.stall_until) return;
            if (sim.rng.uintLessThan(u32, 2000) == 0) {
                self.stall_until = sim.now + randNs(sim.rng, sim.sc.host_stall_ns);
                return;
            }
            const pending = c.pending();
            if (pending.len > 0) {
                const n = sim.rng.intRangeAtMost(usize, 1, @min(pending.len, 3000));
                for (pending[0..n], self.consumed..) |b, k| {
                    if (k >= sim.sc.request_len or b != requestByte(k)) {
                        sim.fault("the host read a byte that is not the next byte of the request");
                        return;
                    }
                }
                // As streamFn: a window that had shrunk below a segment is
                // announced when it reopens.
                const was_tight = c.room() < tcp.our_mss;
                c.consume(n);
                self.consumed += n;
                self.last_progress = sim.now;
                if (sim.sc.host_announces and was_tight and c.room() >= tcp.our_mss) table.ack(&wire, i);
            } else if (c.peer_done or !c.open()) {
                // The request will never be whole: answered and closed, as
                // the host does a request that ends early.
                self.close(sim, i);
            } else if (sim.now - self.last_progress >= idle_ns) {
                self.giveUp(sim, i);
            }
            return;
        }

        if (self.queued < sim.sc.answer_len) {
            var chunk: [2048]u8 = undefined;
            const want = @min(chunk.len, sim.sc.answer_len - self.queued);
            for (chunk[0..want], self.queued..) |*b, k| b.* = answerByte(k);
            const n = table.queue(i, chunk[0..want]);
            self.queued += n;
            if (n > 0 or c.una != self.seen_una) {
                self.last_progress = sim.now;
                self.seen_una = c.una;
            } else if (sim.now - self.last_progress >= idle_ns) {
                // As sendAll: a write that gets nowhere for the idle time.
                return self.giveUp(sim, i);
            }
            if (self.queued < sim.sc.answer_len) return;
        }
        self.close(sim, i);
    }

    /// As gopher.zig's `close`: the FIN is queued and nobody waits for it.
    fn close(self: *Host, sim: *Sim, i: usize) void {
        var wire = TableWire{ .sim = sim };
        sim.table.finish(i);
        if (sim.table.conns[i].state != .closing) sim.table.abandon(&wire, i);
        sim.table.release(i);
        self.finished = true;
    }

    fn giveUp(self: *Host, sim: *Sim, i: usize) void {
        var wire = TableWire{ .sim = sim };
        sim.table.abandon(&wire, i);
        sim.table.release(i);
        self.let_go = true;
    }
};

// ── the run ─────────────────────────────────────────────────────────────────

/// What the table sends goes into the network, toward the client.
const TableWire = struct {
    sim: *Sim,

    pub fn send(self: *TableWire, frame: []const u8) void {
        const sim = self.sim;
        sim.net.send(sim.rng, &sim.sc, sim.now, false, frame);
    }
};

var sim_isn: u32 = 0;
fn simIsn() u32 {
    sim_isn +%= 64_000;
    return sim_isn;
}

const Sim = struct {
    seed: u64,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    sc: Scenario,
    now: i96 = 0,
    net: Network = .{},
    conns: [2]tcp.Conn,
    rx: [2][rx_bytes]u8,
    tx: [2][tx_bytes]u8,
    out: [1600]u8,
    table: tcp.Table,
    host: Host = .{},
    client: Client,
    /// The first oracle that failed, if any.
    broken: ?[]const u8 = null,

    /// In place: the table holds slices of this struct's own buffers.
    fn init(self: *Sim, seed: u64) void {
        self.seed = seed;
        self.prng = std.Random.DefaultPrng.init(seed);
        self.rng = self.prng.random();
        self.sc = Scenario.choose(self.rng);
        self.build();
    }

    /// Like `init`, but with a chosen scenario (the item-96 sweep). The seed
    /// still seeds the RNG, so jitter — which is what reorders frames — is
    /// deterministic per (seed, scenario).
    fn initScenario(self: *Sim, seed: u64, sc: Scenario) void {
        self.seed = seed;
        self.prng = std.Random.DefaultPrng.init(seed);
        self.rng = self.prng.random();
        self.sc = sc;
        self.build();
    }

    fn build(self: *Sim) void {
        self.now = 0;
        self.net = .{};
        self.host = .{};
        self.broken = null;
        for (&self.conns, &self.rx, &self.tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
        sim_isn = self.rng.int(u32);
        self.table = tcp.Table.init(server_ip, server_mac, 80, &self.conns, &self.out, simIsn);
        self.client = Client.init(self.rng.int(u32));
    }

    fn fault(self: *Sim, what: []const u8) void {
        if (self.broken == null) self.broken = what;
    }

    fn checkTable(self: *Sim, phase: invariants.Phase) void {
        if (invariants.check(&self.table, self.now, phase)) |v| {
            std.debug.print("seed {d}: invariant broken {s}, connection {d}, at {d} ms: {s}\n", .{
                self.seed, @tagName(phase), v.conn, @divTrunc(self.now, ns_per_ms), v.rule.says(),
            });
            self.fault("a tcp_check.zig invariant");
        }
    }

    fn quiescent(self: *const Sim) bool {
        for (self.table.conns) |c| if (c.state != .closed) return false;
        return true;
    }

    fn over(self: *const Sim) bool {
        const client_done = self.client.gone or self.client.state == .closed;
        return client_done and (self.host.finished or self.host.let_go or self.host.slot == null) and
            self.quiescent() and self.net.count == 0;
    }

    fn run(self: *Sim) !void {
        self.client.open(self);
        var buf: [1600]u8 = undefined;
        while (self.now < horizon_ns and self.broken == null and !self.over()) {
            self.now += tick_ns;
            var wire = TableWire{ .sim = self };
            while (self.net.take(self.now, &buf)) |p| {
                if (p.to_table) {
                    _ = self.table.handle(&wire, p.frame, self.now);
                    self.checkTable(.after_handle);
                } else self.client.receive(self, p.frame);
            }
            self.client.turn(self);
            self.host.turn(self);
            self.checkTable(.after_handle);
            self.table.transmit(&wire, self.now);
            self.checkTable(.after_transmit);
        }
        try self.judge();
    }

    fn judge(self: *Sim) !void {
        if (self.broken == null and !self.quiescent())
            self.fault("the table still holds a connection at the horizon");
        if (self.broken == null and self.sc.vanish_at == null) {
            const c = &self.client;
            if (c.aborted) {
                self.fault("the connection was reset though the client stayed");
            } else if (c.received != self.sc.answer_len or !c.peer_fin) {
                self.fault("the client did not get the whole answer and our FIN");
            } else if (self.host.consumed != self.sc.request_len) {
                self.fault("the host did not read the whole request");
            } else if (self.table.given_up != 0) {
                self.fault("the table gave up on a client that stayed");
            } else if (c.done_at == null or c.done_at.? > completion_bound_ns) {
                self.fault("the exchange did not finish within the completion bound");
            }
        }
        const what = self.broken orelse return;
        const sc = self.sc;
        std.debug.print(
            \\seed {d} failed: {s}
            \\  scenario: request {d} B, answer {d} B, loss {d:.2} until {d} ms, duplicate {d:.2}, corrupt {d:.2},
            \\            delay {d} us + {d} us jitter, delayed ACK {d} ms, half-close {any}, host stalls {d} ms,
            \\            client stalls {d} ms, vanishes {?d} ms, host announces {any}
            \\
        , .{
            self.seed,                                                 what,
            sc.request_len,                                            sc.answer_len,
            sc.loss,                                                   @divTrunc(sc.lossy_until, ns_per_ms),
            sc.duplicate,                                              sc.corrupt,
            @divTrunc(sc.delay_ns, 1000),                              @divTrunc(sc.jitter_ns, 1000),
            @divTrunc(sc.delayed_ack_ns, ns_per_ms),                   sc.half_close,
            @divTrunc(sc.host_stall_ns, ns_per_ms),                    @divTrunc(sc.client_stall_ns, ns_per_ms),
            if (sc.vanish_at) |at| @divTrunc(at, ns_per_ms) else null, sc.host_announces,
        });
        // Two calls: one holds at most 32 arguments.
        std.debug.print(
            \\  at {d} ms: client {s} (aborted {any}, gone {any}), received {d}, peer FIN {any}, probes {d};
            \\            host read {d}, queued {d}, finished {any}, let go {any};
            \\            table given up {d}, retransmits {d}, probes {d}, window updates {d}, damaged {d};
            \\            network sent {d}, lost {d}, duplicated {d}, corrupted {d}, overflowed {d}
            \\
        , .{
            @divTrunc(self.now, ns_per_ms), @tagName(self.client.state),
            self.client.aborted,            self.client.gone,
            self.client.received,           self.client.peer_fin,
            self.client.probes,             self.host.consumed,
            self.host.queued,               self.host.finished,
            self.host.let_go,               self.table.given_up,
            self.table.retransmits,         self.table.probes,
            self.table.window_updates,      self.table.damaged,
            self.net.sent,                  self.net.lost,
            self.net.duplicated,            self.net.corrupted,
            self.net.overflowed,
        });
        return error.SimulationFailed;
    }
};

/// Runs one seed; an error, with the scenario printed, if any oracle fails.
pub fn runSeed(seed: u64) !void {
    const sim = try std.testing.allocator.create(Sim);
    defer std.testing.allocator.destroy(sim);
    sim.init(seed);
    try sim.run();
}

/// The seeds `zig build test` runs. A seed that once failed and was fixed
/// stays here, named, as a regression test.
const seeds = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ regressions;

/// Seeds that once failed, kept apart from the eight plain ones so that
/// `zig fmt` keeps one to a line, each under the comment that names it.
const regressions = [_]u64{
    // A half-closed client: the table re-marked a window as owed after the
    // peer's FIN, every turn it sent data (fixed in tcp.zig's emit).
    125,
    // Heavy reordering, when this client took segments in order only: every
    // round ended on the 5 s backed-off timer, and Karn's rule threw away the
    // round's only sample. The client now holds segments past a hole.
    1332,
};

test "the table against a simulated network and an RFC 9293 client, a handful of seeds" {
    for (seeds) |seed| try runSeed(seed);
}

// **THE LOST-FRAME IncompleteRead, HUNTED** (QUEUE.md item 96). The bug was
// seen once in nine FAT32 runs of the bulk story with one frame in seven lost:
// the client got 2,820 of 4,895 bytes and then end-of-stream. Here, where loss
// and time are ours, a few-KB answer the host closes after is run under every
// placement of a single lost frame to the client in the first 20 it sends,
// with ACKs delayed and frames reordered. The completion oracle in judge
// catches exactly the reported failure — a short answer, or a FIN/close with
// data still owed, or a give-up/reset on a client that stayed. A failing n
// is the repro; a clean sweep says the bug is not a single lost frame in this
// shape, and the box reads a wire capture under KVM (the bulk story carries
// the per-connection close counts it needs).
test "item 96: one lost frame to the client, swept over the first 20, always recovers" {
    for ([_]bool{ true, false }) |announces| {
        for ([_]usize{ 3000, 4895, 16000 }) |answer| {
            for (0..20) |n| {
                const sim = try std.testing.allocator.create(Sim);
                defer std.testing.allocator.destroy(sim);
                sim.initScenario(90_000 + n, Scenario.fixed(answer, @intCast(n), announces));
                sim.run() catch |e| {
                    std.debug.print("item 96: dropping frame #{d} to the client (answer {d} B, announces {any}) did not recover\n", .{ n, answer, announces });
                    return e;
                };
            }
        }
    }
}
