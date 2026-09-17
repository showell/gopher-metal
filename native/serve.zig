//! **THIS MACHINE'S TCP, ON LINUX, BEHIND A TAP DEVICE.**
//!
//! `src/tcp.zig` touches no device, so it runs as an ordinary Linux program as
//! well as it runs with no operating system: frames come from and go to a TAP
//! device instead of virtio-net. On the other side of the TAP is Linux's own
//! TCP — a real, strict, well-understood peer — with no emulator in between.
//! A question about the TCP table takes seconds to ask here, and the answer
//! owes nothing to QEMU or slirp.
//!
//! The server answers one request per connection and closes first, as the
//! machine does:
//!
//!   GET /tiny          two bytes
//!   GET /bytes/N       N bytes, byte k being (k * 7 + 3) mod 256
//!   GET /stats         the table's counters, as `key value` lines
//!   GET /quit          answers, and the program ends once every connection
//!                      has closed
//!
//! The device is `gmtap0` (GM_TAP overrides it), created and addressed by
//! `native/judge_native.py`; this program only opens it. It is 10.77.0.2.
//! GM_LOSE_SENT=N drops every Nth TCP frame it sends.

const std = @import("std");
const linux = std.os.linux;
const netcore = @import("netcore");
const proto = netcore.proto;
const arp = netcore.arp;
const tcp = netcore.tcp;

const our_ip = [4]u8{ 10, 77, 0, 2 };
const our_mac = [6]u8{ 0x02, 0x67, 0x6d, 0x00, 0x00, 0x02 };
const slots = 64;
const rx_bytes = 16 * 1024;
const tx_bytes = 64 * 1024;

var conns: [slots]tcp.Conn = undefined;
var rx: [slots][rx_bytes]u8 = undefined;
var tx: [slots][tx_bytes]u8 = undefined;
var out: [2048]u8 = undefined;

/// What each connection is being answered with: a body still to queue.
const Answer = struct {
    active: bool = false,
    head: [1200]u8 = undefined,
    head_len: usize = 0,
    head_at: usize = 0,
    body_len: usize = 0,
    body_at: usize = 0,
    kind: enum { tiny, bytes, stats, quit } = .tiny,
    stats: [1024]u8 = undefined,
};
var answers: [slots]Answer = @splat(.{});

var served: u64 = 0;
var closes: u64 = 0;
var quitting = false;

const Wire = struct {
    fd: i32,
    lose_one_in: u64 = 0,
    sent: u64 = 0,
    lost: u64 = 0,

    pub fn send(self: *Wire, frame: []const u8) void {
        self.sent += 1;
        if (self.lose_one_in != 0 and self.sent % self.lose_one_in == 0) {
            self.lost += 1;
            return;
        }
        _ = linux.write(self.fd, frame.ptr, frame.len);
    }
};

fn now() i96 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i96, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn isn() u32 {
    var b: [4]u8 = undefined;
    _ = linux.getrandom(&b, b.len, 0);
    return std.mem.readInt(u32, &b, .little);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("serve: " ++ fmt ++ "\n", args);
    linux.exit(1);
}

/// Opens the TAP device `name`, already created for this user.
fn openTap(name: []const u8) i32 {
    const rc = linux.open("/dev/net/tun", .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
    if (linux.errno(rc) != .SUCCESS) fail("cannot open /dev/net/tun: {s}", .{@tagName(linux.errno(rc))});
    const fd: i32 = @intCast(rc);
    // struct ifreq: the name, then a short of flags.
    var ifr: [40]u8 = @splat(0);
    @memcpy(ifr[0..name.len], name);
    const iff_tap: u16 = 0x0002;
    const iff_no_pi: u16 = 0x1000;
    std.mem.writeInt(u16, ifr[16..18], iff_tap | iff_no_pi, .little);
    const tunsetiff: u32 = 0x400454ca;
    const r = linux.ioctl(fd, tunsetiff, @intFromPtr(&ifr));
    if (linux.errno(r) != .SUCCESS) fail("cannot attach to {s}: {s}", .{ name, @tagName(linux.errno(r)) });
    return fd;
}

fn begin(i: usize, request: []const u8, table: *tcp.Table) void {
    const a = &answers[i];
    a.* = .{ .active = true };
    const line_end = std.mem.indexOfScalar(u8, request, '\r') orelse request.len;
    var words = std.mem.tokenizeScalar(u8, request[0..line_end], ' ');
    _ = words.next();
    const path = words.next() orelse "/";
    var body: []const u8 = "ok";
    if (std.mem.startsWith(u8, path, "/bytes/")) {
        a.kind = .bytes;
        a.body_len = std.fmt.parseInt(usize, path["/bytes/".len..], 10) catch 0;
    } else if (std.mem.eql(u8, path, "/stats")) {
        a.kind = .stats;
        var in_use: usize = 0;
        for (table.conns, 0..) |c, k| {
            if (k != i and c.state != .closed) in_use += 1;
        }
        body = std.fmt.bufPrint(&a.stats,
            \\served {d}
            \\closes {d}
            \\in_use {d}
            \\refused {d}
            \\retransmits {d}
            \\probes {d}
            \\given_up {d}
            \\fin_waits_expired {d}
            \\strays {d}
            \\damaged {d}
            \\
        , .{
            served,          closes,          in_use,           table.refused,
            table.retransmits, table.probes, table.given_up, table.fin_waits_expired,
            table.strays,    table.damaged,
        }) catch "overflow";
        a.body_len = body.len;
    } else if (std.mem.eql(u8, path, "/quit")) {
        a.kind = .quit;
        a.body_len = body.len;
        quitting = true;
    } else {
        a.body_len = body.len;
    }
    const head = std.fmt.bufPrint(&a.head, "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{a.body_len}) catch unreachable;
    a.head_len = head.len;
    if (a.kind != .bytes) {
        // Small bodies go right after the head.
        @memcpy(a.head[a.head_len..][0..body.len], body);
        a.head_len += body.len;
        a.body_at = a.body_len;
    }
    served += 1;
}

/// Queues as much of connection `i`'s answer as fits; finishes it when all is
/// queued.
fn progress(i: usize, table: *tcp.Table) void {
    const a = &answers[i];
    if (!a.active) return;
    if (a.head_at < a.head_len) {
        a.head_at += table.queue(i, a.head[a.head_at..a.head_len]);
        if (a.head_at < a.head_len) return;
    }
    var chunk: [4096]u8 = undefined;
    while (a.body_at < a.body_len) {
        const n = @min(chunk.len, a.body_len - a.body_at, table.conns[i].queueRoom());
        if (n == 0) return;
        for (chunk[0..n], a.body_at..) |*b, k| b.* = @truncate(k *% 7 +% 3);
        a.body_at += table.queue(i, chunk[0..n]);
    }
    table.finish(i);
    a.active = false;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var env = try std.process.Environ.createMap(init.environ, std.heap.page_allocator);
    defer env.deinit();
    const name = env.get("GM_TAP") orelse "gmtap0";
    const fd = openTap(name);
    var wire = Wire{ .fd = fd };
    if (env.get("GM_LOSE_SENT")) |v| wire.lose_one_in = std.fmt.parseInt(u64, v, 10) catch 0;

    for (&conns, &rx, &tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
    var table = tcp.Table.init(our_ip, our_mac, 80, &conns, &out, isn);
    std.debug.print("serve: listening on {s} as 10.77.0.2\n", .{name});

    var frame: [2048]u8 = undefined;
    while (true) {
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&fds, 1, 5);
        // Every waiting frame before any timer.
        while (true) {
            const rc = linux.read(fd, &frame, frame.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
            const f = frame[0..rc];
            if (arp.parseRequest(f)) |req| {
                if (std.mem.eql(u8, &req.target_ip, &our_ip)) {
                    var reply: [64]u8 = undefined;
                    const n = arp.writeReply(&reply, our_mac, our_ip, req);
                    wire.send(reply[0..n]);
                }
                continue;
            }
            const r = table.handle(&wire, f, now());
            switch (r.event) {
                .closed => {
                    closes += 1;
                    answers[r.index].active = false;
                },
                else => {},
            }
        }
        for (table.conns, 0..) |*c, i| {
            if (c.state != .established or answers[i].active) continue;
            if (std.mem.indexOf(u8, c.pending(), "\r\n\r\n")) |end| {
                begin(i, c.pending()[0 .. end + 4], &table);
                c.consume(c.pending().len);
            }
        }
        for (0..slots) |i| progress(i, &table);
        table.transmit(&wire, now());
        if (quitting) {
            var open: usize = 0;
            for (table.conns) |c| {
                if (c.state != .closed) open += 1;
            }
            if (open == 0) break;
        }
    }
    std.debug.print("serve: stopped after {d} answers; {d} frames sent, {d} lost on purpose\n", .{ served, wire.sent, wire.lost });
}
