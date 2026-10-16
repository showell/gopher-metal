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
/// How often an unanswered ARP request is asked again.
const arp_every_ns: i96 = 100 * std.time.ns_per_ms;

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

/// **HOW THE CONNECTION ENDED**, from the counter the table moved when it
/// let it go.
fn ended(t: *const tcp.Table, before: tcp.Table) fetch.Outcome {
    if (t.connects_refused != before.connects_refused) return .refused;
    if (t.connect_deadlines != before.connect_deadlines) return .connect_deadline;
    if (t.idle_deadlines != before.idle_deadlines) return .idle_deadline;
    if (t.total_deadlines != before.total_deadlines) return .total_deadline;
    if (t.given_up != before.given_up) return .given_up;
    return .reset;
}

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

    var request_buf: [512]u8 = undefined;
    var host_buf: [32]u8 = undefined;
    const host = std.fmt.bufPrint(&host_buf, "{d}.{d}.{d}.{d}", .{ server_ip[0], server_ip[1], server_ip[2], server_ip[3] }) catch unreachable;
    const request = fetch.writeRequest(&request_buf, host, path) catch fail("the path is too long", .{});

    const began = now();
    began_at = began;
    trace = env.get("GM_TRACE") != null;
    var cache: arp.Cache = .{};
    var asked_at: ?i96 = null;
    var slot: ?usize = null;
    var queued: usize = 0;
    var answer: fetch.Answer = .{};
    var finished = false;
    var before: tcp.Table = undefined;
    var outcome: ?fetch.Outcome = null;

    var frame: [2048]u8 = undefined;
    while (outcome == null) {
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&fds, 1, 1);
        const t = now();
        while (true) {
            const rc = linux.read(fd, &frame, frame.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
            const f = frame[0..rc];
            if (arp.parse(f)) |p| {
                cache.observe(p, our_ip);
                if (p.op == .request and std.mem.eql(u8, &p.target_ip, &our_ip)) {
                    var reply: [64]u8 = undefined;
                    const n = arp.writeReply(&reply, our_mac, our_ip, .{ .sender_mac = p.sender_mac, .sender_ip = p.sender_ip, .target_ip = p.target_ip });
                    wire.send(reply[0..n]);
                }
                continue;
            }
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
            _ = table.handle(&wire, f, t);
        }

        if (slot == null) {
            // **WHO HAS THE SERVER'S ADDRESS?** Asked every 100 ms, within
            // the connect deadline; then the connection.
            if (cache.lookup(server_ip)) |mac| {
                before = table;
                slot = table.connect(&wire, .{ .mac = mac, .ip = server_ip, .port = port }, deadlines, t) orelse fail("no slot for the connection", .{});
            } else if (t - began >= @as(i96, @intCast(deadlines.connect_ns))) {
                outcome = .no_arp;
            } else if (asked_at == null or t - asked_at.? >= arp_every_ns) {
                var ask: [64]u8 = undefined;
                wire.send(ask[0..arp.writeRequest(&ask, our_mac, our_ip, server_ip)]);
                asked_at = t;
            }
        }

        if (slot) |i| {
            const c = &table.conns[i];
            if (c.state == .established and queued < request.len) queued += table.queue(i, request[queued..]);
            const pending = c.pending();
            if (pending.len > 0) {
                const body = answer.feed(pending);
                writeOut(body);
                if (c.consumeReopens(pending.len)) table.ack(&wire, i);
            }
            if (c.peerDone() and !finished and c.state == .established) {
                table.finish(i);
                finished = true;
            }
            table.transmit(&wire, t);
            if (table.conns[i].state == .closed) {
                outcome = if (finished or c.peerDone()) answer.outcome() else ended(&table, before);
            }
        } else table.transmit(&wire, t);
    }
    const o = outcome.?;
    std.debug.print("fetch: {s} after {d} ms: status {d}, {d} of {?d} body bytes; " ++
        "{d} frames sent ({d} not sent on purpose), {d} retransmits, {d} segments held ahead of a hole\n", .{
        @tagName(o),     @divTrunc(now() - began, std.time.ns_per_ms), answer.status,
        answer.body_len, answer.length,                                wire.sent,
        wire.lost,       table.retransmits,                            table.held_segments,
    });
    linux.exit(o.code());
}
