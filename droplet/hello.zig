//! **THE FIRST KERNEL FOR A REAL DROPLET.** Takes a DHCP lease on both of a
//! droplet's network cards (public, then private, in PCI slot order), puts
//! both addresses on the screen, and answers every HTTP request on either
//! card, forever:
//!
//!     hello from no Linux, on the private card, request 3
//!
//! It never stops, because on a droplet there is no one to stop for: the
//! verdict is what `curl` gets, from this box to the public address and from
//! a droplet in the same region to the private one. Every request is logged on
//! the screen, which is what DigitalOcean's recovery console shows.
//!
//! A card that gets no lease is said so and left alone; the other still
//! serves.

const std = @import("std");
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

const slots_per_card = 4;

/// One network card and everything it needs to serve.
const Card = struct {
    name: []const u8,
    nic: net.Net = undefined,
    lease: dhcp.Lease = .{},
    up: bool = false,
    conns: [slots_per_card]tcp.Conn = undefined,
    rx: [slots_per_card][4096]u8 align(16) = undefined,
    tx: [slots_per_card][4096]u8 align(16) = undefined,
    answered: [slots_per_card]bool = @splat(false),
    table: tcp.Table = undefined,
};

var nic_mem: [2]net.Memory align(4096) = .{ .{}, .{} };
var rng_mem: rng.Memory align(4096) = .{};
var frame: [net.buffer_size]u8 align(16) = undefined;
var reply: [1024]u8 align(16) = undefined;
var out: [net.buffer_size]u8 align(16) = undefined;
var cards = [2]Card{ .{ .name = "public" }, .{ .name = "private" } };
var requests: u64 = 0;

fn isn() u32 {
    return rng.int(u32);
}

fn complete(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, "\r\n\r\n") != null;
}

fn firstLine(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, bytes, "\r\n") orelse bytes.len;
    return bytes[0..@min(end, 60)];
}

/// Brings card `n` up and asks for its lease. Answers whether it has one.
fn bringUp(card: *Card, n: usize) bool {
    const device = virtio.findNth(virtio.device_id_net, n) orelse {
        serial.put("  ");
        serial.put(card.name);
        serial.put(" card: not on the bus\n");
        return false;
    };
    card.nic = net.Net.init(device, &nic_mem[n]) catch {
        serial.put("  ");
        serial.put(card.name);
        serial.put(" card: would not come up\n");
        return false;
    };
    card.lease = dhcp.acquire(&card.nic, &frame, &reply) catch {
        serial.put("  ");
        serial.put(card.name);
        serial.put(" card: no DHCP lease\n");
        return false;
    };
    for (&card.conns, 0..) |*c, k| c.* = .{ .rx = &card.rx[k], .tx = &card.tx[k] };
    card.table = tcp.Table.init(card.lease.address, card.nic.mac, 80, &card.conns, &out, isn);
    serial.put("  ");
    serial.put(card.name);
    serial.put(" card: ");
    serial.putIp(card.lease.address);
    serial.put(" (mask ");
    serial.putIp(card.lease.mask);
    serial.put(", router ");
    serial.putIp(card.lease.router);
    serial.put(")\n");
    return true;
}

/// Takes one frame off a card, if one is waiting, and answers what it asks.
fn serveOne(card: *Card, now: i96) void {
    card.table.transmit(&card.nic, now);
    const got = card.nic.poll() orelse return;
    defer card.nic.recycle(got.id);

    if (arp.parseRequest(got.frame)) |req| {
        if (std.mem.eql(u8, &req.target_ip, &card.lease.address)) {
            const len = arp.writeReply(&out, card.nic.mac, card.lease.address, req);
            card.nic.send(out[0..len]);
        }
        return;
    }

    const r = card.table.handle(&card.nic, got.frame, now);
    switch (r.event) {
        .opened => card.answered[r.index] = false,
        .data, .peer_done => {
            const pending = card.table.conns[r.index].pending();
            if (card.answered[r.index] or !complete(pending)) return;
            requests += 1;
            var body_buf: [96]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "hello from no Linux, on the {s} card, request {d}\n", .{ card.name, requests }) catch unreachable;
            var head_buf: [160]u8 = undefined;
            const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.len}) catch unreachable;
            if (card.table.queue(r.index, head) != head.len or card.table.queue(r.index, body) != body.len) {
                serial.put("  a response did not fit in its send queue\n");
            }
            card.table.finish(r.index);
            card.answered[r.index] = true;
            serial.put("  request ");
            serial.putDec(requests);
            serial.put(" on the ");
            serial.put(card.name);
            serial.put(" card: ");
            serial.put(firstLine(pending));
            serial.put("\n");
        },
        .closed => card.answered[r.index] = false,
        .nothing => {},
    }
}

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal, on a droplet, with no Linux\n");

    const hz = metal.pit.calibrate() catch serial.fail("the PIT would not calibrate the TSC");
    metal.io.startClock(hz);
    rng.attach(&rng_mem);

    var any = false;
    for (&cards, 0..) |*card, n| {
        card.up = bringUp(card, n);
        any = any or card.up;
    }
    if (!any) serial.fail("no card has an address, so there is nothing to listen on");
    serial.put("  listening on port 80\n");

    while (true) {
        const now = metal.io.awakeNs() orelse 0;
        for (&cards) |*card| {
            if (card.up) serveOne(card, now);
        }
        asm volatile ("pause");
    }
}
