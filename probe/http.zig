//! A kernel that takes a DHCP lease, listens on port 80, and answers one HTTP
//! request. It is the smallest thing that is recognisably a web server, and it
//! runs with no operating system under it.
//!
//! The verdict is not what this prints: it is what `curl` on the other side
//! gets back. `probe/run.sh` boots this behind QEMU's user-mode networking with
//! a host port forwarded in, fetches from it, and compares.

const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const net = metal.net;
const dhcp = metal.dhcp;
const rng = metal.rng;
const arp = metal.arp;
const tcp = metal.tcp;

comptime {
    _ = metal.boot;
}

var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var frame: [net.buffer_size]u8 align(16) = undefined;
var reply: [1024]u8 align(16) = undefined;
var out: [net.buffer_size]u8 align(16) = undefined;
var request: [4096]u8 align(16) = undefined;

const body = "hello from no Linux\n";

/// A response built once at compile time, so nothing here has to format.
const response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: text/plain\r\n" ++
    "content-length: 20\r\n" ++
    "connection: close\r\n" ++
    "\r\n" ++
    body;

comptime {
    if (body.len != 20) @compileError("the content-length above must match the body");
}

/// The end of a request's headers. One request per connection, so this is the
/// whole of the framing we need.
fn complete(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and bytes[i + 1] == '\n' and bytes[i + 2] == '\r' and bytes[i + 3] == '\n') return true;
    }
    return false;
}

/// Up to the first CR, which is the request line a human wants to see.
fn firstLine(bytes: []const u8) []const u8 {
    for (bytes, 0..) |b, i| {
        if (b == '\r' or b == '\n') return bytes[0..i];
    }
    return bytes;
}

fn isn() u32 {
    return rng.int(u32);
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal http probe\n");

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

    const lease = dhcp.acquire(&nic, &frame, &reply) catch
        serial.fail("no DHCP lease, so there is no address to listen on");
    serial.put("  address: ");
    serial.putIp(lease.address);
    serial.put("\n  listening on port 80\n");

    var slots = [_]tcp.Conn{.{ .rx = &request }};
    var server = tcp.Table.init(lease.address, nic.mac, 80, &slots, &out, isn);

    // Bounded rather than forever: a probe that hangs is worse than one that
    // fails, and the run script's timeout should never be what stops it.
    var spins: usize = 0;
    var answered = false;
    while (spins < 200_000_000) : (spins += 1) {
        const got = nic.poll() orelse {
            asm volatile ("pause");
            continue;
        };
        defer nic.recycle(got.id);

        // **ARP FIRST.** Nothing can send us a packet until we have said which
        // hardware address owns ours, so this is not an optimisation.
        if (arp.parseRequest(got.frame)) |req| {
            if (eql(&req.target_ip, &lease.address)) {
                const n = arp.writeReply(&out, nic.mac, lease.address, req);
                nic.send(out[0..n]);
            }
            continue;
        }

        const r = server.handle(&nic, got.frame, 0);
        switch (r.event) {
            .data, .peer_done => {
                const pending = server.conns[r.index].pending();
                if (answered or !complete(pending)) continue;
                serial.put("  request: ");
                serial.put(firstLine(pending));
                serial.put("\n");
                server.send(&nic, r.index, response);
                server.finish(&nic, r.index);
                answered = true;
            },
            .closed => {
                if (!answered) continue;
                serial.put("  answered and closed\n");
                serial.pass();
            },
            else => {},
        }
    }

    serial.fail("nothing asked for anything before the spin budget ran out");
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub const panic = @import("std").debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
