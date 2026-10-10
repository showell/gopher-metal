//! TCP (RFC 9293) for a server that holds many connections and answers one
//! request at a time; the others wait in the table, not at the door.
//!
//! **NOTHING HERE WAITS.** Arriving frames go to `handle`; what we have to
//! say goes into a connection's send queue with `queue`; and `transmit`,
//! called every turn of the loop, sends what the peer's window allows,
//! retransmits what timed out, and gives up on a peer that stopped answering.
//!
//! **THE SEND SIDE:**
//!
//! - **The window.** Nothing is sent past the peer's last-advertised window.
//!   A shut window is probed with one byte when the timer runs out.
//! - **The segment size.** Each side's SYN carries its MSS; a peer that sends
//!   none is sent 536-byte segments (RFC 9293 §3.7.1).
//! - **Retransmission.** Sent bytes stay in our custody until acknowledged.
//!   On a timeout everything from the oldest is sent again and the timeout
//!   doubles.
//! - **Giving up.** After `max_retries` timeouts with no progress the
//!   connection is reset: so a vanished peer is noticed, and one that stops
//!   reading (window shut, probes unanswered) is let go.
//! - **The FIN goes last**, after every queued byte. Once it is acknowledged
//!   we wait up to `fin_wait_ns` for the peer's. There is no TIME-WAIT: a FIN
//!   repeated after the close is answered with a reset.
//! - **A segment for no connection is answered with a reset**, so a peer
//!   never waits on a connection this side has forgotten.
//! - **A reopened window is said again until the peer sends.** The
//!   announcement is a bare ACK, which nothing acknowledges; if it is lost,
//!   the peer waits on its own persist timer, which backs off to minutes.
//!
//! **THE SMALL TCP**, allowed because this box sits behind Caddy on a private
//! network: no congestion control, no SACK, no window scaling, no delayed
//! ACK; segments are taken in order only. It does have fast retransmit.
//!
//! **PURE, SO IT IS TESTED ON THE HOST.** Frames go out through the caller's
//! `wire` (anything with `send([]const u8)`), the ISN comes from a function
//! the caller supplies, and the time is a number the caller passes.
//!
//! **WHAT WAITS IN THE TABLE, AND WHAT BOUNDS THE WAIT** (TCP_TESTING.md §2;
//! tcp_check.zig's `liveness` table is this list, checked). Each entry is a
//! **debt**: no debt without a clock, no clock without a debt, no clock
//! without a give-up. Deadlines are looked at only in `transmit`, so each
//! bound is "the deadline, plus the time to the next `transmit`", which the
//! host bounds (stream.zig).
//!
//! - **Bytes queued, not yet sent** (`tx` past `sent`). Sent by the next
//!   `transmit` as the window allows. Bounded by: while the window is shut,
//!   a probe at `rto_at` and a reset after `max_retries` fruitless timeouts.
//! - **Bytes and a FIN on the wire, unacknowledged** (`tx` up to `high`).
//!   Sent again at `rto_at` (measured, `min_rto_ns` to `max_rto_ns`,
//!   doubling), or at once on three duplicate ACKs. Bounded by: a reset after
//!   `max_retries` timeouts with nothing acknowledged: about 16 s from a
//!   200 ms clock, 35 s at most.
//! - **Our FIN, queued** (`fin == .queued`). Sent by the first `transmit`
//!   that finds every queued byte sent. Bounded by: the bytes ahead of it.
//! - **Our SYN-ACK, unanswered** (`syn_received`). Sent again at `rto_at`.
//!   Bounded by: `max_retries`, as above; and, when the table is full, by the
//!   next SYN, to which the oldest half-open older than `min_rto_ns` gives way.
//! - **The peer's FIN, after ours was acknowledged.** Bounded by:
//!   `fin_wait_until` (`fin_wait_ns`, 30 s), then a reset.
//! - **A reopened window the peer may not have seen** (`window_news`).
//!   `.said_once` is timed by the next `transmit`; `.repeating` is said again
//!   at `update_at`, doubling. Bounded by: the peer sending data or its FIN,
//!   the window shutting again, or `max_retries` repeats, after which the
//!   debt lapses.
//! - **Bytes received, not yet read** (`rx[start..end]`), in custody for the
//!   reader. Bounded by: the host (probe/gopher.zig serves a connection once
//!   its request is whole, and lets go of one silent for `idle_ns`). While
//!   the buffer is full the window is shut and the peer's persist timer waits.
//!
//! **NOT QUEUED AT ALL**, so nothing is left waiting: an ACK (every in-order
//! segment is acknowledged as it is taken), a segment ahead (dropped and
//! re-acknowledged; the peer's timer resends it), and a SYN that finds no
//! free slot and no stuck half-open to replace (dropped and counted; the
//! peer's SYN timer retries).

const proto = @import("proto.zig");
const props = @import("coverage");
const machine = @import("machine.zig");

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

pub const header_len: usize = 20;
pub const segment_at: usize = proto.eth_header_len + proto.ip_header_len;

pub const flag_fin: u8 = 0x01;
pub const flag_syn: u8 = 0x02;
pub const flag_rst: u8 = 0x04;
pub const flag_psh: u8 = 0x08;
pub const flag_ack: u8 = 0x10;

/// The MSS for a peer whose SYN names none (RFC 9293 §3.7.1).
pub const default_mss: u16 = 536;
/// Ours: an ethernet frame's worth, which the NIC's receive buffers hold.
pub const our_mss: u16 = 1460;
pub const mss_option = [4]u8{ 2, 4, our_mss >> 8, our_mss & 0xFF };

/// **THE RETRANSMISSION CLOCK IS MEASURED** (RFC 6298): one segment timed at
/// a time, RTO = SRTT + 4 * RTTVAR. The handshake is the first sample, so the
/// first byte of a response already goes out under a measured clock.
///
/// **THE FLOOR IS ABOUT THE PEER'S DELAYED ACKS, NOT THE PATH.** A peer may
/// hold an ACK for tens of milliseconds (Linux) or up to 200 (slirp). Waiting
/// less turns a delay into a "loss" and resends a whole window for nothing,
/// so the floor is Linux's `TCP_RTO_MIN`, not RFC 6298's one second (2.4).
/// It is also the first, unmeasured wait: over a private network to Caddy,
/// RFC 6298's second is a thousand round trips.
///
/// Each timeout doubles the wait up to `max_rto_ns` (RFC 6298 (5.5); the
/// RFC's ceiling is at least 60 s), and the connection is reset after
/// `max_retries` timeouts with nothing acknowledged: RFC 9293's R2 (§3.8.3),
/// counted in timeouts.
pub const min_rto_ns: u64 = 200 * ns_per_ms;
pub const first_rto_ns: u64 = min_rto_ns;
pub const max_rto_ns: u64 = 5 * ns_per_s;
pub const max_retries: u8 = 6;
/// Duplicate ACKs that mean a segment is lost (RFC 5681): the peer says at
/// once what the timer would only guess a round trip later.
pub const dupacks_before_resend: u8 = 3;
/// How long FIN-WAIT-2 waits for the peer's FIN. RFC 9293 sets no bound;
/// Linux's `tcp_fin_timeout` is the same idea.
pub const fin_wait_ns: u64 = 30 * ns_per_s;
pub const ns_per_ms = 1_000_000;
pub const ns_per_s = 1_000_000_000;

/// RFC 9293's states, fewer of them: the table as a whole is LISTEN, and the
/// closing states are told apart by `fin` and `peer_done` rather than by name.
pub const State = enum {
    /// CLOSED. The slot is free — unless the host still holds it (`claimed`).
    closed,
    /// SYN-RECEIVED: our SYN-ACK is out, its acknowledgement not yet in.
    syn_received,
    /// ESTABLISHED, and CLOSE-WAIT once `peer_done`.
    established,
    /// Our FIN is queued, sent or acknowledged: FIN-WAIT-1, FIN-WAIT-2
    /// (`fin` acknowledged), and CLOSING or LAST-ACK (`peer_done`). With
    /// both FINs acknowledged the slot is CLOSED at once: no TIME-WAIT.
    closing,
};

/// **WHERE OUR FIN IS**, as a machine (machine.zig): changed only by these
/// events, each cell a coverage site. `resending` is a FIN sent and then
/// rewound by a timeout or an early resend, owed again; it still holds a
/// sequence number, which `queued` (never sent) does not.
pub const Fin = enum { none, queued, sent, resending, acknowledged };
pub const FinEvent = enum {
    /// The host closes its half (`finish`).
    host_finished,
    /// Every queued byte is out, and the FIN goes after them.
    fin_emitted,
    /// The retransmission timer fires: go back to `una`, FIN included.
    timed_out,
    /// Duplicate ACKs resend early, the same go-back.
    resent_early,
    /// An ACK covers every byte and the FIN.
    fin_acknowledged,
};
pub const FinMachine = machine.Machine("tcp.Fin", Fin, FinEvent, .none, &.{
    .{ .from = .none, .on = .host_finished, .to = .queued },
    .{ .from = .queued, .on = .fin_emitted, .to = .sent },
    .{ .from = .resending, .on = .fin_emitted, .to = .sent },
    .{ .from = .sent, .on = .timed_out, .to = .resending },
    .{ .from = .sent, .on = .resent_early, .to = .resending },
    .{ .from = .sent, .on = .fin_acknowledged, .to = .acknowledged },
    // The first FIN's ACK, arriving after a go-back.
    .{ .from = .resending, .on = .fin_acknowledged, .to = .acknowledged },
});

pub const Conn = struct {
    state: State = .closed,
    // The remote half of the socket pair; the local half is the table's.
    peer_ip: [4]u8 = proto.ip_any,
    peer_mac: [6]u8 = proto.mac_broadcast,
    peer_port: u16 = 0,

    /// RCV.NXT. There is no IRS field; the SYN sets this to IRS + 1.
    rcv_nxt: u32 = 0,

    /// **RECEIVED AND NOT YET READ: `rx[start..end]`**, in custody for the
    /// reader: we acknowledged these bytes, so the peer will not resend them.
    /// RCV.WND is `window()`.
    rx: []u8,
    start: usize = 0,
    end: usize = 0,

    /// **QUEUED AND NOT YET ACKNOWLEDGED: `tx[tx_start..tx_end]`**, in our
    /// custody until the peer acknowledges them. `tx[tx_start]` is the byte
    /// numbered `una`; the first `sent` are on the wire.
    tx: []u8,
    tx_start: usize = 0,
    tx_end: usize = 0,
    /// Where the next segment starts, as a count past `una`. A timeout or a
    /// fast retransmit sets it back to 0. It is not SND.NXT: that never goes
    /// back, and is `highest()`.
    sent: usize = 0,
    /// The most bytes past `una` ever on the wire, so an ACK of bytes sent
    /// before `sent` was rewound still counts.
    high: usize = 0,
    /// SND.UNA. In SYN-RECEIVED it is ISS; there is no ISS field.
    una: u32 = 0,
    fin: FinMachine = .{},
    /// SND.WND, always measured from `una` (see `acknowledge`). At most
    /// 0xFFFF: no window scaling.
    wnd: u32 = 0,
    /// SND.WL1 and SND.WL2: the sequence and acknowledgement numbers of the
    /// segment that last set `wnd`, so an older segment cannot overrule it.
    wl1: u32 = 0,
    wl2: u32 = 0,
    /// SendMSS (RFC 9293 §3.7.1), never more than `our_mss`.
    mss: u16 = default_mss,
    /// The retransmission timer (RFC 6298 §5), also the persist timer and
    /// the SYN-ACK's. Null when nothing is owed to the peer.
    rto_at: ?i96 = null,
    /// RTO (RFC 6298 §2), doubled by each timeout.
    rto_ns: u64 = first_rto_ns,
    /// Timeouts since the peer last acknowledged anything: `rto_at`'s
    /// give-up, against `max_retries`.
    retries: u8 = 0,
    /// SRTT and RTTVAR (RFC 6298). Zero until the first sample.
    srtt_ns: u64 = 0,
    rttvar_ns: u64 = 0,
    /// The one segment being timed: when it went out, and the sequence
    /// number just past it. Null when nothing is timed, including after a
    /// retransmit (Karn's algorithm).
    timed_at: ?i96 = null,
    timed_seq: u32 = 0,
    /// Duplicate ACKs in a row (RFC 5681).
    dupacks: u8 = 0,
    /// This run of duplicates has been answered; cleared when `una` moves.
    resent_early: bool = false,
    /// FIN-WAIT-2's deadline for the peer's FIN.
    fin_wait_until: ?i96 = null,

    /// The peer's FIN has arrived (and is counted in `rcv_nxt`); what came
    /// before it may still be unread.
    peer_done: bool = false,

    /// The window in the last segment we sent: RCV.WND as the peer last saw it.
    told_wnd: u16 = 0xFFFF,
    /// **WHAT WE STILL OWE THE PEER ABOUT OUR WINDOW.** A segment that
    /// reopens a window the peer last saw too small makes it `.said_once`;
    /// the next `transmit` makes it `.repeating` and arms `update_at`. It
    /// ends when the peer sends data or its FIN, the window shuts again, or
    /// `max_retries` repeats pass. Not in RFC 9293, where a lost window
    /// update is recovered only by the peer's persist timer (§3.8.6.1).
    window_news: WindowNews = .none,
    /// When the reopened window is said again. Armed exactly while
    /// `window_news` is `.repeating`.
    update_at: ?i96 = null,
    /// Repeats so far: `update_at`'s give-up, against `max_retries`.
    updates: u8 = 0,

    // ── The host's marks on the slot, not TCP's. `reset()` keeps `claimed`;
    // the rest are set when a connection takes the slot.
    /// **HELD BY THE HOST.** A slot being served is never handed to a new
    /// connection, even after this one ends, or a reader part-way through a
    /// request could find a stranger's bytes in its buffer.
    claimed: bool = false,

    /// When the handshake started and when the peer was last heard from:
    /// the host serves oldest first and lets go of the quiet.
    opened_at: i96 = 0,
    heard_at: i96 = 0,
    /// Arrival order, breaking ties within a clock tick.
    serial: u64 = 0,

    pub fn pending(self: *const Conn) []u8 {
        return self.rx[self.start..self.end];
    }

    /// Releases `n` pending bytes. The buffer is compacted once `start`
    /// passes half of it, so the window reopens while a request is read.
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

    /// Free space at the end of the receive buffer: what arriving bytes go
    /// into and what the window advertises. Space freed at the front counts
    /// only once `consume` compacts.
    pub fn room(self: *const Conn) usize {
        return self.rx.len - self.end;
    }

    /// Queued bytes the peer has not acknowledged, sent or not.
    pub fn queued(self: *const Conn) usize {
        return self.tx_end - self.tx_start;
    }

    pub fn queueRoom(self: *const Conn) usize {
        return self.tx.len - self.queued();
    }

    pub fn open(self: *const Conn) bool {
        return self.state == .established or self.state == .syn_received;
    }

    /// **SND.NXT: just past the furthest thing we have ever sent** (BSD's
    /// `snd_max`). A segment carrying nothing, an ACK or a reset, is numbered
    /// here. `una + sent` is not it: after a rewind, a segment numbered there
    /// is from behind to the peer, and is dropped (a reset) or draws a
    /// duplicate ACK.
    pub fn highest(self: *const Conn) u32 {
        var n = self.una +% @as(u32, @intCast(self.high));
        if (self.state == .syn_received) n +%= 1;
        if (self.fin.is(.sent) or self.fin.is(.resending)) n +%= 1;
        return n;
    }

    /// Starts timing a segment unless one is already timed: one sample per
    /// round trip, as RFC 6298 allows without timestamps.
    fn time(self: *Conn, now: i96, past_it: u32) void {
        if (self.timed_at != null) return;
        self.timed_at = now;
        self.timed_seq = past_it;
    }

    /// **AHEAD**: past `rcv_nxt` but inside the window we advertise, so
    /// acceptable to RFC 9293's sequence test (§3.10.7.4) but not the next
    /// byte. A shut window has nothing ahead.
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

    /// RCV.WND: `room()`, as much as the 16-bit field carries.
    pub fn window(self: *const Conn) u16 {
        return @intCast(@min(self.room(), 0xFFFF));
    }

    /// Too small for the peer to send a full segment into, or half the
    /// buffer when the buffer is smaller than that.
    pub fn tight(self: *const Conn, w: u16) bool {
        return @as(usize, w) < @min(@as(usize, our_mss), self.rx.len / 2);
    }

    /// Nothing more is owed about our window: the peer has sent since, or
    /// there is no open window to announce.
    fn heard(self: *Conn) void {
        self.window_news = .none;
        self.update_at = null;
    }
};

/// The window debt as a state of its own, so each stage has a deadline the
/// checker can ask for.
pub const WindowNews = enum {
    none,
    /// A reopened window was just said, once; the next turn times its repeat.
    said_once,
    /// Said again at `update_at`, doubling.
    repeating,
};

pub const Result = struct {
    event: Event,
    /// Meaningless for `.nothing`.
    index: usize = 0,
};

/// What `handle` decided a frame meant.
/// What one segment did, the most of it: a segment that opens a connection
/// and carries the peer's FIN reports `.peer_done`, not `.opened`. A host
/// that must see every change reads the connection (`pending`, `peer_done`,
/// `state`), as probe/gopher.zig does.
pub const Event = enum {
    nothing,
    /// A handshake completed.
    opened,
    /// A connection's pending bytes grew.
    data,
    /// The peer's FIN arrived; what it sent before it may still be pending.
    peer_done,
    closed,
};

/// Given-way half-opens kept to be revived: 256 covers a 1024-SYN flood at
/// 1 ms apart with room to spare.
pub const revival_slots = 256;

/// What a given-way half-open's completing ACK needs of it.
pub const Revivable = struct {
    used: bool = false,
    ip: [4]u8 = @splat(0),
    mac: [6]u8 = @splat(0),
    port: u16 = 0,
    /// Our ISS: the ACK must name ISS + 1, the one acknowledgement
    /// `syn_received` would not have answered with a reset.
    iss: u32 = 0,
    rcv_nxt: u32 = 0,
    wl1: u32 = 0,
    mss: u16 = 0,
    wnd: u32 = 0,
    told_wnd: u16 = 0,
};

pub const Table = struct {
    local_ip: [4]u8,
    local_mac: [6]u8,
    port: u16,
    conns: []Conn,
    /// Scratch for one outgoing frame.
    out: []u8,
    /// The ISN source. It must be unpredictable: a guessable ISN lets an
    /// off-path attacker inject into a connection.
    isn: *const fn () u32,

    arrivals: u64 = 0,
    /// SYNs dropped because every slot was taken and none could give way, as
    /// Linux drops on a full accept queue. The peer retries.
    refused: u64 = 0,
    /// Half-opens that gave way to a new SYN (see `oldestHalfOpen`).
    half_open_given_way: u64 = 0,
    /// **THE RECENTLY GIVEN WAY, KEPT TO BE REVIVED**, newest over oldest. A
    /// real client whose handshake outlasted `min_rto_ns` (a lost SYN-ACK or
    /// ACK) can lose its slot to a flood's SYN; its ACK finds its entry here
    /// and the connection is rebuilt.
    revivable: [revival_slots]Revivable = @splat(.{}),
    /// How many of `revivable` are used: all in the kernel, fewer where a
    /// simulator measures a smaller ring.
    revival_cap: u16 = revival_slots,
    revival_next: u16 = 0,
    /// Half-opens revived, and matching ACKs that found no slot (dropped,
    /// not reset).
    revived: u64 = 0,
    revival_no_room: u64 = 0,
    /// Retransmissions, by timer or by duplicate ACKs.
    retransmits: u64 = 0,
    /// Those the duplicate ACKs asked for.
    fast_retransmits: u64 = 0,
    /// Window probes.
    probes: u64 = 0,
    /// Connections reset because the peer stopped acknowledging.
    given_up: u64 = 0,
    /// Connections reset because the peer's FIN never came.
    fin_waits_expired: u64 = 0,
    /// Segments for no connection, answered with a reset.
    strays: u64 = 0,
    /// Segments dropped for a bad checksum.
    damaged: u64 = 0,
    /// Reopened windows said again.
    window_updates: u64 = 0,
    /// Round trips measured, and the newest SRTT.
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

    /// **A FULL TABLE GIVES WAY TO A NEW SYN AT ITS OLDEST STUCK HALF-OPEN.**
    /// A half-open holds its slot through `max_retries` timeouts, 16 to 35 s,
    /// so spoofed SYNs, which never answer, could otherwise fill every slot
    /// and keep real clients out.
    ///
    /// **ONLY A STUCK ONE: older than `min_rto_ns`.** A real client completes
    /// its handshake in one round trip, far less; evicting it mid-handshake
    /// would make its ACK draw a reset (native/judge_native.py's burst). When
    /// every half-open is that fresh the SYN is refused: a real burst
    /// retries, a flood is thinned. The one given way gets no reset (to a
    /// spoofed address that is a reset to someone else) and goes into the
    /// revival ring. An established connection never gives way.
    fn oldestHalfOpen(self: *Table, now: i96) ?usize {
        var oldest: ?usize = null;
        for (self.conns, 0..) |c, i| {
            if (c.state != .syn_received or c.claimed) continue;
            if (now - c.opened_at < min_rto_ns) continue;
            if (oldest == null or c.opened_at < self.conns[oldest.?].opened_at) oldest = i;
        }
        const i = oldest orelse return null;
        self.keepRevivable(&self.conns[i]);
        self.conns[i].state = .closed;
        self.half_open_given_way += 1;
        props.reachable(@src(), "tcp: a stuck half-open connection gives way to a new SYN", .{ .conn = i });
        return i;
    }

    /// Sends one segment on connection `i`, numbered `seq`, and keeps the
    /// window debt: a window that reopens one the peer last saw too small
    /// starts it; a tight window or a finished peer ends it.
    fn emit(self: *Table, wire: anytype, i: usize, flags: u8, seq: u32, payload: []const u8) void {
        const c = &self.conns[i];
        const w = c.window();
        if (c.tight(w) or c.peer_done) {
            // A peer that has sent its FIN is owed no window.
            c.heard();
        } else if (c.tight(c.told_wnd)) {
            c.window_news = .said_once;
            c.update_at = null;
            c.updates = 0;
        }
        c.told_wnd = w;
        self.segment(wire, .{
            .mac = c.peer_mac,
            .ip = c.peer_ip,
            .port = c.peer_port,
        }, flags, seq, c.rcv_nxt, w, payload);
    }

    /// Keeps the half-open `c`, about to give way, in the ring, over the
    /// oldest entry.
    fn keepRevivable(self: *Table, c: *const Conn) void {
        const cap = @min(self.revival_cap, revival_slots);
        if (cap == 0) return;
        const at = self.revival_next % cap;
        self.revivable[at] = .{
            .used = true,
            .ip = c.peer_ip,
            .mac = c.peer_mac,
            .port = c.peer_port,
            .iss = c.una,
            .rcv_nxt = c.rcv_nxt,
            .wl1 = c.wl1,
            .mss = c.mss,
            .wnd = c.wnd,
            .told_wnd = c.told_wnd,
        };
        self.revival_next = (at + 1) % cap;
    }

    /// The given-way half-open that would not have reset this segment: same
    /// address and port, its ACK naming ISS + 1. Whatever its sequence
    /// number, the revived `syn_received` treats it as the original would.
    /// A blind sender must still guess the 32-bit ISS. The caller asks only
    /// for an ACK without SYN; resets are handled before.
    fn revivableFor(self: *Table, ip: [4]u8, port: u16, number: u32) ?*Revivable {
        for (&self.revivable) |*e| {
            if (!e.used or e.port != port or !eql(&e.ip, &ip)) continue;
            if (number != e.iss +% 1) continue;
            return e;
        }
        return null;
    }

    /// Rebuilds `e` as `syn_received` in a free slot, else in a stuck
    /// half-open's (almost certainly a flood's: an ACK proves its sender is
    /// real, a half-open proves nothing). Null with neither.
    fn revive(self: *Table, e: Revivable, now: i96) ?usize {
        const slot = self.free() orelse self.oldestHalfOpen(now) orelse return null;
        const c = &self.conns[slot];
        c.reset();
        c.peer_ip = e.ip;
        c.peer_mac = e.mac;
        c.peer_port = e.port;
        c.rcv_nxt = e.rcv_nxt;
        c.wl1 = e.wl1;
        c.una = e.iss;
        c.mss = e.mss;
        c.wnd = e.wnd;
        c.told_wnd = e.told_wnd;
        c.state = .syn_received;
        c.opened_at = now;
        c.heard_at = now;
        c.rto_at = now + c.rto_ns;
        self.arrivals += 1;
        c.serial = self.arrivals;
        self.noteSlots();
        return slot;
    }

    const Peer = struct { mac: [6]u8, ip: [4]u8, port: u16 };

    /// Builds and sends one segment to `to`. A SYN carries our MSS.
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

    /// **A SEGMENT FOR NO CONNECTION** is answered with a reset (RFC 9293
    /// §3.10.7.1): numbered by its ACK if it has one, else acknowledging
    /// everything it carried.
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

    /// Queues as much of `bytes` as fits and returns how much; `transmit`
    /// sends it. Takes nothing unless established with no FIN queued.
    pub fn queue(self: *Table, i: usize, bytes: []const u8) usize {
        const c = &self.conns[i];
        if (c.state != .established or !c.fin.is(.none)) return 0;
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

    /// Tells the peer the window now. The reader calls it after consuming,
    /// so a peer that filled the window need not wait for its own probe.
    pub fn ack(self: *Table, wire: anytype, i: usize) void {
        const c = &self.conns[i];
        if (c.state != .established and c.state != .closing) return;
        self.emit(wire, i, flag_ack, c.highest(), "");
    }

    /// Queues our FIN behind the last queued byte. The connection closes once
    /// the FIN is acknowledged and the peer's has arrived, after
    /// `fin_wait_ns` without the peer's, or when the host abandons it.
    pub fn finish(self: *Table, i: usize) void {
        const c = &self.conns[i];
        if (c.state != .established) return;
        c.fin.fire(.host_finished);
        c.state = .closing;
    }

    /// Gives up on connection `i` with a reset, so a peer waiting for the
    /// rest of an answer, or for its handshake, does not wait out its timer.
    pub fn abandon(self: *Table, wire: anytype, i: usize) void {
        const c = &self.conns[i];
        if (c.state != .closed) {
            self.emit(wire, i, flag_rst | flag_ack, c.highest(), "");
        }
        c.reset();
    }

    /// **HOW FULL THE TABLE CAME**, each time a slot is taken: slots in use
    /// and half-opens against the table's size, as zig-coverage-sdk
    /// comparisons. Properties only; they show how far a run's table came
    /// toward the kernel's 256 slots.
    fn noteSlots(self: *const Table) void {
        var in_use: usize = 0;
        var half_open: usize = 0;
        for (self.conns) |c| {
            if (c.state != .closed or c.claimed) in_use += 1;
            if (c.state == .syn_received) half_open += 1;
        }
        props.alwaysLessThanOrEqualTo(@src(), in_use, self.conns.len, "tcp: slots in use stay within the table", null);
        props.alwaysLessThanOrEqualTo(@src(), half_open, self.conns.len, "tcp: half-open connections stay within the table", null);
    }

    /// The host is serving connection `i`: its slot is not to be reused.
    pub fn claim(self: *Table, i: usize) void {
        self.conns[i].claimed = true;
    }

    /// The host is done with connection `i`; its slot is free once closed.
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
        self.announce(wire, i, now);
        const c = &self.conns[i];
        const expired = if (c.rto_at) |at| now >= at else false;

        if (c.fin.is(.acknowledged)) {
            // FIN-WAIT-2: nothing of ours in flight.
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
            props.reachable(@src(), "tcp: a lost SYN-ACK is sent again", .{ .conn = i });
            c.timed_at = null; // Karn: no telling which copy the ACK answers
            self.emit(wire, i, flag_syn | flag_ack, c.una, "");
            return;
        }

        var probe = false;
        if (expired) {
            if (!backoff(c, now)) return self.giveUp(wire, i);
            // **GO BACK.** Everything from `una` is sent again; the peer
            // drops what it has. RFC 6298 (5.4) asks only for the oldest
            // segment.
            c.sent = 0;
            if (c.fin.is(.sent)) c.fin.fire(.timed_out);
            c.timed_at = null; // Karn: no telling which copy is answered
            self.retransmits += 1;
            props.reachable(@src(), "tcp: the timer goes back to the oldest unacknowledged byte", .{ .conn = i, .retries = c.retries });
            probe = true;
        }

        while (c.queued() > c.sent) {
            const usable = if (c.wnd > c.sent) c.wnd - c.sent else 0;
            var n = @min(c.queued() - c.sent, usable, c.mss);
            if (n == 0) {
                // **A SHUT WINDOW IS PROBED WHEN THE TIMER RUNS OUT** (RFC
                // 9293 §3.8.6.1), with one byte; the answer carries the window.
                if (!probe) {
                    if (c.rto_at == null) c.rto_at = now + c.rto_ns;
                    break;
                }
                self.probes += 1;
                props.reachable(@src(), "tcp: a shut window is probed", .{ .conn = i });
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

        if ((c.fin.is(.queued) or c.fin.is(.resending)) and c.sent == c.queued()) {
            self.emit(wire, i, flag_fin | flag_ack, c.una +% @as(u32, @intCast(c.sent)), "");
            c.fin.fire(.fin_emitted);
            if (c.rto_at == null) c.rto_at = now + c.rto_ns;
        }
        // No debt without a clock: whatever the peer has not acknowledged
        // is timed.
        props.always(@src(), c.highest() == c.una or c.rto_at != null, "tcp: what is outstanding has its retransmission timer", .{ .conn = i });
    }

    /// **THE RECEIVE SIDE'S ONE TIMER.** A window the peer last saw too small,
    /// with room again, is announced (here, if the reader's `ack` did not),
    /// then repeated from `rto_ns`, doubling, until the peer sends data or
    /// its FIN, or `max_retries` repeats pass.
    fn announce(self: *Table, wire: anytype, i: usize, now: i96) void {
        const c = &self.conns[i];
        if (c.state != .established and c.state != .closing) return;
        if (c.peer_done) return c.heard();
        if (c.tight(c.told_wnd) and !c.tight(c.window())) {
            self.emit(wire, i, flag_ack, c.highest(), "");
        }
        switch (c.window_news) {
            .none => return,
            .said_once => {
                c.window_news = .repeating;
                c.update_at = now + c.rto_ns;
                return;
            },
            .repeating => {},
        }
        props.always(@src(), c.update_at != null, "tcp: a reopened window said again has its clock", .{ .conn = i });
        const at = c.update_at orelse return;
        if (now < at) return;
        if (c.updates >= max_retries) {
            // The peer has nothing more to send: the debt lapses.
            c.heard();
            return;
        }
        c.updates += 1;
        self.window_updates += 1;
        props.reachable(@src(), "tcp: a reopened window is announced again", .{ .conn = i, .updates = c.updates });
        const wait = @min(c.rto_ns * (@as(u64, 1) << @intCast(c.updates)), max_rto_ns);
        // Set before the emit, which clears it if the window has shut again.
        c.update_at = now + wait;
        self.emit(wire, i, flag_ack, c.highest(), "");
    }

    /// RFC 5681's fast retransmit: everything from `una` again, now, without
    /// touching the backoff, since a hole is not evidence of a slower path.
    /// Goes back like a timeout; with no congestion control there is no fast
    /// recovery.
    fn resend(self: *Table, wire: anytype, i: usize, now: i96) void {
        const c = &self.conns[i];
        c.dupacks = 0;
        c.resent_early = true;
        c.sent = 0;
        if (c.fin.is(.sent)) c.fin.fire(.resent_early);
        c.timed_at = null; // Karn, the same as after a timeout
        c.rto_at = now + c.rto_ns;
        self.retransmits += 1;
        self.fast_retransmits += 1;
        props.reachable(@src(), "tcp: three duplicate ACKs resend at once", .{ .conn = i });
        self.transmitOne(wire, i, now);
    }

    /// Takes the sample if this ACK covers the timed segment, folded in as
    /// RFC 6298 §2 says (alpha 1/8, beta 1/4).
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
        props.always(@src(), c.rto_ns >= min_rto_ns and c.rto_ns <= max_rto_ns, "tcp: a measured RTO is within its bounds", .{ .rto_ns = c.rto_ns });
        props.sometimes(@src(), c.srtt_ns > rtt, "tcp: a round trip comes in faster than the estimate", null);
        self.samples += 1;
        self.measured_ns = c.srtt_ns;
    }

    /// One more timeout (RFC 6298 (5.5), (5.6)): false once they have run out.
    fn backoff(c: *Conn, now: i96) bool {
        if (c.retries >= max_retries) return false;
        c.retries += 1;
        c.rto_ns = @min(c.rto_ns * 2, max_rto_ns);
        props.always(@src(), c.rto_ns <= max_rto_ns, "tcp: a backed-off RTO stays under the cap", .{ .rto_ns = c.rto_ns });
        props.sometimes(@src(), c.rto_ns == max_rto_ns, "tcp: backoff reaches the RTO cap", null);
        props.alwaysLessThanOrEqualTo(@src(), c.retries, max_retries, "tcp: a connection's timeouts stay within its retries", null);
        c.rto_at = now + c.rto_ns;
        return true;
    }

    fn giveUp(self: *Table, wire: anytype, i: usize) void {
        self.given_up += 1;
        props.reachable(@src(), "tcp: a silent peer is given up on", .{ .conn = i });
        self.abandon(wire, i);
    }

    /// Takes the peer's ACK and window as RFC 9293 §3.10.7.4 does in
    /// ESTABLISHED: SND.UNA < SEG.ACK =< SND.NXT moves `una`, and SND.WL1/WL2
    /// decide whether `wnd` moves. True if this ACK covers our FIN.
    fn acknowledge(self: *Table, c: *Conn, seq: u32, number: u32, window: u16, now: i96) bool {
        const flight = c.highest() -% c.una;
        const advance = number -% c.una;
        // An ACK of something never sent, or an old one (wrapping to a huge
        // advance), is ignored, window included. The RFC also drops and
        // answers a segment that acknowledges what was never sent; here only
        // its ACK is ignored.
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
        // **THE WINDOW IS MEASURED FROM `una`.** When the window rule skipped
        // this segment's window, `wnd` shrinks by the advance, so the right
        // edge stays where the peer put it. (RFC 9293's SND.UNA + SND.WND
        // would let it move forward.)
        if (!updated) c.wnd -= @min(c.wnd, advance);
        if (advance > bytes) {
            // Past every byte, an ACK can cover only our FIN, which takes one.
            props.always(@src(), (c.fin.is(.sent) or c.fin.is(.resending)) and advance == @as(u32, @intCast(bytes)) + 1, "tcp: an ACK past every byte covers our FIN and nothing more", .{ .advance = advance, .bytes = bytes });
            c.fin.fire(.fin_acknowledged);
            c.high = 0;
            c.sent = 0;
        }

        c.retries = 0;
        self.measure(c, number, now);
        if (c.srtt_ns == 0) c.rto_ns = first_rto_ns;
        c.rto_at = if (c.highest() != c.una) now + c.rto_ns else null;
        props.always(@src(), c.sent <= c.high and c.high <= c.queued(), "tcp: after an ACK, what was sent lies within what is queued", .{ .sent = c.sent, .high = c.high, .queued = c.queued() });
        return c.fin.is(.acknowledged);
    }

    /// Feeds one received frame in. `now` is the caller's clock.
    pub fn handle(self: *Table, wire: anytype, frame: []const u8, now: i96) Result {
        const pkt = proto.parseIpv4(frame) orelse return .{ .event = .nothing };
        if (pkt.protocol != proto.proto_tcp) return .{ .event = .nothing };
        if (!eql(&pkt.dst_ip, &self.local_ip)) return .{ .event = .nothing };
        if (pkt.payload.len < header_len) return .{ .event = .nothing };

        const t = pkt.payload;
        if (proto.readBe16(t[2..4]) != self.port) return .{ .event = .nothing };
        if (proto.pseudoChecksum(pkt.src_ip, pkt.dst_ip, proto.proto_tcp, t) != 0) {
            self.damaged += 1;
            props.reachable(@src(), "tcp: a damaged segment is dropped", null);
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

        var found = self.find(pkt.src_ip, src_port);

        if (flags & flag_rst != 0) {
            // **A RESET MUST NAME RCV.NXT EXACTLY** (RFC 9293 §3.10.7.4,
            // after RFC 5961). One ahead draws a challenge ACK, which a
            // genuine peer answers with an exact reset; others are ignored.
            const i = found orelse return .{ .event = .nothing };
            const c = &self.conns[i];
            props.sometimes(@src(), seq == c.rcv_nxt, "tcp: an exact reset closes a connection", null);
            props.sometimes(@src(), seq != c.rcv_nxt and c.ahead(seq), "tcp: an inexact reset in the window draws a challenge ACK", null);
            if (seq == c.rcv_nxt) return self.close(i);
            if (c.ahead(seq)) self.emit(wire, i, flag_ack, c.highest(), "");
            return .{ .event = .nothing };
        }

        // **REVIVED BY ITS CLIENT'S ACK**: an ACK for no connection that a
        // given-way half-open would have taken rebuilds it, and the segment
        // is handled as usual. With no room it is dropped without a reset,
        // so the client sends again and may find room then.
        if (found == null and flags & flag_ack != 0 and flags & flag_syn == 0) {
            if (self.revivableFor(pkt.src_ip, src_port, number)) |e| {
                // The entry leaves the ring first: a revival into a stuck
                // half-open's slot puts that one in the ring, maybe here.
                // With no room nothing gave way, and the entry goes back.
                const kept = e.*;
                e.used = false;
                found = self.revive(kept, now) orelse {
                    e.* = kept;
                    self.revival_no_room += 1;
                    props.reachable(@src(), "tcp: a revival finds no slot, and the ACK is dropped", null);
                    return .{ .event = .nothing };
                };
                self.revived += 1;
                props.reachable(@src(), "tcp: a given-way half-open is revived by its client's ACK", .{ .conn = found.? });
            }
        }

        // The table is LISTEN (RFC 9293 §3.10.7.2): a SYN for no connection
        // opens one if there is a slot; anything else is refused.
        const i = found orelse {
            if (flags & flag_syn == 0 or flags & flag_ack != 0) {
                props.reachable(@src(), "tcp: a segment for no connection is refused", null);
                self.refuse(wire, .{ .mac = pkt.src_mac, .ip = pkt.src_ip, .port = src_port }, seq, number, flags, data.len);
                return .{ .event = .nothing };
            }
            const slot = self.free() orelse self.oldestHalfOpen(now) orelse {
                self.refused += 1;
                props.reachable(@src(), "tcp: a SYN finds the table full, and nothing to give way", null);
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
            self.noteSlots();
            self.emit(wire, slot, flag_syn | flag_ack, c.una, "");
            // The handshake is the first RTT sample.
            c.time(now, c.una +% 1);
            return .{ .event = .nothing };
        };

        const c = &self.conns[i];

        // A repeated SYN in SYN-RECEIVED means our SYN-ACK was lost or is
        // late: it is sent again, from ISS, as Linux does (the RFC's
        // sequence test would send a bare ACK). In any later state it draws
        // a challenge ACK (RFC 9293, after RFC 5961 §4).
        if (flags & flag_syn != 0) {
            if (c.state == .syn_received) {
                c.timed_at = null; // Karn, as when the timer sends it again
                self.emit(wire, i, flag_syn | flag_ack, c.una, "");
            } else self.emit(wire, i, flag_ack, c.highest(), "");
            return .{ .event = .nothing };
        }

        // No ACK bit: dropped (RFC 9293 §3.10.7.4, fifth check).
        if (flags & flag_ack == 0) return .{ .event = .nothing };

        // **A SEGMENT THAT IS NOT THE NEXT ONE IS ANSWERED, NOT TAKEN.**
        //
        // - **the next** (`seq == rcv_nxt`): acceptable, and taken;
        // - **ahead** (`c.ahead(seq)`): acceptable, so its ACK and window
        //   count, but its data and FIN are dropped and re-acknowledged;
        // - **from behind** (a repeated FIN, a keepalive) or beyond the
        //   window: not acceptable, and answered with an ACK.
        //
        // A segment that starts behind and runs past `rcv_nxt` is from behind
        // here; the RFC would trim it and take the new part, which the peer
        // instead resends.
        //
        // From behind, its ACK still counts if it moves `una`, where the RFC
        // drops the segment whole: ACKs are cumulative, and a peer repeating
        // its FIN after ours was acknowledged would otherwise wait on a timer
        // for nothing. (WL1/WL2 keep it from setting the window.)
        const early = c.ahead(seq);
        props.sometimes(@src(), early, "tcp: a segment arrives ahead of the next expected byte", null);
        if (seq != c.rcv_nxt and !early) {
            props.reachable(@src(), "tcp: a segment from behind is answered, not taken", .{ .conn = i });
            // **ONLY FROM BEHIND, NOT BEYOND.** The peer cannot yet have
            // sent a segment past our window; taking its ACK would let a
            // forged one set SND.WL1 to a sequence the peer never reaches,
            // after which the window rule rejects every genuine update.
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
                // An unacceptable ACK draws <SEQ=SEG.ACK><CTL=RST> (RFC 9293
                // §3.10.7.4, SYN-RECEIVED).
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
            // The ACK may carry the first data: fall through.
        } else {
            const was = c.una;
            const held = c.wnd;
            fin_acknowledged = self.acknowledge(c, seq, number, window, now);
            // **A DUPLICATE ACK** (RFC 5681 §2): no data, SYN or FIN; names
            // SND.UNA exactly; leaves the window unchanged; and something of
            // ours is outstanding. It says the peer received what came after
            // a hole; the third resends at once.
            //
            // **NOT WHILE THE WINDOW IS SHUT, AND ONCE PER LOSS.** A peer
            // with no room answers every probe with the same ACK, which is no
            // news of a loss; and a peer repeating itself forever must not
            // hold the connection open by pushing the timer out, so there is
            // no second resend until `una` moves.
            const bare = data.len == 0 and flags & flag_fin == 0 and flags & flag_syn == 0;
            if (c.una != was) {
                c.dupacks = 0;
                c.resent_early = false;
            } else if (bare and number == c.una and c.wnd == held and c.wnd != 0 and c.highest() != c.una) {
                // Counted to the resend and no further: a peer repeating
                // itself forever must not overflow the count.
                if (c.dupacks < dupacks_before_resend) c.dupacks += 1;
                props.alwaysLessThanOrEqualTo(@src(), c.dupacks, dupacks_before_resend, "tcp: duplicate ACKs are counted to the resend and no further", null);
                if (c.dupacks == dupacks_before_resend and !c.resent_early) self.resend(wire, i, now);
            }
        }

        if (early) {
            // Ahead: re-acknowledge, asking for the next byte.
            if (data.len > 0 or flags & flag_fin != 0) self.emit(wire, i, flag_ack, c.highest(), "");
            return self.settle(i, event, fin_acknowledged, now);
        }

        if (data.len > 0) {
            if (c.peer_done) {
                self.emit(wire, i, flag_ack, c.highest(), "");
                return self.settle(i, event, fin_acknowledged, now);
            }
            // **WHAT FITS IS TAKEN, AND ONLY THAT IS ACKNOWLEDGED.** The peer
            // resends the rest once the reader makes room; a FIN behind the
            // untaken part waits for it.
            const n = @min(c.room(), data.len);
            props.sometimes(@src(), n < data.len, "tcp: a peer sends past the window and only what fits is taken", .{ .room = c.room(), .len = data.len });
            @memcpy(c.rx[c.end..][0..n], data[0..n]);
            c.end += n;
            c.rcv_nxt +%= @intCast(n);
            if (n > 0) c.heard();
            self.emit(wire, i, flag_ack, c.highest(), "");
            if (n > 0 and event == .nothing) event = .data;
            if (n < data.len) return self.settle(i, event, fin_acknowledged, now);
        }

        if (flags & flag_fin != 0 and !c.peer_done and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt) {
            c.rcv_nxt +%= 1; // their FIN takes one
            c.peer_done = true;
            self.emit(wire, i, flag_ack, c.highest(), "");
            if (c.fin.is(.acknowledged)) return self.close(i);
            return .{ .event = .peer_done, .index = i };
        }

        return self.settle(i, event, fin_acknowledged, now);
    }

    /// Reports `event`, unless our FIN was just acknowledged: then the
    /// connection closes if the peer has finished too, and otherwise starts
    /// FIN-WAIT-2's clock.
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

/// The MSS a SYN's options carry, if any.
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

/// Sequence number `a` comes after `b`, modulo 2^32.
fn after(a: u32, b: u32) bool {
    const d = a -% b;
    return d != 0 and d < 0x8000_0000;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
