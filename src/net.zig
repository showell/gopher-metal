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
//!
//! **WHAT WAITS IN THE DRIVER, AND WHAT BOUNDS THE WAIT** (TCP_TESTING.md
//! §2). The driver drains nothing by itself; whoever calls `poll` does.
//!
//! - **Frames the device has delivered** (the receive ring's used entries).
//!   Taken by `poll`, which `stream.pump` calls until the ring is empty.
//!   Bounded by: the next `pump` — at most `interrupts.slice_ns` while the
//!   machine is idle, since a frame's arrival or the timer wakes it; but
//!   nothing at all while a request does work that does not pump (the
//!   disk). Then the ring fills, and past `rx_buffers` frames the device
//!   drops what arrives: the wait is bounded, by loss, and TCP sends again.
//! - **A receive buffer handed out by `poll`.** Returned by `recycle`, which
//!   `pump` defers to the end of the frame's turn. Bounded by: that turn.
//! - **A frame being sent** (`send`). One buffer, reused, so `send` waits
//!   until the device has taken it, resting between looks. Bounded by: the
//!   device alone — nothing here gives up. A device that stopped taking
//!   frames would stop the machine; on a droplet the device's own thread
//!   needs this processor, which the rest gives back.

const virtio = @import("virtio.zig");
const interrupts = @import("interrupts.zig");

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
    device: virtio.Device,
    rx: Q,
    tx: Q,
    mem: *Memory,
    /// Our own hardware address, from the device.
    mac: [6]u8,
    /// Frames sent since the device came up.
    sent: u64 = 0,

    pub fn init(found: virtio.Device, mem: *Memory) virtio.Error!Net {
        const st = try virtio.negotiate(found, feature_mac);
        // After negotiate's reset and before the queues: their vectors must be
        // set before they are enabled.
        const device = virtio.prepareMsix(found);
        var rx = try Q.setup(device, 0, &mem.rx_ring);
        const tx = try Q.setup(device, 1, &mem.tx_ring);

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
        for (&mac, 0..) |*b, k| b.* = virtio.configRead8(device, @intCast(k));

        try virtio.driverOk(device, st);
        rx.notify();
        return .{ .device = device, .rx = rx, .tx = tx, .mem = mem, .mac = mac };
    }

    /// Sends one frame, and waits for the device to say it took it. Waiting is
    /// what keeps `tx_buf` safe to reuse on the next call.
    pub fn send(self: *Net, frame: []const u8) void {
        self.sent +%= 1;
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
        // The device's thread takes the frame; on a droplet it needs this
        // processor to do it, so the wait rests rather than spins.
        while (self.tx.take() == null) interrupts.rest();
        virtio.ack(self.device);
    }

    /// From now on both queues interrupt this processor at `vector` when
    /// they have something: a frame arrived, or a frame was taken. False on a
    /// card that cannot (mmio, or no MSI-X), which goes on being polled.
    pub fn interruptOnFrames(self: *Net, address: u32, vector: u8) bool {
        if (!self.rx.vectored or !self.tx.vectored) return false;
        return virtio.routeToProcessor(self.device, address, vector);
    }

    /// The next frame the device has delivered, or null. The slice points into
    /// the receive buffer it arrived in and stays valid until `recycle`.
    ///
    /// **NULL MEANS THE RING IS EMPTY, AND NOTHING ELSE.** A completion that
    /// carries no frame is passed over, not reported as the end: a caller that
    /// drains until null would otherwise stop with frames still waiting behind
    /// it. One naming a buffer we never offered cannot be handed back, and is
    /// dropped; one too short to hold a header returns its buffer at once.
    pub fn poll(self: *Net) ?struct { id: u16, frame: []const u8 } {
        while (self.rx.take()) |e| {
            virtio.ack(self.device);
            if (e.id >= rx_buffers) continue;
            const id: u16 = @intCast(e.id);
            if (e.len <= @sizeOf(Header) or e.len > buffer_size) {
                self.recycle(id);
                continue;
            }
            return .{
                .id = id,
                .frame = self.mem.rx_bufs[id][@sizeOf(Header)..e.len],
            };
        }
        return null;
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
