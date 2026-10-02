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
//!   2. roots.point(base, …)   data/ and auth/, on the DigitalOcean volume if one is attached
//!   3. a Hub over base        each request gets a Bus handle on it
//!   4. store.backfillAll(…)   every chat session's last-message record, once
//!   5. serve what was kept    a table of held streams, drained every turn
//!
//! Its clocks come from its own hardware (wallclock.zig).
//!
//! **IT HOLDS MANY CONNECTIONS AND SERVES ONE REQUEST AT A TIME, IN A LOOP**:
//! a connection whose request has arrived is answered start to finish; the
//! rest wait in the table meanwhile, and the network keeps moving for all of
//! them. Each request gets its own heap, reset afterwards, the
//! way server.zig gives each request an arena it frees wholesale. How many
//! requests to serve is host configuration, read from `gopher-metal.conf` on
//! the boot disk (`requests = N`); without it, forever.
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
const scsi = metal.scsi;
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
const RequestHeap = metal.request_heap.RequestHeap;
const interrupts = metal.interrupts;
const gm_build = @import("gm_build");

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
var volume_mem: virtio.BlockMemory align(4096) = .{};
/// The disks, for the per-request log: how many requests they served and how
/// long they took. The boot disk, then the volume if one is attached.
var disks: [2]?*virtio.Block = .{ null, null };
var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var sector: [fat16.sector_size]u8 align(4096) = undefined;
var volume_sector: [fat16.sector_size]u8 align(4096) = undefined;
var dhcp_frame: [net.buffer_size]u8 align(16) = undefined;
var dhcp_reply: [1024]u8 align(16) = undefined;
var tcp_out: [net.buffer_size]u8 align(16) = undefined;

/// **HOW MANY CONNECTIONS THE MACHINE HOLDS AT ONCE.** A chat tab holds three
/// or four open for as long as it is open, so this is room for about sixty
/// tabs — more than chat has ever had, on purpose. Each connection has its own
/// receive buffer and send queue, taken from the machine's pages at boot:
/// about 20 MB for all of them.
const max_connections = 256;
const rx_bytes = 16 * 1024;
/// A send queue holds what the peer has not yet acknowledged. A response
/// larger than this waits for acknowledgements as it goes; a held stream whose
/// next frames do not fit is a client that is not keeping up.
const tx_bytes = 64 * 1024;
var conn_slots: [max_connections]tcp.Conn = undefined;

fn isn() u32 {
    return rng.int(u32);
}

/// **THE STREAMS THIS MACHINE KEEPS.** A request that kept a stream leaves its
/// connection open and claimed, and the stream lives here, indexed by that
/// connection — so there is always room, and no search. Every turn of the loop
/// drains each one's mailbox and writes what arrived; one that has been quiet
/// for the application's keepalive gets a ping; one whose client has gone is
/// ended. That is the whole of "iterating through the open sessions".
const Held = struct {
    conn: usize,
    kept: streams.Kept,
    last_write: i96,
    /// **THE REST OF A FRAME THE SEND QUEUE HAD NO ROOM FOR**, on the base heap,
    /// and how much of it has been queued. While it is here no further event
    /// is taken: they wait in the stream's mailbox.
    carry: []u8 = &.{},
    carry_at: usize = 0,
    /// Since when the carry has not moved, and where the peer's
    /// acknowledgements stood then: a stream stuck for the idle time is a
    /// client that is not keeping up.
    stuck_since: ?i96 = null,
    stuck_una: u32 = 0,
};
var held: [max_connections]?Held = @splat(null);
var held_now: usize = 0;
var held_most: usize = 0;
var streams_ended: u64 = 0;
/// For /admin/host as well as the closing log: requests served, and the
/// connections open now and at most.
var served: u64 = 0;
var open_now: usize = 0;
var busiest: usize = 0;
/// When this boot's wall clock started, and the TSC's measured rate.
var booted_unix: i64 = 0;
var tsc_hz_seen: u64 = 0;
var read_buf: [16 * 1024]u8 align(16) = undefined;
var write_buf: [64 * 1024]u8 align(16) = undefined;

/// Each request's heap, reset after the response: the equivalent of the arena
/// server.zig gives each request and frees wholesale. A bump allocator is the
/// right shape for it — nothing in a request outlives the request — and the
/// memory under it is asked for once, from the machine's pages, rather than
/// being a fixed array inside the kernel image.
const request_heap_bytes = 32 * 1024 * 1024;

const config_path = "gopher-metal.conf";

/// **THE APPLICATION'S DATA**: the two directories `router.roots.point` is
/// given, and the only ones this machine writes. On a droplet they are on the
/// volume, which outlives every new image; everything else is the site's own,
/// on the boot disk, and comes with the image.
const data_dir = "data";
const auth_dir = "auth";
const data_dirs = [_][]const u8{ data_dir, auth_dir };

pub fn kmain() noreturn {
    serial.init();
    interrupts.install();
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
    // With the restart built in, the kept log's region past the image is
    // reserved too, so the page allocator never hands it out.
    const carved = pages.bring(pvh.largestFree(entries, if (gm_build.restart) metal.restarting.reserved() else image));
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

    // ── the disks ───────────────────────────────────────────────────────────
    // The boot disk holds the site and this machine's settings, and no boot
    // disk is a failure. The settings say whether the application's data is
    // on a volume, and which one (`volume = 92DE-8831`); without that line a
    // volume is used if one is attached, and the boot disk otherwise.
    var boot_disk = bootDisk();
    disks[0] = &boot_disk;
    Io.mount(mountFat(&boot_disk, &sector, "the boot disk"));
    const io = Io.io();
    const base = router.mem_meter.init(gpa.allocator());
    const conf = readConfig(io, base);
    var volume_disk: virtio.Block = undefined;
    if (dataVolume()) |b| {
        volume_disk = b;
        disks[1] = &volume_disk;
        const vol = mountFat(&volume_disk, &volume_sector, "the volume");
        serial.put("  its serial: ");
        putSerial(vol.serial);
        serial.put("\n");
        if (conf.volume) |want| if (vol.serial != want) {
            serial.put("  " ++ config_path ++ " names volume ");
            putSerial(want);
            serial.put("\n");
            serial.fail("the volume attached is not the one this machine serves");
        };
        Io.keepData(&data_dirs, vol);
        serial.put("  chat's data: the volume\n");
    } else {
        // **A VOLUME THAT WAS NAMED AND IS MISSING STOPS THE MACHINE.** Serving
        // on would answer with no accounts and no conversations, and keep what
        // was written meanwhile on the boot disk, which the next image erases.
        if (conf.volume) |want| {
            serial.put("  " ++ config_path ++ " names volume ");
            putSerial(want);
            serial.put("\n");
            serial.fail("the volume this machine serves is not attached");
        }
        Io.keepData(&data_dirs, null);
        serial.put("  chat's data: the boot disk\n");
    }

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
    booted_unix = @intCast(clock.unix);
    tsc_hz_seen = clock.tsc_hz;

    // ── the restart (RESTART.md), only with -Drestart ───────────────────────
    if (gm_build.restart) {
        const restarted = metal.restarting.begin(wallNow);
        if (restarted.wait_seconds > 0) waitSeconds(restarted.wait_seconds);
    }

    // ── the host contract ───────────────────────────────────────────────────
    router.host_status.provide(metalFacts);
    router.roots.point(base, .{ .data_dir = data_dir, .auth_dir = auth_dir }) catch
        serial.fail("roots.point could not allocate the store paths");
    var hub = Hub.init(io, base);

    const limit = conf.requests;
    serial.put("  a connection may make no progress for ");
    serial.putDec(conf.idle_ns / std.time.ns_per_ms);
    serial.put(" ms\n");
    if (limit) |n| {
        serial.put("  serving ");
        serial.putDec(n);
        serial.put(" request(s), as " ++ config_path ++ " says\n");
    } else serial.put("  serving until stopped\n");

    // ── the network ─────────────────────────────────────────────────────────
    rng.attach(&rng_mem);
    const nic_base = virtio.findNth(virtio.device_id_net, @intFromEnum(conf.card)) orelse switch (conf.card) {
        .public => serial.fail("no virtio-net device on the PCI bus or in any mmio slot"),
        .private => serial.fail("`card = private`, and this machine has no second network card"),
    };
    serial.put("  network: the ");
    serial.put(@tagName(conf.card));
    serial.put(" card\n");
    var nic = net.Net.init(nic_base, &nic_mem) catch serial.fail("the NIC would not come up");
    const lease = dhcp.acquire(&nic, &dhcp_frame, &dhcp_reply) catch
        serial.fail("no DHCP lease, so there is no address to listen on");
    restBetweenFrames(&nic, clock.tsc_hz);
    serial.put("  address: ");
    serial.putIp(lease.address);
    serial.put("\n  listening on port 80\n");

    const rx_all = pages.allocator.alloc(u8, max_connections * rx_bytes) catch
        serial.fail("the machine has not enough memory for its connections");
    const tx_all = pages.allocator.alloc(u8, max_connections * tx_bytes) catch
        serial.fail("the machine has not enough memory for its connections");
    for (&conn_slots, 0..) |*c, k| c.* = .{
        .rx = rx_all[k * rx_bytes ..][0..rx_bytes],
        .tx = tx_all[k * tx_bytes ..][0..tx_bytes],
    };
    var table = tcp.Table.init(lease.address, nic.mac, 80, &conn_slots, &tcp_out, isn);
    var wire = stream.Wire{ .nic = &nic, .lose_one_sent_in = conf.lose_one_sent_in };
    if (conf.lose_one_sent_in != 0) {
        serial.put("  losing one TCP frame in ");
        serial.putDec(conf.lose_one_sent_in);
        serial.put(" of those sent, as " ++ config_path ++ " says\n");
    }
    serial.put("  holding up to ");
    serial.putDec(max_connections);
    serial.put(" connections at once\n");

    var request_heap = RequestHeap.init(pages.allocator, request_heap_bytes);
    if (!request_heap.preheat())
        serial.fail("the machine has not enough memory for a request heap");
    // **THE HOST CONTRACT'S FOURTH STEP**, and the machine does it as Linux
    // does: every chat session gets its last-message record before the first
    // request, so /chat/recent never reads a transcript in full — and so the
    // two hosts leave the same files behind, which the judge compares. It runs
    // on a request's heap because that is what it is: one pass, then given
    // back.
    {
        const wrote = router.store.backfillAll(io, request_heap.allocator());
        request_heap.reset();
        if (wrote > 0) {
            serial.put("  wrote a last-message record for ");
            serial.putDec(wrote);
            serial.put(" chat session(s)\n");
        }
    }
    const scratch_heap = pages.allocator.alloc(u8, stream_scratch_bytes) catch
        serial.fail("the machine has not enough memory for its streams' scratch");
    stream_scratch = std.heap.FixedBufferAllocator.init(scratch_heap);
    turning = .{ .wire = &wire, .table = &table, .hub = &hub, .conf = conf };
    stream.after_arrivals = streamTurn;

    // From here a fatal error is a failure while serving: with the restart
    // built in, it restarts the machine (RESTART.md).
    if (gm_build.restart) metal.restarting.serving();

    // ── the loop: talk to the network, serve whatever is ready ──────────────
    //
    // **MANY CONNECTIONS, ONE REQUEST AT A TIME.** Every turn moves the
    // network — every connection, and every held stream — and then serves at
    // most one thing: the oldest connection whose whole request head has
    // arrived, start to finish, or else the oldest one that has been quiet for
    // `idle_timeout_ms`, which is let go. A client that connects and says
    // nothing waits in the table instead of holding the door.
    //
    // **WHAT WAITS FOR THIS LOOP, AND WHAT BOUNDS THE WAIT** (TCP_TESTING.md
    // §2). The loop serves one thing at a time, so every row below is bounded
    // only as long as no single serve waits without a bound of its own.
    //
    // - **A connection whose request has arrived.** Served when it is the
    //   oldest ready. Bounded by: every older ready request's serve, plus the
    //   one in progress. A serve's waits are each bounded by `idle_ns`
    //   without progress (stream.zig); its close queues a FIN and does not
    //   wait — the table finishes it.
    // - **A connection that has gone quiet.** Let go once it has been silent
    //   for `idle_ns`, and only on a turn with nothing ready: a steady run of
    //   ready requests delays it, at the cost of a slot, never of an answer.
    //   Bounded by: `idle_ns`, plus the serves ahead of it.
    // - **A held stream's frames and pings.** Moved by every turn of the
    //   network, the turns inside a serve included (`stream.after_arrivals`).
    //   Bounded by: the next turn — which a serve doing disk work holds back.
    // - **A connection served and closing.** The table's timers.
    // - **The loop itself, with nothing to do.** It rests only when nothing
    //   arrived, nothing was ready and nothing was quiet. Bounded by: the
    //   card's interrupt, or `interrupts.slice_ns`.
    // - **The goodbyes, when the boot ends.** Connections still closing are
    //   given two seconds of turns, then the machine stops.
    var deepest: usize = 0;
    while (limit == null or served < limit.?) {
        open_now = table.inUse();
        busiest = @max(busiest, open_now);
        const arrived = stream.pump(&wire, &table, lease.address);
        const now = Io.awakeNs() orelse 0;
        if (nextReady(&table)) |pick| {
            served += 1;
            serveOne(io, &wire, &table, pick, lease.address, request_heap.allocator(), &hub, served, conf.idle_ns, conf.streams);
        } else if (quiet(&table, now, conf.idle_ns)) |pick| {
            served += 1;
            letGo(&wire, &table, pick, served);
        } else {
            if (arrived == null) interrupts.rest();
            continue;
        }
        // What this request used of its heap, BEFORE the reset: the same
        // request must use the same amount every time, and a heap that was not
        // reset would show up as a number that only grows.
        serial.put("    request heap: ");
        serial.putDec(request_heap.used);
        serial.put(" bytes\n");
        request_heap.reset();
        deepest = reportStack(deepest);
    }

    // The boot is over: every stream still held ends with it, and the
    // goodbyes are given a moment to be acknowledged.
    stream.after_arrivals = null;
    for (&held) |*slot| {
        if (slot.* != null) endStream(slot, &wire, &table, &hub, .stopping);
    }
    const stopping_at = Io.awakeNs() orelse 0;
    while (closing(&table) and (Io.awakeNs() orelse 0) - stopping_at < 2 * std.time.ns_per_s) {
        if (stream.pump(&wire, &table, lease.address) == null) interrupts.rest();
    }
    serial.put("  streams: at most ");
    serial.putDec(held_most);
    serial.put(" held at once, ");
    serial.putDec(streams_ended);
    serial.put(" ended, ");
    // Every stream has been ended, so every subscriber should be gone: one
    // left behind is a stream that was never dropped.
    serial.putDec(hub.entries.items.len);
    serial.put(" still subscribed\n");

    serial.put("  connections: at most ");
    serial.putDec(busiest);
    serial.put(" at once, ");
    serial.putDec(table.refused);
    serial.put(" turned away for want of a slot\n");
    serial.put("  tcp: ");
    serial.putDec(table.retransmits);
    serial.put(" timeouts sent something again, ");
    serial.putDec(table.probes);
    serial.put(" window probes, ");
    serial.putDec(table.given_up);
    serial.put(" peers given up on, ");
    serial.putDec(table.fin_waits_expired);
    serial.put(" never finished, ");
    serial.putDec(table.strays);
    serial.put(" strays reset, ");
    serial.putDec(wire.lost);
    serial.put(" frames lost on purpose, ");
    serial.putDec(table.window_updates);
    serial.put(" reopened windows said again\n");
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
        if (ready.check(c.pending(), c.peer_done, c.rx.len) == .waiting) continue;
        if (best == null or c.serial < table.conns[best.?].serial) best = i;
    }
    return best;
}

/// The oldest connection that has gone quiet for `idle_ns` without sending a
/// whole request, or null.
fn quiet(table: *tcp.Table, now: i96, idle_ns: u64) ?usize {
    var best: ?usize = null;
    for (table.conns, 0..) |*c, i| {
        if (c.claimed or !c.open()) continue;
        if (now - c.heard_at < idle_ns) continue;
        if (best == null or c.serial < table.conns[best.?].serial) best = i;
    }
    return best;
}

/// **A CLIENT THAT STOPPED TALKING IS NOT A BROKEN NIC.** It is logged as a
/// request that never came, the way it always has been, and closed.
fn letGo(wire: *stream.Wire, table: *tcp.Table, i: usize, number: u64) void {
    logRequest(number, "(no request)", "the client stopped sending, and was let go");
    close(wire, table, i);
}

/// Answers the request waiting on connection `i`, and closes it. Every failure
/// short of a panic is logged and survived.
fn serveOne(
    io: Io,
    wire: *stream.Wire,
    table: *tcp.Table,
    i: usize,
    address: [4]u8,
    request_alloc: std.mem.Allocator,
    hub: *Hub,
    number: u64,
    idle_ns: u64,
    max_streams: usize,
) void {
    table.claim(i);
    // A connection that now carries a kept stream stays claimed and open.
    var kept_open = false;
    defer if (!kept_open) table.release(i);
    var s = stream.Stream.init(wire, table, i, address, &read_buf, &write_buf);
    s.idle_ns = idle_ns;

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
        close(wire, table, i);
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
    const disk_before = diskWork();

    var outcome: []const u8 = "ok";
    var bus = Bus.of(hub);
    router.route(&req, io, request_alloc, &bus) catch |e| {
        outcome = @errorName(e);
    };
    // **THE HEAD AND BACKLOG GO FIRST.** Every turn of the network may service
    // the held streams, and this flush takes turns: a stream registered before
    // it would have its live frames queued ahead of its own head.
    const flushed = if (s.writer().flush()) |_| true else |_| false;
    if (!flushed) outcome = "the response would not flush";
    if (bus.kept) |kept| if (!flushed) {
        streams.drop(hub, kept);
        bus.kept = null;
    };
    if (bus.kept) |kept| {
        // The handler wrote the stream's head and backlog; the live part is
        // this machine's now.
        // **THE BUDGET IS KEPT BY ENDING THE OLDEST.** A browser whose stream
        // ends reconnects, and a conversation stream resumes from its last
        // event; a new tab that could not open at all would not.
        if (held_now >= max_streams) {
            if (oldestHeld(table)) |slot| endStream(slot, wire, table, hub, .displaced);
        }
        held[i] = .{ .conn = i, .kept = kept, .last_write = Io.awakeNs() orelse 0 };
        held_now += 1;
        held_most = @max(held_most, held_now);
        kept_open = true;
        outcome = "ok, and its stream is kept";
    }
    // A write that timed out fails wherever it happened — inside the route or
    // in this flush — and is the same event either way.
    if (s.timed_out) outcome = "the client stopped taking the response";
    const done_at = Io.awakeNs() orelse 0;
    logRequest(number, what, outcome);
    serial.put("    waited ");
    serial.putDec(@intCast(@divTrunc(head_at - opened_at, 1000)));
    serial.put(" us, answered in ");
    serial.putDec(@intCast(@divTrunc(done_at - head_at, 1000)));
    serial.put(" us, ");
    const disk_after = diskWork();
    serial.putDec(disk_after.requests - disk_before.requests);
    serial.put(" disk requests taking ");
    serial.putDec(@intCast(@divTrunc(Io.ticksToNs(disk_after.ticks -% disk_before.ticks), 1000)));
    serial.put(" us\n");
    if (kept_open) return;
    // A client that stopped taking the response has had its idle time
    // already: it is reset rather than waited on again for a goodbye.
    if (s.timed_out) {
        table.abandon(wire, i);
    } else close(wire, table, i);
}

/// What a turn of the held streams needs, set once the network is up.
var turning: ?struct { wire: *stream.Wire, table: *tcp.Table, hub: *Hub, conf: Config } = null;
/// The streams' own scratch: a turn can come in the middle of a request, whose
/// heap is not the streams' to reset. Big enough for the largest frame chat
/// renders, several times over.
const stream_scratch_bytes = 4 * 1024 * 1024;
var stream_scratch: std.heap.FixedBufferAllocator = undefined;
var in_turn = false;

/// Called by every turn of the network (`stream.after_arrivals`). A turn does
/// not start another: ending a stream never waits, but it is simpler to know
/// that than to prove it each time.
fn streamTurn() void {
    const t = turning orelse return;
    if (in_turn) return;
    in_turn = true;
    defer in_turn = false;
    serviceStreams(t.wire, t.table, t.hub, stream_scratch.allocator(), Io.awakeNs() orelse 0, t.conf);
    stream_scratch.reset();
}

/// One pass over the held streams: end the ones whose client has gone, queue
/// what has arrived for the rest, ping the quiet ones. `scratch` holds the
/// rendered frames for this pass only.
///
/// **NOTHING HERE WAITS.** A frame goes into its connection's send queue as far
/// as there is room, and the rest is carried to the next turn. A stream whose
/// carry has not moved for the idle time is ended: its tab is not reading, and
/// its browser will reconnect and resume. So is one whose mailbox overflowed —
/// a stream with a gap in it is worse than one that starts again.
fn serviceStreams(wire: *stream.Wire, table: *tcp.Table, hub: *Hub, scratch: std.mem.Allocator, now: i96, conf: Config) void {
    for (&held) |*slot| {
        const h = if (slot.*) |*h| h else continue;
        const c = &table.conns[h.conn];
        if (!c.open() or c.peer_done) {
            endStream(slot, wire, table, hub, .client_left);
            continue;
        }
        var wrote = false;
        while (true) {
            if (h.carry_at < h.carry.len) {
                const n = table.queue(h.conn, h.carry[h.carry_at..]);
                h.carry_at += n;
                wrote = wrote or n > 0;
                if (h.carry_at < h.carry.len) break;
                hub.gpa.free(h.carry);
                h.carry = &.{};
                h.carry_at = 0;
            }
            const next = streams.nextFrame(h.kept, scratch) catch |e| {
                endStream(slot, wire, table, hub, if (e == error.EventsMissed) .missed_events else .no_room_to_render);
                break;
            };
            const frame = next orelse break;
            const n = table.queue(h.conn, frame);
            wrote = wrote or n > 0;
            if (n == frame.len) continue;
            h.carry = hub.gpa.dupe(u8, frame[n..]) catch {
                endStream(slot, wire, table, hub, .no_room_to_render);
                break;
            };
        }
        const still = if (slot.*) |*left| left else continue;
        if (wrote) still.last_write = now;
        if (still.carry.len == 0) {
            still.stuck_since = null;
            if (!wrote and now - still.last_write >= conf.keepalive_ns and c.queueRoom() >= streams.ping.len) {
                _ = table.queue(still.conn, streams.ping);
                still.last_write = now;
            }
            continue;
        }
        if (still.stuck_since == null or c.una != still.stuck_una or wrote) {
            still.stuck_since = now;
            still.stuck_una = c.una;
        } else if (now - still.stuck_since.? >= conf.idle_ns) {
            endStream(slot, wire, table, hub, .lagging);
        }
    }
}

/// Whether any connection is still saying goodbye.
fn closing(table: *tcp.Table) bool {
    for (table.conns) |c| {
        if (c.state == .closing) return true;
    }
    return false;
}

/// Why a stream ended, as the log says it.
const Ending = enum {
    client_left,
    no_room_to_render,
    /// Its client has not taken what it was sent. Such a stream is reset, not
    /// closed: a goodbye would queue behind everything the client is not
    /// reading.
    lagging,
    /// Its mailbox overflowed. Reset, like a lagging one.
    missed_events,
    displaced,
    stopping,

    fn why(self: Ending) []const u8 {
        return switch (self) {
            .client_left => "its client went away",
            .no_room_to_render => "there was no room to render it",
            .lagging => "its client is not keeping up",
            .missed_events => "it fell too far behind and missed events",
            .displaced => "to make room for a newer one",
            .stopping => "the machine is stopping",
        };
    }
};

fn oldestHeld(table: *tcp.Table) ?*?Held {
    var best: ?*?Held = null;
    for (&held) |*slot| {
        const h = slot.* orelse continue;
        if (best == null or table.conns[h.conn].serial < table.conns[best.?.*.?.conn].serial) best = slot;
    }
    return best;
}

/// Ends a held stream: its subscriber leaves the bus, its slot is free again,
/// and its connection is closed — without waiting. The FIN is queued behind
/// whatever the stream still had on its way, and the table finishes the close
/// on later turns (or gives up on a peer that stops answering); a closing
/// connection is not handed to anyone else meanwhile.
fn endStream(slot: *?Held, wire: *stream.Wire, table: *tcp.Table, hub: *Hub, ending: Ending) void {
    const h = slot.*.?;
    streams.drop(hub, h.kept);
    if (h.carry.len > 0) hub.gpa.free(h.carry);
    switch (ending) {
        .lagging, .missed_events => table.abandon(wire, h.conn),
        else => table.finish(h.conn),
    }
    table.release(h.conn);
    slot.* = null;
    held_now -= 1;
    streams_ended += 1;
    serial.put("  stream ended: ");
    serial.put(ending.why());
    serial.put("\n");
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

/// **SAYS GOODBYE WITHOUT WAITING FOR IT TO BE HEARD.** The FIN is queued
/// behind whatever the response still has on its way, and the table finishes
/// the close on later turns: it re-sends what is not acknowledged, waits
/// `fin_wait_ns` for the peer's own FIN, and resets a peer that stops
/// answering. A closing connection is not handed to anyone else meanwhile.
///
/// **WAITING HERE WOULD STOP THE MACHINE.** It answers one request at a time,
/// so a close that waited for the peer's acknowledgement held every other
/// ready request for as long as the peer said nothing — up to the idle time,
/// once per connection, and a client that has gone quiet is exactly the one
/// that says nothing. A handshake that never completed has no FIN to wait for
/// at all, and is reset.
///
/// The FIN goes on the wire now rather than on the next turn of the network,
/// which comes after the request's log is written.
fn close(wire: *stream.Wire, table: *tcp.Table, i: usize) void {
    table.finish(i);
    if (table.conns[i].state != .closing) return table.abandon(wire, i);
    table.transmit(wire, Io.awakeNs() orelse 0);
}

/// **A MACHINE WITH NOTHING TO DO HALTS**, once the network card can wake it.
/// Only a card on the PCI bus can: on mmio (QEMU's microvm, metal-vmm) nothing
/// is touched and every wait goes on spinning, as it always has.
fn restBetweenFrames(nic: *net.Net, tsc_hz: u64) void {
    if (nic.device != .pci) return;
    switch (interrupts.startApic()) {
        .refused => |why| {
            serial.put("  never resting: the local APIC refused (");
            serial.put(@tagName(why));
            serial.put(")\n");
        },
        .id => |apic| if (nic.interruptOnFrames(interrupts.msiAddress(apic), interrupts.wake_vector)) {
            interrupts.arm(tsc_hz);
            serial.put("  resting between frames: the card interrupts when one comes\n");
        } else serial.put("  never resting: the card would not take an MSI-X vector\n"),
    }
}

/// Every request the disks have served, and the time they took, so far.
fn diskWork() struct { requests: u64, ticks: u64 } {
    var requests: u64 = 0;
    var ticks: u64 = 0;
    for (disks) |d| if (d) |b| {
        requests += b.requests;
        ticks +%= b.busy_ticks;
    };
    return .{ .requests = requests, .ticks = ticks };
}

/// The disk the machine was booted from, which holds the site.
fn bootDisk() virtio.Block {
    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no disk: this kernel serves the site from a FAT16 volume");
    return blk_mem.bring(base) catch serial.fail("the block device would not come up");
}

/// **A DIGITALOCEAN VOLUME**, if one is attached: a disk on the SCSI
/// controller a droplet has whether or not one is, so finding no disk on it is
/// ordinary and said. A controller or a disk that will not work stops the
/// machine instead of quietly keeping the data on the boot disk, where the
/// next image would erase it.
fn dataVolume() ?virtio.Block {
    const controller = virtio.find(scsi.device_id) orelse return null;
    if (scsi.bring(controller, &volume_mem)) |b| {
        const at = b.address.?;
        serial.put("  a volume: SCSI target ");
        serial.putDec(at.target);
        serial.put(", LUN ");
        serial.putDec(at.lun);
        serial.put(", ");
        serial.putDec(b.capacity / 2048);
        serial.put(" MB\n");
        return b;
    } else |e| switch (e) {
        error.NoDisk => {
            serial.put("  no volume attached\n");
            return null;
        },
        else => {
            serial.put("  the SCSI controller: ");
            serial.put(@errorName(e));
            serial.put("\n");
            serial.fail("the volume controller or its disk would not come up");
        },
    }
}

/// The FAT16 filesystem in `blk`'s first data partition, with its FAT held in
/// memory: without that every lookup is a device read, and the free-cluster
/// search re-reads its way past every cluster in use on each small file the
/// application replaces.
fn mountFat(blk: *virtio.Block, scratch: *[fat16.sector_size]u8, what: []const u8) fat16.Volume {
    const part = gpt.dataPartition(blk, scratch) catch {
        serial.put("  ");
        serial.put(what);
        serial.put(": no GPT partition\n");
        serial.fail("a disk has no partition to serve from");
    };
    var vol = fat16.Volume.mount(blk, scratch, part.first_lba) catch {
        serial.put("  ");
        serial.put(what);
        serial.put(": its first partition is not FAT16\n");
        serial.fail("a disk's partition is not FAT16");
    };
    const fat_cache = pages.allocator.alloc(u8, vol.fatBytes()) catch
        serial.fail("no memory to hold the FAT");
    vol.cacheFat(fat_cache) catch |e| {
        serial.put("  fat cache: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the FAT could not be held in memory");
    };
    serial.put("  ");
    serial.put(what);
    serial.put(": FAT16 at LBA ");
    serial.putDec(part.first_lba);
    serial.put(", FAT held in memory (");
    serial.putDec(vol.fatBytes());
    serial.put(" bytes)\n");
    diskCheck(&vol, what);
    return vol;
}

/// **THE DISK CHECK, AT EVERY MOUNT** (`fat16.Volume.check`, QUEUE.md item
/// 13): one summary line per volume, then each finding. It reports and never
/// halts, and it writes nothing: a damaged volume still boots and serves, and
/// the log says what to look at with fsck.vfat on a copy. The judges read the
/// summary line on every boot (probe/judge_gopher.py, `disk_check_lines`).
///
/// It runs after `cacheFat`, so following a chain is a memory read; the walk
/// reads each directory sector once.
fn diskCheck(vol: *fat16.Volume, what: []const u8) void {
    serial.put("  disk check, ");
    serial.put(what);
    serial.put(": ");
    const seen = pages.allocator.alloc(u8, vol.checkBytes()) catch {
        serial.put("not run: no memory for its map of the clusters\n");
        return;
    };
    defer pages.allocator.free(seen);
    const Shown = struct {
        /// More findings than this are counted, not printed: a volume with
        /// thousands of leaked runs must not bury the rest of the boot.
        const most = 20;
        held: [most]fat16.Finding = undefined,
        paths: [most][256]u8 = undefined,
        n: u32 = 0,
        fn each(self: *@This(), f: fat16.Finding) void {
            if (self.n < most) {
                const len = @min(f.path.len, self.paths[self.n].len);
                @memcpy(self.paths[self.n][0..len], f.path[0..len]);
                self.held[self.n] = f;
                self.held[self.n].path = self.paths[self.n][0..len];
            }
            self.n += 1;
        }
    };
    var shown: Shown = .{};
    const h = vol.check(seen, &shown, Shown.each) catch |e| {
        serial.put("not run: ");
        serial.put(@errorName(e));
        serial.put("\n");
        return;
    };
    serial.putDec(h.files);
    serial.put(" files, ");
    serial.putDec(h.directories);
    serial.put(" directories, ");
    serial.putDec(h.used);
    serial.put(" clusters used, ");
    serial.putDec(h.leaked);
    serial.put(" leaked, ");
    serial.putDec(h.problems);
    serial.put(" problems\n");
    for (shown.held[0..@min(shown.n, Shown.most)]) |f| {
        serial.put("    ");
        serial.put(@tagName(f.problem));
        serial.put(" at ");
        serial.put(if (f.path.len > 0) f.path else "(the volume)");
        serial.put(", cluster ");
        serial.putDec(f.cluster);
        if (f.count != 0) {
            serial.put(", count ");
            serial.putDec(f.count);
        }
        serial.put("\n");
    }
    if (shown.n > Shown.most) {
        serial.put("    and ");
        serial.putDec(shown.n - Shown.most);
        serial.put(" more\n");
    }
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

/// **HOST CONFIGURATION, FROM THE BOOT DISK.** What a Linux host would read from
/// a config file or the environment, this reads from `gopher-metal.conf` on the
/// boot disk, which comes with each image — the things that are about this
/// machine rather than about the site:
///
///     requests = N            serve N and stop; absent, serve until stopped
///     idle_timeout_ms = N     how long a connection may make no progress
///     streams = N             how many live streams may be held at once
///     keepalive_ms = N        how long a stream may be quiet before a ping;
///                             absent, the application's own keepalive
///     lose_one_sent_in = N    lose every Nth TCP frame sent, to prove that
///                             what is lost is sent again
///     card = public|private   which network card to serve on: the first
///                             (public, the default) or the second (private).
///                             A droplet's are public then private in PCI slot
///                             order; chat there belongs on the private one,
///                             behind prod's Caddy.
///     volume = 92DE-8831      the FAT serial (as `blkid` shows it) of the
///                             DigitalOcean volume the application's data is
///                             on. Set, that volume must be attached or the
///                             machine stops; absent, any volume is used, or
///                             the boot disk when there is none.
///
/// A key that is not one of those is a misconfiguration, and stops the machine
/// rather than being ignored: a timeout that was silently not applied is how a
/// server ends up held open by one client.
const Config = struct {
    requests: ?u64 = null,
    idle_ns: u64 = stream.default_idle_ns,
    keepalive_ns: u64 = streams.Subscriber.keepalive_s * std.time.ns_per_s,
    lose_one_sent_in: u32 = 0,
    /// **HOW MANY STREAMS MAY BE HELD AT ONCE.** A held stream occupies a
    /// connection slot for as long as its tab is open, so without a budget the
    /// streams alone could fill the table and every new page load would be
    /// turned away. The rest of the slots are for requests.
    streams: usize = max_connections - reserved_for_requests,
    card: Card = .public,
    /// The FAT serial of the volume the application's data is on, as `blkid`
    /// spells it: `volume = 92DE-8831`. When it is set, a volume with exactly
    /// that serial must be attached, or the machine stops.
    volume: ?u32 = null,
};

/// A droplet's two network cards, in PCI slot order: what `virtio.findNth` is
/// asked for.
const Card = enum(u1) { public = 0, private = 1 };

/// Connection slots no stream may take: room for a burst of page loads while
/// every stream slot is held.
const reserved_for_requests = 64;

fn readConfig(io: Io, alloc: std.mem.Allocator) Config {
    var conf = Config{};
    const text = Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .limited(4096)) catch return conf;
    // No setting keeps the text (numbers, and a card's name), so nothing needs
    // it once it is read. It
    // used to stay in the long-lived heap, where a longer file meant a bigger
    // heap for the life of the boot — which the stream-churn gate saw as one
    // byte between `requests = 8` and `requests = 28`.
    defer alloc.free(text);
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
        } else if (std.mem.eql(u8, key, "idle_timeout_ms")) {
            const ms = std.fmt.parseInt(u64, value, 10) catch
                serial.fail(config_path ++ ": `idle_timeout_ms` is not a number");
            if (ms == 0) serial.fail(config_path ++ ": an idle timeout of zero would answer nobody");
            conf.idle_ns = ms * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, key, "keepalive_ms")) {
            const ms = std.fmt.parseInt(u64, value, 10) catch
                serial.fail(config_path ++ ": `keepalive_ms` is not a number");
            if (ms == 0) serial.fail(config_path ++ ": a keepalive of zero would ping on every turn");
            conf.keepalive_ns = ms * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, key, "lose_one_sent_in")) {
            conf.lose_one_sent_in = std.fmt.parseInt(u32, value, 10) catch
                serial.fail(config_path ++ ": `lose_one_sent_in` is not a number");
            if (conf.lose_one_sent_in == 1) serial.fail(config_path ++ ": losing every frame would answer nobody");
        } else if (std.mem.eql(u8, key, "streams")) {
            const n = std.fmt.parseInt(usize, value, 10) catch
                serial.fail(config_path ++ ": `streams` is not a number");
            if (n == 0 or n > max_connections - reserved_for_requests)
                serial.fail(config_path ++ ": `streams` must leave room for requests");
            conf.streams = n;
        } else if (std.mem.eql(u8, key, "card")) {
            conf.card = std.meta.stringToEnum(Card, value) orelse
                serial.fail(config_path ++ ": `card` is `public` or `private`");
        } else if (std.mem.eql(u8, key, "volume")) {
            conf.volume = parseSerial(value) orelse
                serial.fail(config_path ++ ": `volume` is a FAT serial, as blkid shows it: 92DE-8831");
        } else {
            serial.fail(config_path ++ ": the keys are `requests`, `idle_timeout_ms`, `streams`, `keepalive_ms`, `lose_one_sent_in`, `card` and `volume`");
        }
    }
    if (!said_anything) serial.fail(config_path ++ " is present but says nothing");
    return conf;
}

/// **WHAT THIS MACHINE SAYS ABOUT ITSELF**, for /admin/host: what a Linux
/// host reads from /proc, read here from this machine's own counters, clocks
/// and volumes.
fn metalFacts(io: Io, alloc: std.mem.Allocator) anyerror![]const router.host_status.Fact {
    const hs = router.host_status;
    var facts: std.ArrayList(hs.Fact) = .empty;
    const now: i64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const add = struct {
        fn f(list: *std.ArrayList(hs.Fact), a: std.mem.Allocator, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
            try list.append(a, .{ .label = label, .value = try std.fmt.allocPrint(a, fmt, args) });
        }
    }.f;
    try add(&facts, alloc, "host", "gopher-metal, with no operating system", .{});
    try add(&facts, alloc, "gopher-metal commit", "{s}", .{gm_build.commit});
    try add(&facts, alloc, "booted", "{s}", .{try hs.utc(alloc, booted_unix)});
    try add(&facts, alloc, "up for", "{s}", .{try hs.duration(alloc, now - booted_unix)});
    try add(&facts, alloc, "its clock now", "{s} (set from the hardware clock at boot, never corrected)", .{try hs.utc(alloc, now)});
    try add(&facts, alloc, "processor", "TSC at {d} MHz; {s}", .{
        tsc_hz_seen / 1_000_000,
        if (interrupts.armed()) "rests between frames" else "never rests (polls)",
    });
    try add(&facts, alloc, "requests served", "{d}", .{served});
    try add(&facts, alloc, "connections", "{d} open now, {d} at most, of {d}", .{ open_now, busiest, max_connections });
    try add(&facts, alloc, "streams", "{d} held now, {d} at most, {d} ended", .{ held_now, held_most, streams_ended });
    const p = pages.stats();
    try add(&facts, alloc, "memory (pages)", "{d} MB taken now, {d} MB at most, of {d} MB", .{
        p.bytes_taken >> 20, (p.pages_high_water * pages.page_size) >> 20, p.bytes_total >> 20,
    });
    if (Io.siteVolume()) |v| try addVolume(&facts, alloc, "the boot disk (the site)", v);
    if (Io.dataVolume()) |v| {
        try addVolume(&facts, alloc, "the volume (chat's data)", v);
    } else try add(&facts, alloc, "the volume (chat's data)", "none attached: the data is on the boot disk", .{});
    const work = diskWork();
    try add(&facts, alloc, "disk requests", "{d}, busy {d} ms in all", .{ work.requests, @divTrunc(Io.ticksToNs(work.ticks), std.time.ns_per_ms) });
    try add(&facts, alloc, "NMIs", "{d}", .{interrupts.nmis});
    return facts.items;
}

fn addVolume(facts: *std.ArrayList(router.host_status.Fact), alloc: std.mem.Allocator, label: []const u8, v: *fat16.Volume) !void {
    var serial_text: [9]u8 = undefined;
    const named = if (v.serial) |n| serialText(&serial_text, n) else "no serial";
    const value = if (v.space()) |sp|
        try std.fmt.allocPrint(alloc, "FAT16, serial {s}: {d} MB free of {d} MB", .{ named, sp.free >> 20, sp.total >> 20 })
    else |e|
        try std.fmt.allocPrint(alloc, "FAT16, serial {s}: free space unreadable ({s})", .{ named, @errorName(e) });
    try facts.append(alloc, .{ .label = label, .value = value });
}

/// `92DE-8831`: two halves of four hex digits, high half first.
fn parseSerial(text: []const u8) ?u32 {
    if (text.len != 9 or text[4] != '-') return null;
    const high = std.fmt.parseInt(u16, text[0..4], 16) catch return null;
    const low = std.fmt.parseInt(u16, text[5..9], 16) catch return null;
    return (@as(u32, high) << 16) | low;
}

fn putSerial(serial_number: ?u32) void {
    const n = serial_number orelse return serial.put("none");
    var text: [9]u8 = undefined;
    serial.put(serialText(&text, n));
}

/// `92DE-8831`, as `blkid` spells a FAT serial.
fn serialText(text: *[9]u8, n: u32) []const u8 {
    const digits = "0123456789ABCDEF";
    for (0..8) |k| {
        const at = if (k < 4) k else k + 1;
        text[at] = digits[@as(u4, @truncate(n >> @intCast(28 - 4 * k)))];
    }
    text[4] = '-';
    return text;
}

/// The wall clock in Unix seconds, or null before it is set: for the restart
/// record, which must not panic asking.
fn wallNow() ?i64 {
    if (!Io.realTimeIsSet()) return null;
    return @intCast(@divFloor(Io.Clock.now(.real, Io.io()).nanoseconds, std.time.ns_per_s));
}

/// The restart's back-off: a busy wait on the TSC, before anything serves.
fn waitSeconds(s: u32) void {
    const until = Io.awakeNs().? + @as(i96, s) * std.time.ns_per_s;
    while (Io.awakeNs().? < until) asm volatile ("pause");
    serial.put("  waited ");
    serial.putDec(s);
    serial.put(" s; serving\n");
}

pub const panic = std.debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    if (serial.on_fatal) |f| f(.panic, msg);
    serial.exitQemu(1);
}
