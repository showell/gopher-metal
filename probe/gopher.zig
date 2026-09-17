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
//!   3. a Hub over base        each request gets a Bus handle on it
//!   4. serve what was kept    not yet: a kept stream is logged and dropped
//!
//! Its clocks come from its own hardware (wallclock.zig).
//!
//! **IT HOLDS MANY CONNECTIONS AND SERVES ONE REQUEST AT A TIME, IN A LOOP**:
//! a connection whose request has arrived is answered start to finish; the
//! rest wait in the table meanwhile, and the network keeps moving for all of
//! them. Each request gets its own heap, reset afterwards, the
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
const stack = metal.stack;
const pages = metal.pages;
const pvh = metal.pvh;
const Io = metal.io;
const ready = metal.ready;

/// The application, as it is.
const router = @import("router.zig");
const Bus = router.Bus;
const Hub = router.Hub;
const streams = router.streams;

comptime {
    _ = metal.boot;
    // **NO THREADS, AND THE COMPILER AGREES.** A freestanding target is
    // single-threaded, so `std.Thread.spawn` is not a thing that compiles here
    // -- which is why the Linux host's task pool is not part of the port, and
    // why every lock, futex and group in the application costs nothing (see
    // src/io.zig). If this ever stops holding, the concurrency stubs there are
    // lies and this must not build.
    if (!@import("builtin").single_threaded) @compileError("this host serves one connection at a time; std.Io's concurrency here is stubbed for a single thread");
}

/// **THE SEAM.** `std.heap.page_allocator` is defined as
/// `root.os.heap.page_allocator` when the root file declares one — zig's own
/// hook for a target that must supply its own. So this one line puts every
/// allocator in std on this machine's RAM, and std's general-purpose allocator
/// below needs nothing passed to it. It is the same arrangement as on Linux,
/// where `page_allocator` is mmap and the allocator above it is std's either
/// way; what this machine has to supply is exactly what Linux supplies.
pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = pages.allocator;
    };
};

/// std.heap asks a freestanding target for its page size rather than assuming
/// one. **No stack traces**: this machine has no unwinder and no debug info, and
/// saying so is what keeps std's allocator from reaching for `std.Io.Threaded`
/// to capture a trace of zero frames.
pub const std_options: std.Options = .{
    .page_size_max = 4096,
    .page_size_min = 4096,
    .allow_stack_tracing = false,
};

/// **THE SITE'S LONG-LIVED HEAP IS std's GENERAL-PURPOSE ALLOCATOR**, over this
/// machine's pages. It used to be a bump allocator over a fixed array, which
/// reclaims a free only when the block being freed was the last one handed out;
/// everything else it handed out was gone for the life of the boot. That is a
/// clock on the machine, whatever leaks or does not.
///
/// `safety` off, because the safety this config buys is use-after-free
/// detection by NOT reusing a freed slot — which is the opposite of what a
/// server needs. The double-free check that matters is still there, one layer
/// down, where pages.zig panics rather than handing the same memory out twice.
var gpa: std.heap.DebugAllocator(.{
    .backing_allocator_zeroes = false,
    .stack_trace_frames = 0,
    .thread_safe = false,
    .safety = false,
    .page_size = pages.page_size,
}) = .{};

var blk_mem: virtio.BlockMemory align(4096) = .{};
/// The block device, for the per-request log: how many requests it served and
/// how long they took. Set once the device is up.
var disk: ?*virtio.Block = null;
var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var sector: [fat16.sector_size]u8 align(4096) = undefined;
var dhcp_frame: [net.buffer_size]u8 align(16) = undefined;
var dhcp_reply: [1024]u8 align(16) = undefined;
var tcp_out: [net.buffer_size]u8 align(16) = undefined;

/// **HOW MANY CONNECTIONS THE MACHINE HOLDS AT ONCE.** A chat tab holds three
/// open for as long as it is open, so this is about twenty tabs — a guess,
/// until the question of how many to size for is answered. Each connection
/// has its own receive buffer, taken from the machine's pages at boot.
const max_connections = 64;
const rx_bytes = 16 * 1024;
var conn_slots: [max_connections]tcp.Conn = undefined;

fn isn() u32 {
    return rng.int(u32);
}
var read_buf: [16 * 1024]u8 align(16) = undefined;
var write_buf: [64 * 1024]u8 align(16) = undefined;

/// Each request's heap, reset after the response: the equivalent of the arena
/// server.zig gives each request and frees wholesale. A bump allocator is the
/// right shape for it — nothing in a request outlives the request — and the
/// memory under it is asked for once, from the machine's pages, rather than
/// being a fixed array inside the kernel image.
const request_heap_bytes = 32 * 1024 * 1024;

const config_path = "gopher-metal.conf";

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal: angry-gopher's route table, with no Linux under it\n");

    // ── the machine's memory ────────────────────────────────────────────────
    // What RAM there is, where it is, and which of it this kernel is sitting
    // in. Everything below — the site's heap and each request's — comes out of
    // what is left, so this machine serves as much as it was booted with.
    const entries = metal.boot.memoryMap() catch |e| {
        serial.put("  memory map: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the loader described no memory, so there is nothing to serve from");
    };
    const image = metal.boot.image();
    const carved = pages.bring(pvh.largestFree(entries, image));
    if (carved.pages_total == 0) serial.fail("no usable region of RAM to serve from");
    serial.put("  ram: ");
    serial.putDec(pvh.totalRam(entries));
    serial.put(" bytes, kernel image ");
    serial.putDec(image.len);
    serial.put(", heap ");
    serial.putDec(carved.bytes_total);
    serial.put(" in ");
    serial.putDec(carved.pages_total);
    serial.put(" pages\n");

    // ── the volume. This host serves from it, so no disk is a failure. ──────
    const blk_base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no disk: this kernel serves the site from a FAT16 volume");
    var blk = blk_mem.bring(blk_base) catch serial.fail("the block device would not come up");
    disk = &blk;
    const part = gpt.firstPartition(&blk, &sector) catch
        serial.fail("the disk has no GPT partition to serve from");
    var vol = fat16.Volume.mount(&blk, &sector, part.first_lba) catch
        serial.fail("the first partition is not FAT16");
    // The FAT, in memory: without it every lookup is a device read, and the
    // free-cluster search re-reads its way past every cluster in use on each
    // small file the application replaces.
    const fat_cache = pages.allocator.alloc(u8, vol.fatBytes()) catch
        serial.fail("no memory to hold the FAT");
    vol.cacheFat(fat_cache) catch |e| {
        serial.put("  fat cache: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the FAT could not be held in memory");
    };
    Io.mount(vol);
    serial.put("  volume mounted at LBA ");
    serial.putDec(part.first_lba);
    serial.put(", FAT held in memory (");
    serial.putDec(vol.fatBytes());
    serial.put(" bytes)\n");

    const clock = metal.wallclock.start() catch |e| {
        serial.put("  wallclock: ");
        serial.put(@errorName(e));
        const m = metal.rtc.last_miss;
        serial.put(" (rtc: ");
        serial.putDec(m.polls);
        serial.put(" polls, ");
        serial.putDec(m.updating);
        serial.put(" mid-update, seconds ");
        serial.putDec(m.first_seconds);
        serial.put(" -> ");
        serial.putDec(m.last_seconds);
        serial.put(")\n");
        serial.fail("the clocks would not come up");
    };
    serial.put("  clock: TSC at ");
    serial.putDec(clock.tsc_hz);
    serial.put(" Hz, wall clock ");
    serial.putDec(@intCast(clock.unix));
    serial.put("\n");
    const io = Io.io();

    // ── the host contract ───────────────────────────────────────────────────
    const base = router.mem_meter.init(gpa.allocator());
    router.roots.point(base, .{ .data_dir = "data", .auth_dir = "auth" }) catch
        serial.fail("roots.point could not allocate the store paths");
    var hub = Hub.init(io, base);

    const conf = readConfig(io, base);
    const limit = conf.requests;
    serial.put("  a connection may say nothing for ");
    serial.putDec(conf.read_ns / std.time.ns_per_ms);
    serial.put(" ms\n");
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

    const rx_all = pages.allocator.alloc(u8, max_connections * rx_bytes) catch
        serial.fail("the machine has not enough memory for its connections");
    for (&conn_slots, 0..) |*c, k| c.* = .{ .rx = rx_all[k * rx_bytes ..][0..rx_bytes] };
    var table = tcp.Table.init(lease.address, nic.mac, 80, &conn_slots, &tcp_out, isn);
    serial.put("  holding up to ");
    serial.putDec(max_connections);
    serial.put(" connections at once\n");

    const request_heap = pages.allocator.alloc(u8, request_heap_bytes) catch
        serial.fail("the machine has not enough memory for a request heap");
    var request_fba = std.heap.FixedBufferAllocator.init(request_heap);

    // ── the loop: talk to the network, serve whatever is ready ──────────────
    //
    // **MANY CONNECTIONS, ONE REQUEST AT A TIME.** Every turn, the oldest
    // connection whose whole request head has arrived is served, start to
    // finish. One that has been quiet for `read_timeout_ms` without sending a
    // head is let go. Otherwise the network is polled, which moves every
    // connection along at once — so a client that connects and says nothing
    // waits in the table instead of holding the door.
    var served: u64 = 0;
    var deepest: usize = 0;
    var busiest: usize = 0;
    while (limit == null or served < limit.?) {
        busiest = @max(busiest, table.inUse());
        const now = Io.awakeNs() orelse 0;
        if (nextReady(&table)) |pick| {
            served += 1;
            serveOne(io, &nic, &table, pick, lease.address, request_fba.allocator(), &hub, served, conf.read_ns);
        } else if (quiet(&table, now, conf.read_ns)) |pick| {
            served += 1;
            letGo(&nic, &table, pick, lease.address, served);
        } else {
            if (stream.pump(&nic, &table, lease.address) == null) asm volatile ("pause");
            continue;
        }
        // What this request used of its heap, BEFORE the reset: the same
        // request must use the same amount every time, and a heap that was not
        // reset would show up as a number that only grows.
        serial.put("    request heap: ");
        serial.putDec(request_fba.end_index);
        serial.put(" bytes\n");
        request_fba.reset();
        deepest = reportStack(deepest);
    }

    serial.put("  connections: at most ");
    serial.putDec(busiest);
    serial.put(" at once, ");
    serial.putDec(table.refused);
    serial.put(" turned away for want of a slot\n");
    const mem = router.mem_meter.snapshot();
    const page_stats = pages.stats();
    serial.put("  pages: ");
    serial.putDec(page_stats.bytes_taken);
    serial.put(" bytes held of ");
    serial.putDec(page_stats.bytes_total);
    serial.put(", peak ");
    serial.putDec(page_stats.pages_high_water * pages.page_size);
    serial.put("\n  served ");
    serial.putDec(served);
    serial.put(" request(s); base heap holds ");
    serial.putDec(mem.live_bytes);
    serial.put(" live bytes in ");
    serial.putDec(mem.live_allocs);
    serial.put(" allocations\n");
    serial.put("  stack high water: ");
    serial.putDec(deepest);
    serial.put(" of ");
    serial.putDec(stack.size);
    serial.put(" bytes\n");
    serial.pass();
}

/// The oldest connection with something to serve, or null.
fn nextReady(table: *tcp.Table) ?usize {
    var best: ?usize = null;
    for (table.conns, 0..) |*c, i| {
        if (c.claimed or c.state != .established) continue;
        if (ready.check(c.pending(), c.peer_done) == .waiting) continue;
        if (best == null or c.serial < table.conns[best.?].serial) best = i;
    }
    return best;
}

/// The oldest connection that has gone quiet for `read_ns` without sending a
/// whole request, or null.
fn quiet(table: *tcp.Table, now: i96, read_ns: u64) ?usize {
    var best: ?usize = null;
    for (table.conns, 0..) |*c, i| {
        if (c.claimed or !c.open()) continue;
        if (now - c.heard_at < read_ns) continue;
        if (best == null or c.serial < table.conns[best.?].serial) best = i;
    }
    return best;
}

/// **A CLIENT THAT STOPPED TALKING IS NOT A BROKEN NIC.** It is logged as a
/// request that never came, the way it always has been, and closed.
fn letGo(nic: *net.Net, table: *tcp.Table, i: usize, address: [4]u8, number: u64) void {
    table.claim(i);
    defer table.release(i);
    var s = stream.Stream.init(nic, table, i, address, &read_buf, &write_buf);
    logRequest(number, "(no request)", "the client stopped sending, and was let go");
    close(&s, table, i);
}

/// Answers the request waiting on connection `i`, and closes it. Every failure
/// short of a panic is logged and survived.
fn serveOne(
    io: Io,
    nic: *net.Net,
    table: *tcp.Table,
    i: usize,
    address: [4]u8,
    request_alloc: std.mem.Allocator,
    hub: *Hub,
    number: u64,
    read_ns: u64,
) void {
    table.claim(i);
    defer table.release(i);
    var s = stream.Stream.init(nic, table, i, address, &read_buf, &write_buf);
    s.read_ns = read_ns;

    // **WHAT THIS MACHINE'S OWN CLOCK SAYS EACH REQUEST COST.** How long the
    // connection had been open before its turn came — the client finishing
    // its request, and then the queue — and how long the route table took to
    // answer. Timing from outside measures curl, slirp and the emulator too.
    const opened_at = table.conns[i].opened_at;

    var server = std.http.Server.init(s.reader(), s.writer());
    var req = server.receiveHead() catch |e| {
        logRequest(number, "(no request)", if (s.timed_out)
            "the client stopped sending, and was let go"
        else
            @errorName(e));
        close(&s, table, i);
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

    const head_at = Io.awakeNs() orelse 0;
    const disk_requests = if (disk) |d| d.requests else 0;
    const disk_ticks = if (disk) |d| d.busy_ticks else 0;

    var outcome: []const u8 = "ok";
    var bus = Bus.of(hub);
    router.route(&req, io, request_alloc, &bus) catch |e| {
        outcome = @errorName(e);
    };
    if (bus.kept) |kept| {
        // **NOT YET SERVED HERE.** The handler has written the stream's head
        // and backlog and handed the live part over; this machine has no
        // stream table yet, so it ends the stream and closes the connection.
        // The browser reconnects and resumes from its last event.
        streams.drop(hub, kept);
        outcome = "a stream, ended after its backlog (streams are not kept on this machine yet)";
    }
    s.writer().flush() catch {
        outcome = "the response would not flush";
    };
    const done_at = Io.awakeNs() orelse 0;
    logRequest(number, what, outcome);
    serial.put("    waited ");
    serial.putDec(@intCast(@divTrunc(head_at - opened_at, 1000)));
    serial.put(" us, answered in ");
    serial.putDec(@intCast(@divTrunc(done_at - head_at, 1000)));
    serial.put(" us, ");
    if (disk) |d| {
        serial.putDec(d.requests - disk_requests);
        serial.put(" disk requests taking ");
        serial.putDec(@intCast(@divTrunc(Io.ticksToNs(d.busy_ticks -% disk_ticks), 1000)));
        serial.put(" us\n");
    } else serial.put("no disk\n");
    close(&s, table, i);
}

/// How deep the calls have gone, said out loud the first time each new depth is
/// reached: a request that needs more stack than every request before it is
/// worth a line, and one that needs no more is not.
///
/// **A BREACHED GUARD STOPS THE MACHINE.** Past the end of the stack is `.bss`
/// -- the heaps, the virtqueues, the volume's sector buffer -- so a frame that
/// runs off the end corrupts whatever it lands on and the machine carries on
/// lying. This is the one place that can still be said clearly.
fn reportStack(deepest: usize) usize {
    const u = stack.usage();
    if (u.guard_breached) {
        serial.put("    stack: ");
        serial.putDec(u.used);
        serial.put(" of ");
        serial.putDec(u.size);
        serial.put(" bytes used\n");
        serial.fail("the stack guard was written: the next call would corrupt .bss");
    }
    if (u.used <= deepest) return deepest;
    serial.put("    stack high water: ");
    serial.putDec(u.used);
    serial.put(" of ");
    serial.putDec(u.size);
    serial.put(" bytes\n");
    return u.used;
}

fn close(s: *stream.Stream, table: *tcp.Table, i: usize) void {
    s.finish();
    // A peer that never acknowledged our FIN would otherwise hold its slot in
    // `closing` for good.
    if (table.conns[i].state != .closed) table.abandon(i);
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
    serial.put(" live bytes, ");
    serial.putDec(pages.stats().bytes_taken);
    serial.put(" in pages, peak ");
    serial.putDec(pages.stats().pages_high_water * pages.page_size);
    serial.put(")\n");
}

/// **HOST CONFIGURATION, FROM THE VOLUME.** What a Linux host would read from
/// a config file or the environment, this reads from `gopher-metal.conf` on the
/// disk it serves — the two things that are about this machine rather than
/// about the site:
///
///     requests = N            serve N and stop; absent, serve until stopped
///     read_timeout_ms = N     how long a connection may say nothing
///
/// A key that is not one of those is a misconfiguration, and stops the machine
/// rather than being ignored: a timeout that was silently not applied is how a
/// server ends up held open by one client.
const Config = struct {
    requests: ?u64 = null,
    read_ns: u64 = stream.default_read_ns,
};

fn readConfig(io: Io, alloc: std.mem.Allocator) Config {
    var conf = Config{};
    const text = Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .limited(4096)) catch return conf;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var said_anything = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        said_anything = true;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse
            serial.fail(config_path ++ ": a line with no `=`");
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "requests")) {
            conf.requests = std.fmt.parseInt(u64, value, 10) catch
                serial.fail(config_path ++ ": `requests` is not a number");
        } else if (std.mem.eql(u8, key, "read_timeout_ms")) {
            const ms = std.fmt.parseInt(u64, value, 10) catch
                serial.fail(config_path ++ ": `read_timeout_ms` is not a number");
            if (ms == 0) serial.fail(config_path ++ ": a read timeout of zero would answer nobody");
            conf.read_ns = ms * std.time.ns_per_ms;
        } else {
            serial.fail(config_path ++ ": the keys are `requests` and `read_timeout_ms`");
        }
    }
    if (!said_anything) serial.fail(config_path ++ " is present but says nothing");
    return conf;
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
