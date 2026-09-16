//! **THE REAL SERVER.** Not a probe that imitates it — `angry-gopher`'s own
//! ROUTE TABLE, compiled from its own source, answering one real request on a
//! machine with no operating system, with its data on a FAT16 volume.
//!
//! The only thing done to the application is `port.sh`: one line changed in
//! each file that opens with `const Io = std.Io;`. Not one call site moves, and
//! `std.http.Server` is the one the application already constructs.
//!
//! **THIS FILE IS A HOST**, and does what router.zig's host contract says any
//! host must, with what this machine has instead of Linux:
//!
//!   1. mem_meter.init(base)   base is a bump allocator over a static block
//!   2. roots.point(base, …)   data/ and auth/, on the volume
//!   3. a Bus over base        nothing subscribes yet
//!
//! and then gives each request an arena over base, as server.zig does.
//!
//! **WHAT IT DOES NOT DO YET.** It serves one request and stops.
//!
//! Its clocks come from its own hardware (wallclock.zig): the TSC's rate from
//! the PIT, the wall clock from the CMOS RTC. That is what lets routes that
//! stamp a time — new sessions, last-seen — be served at all.
//!
//! **IT IS JUDGED AGAINST LINUX.** judge_gopher.py sends each request to this
//! kernel and to the same application running as an ordinary Linux process over
//! the same files, and requires the same answer. "The port changes nothing" is
//! the claim, so the Linux build is the oracle.

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
const router = @import("router.zig");
const Bus = router.Bus;

comptime {
    _ = metal.boot;
}

/// std.heap asks a freestanding target for its page size rather than assuming
/// one. Nothing here maps pages, but the allocators want the number.
pub const std_options: std.Options = .{ .page_size_max = 4096, .page_size_min = 4096 };

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

/// The process-lifetime heap. On Linux the host names page_allocator; here it
/// is this block and a bump pointer. One request per boot, so nothing needs to
/// be given back — but the per-request arena still frees into it, as it would
/// on a host that serves more than one.
var base_heap: [16 * 1024 * 1024]u8 align(16) = undefined;

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal: angry-gopher's route table, with no Linux under it\n");

    // ── the volume. This host serves from it, so no disk is a failure. ──────
    const blk_base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no disk: this kernel serves the site from a FAT16 volume");
    var blk = blk_mem.bring(blk_base) catch serial.fail("the block device would not come up");
    const part = gpt.firstPartition(&blk, &sector) catch
        serial.fail("the disk has no GPT partition to serve from");
    const vol = fat16.Volume.mount(&blk, &sector, part.first_lba) catch
        serial.fail("the first partition is not FAT16");
    Io.mount(vol);
    serial.put("  volume mounted at LBA ");
    serial.putDec(part.first_lba);
    serial.put("\n");
    const clock = metal.wallclock.start() catch |e| {
        serial.put("  wallclock: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the clocks would not come up");
    };
    serial.put("  clock: TSC at ");
    serial.putDec(clock.tsc_hz);
    serial.put(" Hz, wall clock ");
    serial.putDec(@intCast(clock.unix));
    serial.put("\n");
    const io = Io.io();

    // ── the host contract ───────────────────────────────────────────────────
    var fba = std.heap.FixedBufferAllocator.init(&base_heap);
    const base = router.mem_meter.init(fba.allocator());
    router.roots.point(base, .{ .data_dir = "data", .auth_dir = "auth" }) catch
        serial.fail("roots.point could not allocate the store paths");
    var bus = Bus.init(io, base);

    // ── the network ─────────────────────────────────────────────────────────
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

    // ── one request, the application's own way ─────────────────────────────
    var server = std.http.Server.init(s.reader(), s.writer());
    var req = server.receiveHead() catch serial.fail("std.http.Server could not read the request");
    serial.put("  ");
    serial.put(@tagName(req.head.method));
    serial.put(" ");
    serial.put(req.head.target);
    serial.put("\n");
    req.head.keep_alive = false;

    var arena = std.heap.ArenaAllocator.init(base);
    router.route(&req, io, arena.allocator(), &bus) catch |e| {
        serial.put("  router.route: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the application's own route table failed");
    };
    s.writer().flush() catch serial.fail("the response would not flush");
    arena.deinit();

    const mem = router.mem_meter.snapshot();
    serial.put("  served; base heap holds ");
    serial.putDec(mem.live_bytes);
    serial.put(" live bytes in ");
    serial.putDec(mem.live_allocs);
    serial.put(" allocations\n");
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
