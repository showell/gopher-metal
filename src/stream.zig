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
const net = @import("net.zig");
const tcp = @import("tcp.zig");
const arp = @import("arp.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// What one segment carries. Kept well under the 1500-byte ethernet MTU, and
/// under the 536 bytes a peer assumes when we send no MSS option -- **we do
/// not advertise one**, so a peer is entitled to assume the smaller number,
/// and sending more than it expects is how a connection mysteriously stalls.
const segment_max: usize = 512;

pub const Stream = struct {
    nic: *net.Net,
    conn: *tcp.Listener,
    /// Our own address, for answering ARP while a read is waiting.
    ip: [4]u8,

    /// How much of what the connection has received we have handed out.
    consumed: usize = 0,
    /// The peer has closed, or the connection ended.
    ended: bool = false,

    reader_iface: Reader,
    writer_iface: Writer,

    pub fn init(nic: *net.Net, conn: *tcp.Listener, ip: [4]u8, read_buf: []u8, write_buf: []u8) Stream {
        return .{
            .nic = nic,
            .conn = conn,
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

    /// One turn of the event loop: take a frame if there is one, answer ARP,
    /// and let TCP see the rest.
    pub fn pump(self: *Stream) void {
        const got = self.nic.poll() orelse return;
        defer self.nic.recycle(got.id);

        if (arp.parseRequest(got.frame)) |req| {
            if (eql(&req.target_ip, &self.ip)) {
                var out: [64]u8 = undefined;
                const n = arp.writeReply(&out, self.nic.mac, self.ip, req);
                self.nic.send(out[0..n]);
            }
            return;
        }

        switch (self.conn.handle(self.nic, got.frame)) {
            .closed => self.ended = true,
            else => {},
        }
    }

    /// Bytes the peer has sent that we have not handed out, waiting for some
    /// to arrive if there are none. Null once nothing more is coming.
    fn waitForBytes(self: *Stream) ?[]u8 {
        var spins: usize = 0;
        while (spins < 200_000_000) : (spins += 1) {
            if (self.consumed < self.conn.received_len) {
                return self.conn.received[self.consumed..self.conn.received_len];
            }
            if (self.ended) return null;
            self.pump();
            asm volatile ("pause");
        }
        return null;
    }

    /// Sends bytes as TCP segments, a segment at a time.
    fn sendAll(self: *Stream, bytes: []const u8) error{WriteFailed}!void {
        if (self.ended) return error.WriteFailed;
        var at: usize = 0;
        while (at < bytes.len) {
            const n = @min(segment_max, bytes.len - at);
            self.conn.send(self.nic, bytes[at..][0..n]);
            at += n;
        }
    }

    /// Says we are done sending, which closes the connection once the peer
    /// agrees. `std.http.Server` writes `connection: close` for us; this is the
    /// TCP half of the same statement.
    pub fn finish(self: *Stream) void {
        self.conn.finish(self.nic);
        var spins: usize = 0;
        while (!self.ended and spins < 50_000_000) : (spins += 1) {
            self.pump();
            asm volatile ("pause");
        }
    }
};

fn streamFn(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    const self: *Stream = @fieldParentPtr("reader_iface", r);
    const bytes = self.waitForBytes() orelse return error.EndOfStream;
    const n = try w.write(limit.slice(bytes));
    self.consumed += n;
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
