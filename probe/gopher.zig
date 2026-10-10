//! **THE REAL SERVER.** Not a probe that imitates it — `angry-gopher`'s own
//! ROUTE TABLE, compiled from its own source, serving real requests on a machine
//! with no operating system, with its data on a FAT16 or FAT32 volume.
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
const disk_fat = metal.disk_fat;
const stack = metal.stack;
const pages = metal.pages;
const pvh = metal.pvh;
const Io = metal.io;
const ready = metal.ready;
const RequestHeap = metal.request_heap.RequestHeap;
const interrupts = metal.interrupts;
const gm_build = @import("gm_build");
/// B15 (metal-vmm QUEUE item 78): a `-Dcoverage` build checks the TCP table
/// after every turn of the network (`stream.checkTable`) and the volumes after
/// every request (`checkVolumes`). A production build has neither.
pub const coverage_checks = gm_build.coverage;

/// The application, as it is.
const router = @import("router.zig");
const edge = router.edge;
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
var sector: [disk_fat.sector_size]u8 align(4096) = undefined;
var volume_sector: [disk_fat.sector_size]u8 align(4096) = undefined;
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
comptime {
    // A head the application allows must fit a connection's receive buffer,
    // or ready.zig would wait for one that cannot arrive.
    std.debug.assert(rx_bytes >= router.request_limits.head_bytes);
}
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

/// **RESPONSES STILL ON THEIR WAY**, after their handler finished: what the
/// send queue had no room for (`stream.Spill`), indexed by connection, as
/// `held` is. Every turn of the network queues more of each as its peer's
/// window opens; one that is empty is closed, one that has not moved for the
/// idle time is reset. Meanwhile the connection stays claimed, and the
/// machine serves the next request.
const Draining = struct {
    spill: stream.Spill,
    since: i96,
    una: u32,
};
var draining: [max_connections]?Draining = @splat(null);
var draining_now: usize = 0;
/// The most bytes one connection may keep (a whole upload of a few MB fits;
/// a larger response waits for room, as before spills).
const spill_cap = 32 * 1024 * 1024;
/// How much of the console's backlog one idle turn writes (serial.drain): at
/// a few tens of microseconds a byte, under a millisecond, which is how long
/// a request that arrives meanwhile waits for it.
const console_budget = 16;

/// **THE CONSOLE WAITS FOR THE RESPONSES** (QUEUE.md item 90). While a
/// connection has bytes the peer has not acknowledged, its acknowledgements
/// are what lets the rest go out, and a console turn taken then holds them:
/// a 4 MB picture spent half its time behind the console's turns. So the
/// console is written only once nothing is on its way, or once its backlog
/// is half full, so it never reaches the point where `put` writes directly.
fn consoleTurn(table: *const tcp.Table) bool {
    if (serial.pending() == 0) return false;
    if (serial.pending() >= serial.backlog / 2) return true;
    for (table.conns) |*c| {
        if (c.queued() > 0) return false;
    }
    return draining_now == 0;
}
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
/// The request head's buffer: angry-gopher's limits.zig sizes it, as it
/// sizes Linux's, so the two hosts answer 431 at the same byte.
var read_buf: [router.request_limits.head_bytes]u8 align(16) = undefined;
var write_buf: [64 * 1024]u8 align(16) = undefined;

/// Each request's heap, reset after the response: the equivalent of the arena
/// server.zig gives each request and frees wholesale. A bump allocator is the
/// right shape for it — nothing in a request outlives the request — and the
/// memory under it is asked for once, from the machine's pages, rather than
/// being a fixed array inside the kernel image.
const request_heap_bytes = 32 * 1024 * 1024;

/// The page cache (`metal.page_cache`), its size from the config. In `.bss`:
/// its table of names is a megabyte, and the files' bytes are taken from the
/// pages as they are kept.
var page_cache: metal.page_cache.PageCache = undefined;
/// The largest file the cache keeps, when `page_cache_largest_kib` is absent:
/// the application's `whole_read_max` (4 MiB), the line above which a GET of an
/// upload streams instead of reading the file whole. So by default what is kept
/// and what is read whole are one number; a `page_cache_largest_kib` above it
/// keeps no bigger upload, since an upload past the line streams past the cache.
///
/// 4 MiB holds every transcript (prod's largest is 362 KB) and every picture
/// people actually load (a phone photo or a screenshot is a few MB; chat's image
/// cap is 10 MiB), so a picture read once is served from memory rather than read
/// whole from the disk on every GET — the one stall item 90 left (30-39 MB/s).
/// A file past the cap is read from the disk as before, so no single big upload
/// pushes the transcripts out. `docs/designs/DESIGN-picture-cache.md` has the
/// method and the budget cost.
const page_cache_largest_kib_default = router.whole_read_max >> 10;

const config_path = "gopher-metal.conf";

/// **THE APPLICATION'S DATA**: the two directories `router.roots.point` is
/// given, and the only ones this machine writes. On a droplet they are on the
/// volume, which outlives every new image; everything else is the site's own,
/// on the boot disk, and comes with the image.
const data_dir = "data";
const auth_dir = "auth";
const data_dirs = [_][]const u8{ data_dir, auth_dir };

/// **A COVERAGE LINE, ON THE PORT ONLY** (-Dcoverage): not into the ring,
/// which is the log /admin/host shows, and after whatever the console still
/// owes, so no line lands inside another. tools/coverage_jsonl.sh takes each
/// back out by its prefix.
/// **metal-vmm's COVERAGE DOOR** (its main.zig): a port that answers
/// `coverage_door_answer` there and nowhere else (a PC decodes nothing at
/// 0xE2, and an unanswered read is 0xFF). A line handed to it costs the
/// guest no time, where on the serial port every byte is an exit (KVM
/// emulates `rep outsb` a byte at a time), and a boot's catalog alone was
/// about nine seconds of guest time: enough to change what a run did
/// (metal-vmm QUEUE B28). The line is copied into `door_line` (its length,
/// then its bytes) and the buffer's address written to the door, one exit.
/// The kernel's memory is identity-mapped, so the address is physical.
/// Read once, at boot.
const coverage_door: u16 = 0xE2;
const coverage_door_answer: u8 = 'M';
var coverage_door_found = false;
var door_line: [4 + 4096]u8 align(4) = undefined;

fn coverageLine(line: []const u8) void {
    if (coverage_door_found) {
        // A line longer than the buffer goes in pieces; metal-vmm joins
        // them up to the newline.
        var rest = line;
        while (rest.len > 0) {
            const n = @min(rest.len, door_line.len - 4);
            std.mem.writeInt(u32, door_line[0..4], @intCast(n), .little);
            @memcpy(door_line[4..][0..n], rest[0..n]);
            metal.port.outl(coverage_door, @intCast(@intFromPtr(&door_line)));
            rest = rest[n..];
        }
        return;
    }
    serial.flushPending();
    serial.putPort("coverage: ");
    serial.putPort(line);
}

pub fn kmain() noreturn {
    serial.init();
    interrupts.install();
    serial.put("gopher-metal: angry-gopher's route table, with no Linux under it\n");
    if (gm_build.coverage) {
        coverage_door_found = metal.port.inb(coverage_door) == coverage_door_answer;
        metal.coverage.sink = coverageLine;
        metal.coverage.declare();
    }

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
    boot_disk.read_tries = boot_read_tries;
    disks[0] = &boot_disk;
    Io.mount(mountFat(&boot_disk, &sector, "the boot disk"));
    const io = Io.io();
    const base = router.mem_meter.init(gpa.allocator());
    const conf = readConfig(io, base);
    var volume_disk: virtio.Block = undefined;
    if (dataVolume()) |b| {
        volume_disk = b;
        volume_disk.read_tries = boot_read_tries;
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
    // **THE DATA'S FILES, KEPT AFTER THEIR FIRST READ** (QUEUE.md item 87):
    // a transcript two people are reading is read from memory, not walked to
    // and read from the disk on every send. Memory is taken as files are
    // kept, never more than this; what it cannot get, it does not keep.
    //
    // **NEVER MORE THAN A QUARTER OF WHAT IS FREE.** The request heap is an
    // arena over the same pages, and a request larger than what it keeps grows
    // it while serving; memory the cache held would be memory that request
    // could not have. On a machine with little to spare the cache is smaller,
    // and the boot says so.
    if (conf.page_cache_mib != 0) {
        const p = pages.stats();
        const budget = @min(@as(usize, conf.page_cache_mib) << 20, (p.bytes_total - p.bytes_taken) / 4);
        const largest = @as(usize, conf.page_cache_largest_kib) << 10;
        page_cache = metal.page_cache.PageCache.init(pages.allocator, budget, largest);
        Io.keepPages(&page_cache);
        serial.put("  the data's files kept in memory: up to ");
        serial.putDec(budget >> 20);
        if (budget >> 20 < conf.page_cache_mib) {
            serial.put(" MiB (a quarter of the ");
            serial.putDec((p.bytes_total - p.bytes_taken) >> 20);
            serial.put(" MiB free, not the ");
            serial.putDec(conf.page_cache_mib);
            serial.put(" asked)");
        } else serial.put(" MiB");
        serial.put(", files of up to ");
        serial.putDec(largest >> 10);
        serial.put(" KiB\n");
    } else serial.put("  the data's files kept in memory: none (page_cache_mib = 0)\n");

    // **THE ADMIN'S LOST PASSWORD** (QUEUE.md item 89): a reset the boot
    // disk carries, applied before anything is served, and once.
    if (conf.reset) {
        const r = metal.admin_reset.Reset{ .name = conf.reset_name[0..conf.reset_name_len], .hash = &conf.reset_hash };
        serial.put("  admin password reset for ");
        serial.put(r.name);
        serial.put(": ");
        serial.put(switch (metal.admin_reset.apply(base, r)) {
            .applied => "applied; the old hash is auth/1/password.before-reset\n",
            .already => "applied by an earlier boot; nothing changed\n",
            .no_admin => "REFUSED: uid 1 has no password, so there is no admin to give one to; nothing changed\n",
            .other_name => "REFUSED: uid 1 is not named so on this volume; nothing changed\n",
            .failed => "FAILED: the volume would not read or write; the next boot tries again\n",
        });
    }

    const clock = metal.wallclock.start() catch |e| {
        serial.put("  wallclock: ");
        serial.put(@errorName(e));
        // **SAY WHICH CLOCK.** NoTimer and Implausible are the timer's: its
        // rate never settled, and the RTC was never asked. This printed the
        // RTC's empty record for them, "0 polls", which read as an RTC that
        // was never polled (QUEUE.md item 67).
        if (e == error.NoTimer or e == error.Implausible) {
            serial.put(" (the timestamp counter's rate, against the PIT, never settled; the RTC was not asked)\n");
            serial.fail("the clocks would not come up");
        }
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
    router.host_status.provideLog(metalLog);
    router.roots.point(base, .{ .data_dir = data_dir, .auth_dir = auth_dir }) catch
        serial.fail("roots.point could not allocate the store paths");
    // The game store's floor reads the data's volume (QUEUE.md item 52).
    router.game_limits.free_space = dataSpace;
    if (conf.trusted_proxy) |p| {
        router.game_limits.trusted_proxy = ipText(&trusted_proxy_text, p);
        serial.put("  X-Forwarded-For is believed from ");
        serial.put(router.game_limits.trusted_proxy.?);
        serial.put(" only\n");
    } else serial.put("  no trusted_proxy: every request is the address it came from\n");
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
    // Serving, a failed read fails its request and says so; boot's retries
    // end here, and those it needed are told.
    for (disks) |maybe| if (maybe) |d| {
        d.read_tries = 1;
        if (d.reads_retried > 0) {
            serial.put("  reads that failed at boot and answered when tried again: ");
            serial.putDec(d.reads_retried);
            serial.put(if (d == &boot_disk) " (the boot disk)\n" else " (the volume)\n");
        }
    };

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
    // **THE SESSION SECRET MOVES INTO auth/, ONCE** (QUEUE.md item 106): a
    // volume written before the move keeps it in data/chat/; carry it over
    // before the first request so no session is lost. No-op once it is in auth/.
    {
        router.roots.migrateSecret(io, request_heap.allocator());
        request_heap.reset();
    }
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
    var oversized_seen: u64 = 0; // net.oversized last reported to the console
    // From here the console waits for idle turns (serial.deferred).
    serial.deferred = true;
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
            // Nothing to serve: the console's turn, a little at a time so a
            // request that arrives meanwhile waits at most this much.
            if (consoleTurn(&table)) {
                serial.drain(console_budget);
                continue;
            }
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
        if (coverage_checks) checkVolumes();
        deepest = reportStack(deepest);
        // **LOUD, ONCE PER OCCURRENCE** (REVIEW-item90-step2.md finding 1): a
        // frame too long to send is a kernel bug net.zig refused rather than
        // overrun. The count is on /admin/host; this is the console line.
        if (nic.oversized != oversized_seen) {
            oversized_seen = nic.oversized;
            serial.put("  net: a frame too long to send was refused (a kernel bug); /admin/host counts them\n");
        }
    }

    // The boot is over: the console is written out in full from here.
    serial.immediate();
    // Responses still on their way are given the idle time
    // to finish (their turns run inside `pump`), then the rest are reset.
    const draining_from = Io.awakeNs() orelse 0;
    while (draining_now > 0 and (Io.awakeNs() orelse 0) - draining_from < conf.idle_ns) {
        if (stream.pump(&wire, &table, lease.address) == null) interrupts.rest();
    }
    for (&draining, 0..) |*slot, i| {
        if (slot.*) |*d| {
            table.abandon(&wire, i);
            serial.put("  let go at the end: the client stopped taking the response\n");
            d.spill.deinit();
            table.release(i);
            slot.* = null;
            draining_now -= 1;
        }
    }
    // Every stream still held ends with it, and the goodbyes are given a
    // moment to be acknowledged.
    stream.after_arrivals = null;
    for (&held) |*slot| {
        if (slot.* != null) endStream(slot, &wire, &table, &hub, .stopping);
    }
    const stopping_at = Io.awakeNs() orelse 0;
    while (closing(&table) and (Io.awakeNs() orelse 0) - stopping_at < 2 * std.time.ns_per_s) {
        if (stream.pump(&wire, &table, lease.address) == null) interrupts.rest();
    }
    // **A RESPONSE CUT BY THE STOP IS SAID TO BE.** One still unacknowledged
    // now is never finished: its request counted as answered, and its client
    // has part of the answer. Only a request limit stops the machine.
    var cut_conns: usize = 0;
    var cut_bytes: usize = 0;
    for (table.conns) |c| {
        if (c.state != .closing or c.queued() == 0) continue;
        cut_conns += 1;
        cut_bytes += c.queued();
    }
    if (cut_conns > 0) {
        serial.put("  let go at the end: ");
        serial.putDec(cut_conns);
        serial.put(" response(s) cut by the stop, ");
        serial.putDec(cut_bytes);
        serial.put(" bytes never acknowledged\n");
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
    serial.put("\n");
    // The judge (metal-vmm sweep.sh, `counted_leak`) reads these: what fsck
    // reclaims on a disk must not pass what the kernel counted there.
    if (Io.siteVolume()) |v| leakLine("the boot disk", v);
    if (Io.dataVolume()) |v| leakLine("the volume", v);
    serial.put("  served ");
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
        if (ready.check(c.pending(), c.peerDone(), c.rx.len) == .waiting) continue;
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
    var spill = stream.Spill{ .gpa = hub.gpa, .cap = spill_cap };
    var spill_kept = false;
    defer if (!spill_kept) spill.deinit();
    s.spill = &spill;

    // **WHAT THIS MACHINE'S OWN CLOCK SAYS EACH REQUEST COST.** How long the
    // connection had been open before its turn came — the client finishing
    // its request, and then the queue — and how long the route table took to
    // answer. Timing from outside measures curl, slirp and the emulator too.
    const opened_at = table.conns[i].opened_at;

    var server = std.http.Server.init(s.reader(), s.writer());
    var req = server.receiveHead() catch |e| {
        // **A HEAD PAST THE READ BUFFER IS ANSWERED 431, AS LINUX ANSWERS IT**
        // (angry-gopher's server.zig, handleConn): counted for /version, and
        // the same bytes. Metal closed without a word, so a browser with an
        // oversized cookie saw an empty reply (QUEUE.md item 81, found by
        // probe/fuzz_requests.py).
        if (e == error.HttpHeadersOversize) {
            edge.count(.header_too_large);
            s.writer().writeAll("HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
                "connection: close\r\ncontent-length: 0\r\n\r\n") catch {};
            s.writer().flush() catch {};
        }
        logRequest(number, "(no request)", if (s.timed_out)
            "the client stopped sending, and was let go"
        else
            @errorName(e));
        close(wire, table, i);
        return;
    };
    req.head.keep_alive = false;

    // The target is borrowed from the read buffer, which the handler may
    // consume; copy it for the log now — the PATH only, never the query, which
    // is not the log's to keep (serial.log_ring.withoutQuery; QUEUE.md item 95).
    var what_buf: [300]u8 = undefined;
    const path = metal.log_ring.withoutQuery(req.head.target);
    const what = std.fmt.bufPrint(&what_buf, "{s} {s}", .{
        @tagName(req.head.method),
        path[0..@min(path.len, 256)],
    }) catch "(unprintable)";

    const head_at = Io.awakeNs() orelse 0;
    const disk_before = diskWork();

    var outcome: []const u8 = "ok";
    var bus = Bus.of(hub);
    var peer_text: [15]u8 = undefined;
    bus.peer = ipText(&peer_text, table.conns[i].peer_ip);
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
        // What the head and backlog left in the spill goes ahead of every live
        // frame, as the carry the stream already drains first.
        if (spill.pending().len > 0) {
            if (hub.gpa.dupe(u8, spill.pending())) |rest| {
                held[i].?.carry = rest;
            } else |_| {}
        }
        held_now += 1;
        held_most = @max(held_most, held_now);
        kept_open = true;
        outcome = "ok, and its stream is kept";
    }
    // A write that timed out fails wherever it happened — inside the route or
    // in this flush — and is the same event either way.
    if (s.timed_out) outcome = "the client stopped taking the response";
    const done_at = Io.awakeNs() orelse 0;
    // **THE CONNECTION IS LET GO BEFORE ITS LOG IS WRITTEN**, so the client is
    // done when the response is, not when the console has caught up.
    if (!kept_open) {
        if (s.timed_out) {
            table.abandon(wire, i);
        } else if (spill.pending().len > 0 and table.conns[i].state == .established) {
            draining[i] = .{ .spill = spill, .since = Io.awakeNs() orelse 0, .una = table.conns[i].una };
            draining_now += 1;
            spill_kept = true;
            kept_open = true;
        } else close(wire, table, i);
    }
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
}

/// One pass over the responses still on their way: queue more of each, close
/// the ones that are done, reset the ones whose peer stopped taking them.
fn serviceDraining(wire: *stream.Wire, table: *tcp.Table, now: i96, idle_ns: u64) void {
    if (draining_now == 0) return;
    for (&draining, 0..) |*slot, i| {
        const d = if (slot.*) |*d| d else continue;
        const c = &table.conns[i];
        var done = false;
        if (c.state != .established) {
            done = true;
        } else {
            if (d.spill.push(table, i) > 0 or c.una != d.una) {
                d.since = now;
                d.una = c.una;
            }
            if (d.spill.pending().len == 0) {
                close(wire, table, i);
                done = true;
            } else if (now - d.since >= idle_ns) {
                table.abandon(wire, i);
                serial.put("  let go: the client stopped taking the response\n");
                done = true;
            }
        }
        if (done) {
            d.spill.deinit();
            table.release(i);
            slot.* = null;
            draining_now -= 1;
        }
    }
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
    const now = Io.awakeNs() orelse 0;
    serviceStreams(t.wire, t.table, t.hub, stream_scratch.allocator(), now, t.conf);
    stream_scratch.reset();
    serviceDraining(t.wire, t.table, now, t.conf.idle_ns);
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
    // A frame shows others what was just saved: the save is durable first,
    // as for any response (`io.durable`). These frames, and the keepalive
    // ping below, are queued here, not through a Stream, so this one call
    // covers all three of this function's queues.
    Io.durable();
    for (&held) |*slot| {
        const h = if (slot.*) |*h| h else continue;
        const c = &table.conns[h.conn];
        if (!c.open() or c.peerDone()) {
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
    const now = Io.awakeNs() orelse 0;
    table.transmit(wire, now);
    if (coverage_checks) stream.checkTable(table, now, .after_transmit);
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
        if (b.cache_on_at_bringup) switch (metal.scsi_mode.report(b.write_cache, true)) {
            .turned_off => serial.put("  the volume's write cache is turned off: every write is on the disk when answered\n"),
            .would_not_turn_off => serial.put("  the volume's write cache would not turn off: a power cut can leave its filesystem damaged\n"),
            else => serial.put("  the volume's write cache was on, and will not say now: every save is flushed as if it were\n"),
        };
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
/// The most memory one volume's FAT may take (FAT32.md §9): about 256 GiB of
/// volume at 32 KiB clusters.
const fat_budget_bytes: usize = 32 << 20;

/// **HOW MANY TIMES BOOT TRIES A READ** (B25, Steve 2026-10-08): one refused
/// read of the partition table or the FAT stopped the machine, and a disk
/// that refused once answers the next time. Serving, a read is tried once.
const boot_read_tries: u8 = 3;

fn mountFat(blk: *virtio.Block, scratch: *[disk_fat.sector_size]u8, what: []const u8) disk_fat.Volume {
    // A table that cannot be read is a disk failing, not a blank one: the
    // two are told apart.
    const part = gpt.dataPartition(blk, scratch) catch |e| {
        serial.put("  ");
        serial.put(what);
        if (e == error.ReadFailed) {
            serial.put(": its partition table cannot be read\n");
            serial.fail("a disk's partition table cannot be read");
        }
        serial.put(": no GPT partition\n");
        serial.fail("a disk has no partition to serve from");
    };
    var vol = disk_fat.Volume.mount(blk, scratch, part.first_lba) catch |e| {
        serial.put("  ");
        serial.put(what);
        if (e == error.ReadFailed) {
            serial.put(": its first partition cannot be read\n");
            serial.fail("a disk's partition cannot be read");
        }
        serial.put(": its first partition is not a FAT this machine takes (");
        serial.put(@errorName(e));
        serial.put(")\n");
        serial.fail("a disk's partition is not FAT16 or FAT32, or is one this machine refuses");
    };
    // **THE FAT IS HELD WHOLE, SO ITS SIZE IS CAPPED** (FAT32.md §9): one
    // copy is 4 bytes a cluster on FAT32, 12.5 MiB for 100 GiB at 32 KiB
    // clusters. A volume whose FAT is larger is refused, saying so, rather
    // than failing an allocation. Format larger volumes with larger clusters.
    if (vol.fatBytes() > fat_budget_bytes) {
        serial.put("  ");
        serial.put(what);
        serial.put(": its FAT is ");
        serial.putDec(vol.fatBytes() >> 20);
        serial.put(" MiB, past the ");
        serial.putDec(fat_budget_bytes >> 20);
        serial.put(" MiB set aside for it\n");
        serial.fail("a disk's FAT is too large to hold in memory; format it with larger clusters");
    }
    const fat_cache = pages.allocator.alloc(u8, vol.fatBytes()) catch
        serial.fail("no memory to hold the FAT");
    // Room for the check that weighs the FAT's copies when they differ (B26);
    // without it, the first copy is the FAT, as before.
    const weigh_room: ?[]u8 = pages.allocator.alloc(u8, vol.checkBytes()) catch null;
    defer if (weigh_room) |r| pages.allocator.free(r);
    const mirrors = vol.cacheFatChecked(fat_cache, weigh_room) catch |e| {
        serial.put("  fat cache: ");
        serial.put(@errorName(e));
        serial.put("\n");
        serial.fail("the FAT could not be held in memory");
    };
    // Lookups read a directory up to a cluster per request (disk_fat's
    // `dir_burst`), within the most one request carries.
    const burst_sectors = @min(vol.sectors_per_cluster, virtio.Block.max_sectors);
    vol.dir_burst = pages.allocator.alloc(u8, burst_sectors * disk_fat.sector_size) catch
        serial.fail("no memory to read directories in bursts");
    // Directory sectors, once read, are held (disk_fat's `dirs`): 8 MiB, sixteen
    // thousand sectors, so a send or Recent finds its folders in memory.
    // A speed-up, so memory it cannot have means serving without it, never
    // a boot that stops.
    const dir_slots = 16384;
    if (pages.allocator.alloc(u32, dir_slots)) |dir_keys| {
        if (pages.allocator.alloc(u8, dir_slots * disk_fat.sector_size)) |dir_data| {
            vol.cacheDirs(dir_keys, dir_data);
        } else |_| {
            pages.allocator.free(dir_keys);
            serial.put("  no memory to hold folders: they are read from the disk\n");
        }
    } else |_| serial.put("  no memory to hold folders: they are read from the disk\n");
    // A machine stopped between the FAT copies' writes, or a copy that
    // reads wrong, leaves them apart; the copy that checks cleaner is the
    // FAT, the first on a tie (disk_fat.cacheFatChecked).
    if (mirrors.repaired > 0) {
        serial.put("  ");
        serial.put(what);
        serial.put(": ");
        serial.putDec(mirrors.repaired);
        serial.put(" sectors of the FAT's copies differed; ");
        if (mirrors.found == .weighed or mirrors.found == .tied) {
            serial.put("checked with each copy, the first had ");
            serial.putDec(mirrors.health[0].problems);
            serial.put(" problems and ");
            serial.putDec(mirrors.health[0].leaked);
            serial.put(" leaked, the second ");
            serial.putDec(mirrors.health[1].problems);
            serial.put(" and ");
            serial.putDec(mirrors.health[1].leaked);
            serial.put("; ");
        }
        serial.put(if (mirrors.trusted == 1) "the first was written from the second\n" else "the second was written from the first\n");
    }
    if (weigh_room == null) serial.put("  no memory to weigh the FAT's copies: the first is the FAT\n");
    if (mirrors.found == .tied) {
        serial.put("  ");
        serial.put(what);
        serial.put(": the FAT's copies differ and check alike: the first is held, neither written over\n");
    }
    if (mirrors.repair == .refused) {
        serial.put("  ");
        serial.put(what);
        serial.put(": the disk refused a repair of the FAT's copies: the FAT is held, the copies left apart\n");
    }
    if (mirrors.found == .unweighed) {
        serial.put("  ");
        serial.put(what);
        serial.put(": the FAT's copies differ and could not be weighed (a read failed): the first is held, neither written over\n");
    }
    serial.put("  ");
    serial.put(what);
    serial.put(if (vol.kind == .fat32) ": FAT32 at LBA " else ": FAT16 at LBA ");
    serial.putDec(part.first_lba);
    serial.put(", FAT held in memory (");
    serial.putDec(vol.fatBytes());
    serial.put(" bytes), ");
    // The reserve for small writes (metal-vmm QUEUE 132).
    serial.putDec(@as(u64, vol.reserve_clusters) * vol.sectors_per_cluster * 512 >> 20);
    serial.put(" MB kept for small writes\n");
    diskCheck(&vol, what);
    return vol;
}

/// **B15: THE VOLUMES, CHECKED AFTER EVERY REQUEST**, in a `-Dcoverage` build
/// only: the whole check, as `diskCheck` runs it at boot, with no line
/// printed. The kernel cannot tell when a run ends (metal-vmm ends it from
/// outside), so this is the nearest thing: the state after the last request
/// is the state the run ended in.
fn checkVolumes() void {
    for ([_]?*disk_fat.Volume{ Io.siteVolume(), Io.dataVolume() }) |maybe| {
        const vol = maybe orelse continue;
        const seen = pages.allocator.alloc(u8, vol.checkBytes()) catch continue;
        defer pages.allocator.free(seen);
        var damage: u32 = 0;
        const Count = struct {
            fn each(n: *u32, f: disk_fat.Finding) void {
                if (f.problem.damage()) n.* += 1;
            }
        };
        _ = vol.check(seen, &damage, Count.each) catch continue;
        metal.coverage.always(@src(), damage == 0, "fat: after a request, a volume has no damage beyond what a stop leaves", .{ .damage = damage });
        // **WHAT THE VOLUME KEEPS OF ITS FAT IS WHAT THE FAT SAYS NOW**
        // (essay web-server-in-a-box; kernel-facts #8): the kept count, and
        // a hint with no free cluster below it.
        const now = vol.derive() catch continue;
        metal.coverage.always(@src(), vol.free_clusters == now.free, "fat: after a request, the kept free count is the FAT's", .{ .kept = vol.free_clusters, .fat = now.free });
        if (now.first_free) |first| metal.coverage.always(@src(), vol.alloc_hint <= first, "fat: after a request, no free cluster lies below the allocation hint", .{ .hint = vol.alloc_hint, .first_free = first });
    }
}

/// **THE DISK CHECK, AT EVERY MOUNT** (`disk_fat.Volume.check`, QUEUE.md item
/// 13): one summary line per volume, then each finding. It reports and never
/// halts, and it writes nothing: a damaged volume still boots and serves, and
/// the log says what to look at with fsck.vfat on a copy. The judges read the
/// summary line on every boot (probe/judge_gopher.py, `disk_check_lines`).
///
/// It runs after `cacheFat`, so following a chain is a memory read; the walk
/// reads each directory sector once.
fn diskCheck(vol: *disk_fat.Volume, what: []const u8) void {
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
        held: [most]disk_fat.Finding = undefined,
        paths: [most][256]u8 = undefined,
        n: u32 = 0,
        /// Findings that are damage (`disk_fat.Problem.damage`), all of them.
        damage: u32 = 0,
        fn each(self: *@This(), f: disk_fat.Finding) void {
            if (f.problem.damage()) self.damage += 1;
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
    // At boot, so the last run's end: observed in every build.
    metal.coverage.always(@src(), shown.damage == 0, "fat: at boot, a volume has no damage beyond what a stop leaves", .{ .damage = shown.damage });
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
///     page_cache_mib = N      memory for the data's files read whole
///                             (`page_cache.zig`), 64 when absent; 0 keeps
///                             none, every read from the disk, as before
///     page_cache_largest_kib = N
///                             the largest file the cache keeps, in KiB; 4096
///                             (4 MiB) when absent, at most 10240 (chat's image
///                             cap). Raising it keeps bigger pictures in memory
///                             at the cost of room for transcripts.
///     admin_password_reset = Steve $2b$10$…
///                             a new password hash for the admin, uid 1, if
///                             uid 1 is named so; applied once, at boot
///                             (`admin_reset.zig`, ADMIN-PASSWORD-LOST.md)
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
    /// The reverse proxy whose X-Forwarded-For names the client
    /// (`trusted_proxy = 10.0.0.2`): prod's Caddy, over the private network.
    /// Without it every request counts as the address it came from, and
    /// through Caddy that is one address for everyone, so the game store's
    /// bounds on what one address may do become bounds on the whole site.
    trusted_proxy: ?[4]u8 = null,
    /// Memory for the page cache, in MiB; 0 keeps none.
    page_cache_mib: u32 = 64,
    /// The largest file the page cache keeps, in KiB (`page_cache.zig`'s
    /// `largest`). Default 4 MiB; the box raises it toward chat's 10 MiB image
    /// cap once prod's picture sizes are measured.
    page_cache_largest_kib: u32 = page_cache_largest_kib_default,
    /// The admin's password reset, kept here because the text it was read
    /// from is freed: the name, and the 60-byte hash.
    reset_name: [64]u8 = undefined,
    reset_name_len: usize = 0,
    reset_hash: [60]u8 = undefined,
    reset: bool = false,
};

/// A droplet's two network cards, in PCI slot order: what `virtio.findNth` is
/// asked for.
const Card = enum(u1) { public = 0, private = 1 };

/// Connection slots no stream may take: room for a burst of page loads while
/// every stream slot is held.
const reserved_for_requests = 64;

fn readConfig(io: Io, alloc: std.mem.Allocator) Config {
    var conf = Config{};
    // **A MISSING FILE IS THE DEFAULTS; ANY OTHER FAILURE STOPS THE BOOT**
    // (metal-vmm QUEUE B21). A refused read once meant "serve with the
    // defaults", which on a droplet is serving without the settings it was
    // given: the volume it must serve, the proxy it must trust. As
    // angry-gopher's files.zig has it, an error is not an empty file.
    const text = Io.Dir.cwd().readFileAlloc(io, config_path, alloc, .limited(4096)) catch |e| switch (e) {
        error.FileNotFound => return conf,
        else => {
            serial.put("  " ++ config_path ++ ": ");
            serial.put(@errorName(e));
            serial.put("\n");
            serial.fail(config_path ++ " is there but could not be read; serving without it would ignore what it says");
        },
    };
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
        } else if (std.mem.eql(u8, key, "admin_password_reset")) {
            const r = metal.admin_reset.parse(value) orelse
                serial.fail(config_path ++ ": `admin_password_reset` is the admin's name, then a bcrypt hash of cost 10 or more");
            if (r.name.len > conf.reset_name.len) serial.fail(config_path ++ ": `admin_password_reset` names someone longer than 64 bytes");
            @memcpy(conf.reset_name[0..r.name.len], r.name);
            conf.reset_name_len = r.name.len;
            @memcpy(&conf.reset_hash, r.hash[0..60]);
            conf.reset = true;
        } else if (std.mem.eql(u8, key, "page_cache_mib")) {
            conf.page_cache_mib = std.fmt.parseInt(u32, value, 10) catch
                serial.fail(config_path ++ ": `page_cache_mib` is a number of MiB, 0 for none");
            if (conf.page_cache_mib > 1024) serial.fail(config_path ++ ": `page_cache_mib` past 1024 is more memory than a droplet has to spare");
        } else if (std.mem.eql(u8, key, "page_cache_largest_kib")) {
            conf.page_cache_largest_kib = std.fmt.parseInt(u32, value, 10) catch
                serial.fail(config_path ++ ": `page_cache_largest_kib` is a number of KiB");
            if (conf.page_cache_largest_kib == 0) serial.fail(config_path ++ ": `page_cache_largest_kib` is 0 — set `page_cache_mib = 0` to keep no files, not a zero cap");
            if (conf.page_cache_largest_kib > 10 << 10) serial.fail(config_path ++ ": `page_cache_largest_kib` past 10240 (10 MiB) is more than chat's image cap, so no picture reaches it");
        } else if (std.mem.eql(u8, key, "trusted_proxy")) {
            const a = std.Io.net.Ip4Address.parse(value, 0) catch
                serial.fail(config_path ++ ": `trusted_proxy` is an IPv4 address: 10.0.0.2");
            conf.trusted_proxy = a.bytes;
        } else {
            serial.fail(config_path ++ ": the keys are `requests`, `idle_timeout_ms`, `streams`, `keepalive_ms`, `lose_one_sent_in`, `card`, `volume`, `trusted_proxy`, `page_cache_mib`, `page_cache_largest_kib` and `admin_password_reset`");
        }
    }
    if (!said_anything) serial.fail(config_path ++ " is present but says nothing");
    return conf;
}

/// **THE LOG, FOR /admin/host**: what the serial ring holds (its last 64 KiB),
/// oldest first from its first whole line. Its secrets were taken out as it
/// was written (log_ring.zig's Redactor), so it is shown as it is.
fn metalLog(io: Io, alloc: std.mem.Allocator) anyerror!?[]const u8 {
    _ = io;
    const buf = try alloc.alloc(u8, serial.ring.len());
    return serial.ring.read(buf);
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
    if (Io.siteVolume()) |v| try addVolume(&facts, alloc, "the boot disk (the site)", "the boot disk's write cache", "the boot disk's folders in memory", v);
    if (Io.dataVolume()) |v| {
        try addVolume(&facts, alloc, "the volume (chat's data)", "the volume's write cache", "the volume's folders in memory", v);
    } else try add(&facts, alloc, "the volume (chat's data)", "none attached: the data is on the boot disk", .{});
    const kept = Io.siteCache();
    try add(&facts, alloc, "site files in memory", "{d} kept, {d} KB of {d} KB; {d} reads answered from them", .{
        kept.count, kept.used >> 10, @as(usize, Io.SiteCache.capacity) >> 10, kept.hits,
    });
    if (Io.pageCache()) |pc| {
        try add(&facts, alloc, "data files in memory", "{d} kept, {d} MB of {d} MB, files up to {d} KiB; {d} reads answered from them, {d} from the disk; {d} pushed out", .{
            pc.count, pc.held >> 20, pc.budget >> 20, pc.largest >> 10, pc.hits, pc.misses, pc.evicted,
        });
    } else try add(&facts, alloc, "data files in memory", "none (page_cache_mib = 0)", .{});
    const work = diskWork();
    try add(&facts, alloc, "disk requests", "{d}, busy {d} ms in all", .{ work.requests, @divTrunc(Io.ticksToNs(work.ticks), std.time.ns_per_ms) });
    try add(&facts, alloc, "NMIs", "{d}", .{interrupts.nmis});
    if (turning) |t| try add(&facts, alloc, "frames refused (too long to send)", "{d}", .{t.wire.nic.oversized});
    return facts.items;
}

/// What the host status page calls a volume: it said FAT16 of every one,
/// and metal's volume is FAT32.
/// **K AND P ARE CEILINGS** (metal-vmm 148(a)): what the volume counted
/// exactly plus what may be live (`unsure_*`), so the judge's "fsck finds no
/// more than K" holds; how much of each may be live is said after.
fn leakLine(what: []const u8, v: *const disk_fat.Volume) void {
    serial.put("  ");
    serial.put(what);
    serial.put(": ");
    serial.putDec(v.leaked_clusters + v.unsure_clusters);
    serial.put(" clusters left a counted leak, ");
    serial.putDec(v.orphaned_parts + v.unsure_parts);
    serial.put(" long-name parts left orphaned, of them ");
    serial.putDec(v.unsure_clusters);
    serial.put(" clusters and ");
    serial.putDec(v.unsure_parts);
    serial.put(" parts that may be live; ");
    serial.putDec(v.long_clusters + v.unsure_long);
    serial.put(" clusters past a size (");
    serial.putDec(v.cleanups_failed);
    serial.put(" cleanups failed)\n");
}

fn kindName(v: *const disk_fat.Volume) []const u8 {
    return if (v.kind == .fat32) "FAT32" else "FAT16";
}

fn addVolume(facts: *std.ArrayList(router.host_status.Fact), alloc: std.mem.Allocator, label: []const u8, cache_label: []const u8, dirs_label: []const u8, v: *disk_fat.Volume) !void {
    var serial_text: [9]u8 = undefined;
    const named = if (v.serial) |n| serialText(&serial_text, n) else "no serial";
    const value = if (v.space()) |sp|
        try std.fmt.allocPrint(alloc, "{s}, serial {s}: {d} MB free of {d} MB, {d} MB of it kept for small writes; {d} cleanups after a commit failed (leaks, {d} clusters counted), {d} FAT copy writes failed (copies apart)", .{
            kindName(v),                                                      named,             sp.free >> 20,     sp.total >> 20,
            @as(u64, v.reserve_clusters) * v.sectors_per_cluster * 512 >> 20, v.cleanups_failed, v.leaked_clusters, v.fat_copies_failed,
        })
    else |e|
        try std.fmt.allocPrint(alloc, "{s}, serial {s}: free space unreadable ({s})", .{ kindName(v), named, @errorName(e) });
    try facts.append(alloc, .{ .label = label, .value = value });
    // **WHETHER A SAVE IS DURABLE BEFORE IT IS ANSWERED** (io.durable): what
    // the disk says of its write cache, and the flushes sent to it.
    const cache: []const u8 = switch (metal.scsi_mode.report(v.blk.write_cache, v.blk.cache_on_at_bringup)) {
        .would_not_turn_off => "on, and it would not turn off: writes wait in it until flushed, and a power cut can damage the filesystem",
        .turned_off => "turned off at boot: it writes through",
        .caches => "on: writes wait in it until flushed",
        .writes_through => "off: it writes through",
        .unknown => "not said: flushed as if on",
    };
    try facts.append(alloc, .{
        .label = cache_label,
        .value = try std.fmt.allocPrint(alloc, "{s}; {d} flushes, {d} failed; looked at again after {d} resets", .{ cache, v.blk.flushes, v.blk.flush_failures, v.blk.cache_rechecks }),
    });
    if (v.dirs) |d| try facts.append(alloc, .{
        .label = dirs_label,
        .value = try std.fmt.allocPrint(alloc, "{d} sectors held at most; {d} sector reads answered from it, {d} from the disk (every sector read asks it, folders or not)", .{ d.keys.len, d.hits, d.misses }),
    });
}

/// The data's volume, free and total, for the game store's floor: the volume
/// when one is attached, else the boot disk, which then holds the data.
fn dataSpace() ?router.game_limits.Space {
    const v = Io.dataVolume() orelse Io.siteVolume() orelse return null;
    const sp = v.space() catch return null;
    return .{ .free = sp.free, .total = sp.total };
}

var trusted_proxy_text: [15]u8 = undefined;

/// `203.0.113.7`, into `buf`.
fn ipText(buf: *[15]u8, ip: [4]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch unreachable;
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
    serial.immediate();
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    if (serial.on_fatal) |f| f(.panic, msg);
    serial.exitQemu(1);
}
