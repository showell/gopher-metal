//! **THE ONE THAT MATTERS.** The same probe as `http.zig`, except that the
//! HTTP is not ours: it is `std.http.Server`, from zig's standard library,
//! unmodified, running on a machine with no operating system under it.
//!
//! `angry-gopher/zig-server` builds its server exactly this way —
//!
//!     var server = std.http.Server.init(&sr.interface, &sw.interface);
//!     const req = try server.receiveHead();
//!     try req.respond(body, .{});
//!
//! — so if this works, the HTTP layer of the port is done before it is
//! started. What is left is `Io.Dir` over a filesystem and a clock, which are
//! smaller problems than this one was.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const net = metal.net;
const dhcp = metal.dhcp;
const rng = metal.rng;
const tcp = metal.tcp;
const stream = metal.stream;

comptime {
    _ = metal.boot;
}

var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var dhcp_frame: [net.buffer_size]u8 align(16) = undefined;
var dhcp_reply: [1024]u8 align(16) = undefined;
var tcp_out: [net.buffer_size]u8 align(16) = undefined;
var tcp_received: [8192]u8 align(16) = undefined;
var read_buf: [4096]u8 align(16) = undefined;
var write_buf: [4096]u8 align(16) = undefined;

const body = "hello from std.http.Server, with no Linux under it\n";

fn isn() u32 {
    return rng.int(u32);
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal std.http probe\n");

    // **A CONNECTION IS READ AGAINST A CLOCK.** stream.zig bounds every wait by
    // a measured duration rather than a spin count, so the timestamp counter's
    // rate has to be known before anything is served. No wall clock is needed
    // for that — only the rate.
    const hz = metal.pit.calibrate() catch serial.fail("the PIT would not calibrate the TSC");
    metal.io.startClock(hz);

    rng.attach(&rng_mem);
    const base = virtio.find(virtio.device_id_net) orelse
        serial.fail("no virtio-net device in any mmio slot");
    var nic = net.Net.init(base, &nic_mem) catch serial.fail("the NIC would not come up");

    const lease = dhcp.acquire(&nic, &dhcp_frame, &dhcp_reply) catch
        serial.fail("no DHCP lease, so there is no address to listen on");
    serial.put("  address: ");
    serial.putIp(lease.address);
    serial.put("\n  listening on port 80, with zig's own HTTP\n");

    var slots = [_]tcp.Conn{.{ .rx = &tcp_received }};
    var table = tcp.Table.init(lease.address, nic.mac, 80, &slots, &tcp_out, isn);

    // Wait for a request to arrive before handing the stream to std.http:
    // the host only ever serves a connection whose request head is here.
    var spins: usize = 0;
    while (spins < 200_000_000) : (spins += 1) {
        const c = &table.conns[0];
        if (c.state == .established and metal.ready.check(c.pending(), c.peer_done) != .waiting) break;
        if (stream.pump(&nic, &table, lease.address) == null) asm volatile ("pause");
    }
    if (table.conns[0].state != .established) serial.fail("nothing connected before the spin budget ran out");
    serial.put("  connected\n");
    table.claim(0);
    var s = stream.Stream.init(&nic, &table, 0, lease.address, &read_buf, &write_buf);

    var server = std.http.Server.init(s.reader(), s.writer());

    var req = server.receiveHead() catch |e| {
        serial.put("  receiveHead: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("std.http.Server could not read the request");
    };
    serial.put("  method: ");
    serial.put(@tagName(req.head.method));
    serial.put("  target: ");
    serial.put(req.head.target);
    serial.put("\n");

    req.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    }) catch |e| {
        serial.put("  respond: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("std.http.Server could not write the response");
    };

    s.writer().flush() catch serial.fail("the response would not flush");
    serial.put("  responded\n");
    s.finish();
    serial.pass();
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
