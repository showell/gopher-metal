//! **THE REAL SERVER.** Not a probe that imitates it — `angry-gopher`'s own
//! `driving.zig`, compiled from its own source, answering a real request on a
//! machine with no operating system.
//!
//! The only thing done to it is `port.sh`: one line changed in each of the 37
//! files that has `const Io = std.Io;`. Not one call site moves, and
//! `std.http.Server` is the one the application already constructs.
//!
//! `/driving` is the right page to start with: it only reads, so it proves the
//! path end to end without needing the volume to be writable first.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const net = metal.net;
const dhcp = metal.dhcp;
const rng = metal.rng;
const tcp = metal.tcp;
const stream = metal.stream;
const gpt = metal.gpt;
const fat16 = metal.fat16;
const Io = metal.io;

/// The application, as it is.
const driving = @import("driving.zig");

comptime {
    _ = metal.boot;
}

var blk_mem: virtio.BlockMemory align(4096) = .{};
var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var sector: [fat16.sector_size]u8 align(4096) = undefined;
var dhcp_frame: [net.buffer_size]u8 align(16) = undefined;
var dhcp_reply: [1024]u8 align(16) = undefined;
var tcp_out: [net.buffer_size]u8 align(16) = undefined;
var tcp_received: [16384]u8 align(16) = undefined;
var read_buf: [16 * 1024]u8 align(16) = undefined;
var write_buf: [64 * 1024]u8 align(16) = undefined;

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal: angry-gopher, with no Linux under it\n");

    // Storage, if there is any. /driving serves from its own source, so a
    // missing disk is not fatal -- but Io wants a volume before anything else
    // asks it for a file.
    if (virtio.find(virtio.device_id_block)) |blk_base| {
        var blk = blk_mem.bring(blk_base) catch serial.fail("the block device would not come up");
        if (gpt.firstPartition(&blk, &sector) catch null) |part| {
            if (fat16.Volume.mount(&blk, &sector, part.first_lba) catch null) |vol| {
                Io.mount(vol);
                serial.put("  volume mounted at LBA ");
                serial.putDec(part.first_lba);
                serial.put("\n");
            }
        }
    }
    Io.startClock();

    rng.attach(&rng_mem);
    const nic_base = virtio.find(virtio.device_id_net) orelse
        serial.fail("no virtio-net device in any mmio slot");
    var nic = net.Net.init(nic_base, &nic_mem) catch serial.fail("the NIC would not come up");
    const lease = dhcp.acquire(&nic, &dhcp_frame, &dhcp_reply) catch
        serial.fail("no DHCP lease, so there is no address to listen on");
    serial.put("  address: ");
    serial.putIp(lease.address);
    serial.put("\n  listening on port 80\n");

    var conn = tcp.Listener.init(lease.address, nic.mac, 80, &tcp_received, &tcp_out);
    var s = stream.Stream.init(&nic, &conn, lease.address, &read_buf, &write_buf);

    var spins: usize = 0;
    while (conn.state != .established and spins < 200_000_000) : (spins += 1) {
        s.pump();
        asm volatile ("pause");
    }
    if (conn.state != .established) serial.fail("nothing connected before the spin budget ran out");

    // From here down it is the application's own shape: std.http.Server over a
    // reader and a writer, receiveHead, and a handler from its own source.
    var server = std.http.Server.init(s.reader(), s.writer());
    var req = server.receiveHead() catch serial.fail("std.http.Server could not read the request");
    serial.put("  ");
    serial.put(@tagName(req.head.method));
    serial.put(" ");
    serial.put(req.head.target);
    serial.put("\n");
    req.head.keep_alive = false;

    driving.handle(&req, "/") catch |e| {
        serial.put("  driving.handle: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the application's own handler failed");
    };

    s.writer().flush() catch serial.fail("the response would not flush");
    serial.put("  served /driving from angry-gopher's own source\n");
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
