//! virtio-net over MMIO: frames out, frames in.
//!
//! Two virtqueues, and the asymmetry between them is the whole of the driver.
//! **The receive queue is filled with empty buffers before the device is told
//! it may run**, because a device with nowhere to put a frame drops it; the
//! transmit queue is filled one buffer at a time, when there is something to
//! send. Every buffer, in both directions, carries a 12-byte virtio header in
//! front of the ethernet frame.
//!
//! Nothing here interprets a frame. That is `proto.zig`'s job, and keeping the
//! line there is what lets the same driver carry ARP, DHCP and eventually TCP
//! without learning about any of them.

const virtio = @import("virtio.zig");

/// The header on every buffer in both directions. With VIRTIO_F_VERSION_1 it
/// always carries `num_buffers`, so it is 12 bytes and not the legacy 10.
pub const Header = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    num_buffers: u16 = 0,
};

comptime {
    if (@sizeOf(Header) != 12) @compileError("virtio-net header must be 12 bytes under VERSION_1");
}

/// VIRTIO_NET_F_MAC: the device tells us our own address in its config space.
/// Without it we would have to invent one, which QEMU's network would then not
/// route to.
const feature_mac: u32 = 1 << 5;

/// An ethernet frame is at most 1514 bytes without the FCS; 2048 leaves room
/// for the header in front and is a round number the device likes.
pub const buffer_size: usize = 2048;
pub const rx_buffers: u16 = 8;

pub const Q = virtio.Queue(rx_buffers);

/// The rings and the buffers, which the caller owns and keeps for as long as
/// the device is up. Identity-mapped, because a descriptor carries a PHYSICAL
/// address.
pub const Memory = struct {
    rx_ring: Q.RingType align(16) = undefined,
    tx_ring: Q.RingType align(16) = undefined,
    rx_bufs: [rx_buffers][buffer_size]u8 align(16) = undefined,
    tx_buf: [buffer_size]u8 align(16) = undefined,
};

pub const Net = struct {
    base: usize,
    rx: Q,
    tx: Q,
    mem: *Memory,
    /// Our own hardware address, from the device.
    mac: [6]u8,

    pub fn init(base: usize, mem: *Memory) virtio.Error!Net {
        const st = try virtio.negotiate(base, feature_mac);
        var rx = try Q.setup(base, 0, &mem.rx_ring);
        const tx = try Q.setup(base, 1, &mem.tx_ring);

        // **EVERY RECEIVE BUFFER IS OFFERED BEFORE DRIVER_OK.** A frame that
        // arrives with no buffer waiting is dropped, and the first frame we
        // care about is the answer to the first frame we send.
        var i: u16 = 0;
        while (i < rx_buffers) : (i += 1) {
            rx.ring.desc[i] = .{
                .addr = @intFromPtr(&mem.rx_bufs[i]),
                .len = buffer_size,
                .flags = virtio.desc_flag_write,
                .next = 0,
            };
            rx.offer(i);
        }

        var mac: [6]u8 = undefined;
        for (&mac, 0..) |*b, k| b.* = virtio.configRead8(base, @intCast(k));

        try virtio.driverOk(base, st);
        rx.notify();
        return .{ .base = base, .rx = rx, .tx = tx, .mem = mem, .mac = mac };
    }

    /// Sends one frame, and waits for the device to say it took it. Waiting is
    /// what keeps `tx_buf` safe to reuse on the next call.
    pub fn send(self: *Net, frame: []const u8) void {
        const hdr: *Header = @ptrCast(@alignCast(&self.mem.tx_buf));
        hdr.* = .{};
        @memcpy(self.mem.tx_buf[@sizeOf(Header)..][0..frame.len], frame);

        self.tx.ring.desc[0] = .{
            .addr = @intFromPtr(&self.mem.tx_buf),
            .len = @intCast(@sizeOf(Header) + frame.len),
            .flags = 0,
            .next = 0,
        };
        self.tx.offer(0);
        self.tx.notify();
        _ = self.tx.wait();
        virtio.ack(self.base);
    }

    /// The next frame the device has delivered, or null. The slice points into
    /// the receive buffer it arrived in and stays valid until `recycle`.
    pub fn poll(self: *Net) ?struct { id: u16, frame: []const u8 } {
        const e = self.rx.take() orelse return null;
        virtio.ack(self.base);
        const id: u16 = @intCast(e.id);
        if (id >= rx_buffers or e.len <= @sizeOf(Header)) {
            self.recycle(id);
            return null;
        }
        return .{
            .id = id,
            .frame = self.mem.rx_bufs[id][@sizeOf(Header)..e.len],
        };
    }

    /// Hands a receive buffer back to the device. A driver that forgets this
    /// works until it has used every buffer once and then goes quiet, which is
    /// a memorable afternoon.
    pub fn recycle(self: *Net, id: u16) void {
        self.rx.ring.desc[id] = .{
            .addr = @intFromPtr(&self.mem.rx_bufs[id]),
            .len = buffer_size,
            .flags = virtio.desc_flag_write,
            .next = 0,
        };
        self.rx.offer(id);
        self.rx.notify();
    }
};
