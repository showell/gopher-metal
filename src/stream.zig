//! A TCP connection as a `std.Io.Reader` and a `std.Io.Writer`.
//!
//! **THIS IS THE WHOLE POINT OF THE PROJECT, IN ABOUT A HUNDRED LINES.**
//! `angry-gopher/zig-server` builds its HTTP server like this:
//!
//!     var server = std.http.Server.init(&sr.interface, &sw.interface);
//!
//! — a reader and a writer, and nothing else. So if a TCP connection on a
//! machine with no operating system can present those two interfaces, zig's
//! entire HTTP/1.1 implementation runs on it unmodified. Not ported, not
//! vendored, not adapted: the same code, from the same standard library.
//!
//! Each interface needs exactly one function. A reader needs `stream`, which
//! hands bytes onward; a writer needs `drain`, which sends them. Everything
//! else in both vtables has a default.
//!
//! **A READ HERE RUNS THE EVENT LOOP.** On a machine with one core and no
//! preemption there is nobody else to move the connection forward, so a read
//! that has no bytes yet polls the NIC, answers ARP, feeds TCP, and tries
//! again. That is what "blocking" means when there are no threads to block.

const std = @import("std");
const io = @import("io.zig");
const net = @import("net.zig");
const tcp = @import("tcp.zig");
const arp = @import("arp.zig");
const proto = @import("proto.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// **EVERY WAIT ON THIS MACHINE IS A MEASURED DURATION.** These were spin
/// counts once — some unknown number of seconds that changed with the CPU.
///
/// **HOW LONG A CONNECTION MAY MAKE NO PROGRESS**, in either direction: a
/// read that gets no bytes, a write whose peer takes none, a close whose FIN
/// is not acknowledged. A client that connects and then says nothing is the
/// case that matters most, and ten seconds is long for a peer that has already
/// completed a TCP handshake and is behind Caddy on the same machine.
pub const default_idle_ns: u64 = 10 * std.time.ns_per_s;

/// **THE NIC, AS THE TABLE SEES IT, WITH A WAY TO LOSE FRAMES ON PURPOSE.**
/// Retransmission is invisible on an emulated network that never drops
/// anything, so it cannot be judged there. With `lose_one_sent_in` set, every
/// Nth TCP frame this machine sends is thrown away instead of delivered, and
/// the count says how many — the same path a lossy link would take, chosen by
/// the host's configuration rather than by luck. Zero loses nothing.
///
/// **ONLY WHAT WE SEND.** Losing what arrives would judge the peer's recovery,
/// and our in-order-only receiving, rather than our retransmission.
pub const Wire = struct {
    nic: *net.Net,
    lose_one_sent_in: u32 = 0,
    tcp_sent: u64 = 0,
    lost: u64 = 0,

    pub fn send(self: *Wire, frame: []const u8) void {
        if (self.lose_one_sent_in != 0 and isTcp(frame)) {
            self.tcp_sent += 1;
            if (self.tcp_sent % self.lose_one_sent_in == 0) {
                self.lost += 1;
                return;
            }
        }
        self.nic.send(frame);
    }

    fn isTcp(frame: []const u8) bool {
        const pkt = proto.parseIpv4(frame) orelse return false;
        return pkt.protocol == proto.proto_tcp;
    }
};

/// One turn of the loop for every connection at once: take every frame that
/// has arrived, answer ARP, let the table see the rest, and then let the table
/// send what it has to. Null when no frame had arrived. The host calls this
/// while nothing is ready to serve; a Stream calls it while it waits, so the
/// other connections keep moving either way.
///
/// **EVERY WAITING FRAME BEFORE ANY TIMER.** A loop that has been busy for a
/// while finds acknowledgements queued in the NIC's ring; looking at the
/// timers first would call those segments lost and send them again. A
/// needless second SYN-ACK once left slirp sending nothing more on that
/// connection for as long as the host would wait.
/// **THE HOST'S OWN STATE MACHINES TURN HERE TOO**, after what arrived and
/// before what is sent: a host that keeps live streams sets this, and they move
/// on every turn — including the turns taken inside a request's reads and
/// writes — rather than only between requests.
pub var after_arrivals: ?*const fn () void = null;

pub fn pump(wire: *Wire, table: *tcp.Table, ip: [4]u8) ?tcp.Result {
    const now = io.awakeNs() orelse 0;
    const nic = wire.nic;
    var last: ?tcp.Result = null;
    var taken: usize = 0;
    while (taken < net.rx_buffers) : (taken += 1) {
        const got = nic.poll() orelse break;
        defer nic.recycle(got.id);
        last = .{ .event = .nothing };
        if (arp.parseRequest(got.frame)) |req| {
            if (eql(&req.target_ip, &ip)) {
                var out: [64]u8 = undefined;
                const n = arp.writeReply(&out, nic.mac, ip, req);
                nic.send(out[0..n]);
            }
            continue;
        }
        const r = table.handle(wire, got.frame, now);
        if (r.event != .nothing) last = r;
    }
    if (after_arrivals) |turn| turn();
    table.transmit(wire, now);
    return last;
}

/// One connection of the table, as a reader and a writer.
pub const Stream = struct {
    wire: *Wire,
    table: *tcp.Table,
    index: usize,
    /// Our own address, for answering ARP while a read is waiting.
    ip: [4]u8,

    /// How long a read, a write or a close may go without progress.
    idle_ns: u64 = default_idle_ns,

    /// **WHY THE LAST READ OR WRITE FAILED.** `std.Io.Reader` says the detail
    /// behind `ReadFailed` belongs to the implementation, and this is it: the
    /// host logs "the client stopped sending" rather than an error name that
    /// could equally mean the NIC fell over.
    timed_out: bool = false,

    reader_iface: Reader,
    writer_iface: Writer,

    pub fn init(wire: *Wire, table: *tcp.Table, index: usize, ip: [4]u8, read_buf: []u8, write_buf: []u8) Stream {
        return .{
            .wire = wire,
            .table = table,
            .index = index,
            .ip = ip,
            .reader_iface = .{
                .vtable = &.{ .stream = streamFn },
                .buffer = read_buf,
                .seek = 0,
                .end = 0,
            },
            .writer_iface = .{
                .vtable = &.{ .drain = drainFn },
                .buffer = write_buf,
                .end = 0,
            },
        };
    }

    pub fn reader(self: *Stream) *Reader {
        return &self.reader_iface;
    }

    pub fn writer(self: *Stream) *Writer {
        return &self.writer_iface;
    }

    fn conn(self: *Stream) *tcp.Conn {
        return &self.table.conns[self.index];
    }

    pub fn pumpOnce(self: *Stream) void {
        _ = pump(self.wire, self.table, self.ip);
    }

    /// Bytes the peer has sent that we have not handed out, waiting for some
    /// to arrive if there are none. Null once nothing more is coming — either
    /// because the peer closed, or because it stopped talking for `idle_ns`,
    /// which `timed_out` tells apart.
    fn waitForBytes(self: *Stream) ?[]u8 {
        self.timed_out = false;
        const started = self.clock();
        while (true) {
            const c = self.conn();
            if (c.pending().len > 0) return c.pending();
            // Closed, or the peer has said it is done: nothing more is coming.
            if (!c.open() or c.peer_done) return null;
            if (self.clock() - started >= self.idle_ns) {
                self.timed_out = true;
                return null;
            }
            self.pumpOnce();
            asm volatile ("pause");
        }
    }

    /// **A STREAM NEEDS A CLOCK, AND SAYS SO.** Every wait here is a duration,
    /// so a kernel that streams must have measured its timestamp counter
    /// first — `pit.calibrate()` and `io.startClock()`, or `wallclock.start()`
    /// which does both. Without it there is no way to bound a wait except by
    /// counting spins, which is what this replaced.
    fn clock(self: *Stream) i96 {
        _ = self;
        return io.awakeNs() orelse
            @panic("a connection was read before the clock was started: this machine cannot bound a wait it cannot measure");
    }

    /// **HANDS BYTES TO THE CONNECTION'S SEND QUEUE, WAITING FOR ROOM.** The
    /// table puts them on the wire as the peer's window allows. A queue that
    /// stays full is a peer taking nothing; after `idle_ns` of that the write
    /// fails, and the table's own retransmission count ends a peer that has
    /// gone altogether.
    fn sendAll(self: *Stream, bytes: []const u8) error{WriteFailed}!void {
        self.timed_out = false;
        var at: usize = 0;
        var since = self.clock();
        var una = self.conn().una;
        while (at < bytes.len) {
            const c = self.conn();
            if (c.state != .established) return error.WriteFailed;
            const n = self.table.queue(self.index, bytes[at..]);
            at += n;
            if (n > 0 or c.una != una) {
                since = self.clock();
                una = c.una;
            }
            if (at == bytes.len) break;
            if (self.clock() - since >= self.idle_ns) {
                self.timed_out = true;
                return error.WriteFailed;
            }
            self.pumpOnce();
            asm volatile ("pause");
        }
    }

    /// Says we are done sending, and waits for everything queued to be
    /// delivered and our FIN acknowledged — for as long as the peer keeps
    /// acknowledging something. `std.http.Server` writes `connection: close`
    /// for us; this is the TCP half of the same statement.
    pub fn finish(self: *Stream) void {
        self.table.finish(self.index);
        var since = self.clock();
        var una = self.conn().una;
        while (self.conn().state != .closed) {
            const c = self.conn();
            if (c.una != una) {
                since = self.clock();
                una = c.una;
            }
            if (self.clock() - since >= self.idle_ns) return;
            self.pumpOnce();
            asm volatile ("pause");
        }
    }
};

fn streamFn(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    const self: *Stream = @fieldParentPtr("reader_iface", r);
    const bytes = self.waitForBytes() orelse
        return if (self.timed_out) error.ReadFailed else error.EndOfStream;
    const n = try w.write(limit.slice(bytes));
    const c = self.conn();
    // A window that had shrunk below a segment is announced when it reopens,
    // so a peer that filled it does not sit waiting for its own probe.
    const was_tight = c.room() < tcp.our_mss;
    c.consume(n);
    if (was_tight and c.room() >= tcp.our_mss) self.table.ack(self.wire, self.index);
    return n;
}

fn drainFn(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *Stream = @fieldParentPtr("writer_iface", w);

    // Whatever is buffered goes first, then each slice in order, and the last
    // one `splat` times. Only the bytes taken from `data` are counted: the
    // buffer is the writer's own and is always consumed whole.
    if (w.end > 0) {
        try self.sendAll(w.buffer[0..w.end]);
        w.end = 0;
    }
    if (data.len == 0) return 0;

    var written: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        try self.sendAll(bytes);
        written += bytes.len;
    }
    const pattern = data[data.len - 1];
    if (pattern.len > 0) {
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            try self.sendAll(pattern);
            written += pattern.len;
        }
    }
    return written;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
