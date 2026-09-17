//! **THE REAL SERVER.** Not a probe that imitates it — `angry-gopher`'s own
//! ROUTE TABLE, compiled from its own source, serving real requests on a machine
//! with no operating system, with its data on a FAT16 volume.
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
//! Its clocks come from its own hardware (wallclock.zig).
//!
//! **IT SERVES ONE CONNECTION AT A TIME, IN A LOOP** — which is what
//! angry-gopher's own server did before it had a thread pool: accept, read one
//! request, answer, close. Each request gets its own heap, reset afterwards, the
//! way server.zig gives each request an arena it frees wholesale. How many
//! requests to serve is host configuration, read from `gopher-metal.conf` on
//! the volume (`requests = N`); without it, forever.
//!
//! **A FAILED REQUEST IS NOT A FAILED MACHINE.** On Linux, an error from the
//! route table is logged and the connection closed; so it is here. A panic
//! still stops the machine, as a crash stops a Linux process.
//!
//! **IT IS JUDGED AGAINST LINUX.** judge_gopher.py sends the same requests to
//! this kernel and to the same application running as an ordinary Linux process
//! over the same files, and requires the same answers.

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

/// The process-lifetime heap: what the application keeps between requests
/// (presence, the reading-list cache, the bus). A bump allocator, so what it
/// frees is not reused — which the per-request log makes visible, and which a
/// real free-list will have to fix before this serves anything for long.
var base_heap: [8 * 1024 * 1024]u8 align(16) = undefined;

/// Each request's heap, reset after the response: the equivalent of the arena
/// server.zig gives each request and frees wholesale.
var request_heap: [32 * 1024 * 1024]u8 align(16) = undefined;

const config_path = "gopher-metal.conf";

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
    var base_fba = std.heap.FixedBufferAllocator.init(&base_heap);
    const base = router.mem_meter.init(base_fba.allocator());
    router.roots.point(base, .{ .data_dir = "data", .auth_dir = "auth" }) catch
        serial.fail("roots.point could not allocate the store paths");
    var bus = Bus.init(io, base);

    const limit = requestLimit(io, base);
    if (limit) |n| {
        serial.put("  serving ");
        serial.putDec(n);
        serial.put(" request(s), as " ++ config_path ++ " says\n");
    } else serial.put("  serving until stopped\n");

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
    var request_fba = std.heap.FixedBufferAllocator.init(&request_heap);

    // ── one connection at a time ────────────────────────────────────────────
    var served: u64 = 0;
    while (limit == null or served < limit.?) {
        served += 1;
        serveOne(io, &nic, &conn, lease.address, request_fba.allocator(), &bus, served);
        // What this request used of its heap, BEFORE the reset: the same
        // request must use the same amount every time, and a heap that was not
        // reset would show up as a number that only grows.
        serial.put("    request heap: ");
        serial.putDec(request_fba.end_index);
        serial.put(" bytes\n");
        request_fba.reset();
    }

    const mem = router.mem_meter.snapshot();
    serial.put("  served ");
    serial.putDec(served);
    serial.put(" request(s); base heap holds ");
    serial.putDec(mem.live_bytes);
    serial.put(" live bytes in ");
    serial.putDec(mem.live_allocs);
    serial.put(" allocations\n");
    serial.pass();
}

/// Accepts one connection, answers one request on it, and closes it. Every
/// failure short of a panic is logged and survived.
fn serveOne(
    io: Io,
    nic: *net.Net,
    conn: *tcp.Listener,
    address: [4]u8,
    request_alloc: std.mem.Allocator,
    bus: *Bus,
    number: u64,
) void {
    var s = stream.Stream.init(nic, conn, address, &read_buf, &write_buf);
    while (conn.state != .established) {
        s.pump();
        asm volatile ("pause");
    }

    var server = std.http.Server.init(s.reader(), s.writer());
    var req = server.receiveHead() catch |e| {
        logRequest(number, "(no request)", @errorName(e));
        close(&s, conn);
        return;
    };
    req.head.keep_alive = false;

    // The target is borrowed from the read buffer, which the handler may
    // consume; copy it for the log now.
    var what_buf: [300]u8 = undefined;
    const what = std.fmt.bufPrint(&what_buf, "{s} {s}", .{
        @tagName(req.head.method),
        req.head.target[0..@min(req.head.target.len, 256)],
    }) catch "(unprintable)";

    var outcome: []const u8 = "ok";
    router.route(&req, io, request_alloc, bus) catch |e| {
        outcome = @errorName(e);
    };
    s.writer().flush() catch {
        outcome = "the response would not flush";
    };
    logRequest(number, what, outcome);
    close(&s, conn);
}

fn close(s: *stream.Stream, conn: *tcp.Listener) void {
    s.finish();
    // A peer that never acknowledged our FIN would otherwise hold the listener
    // in `closing`, and every later connection would be ignored.
    if (conn.state != .listen) conn.abandon();
}

fn logRequest(number: u64, what: []const u8, outcome: []const u8) void {
    const mem = router.mem_meter.snapshot();
    serial.put("  request ");
    serial.putDec(number);
    serial.put(": ");
    serial.put(what);
    serial.put(" -> ");
    serial.put(outcome);
    serial.put(" (base: ");
    serial.putDec(mem.live_bytes);
    serial.put(" live bytes)\n");
}

/// `requests = N` from the volume's gopher-metal.conf, or null to serve until
/// stopped. A file that is present but says something else is a
/// misconfiguration, and stops the machine rather than being guessed at.
fn requestLimit(io: Io, alloc: std.mem.Allocator) ?u64 {
    const text = Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .limited(4096)) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse
            serial.fail(config_path ++ ": a line with no `=`");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (!std.mem.eql(u8, key, "requests"))
            serial.fail(config_path ++ ": the only key is `requests`");
        return std.fmt.parseInt(u64, value, 10) catch
            serial.fail(config_path ++ ": `requests` is not a number");
    }
    serial.fail(config_path ++ " is present but says nothing");
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
