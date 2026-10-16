//! **THIS MACHINE'S TCP AS A CLIENT, ON LINUX, BEHIND A TAP DEVICE**
//! (metal-vmm QUEUE 225, chunk 8): `serve.zig`'s other half. One GET, made
//! with `tcp.Table.connect`, to a Linux server on the far side of the TAP,
//! so Linux's TCP is the witness to the client as it is to the server.
//!
//!   gm-fetch <ip> <port> <path> connect_ms=N idle_ms=N total_ms=N
//!
//! The deadlines have no defaults (docs/TWO-KERNELS.md §5): each run says
//! what it can wait. The body goes to stdout; one line on stderr says how it
//! ended, and the exit status is that outcome's code (`fetch.Outcome`):
//! 0 a whole 200, 2 refused, 3, 4 and 5 the connect, idle and total
//! deadlines, 6 given up, 7 reset, 8 a bad answer, 9 no ARP reply, 10 a
//! short one, and 1 when it could not start.
//!
//! The device is `gmtap0` (GM_TAP overrides it), set up by
//! `native/judge_native.py`; this machine is 10.77.0.2 on it, and asks ARP
//! for the server's hardware address (`arp.Cache`). The knobs, all of what
//! this machine sends or takes, so a run is repeated exactly:
//!
//!   GM_EAT_SYNS=N      our first N SYNs are not sent
//!   GM_DROP_SENT=K     the K-th TCP frame we send (from 0) is not sent
//!   GM_DROP_RECEIVED=K the K-th TCP frame that arrives (from 0) is not taken
//!   GM_DEAF_FROM=K     no TCP frame from the K-th on is taken (0: a server
//!                      that answers nothing, its ARP reply aside)
//!   GM_TRACE=1         every TCP frame each way, one line on stderr
//!   GM_LOSE_SENT=N     one in N of the frames we send, at random from
//!                      GM_LOSE_SEED (default 1), as serve.zig's

const std = @import("std");
const linux = std.os.linux;
const netcore = @import("netcore");
const proto = netcore.proto;
const arp = netcore.arp;
const tcp = netcore.tcp;
const fetch = netcore.fetch;

const our_ip = [4]u8{ 10, 77, 0, 2 };
const our_mac = [6]u8{ 0x02, 0x67, 0x6d, 0x00, 0x00, 0x02 };
/// Two slots: the one kept for this connection (`reserved_for_initiated`)
/// and one the listening port may take (nobody connects to it here).
const slots = 2;
const rx_bytes = 16 * 1024;
const tx_bytes = 4 * 1024;

var conns: [slots]tcp.Conn = undefined;
var rx: [slots][rx_bytes]u8 = undefined;
var tx: [slots][tx_bytes]u8 = undefined;
var out: [2048]u8 = undefined;

var trace = false;
var began_at: i96 = 0;

/// One line for a TCP frame: when, which way, its flags and numbers.
fn traceFrame(way: []const u8, frame: []const u8, note: []const u8) void {
    if (!trace or !isTcp(frame)) return;
    const t = frame[tcp.segment_at..];
    const hlen = @as(usize, t[12] >> 4) * 4;
    std.debug.print("{d:>6} us {s} flags {x:0>2} seq {d} ack {d} win {d} len {d}{s}\n", .{
        @divTrunc(now() - began_at, 1000), way,                      t[13],
        proto.readBe32(t[4..8]),           proto.readBe32(t[8..12]), proto.readBe16(t[14..16]),
        t.len -| hlen,                     note,
    });
}

const Wire = struct {
    fd: i32,
    eat_syns: u64 = 0,
    drop_sent: ?u64 = null,
    lose_one_in: u64 = 0,
    loss: std.Random.DefaultPrng = .init(1),
    tcp_sent: u64 = 0,
    sent: u64 = 0,
    lost: u64 = 0,

    pub fn send(self: *Wire, frame: []const u8) void {
        self.sent += 1;
        if (isTcp(frame)) {
            const nth = self.tcp_sent;
            self.tcp_sent += 1;
            const flags = frame[tcp.segment_at + 13];
            if (flags & tcp.flag_syn != 0 and self.eat_syns > 0) {
                self.eat_syns -= 1;
                self.lost += 1;
                return traceFrame("out", frame, " (eaten)");
            }
            if (self.drop_sent == nth) {
                self.lost += 1;
                return traceFrame("out", frame, " (dropped)");
            }
            traceFrame("out", frame, "");
        }
        if (self.lose_one_in != 0 and self.loss.random().uintLessThan(u64, self.lose_one_in) == 0) {
            self.lost += 1;
            return;
        }
        _ = linux.write(self.fd, frame.ptr, frame.len);
    }
};

fn isTcp(frame: []const u8) bool {
    const pkt = switch (proto.readIpv4(frame)) {
        .packet => |p| p,
        .not => return false,
    };
    return pkt.protocol == proto.proto_tcp and frame.len >= tcp.segment_at + tcp.header_len;
}

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
    std.debug.print("fetch: " ++ fmt ++ "\n", args);
    linux.exit(1);
}

/// Opens the TAP device `name`, already created for this user.
fn openTap(name: []const u8) i32 {
    const rc = linux.open("/dev/net/tun", .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
    if (linux.errno(rc) != .SUCCESS) fail("cannot open /dev/net/tun: {s}", .{@tagName(linux.errno(rc))});
    const fd: i32 = @intCast(rc);
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

/// The body, to stdout, whole.
fn writeOut(bytes: []const u8) void {
    var at: usize = 0;
    while (at < bytes.len) {
        const rc = linux.write(1, bytes[at..].ptr, bytes.len - at);
        if (linux.errno(rc) != .SUCCESS) fail("cannot write the body: {s}", .{@tagName(linux.errno(rc))});
        at += rc;
    }
}

fn parseIp(text: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, '.');
    for (&ip) |*b| b.* = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    return ip;
}

/// `name=N` milliseconds among `args`, in nanoseconds; there is no default.
fn deadlineArg(args: []const []const u8, name: []const u8) u64 {
    for (args) |a| {
        if (a.len > name.len and std.mem.startsWith(u8, a, name) and a[name.len] == '=') {
            const ms = std.fmt.parseInt(u64, a[name.len + 1 ..], 10) catch fail("{s} is not a number of milliseconds", .{a});
            return ms * std.time.ns_per_ms;
        }
    }
    fail("no {s}=N: the deadlines have no defaults", .{name});
}

/// The body, as `fetch.Client` hands it over: to stdout.
const Stdout = struct {
    pub fn body(_: *Stdout, bytes: []const u8) void {
        writeOut(bytes);
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    var env = try std.process.Environ.createMap(init.environ, std.heap.page_allocator);
    defer env.deinit();
    var args_buf: [16][]const u8 = undefined;
    var n_args: usize = 0;
    var it = init.args.iterate();
    _ = it.skip();
    while (it.next()) |a| {
        if (n_args == args_buf.len) fail("too many arguments", .{});
        args_buf[n_args] = a;
        n_args += 1;
    }
    const args = args_buf[0..n_args];
    if (args.len < 6) fail("usage: gm-fetch <ip> <port> <path> connect_ms=N idle_ms=N total_ms=N", .{});
    const server_ip = parseIp(args[0]) orelse fail("{s} is not an IPv4 address", .{args[0]});
    const port = std.fmt.parseInt(u16, args[1], 10) catch fail("{s} is not a port", .{args[1]});
    const path = args[2];
    const deadlines: tcp.Deadlines = .{
        .connect_ns = deadlineArg(args[3..], "connect_ms"),
        .idle_ns = deadlineArg(args[3..], "idle_ms"),
        .total_ns = deadlineArg(args[3..], "total_ms"),
    };

    const name = env.get("GM_TAP") orelse "gmtap0";
    const fd = openTap(name);
    var wire = Wire{ .fd = fd };
    if (env.get("GM_EAT_SYNS")) |v| wire.eat_syns = std.fmt.parseInt(u64, v, 10) catch 0;
    if (env.get("GM_DROP_SENT")) |v| wire.drop_sent = std.fmt.parseInt(u64, v, 10) catch null;
    if (env.get("GM_LOSE_SENT")) |v| wire.lose_one_in = std.fmt.parseInt(u64, v, 10) catch 0;
    if (env.get("GM_LOSE_SEED")) |v| wire.loss = .init(std.fmt.parseInt(u64, v, 10) catch 1);
    const drop_received: ?u64 = if (env.get("GM_DROP_RECEIVED")) |v| std.fmt.parseInt(u64, v, 10) catch null else null;
    const deaf_from: ?u64 = if (env.get("GM_DEAF_FROM")) |v| std.fmt.parseInt(u64, v, 10) catch null else null;
    var tcp_received: u64 = 0;

    for (&conns, &rx, &tx) |*c, *r, *t| c.* = .{ .rx = r, .tx = t };
    var table = tcp.Table.init(our_ip, our_mac, 7, &conns, &out, isn);
    table.reserved_for_initiated = 1;
    table.ephemeral_next = @intCast(tcp.ephemeral_first + isn() % (0xFFFF - tcp.ephemeral_first));

    const began = now();
    began_at = began;
    trace = env.get("GM_TRACE") != null;
    var client = fetch.Client.init(.{ .ip = server_ip, .port = port, .path = path }, deadlines, our_ip, our_mac, began) catch fail("the path is too long", .{});
    var sink: Stdout = .{};

    var frame: [2048]u8 = undefined;
    const o = while (true) {
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&fds, 1, 1);
        const t = now();
        while (true) {
            const rc = linux.read(fd, &frame, frame.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
            const f = frame[0..rc];
            if (isTcp(f)) {
                const nth = tcp_received;
                tcp_received += 1;
                if (drop_received == nth) {
                    traceFrame("in ", f, " (dropped)");
                    continue;
                }
                if (deaf_from) |k| if (nth >= k) {
                    traceFrame("in ", f, " (dropped)");
                    continue;
                };
                traceFrame("in ", f, "");
            }
            client.arrived(&table, &wire, f, t);
        }
        if (client.turn(&table, &wire, t, &sink)) |done| break done;
    };
    const answer = &client.answer;
    std.debug.print("fetch: {s} after {d} ms: status {d}, {d} of {?d} body bytes; " ++
        "{d} frames sent ({d} not sent on purpose), {d} retransmits, {d} segments held ahead of a hole\n", .{
        @tagName(o),     @divTrunc(now() - began, std.time.ns_per_ms), answer.status,
        answer.body_len, answer.length,                                wire.sent,
        wire.lost,       table.retransmits,                            table.held_segments,
    });
    linux.exit(o.code());
}
