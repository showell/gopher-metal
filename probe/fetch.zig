//! **THE CLIENT KERNEL** (metal-vmm QUEUE 225, chunk 9): a DHCP lease, then
//! one GET made with `tcp.Table.connect`, and its outcome as the exit code.
//! The same `fetch.Client` as `native/fetch.zig`, here on virtio-net.
//!
//! The PVH command line names the target and the deadlines, which have no
//! defaults (docs/TWO-KERNELS.md §5):
//!
//!   fetch <ip> <port> <path> connect_ms=N idle_ms=N total_ms=N
//!
//! (the leading `fetch` is optional). Under QEMU's user networking the host
//! is 10.0.2.2, so `python3 -m http.server` there is reached as
//! `fetch 10.0.2.2 8000 /tiny ...`. The kernel ends through isa-debug-exit
//! with `fetch.Outcome`'s code, which QEMU reports as `code << 1 | 1`: a
//! whole 200 exits QEMU with 1, refused with 5, the connect, idle and total
//! deadlines with 7, 9 and 11. 1 (QEMU's 3) is a kernel that could not
//! start, as every probe's `serial.fail`.

const std = @import("std");
const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const net = metal.net;
const dhcp = metal.dhcp;
const rng = metal.rng;
const tcp = metal.tcp;
const fetch = metal.fetch;

comptime {
    _ = metal.boot;
}

var nic_mem: net.Memory align(4096) = .{};
var rng_mem: rng.Memory align(4096) = .{};
var frame: [net.buffer_size]u8 align(16) = undefined;
var reply: [1024]u8 align(16) = undefined;
var out: [net.buffer_size]u8 align(16) = undefined;
var rx: [2][16 * 1024]u8 align(16) = undefined;
var tx: [2][4096]u8 align(16) = undefined;

fn isn() u32 {
    return rng.int(u32);
}

/// The body, counted and hashed (FNV-1a), so the serial log can say what
/// arrived without printing it.
const Digest = struct {
    bytes: u64 = 0,
    hash: u64 = 0xcbf29ce484222325,

    pub fn body(self: *Digest, bytes: []const u8) void {
        for (bytes) |b| {
            self.hash = (self.hash ^ b) *% 0x100000001b3;
        }
        self.bytes += bytes.len;
    }
};

pub fn kmain() noreturn {
    serial.init();
    serial.put("zig-metal-unikernel fetch probe\n");
    const ask = fetch.parseAsk(metal.boot.commandLine()) catch |e| switch (e) {
        error.NoTarget => serial.fail("the command line names no target: fetch <ip> <port> <path> connect_ms=N idle_ms=N total_ms=N"),
        error.BadAddress => serial.fail("the command line's address is not an IPv4 address"),
        error.BadPort => serial.fail("the command line's port is not a port"),
        error.NoDeadline => serial.fail("the command line lacks a deadline: connect_ms, idle_ms and total_ms have no defaults"),
        error.BadDeadline => serial.fail("a deadline on the command line is not a number of milliseconds"),
    };

    const hz = metal.pit.calibrate() catch serial.fail("the PIT would not calibrate the TSC");
    metal.io.startClock(hz);
    rng.attach(&rng_mem);
    const base = virtio.find(virtio.device_id_net) orelse
        serial.fail("no virtio-net device on the PCI bus or in any mmio slot");
    var nic = net.Net.init(base, &nic_mem) catch serial.fail("the NIC would not come up");
    const lease = dhcp.acquire(&nic, &frame, &reply) catch serial.fail("no DHCP lease");
    serial.put("  address: ");
    serial.putIp(lease.address);
    serial.put("\n  fetching ");
    serial.putIp(ask.target.ip);
    serial.put(" ");
    serial.put(ask.target.path);
    serial.put("\n");

    var slots = [_]tcp.Conn{ .{ .rx = &rx[0], .tx = &tx[0] }, .{ .rx = &rx[1], .tx = &tx[1] } };
    var table = tcp.Table.init(lease.address, nic.mac, 7, &slots, &out, isn);
    table.reserved_for_initiated = 1;
    table.ephemeral_next = @intCast(tcp.ephemeral_first + rng.int(u16) % (0xFFFF - tcp.ephemeral_first));

    const began = metal.io.awakeNs() orelse 0;
    var client = fetch.Client.init(ask.target, ask.deadlines, lease.address, nic.mac, began) catch
        serial.fail("the path is too long for the request");
    var digest: Digest = .{};
    const o = while (true) {
        const now = metal.io.awakeNs() orelse 0;
        while (nic.poll()) |got| {
            client.arrived(&table, &nic, got.frame, now);
            nic.recycle(got.id);
        }
        if (client.turn(&table, &nic, now, &digest)) |done| break done;
        asm volatile ("pause");
    };
    const took_ms = @divTrunc((metal.io.awakeNs() orelse 0) - began, std.time.ns_per_ms);
    serial.put("  outcome: ");
    serial.put(@tagName(o));
    serial.put(" after ");
    serial.putDec(@intCast(took_ms));
    serial.put(" ms; status ");
    serial.putDec(client.answer.status);
    serial.put(", ");
    serial.putDec(digest.bytes);
    serial.put(" body bytes, fnv1a ");
    serial.putHex(digest.hash, 16);
    serial.put("; ");
    serial.putDec(table.retransmits);
    serial.put(" retransmits, ");
    serial.putDec(table.held_segments);
    serial.put(" held ahead of a hole\n");
    serial.exitQemu(o.code());
}

pub const panic = metal.serial.panic;
