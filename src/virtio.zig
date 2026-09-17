//! virtio over MMIO: the transport, and the block device on it.
//!
//! **THIS IS THE DEVICE THE FLOOR'S DISK DOOR WAS ALREADY SHAPED FOR.** A
//! virtio-blk request is a header naming a sector, a data buffer named by
//! ADDRESS, and a status byte -- which is `Disk.read!(lba, addr)` and its
//! outcome, arrived at from the other direction. Nothing here copies a sector;
//! the device writes into the page the caller named.
//!
//! The transport is virtio-mmio, not PCI: a device is a window of registers at
//! a known physical address, with a magic value at offset 0 and no bus to
//! enumerate. That is what QEMU's `microvm` machine and Firecracker give a
//! guest, and it is the smallest thing that could possibly work. A cloud VM
//! hands out the same devices behind PCI instead, which is a discovery
//! problem and not a different driver.
//!
//! The spec is virtio 1.2. Register offsets and constants below are its
//! numbers, not ours.

const std = @import("std");
const tsc = @import("tsc.zig");

// ---- the mmio register window --------------------------------------------

const Reg = enum(u32) {
    magic = 0x000, // "virt", 0x74726976
    version = 0x004, // 2 for the modern interface, 1 for legacy
    device_id = 0x008, // 2 is block, 1 is net
    vendor_id = 0x00c,
    device_features = 0x010,
    device_features_sel = 0x014,
    driver_features = 0x020,
    driver_features_sel = 0x024,
    queue_sel = 0x030,
    queue_num_max = 0x034,
    queue_num = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_ack = 0x064,
    status = 0x070,
    queue_desc_lo = 0x080,
    queue_desc_hi = 0x084,
    queue_driver_lo = 0x090,
    queue_driver_hi = 0x094,
    queue_device_lo = 0x0a0,
    queue_device_hi = 0x0a4,
    config = 0x100,
};

const magic_value: u32 = 0x74726976;

/// Status bits the driver walks up in order; the device watches them.
const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;
const status_failed: u32 = 128;

/// VIRTIO_F_VERSION_1: the driver speaks the modern interface. Without it a
/// modern device refuses to start.
const feature_version_1: u6 = 32;

pub const device_id_block: u32 = 2;
pub const device_id_net: u32 = 1;

/// The device may read the rings the instant the index moves, so the stores
/// that build a chain have to land before the store that publishes it.
fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn mmioRead(base: usize, reg: Reg) u32 {
    const p: *volatile u32 = @ptrFromInt(base + @intFromEnum(reg));
    return p.*;
}

fn mmioWrite(base: usize, reg: Reg, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(base + @intFromEnum(reg));
    p.* = value;
}

pub fn configRead8(base: usize, off: u32) u8 {
    const p: *volatile u8 = @ptrFromInt(base + @intFromEnum(Reg.config) + off);
    return p.*;
}

fn configRead64(base: usize, off: u32) u64 {
    const lo: *volatile u32 = @ptrFromInt(base + @intFromEnum(Reg.config) + off);
    const hi: *volatile u32 = @ptrFromInt(base + @intFromEnum(Reg.config) + off + 4);
    return (@as(u64, hi.*) << 32) | lo.*;
}

/// Every window QEMU's microvm machine puts a virtio-mmio transport in: slots
/// of 512 bytes from 0xFEB00000.
///
/// **THERE ARE 24 OF THEM AND QEMU FILLS THEM FROM THE TOP.** A single
/// `-device virtio-blk-device` lands on bus 23, at 0xFEB02E00, with the first
/// eight slots present-but-empty -- which looks exactly like "no device" if
/// you only scan eight. Measured with `info qtree`, 2026-09-16. 32 is scanned
/// for headroom; an empty transport answers device id 0 and costs one read.
pub const mmio_base: usize = 0xFEB00000;
pub const mmio_stride: usize = 0x200;
pub const mmio_slots: usize = 32;

/// What a slot says it is, for a host that wants to report the scan rather
/// than only its verdict.
pub fn magicAt(base: usize) u32 {
    return mmioRead(base, .magic);
}
pub fn versionAt(base: usize) u32 {
    return mmioRead(base, .version);
}
pub fn deviceIdAt(base: usize) u32 {
    return mmioRead(base, .device_id);
}

/// The first slot holding a device of this kind, or null. A slot whose magic
/// is wrong is empty; a slot whose version is not 2 is the legacy interface,
/// which this driver does not speak and will not pretend to.
pub fn find(want: u32) ?usize {
    var i: usize = 0;
    while (i < mmio_slots) : (i += 1) {
        const base = mmio_base + i * mmio_stride;
        if (mmioRead(base, .magic) != magic_value) continue;
        if (mmioRead(base, .device_id) != want) continue;
        if (mmioRead(base, .version) != 2) continue;
        return base;
    }
    return null;
}

// ---- the virtqueue -------------------------------------------------------

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const desc_flag_next: u16 = 1;
/// The DEVICE writes this buffer; without it the device reads.
pub const desc_flag_write: u16 = 2;

/// A virtqueue's three rings, laid out as one block of memory the caller owns.
/// The device is told where each ring is and then reads and writes them
/// directly: no ports, no copying, one doorbell.
///
/// Sized by its job. A block queue needs one chain in flight; a receive queue
/// wants as many buffers as it can hold frames.
pub fn Ring(comptime size: u16) type {
    return extern struct {
        const Self = @This();
        pub const len: u16 = size;

        desc: [size]Desc align(16),

        avail_flags: u16 align(2),
        avail_idx: u16,
        avail_ring: [size]u16,
        avail_used_event: u16,

        used_flags: u16 align(4),
        used_idx: u16,
        used_ring: [size]UsedElem,
        used_avail_event: u16,
    };
}

pub const UsedElem = extern struct { id: u32, len: u32 };

/// One queue on a device: the ring, which queue index it is, and how far we
/// have read its used ring.
pub fn Queue(comptime size: u16) type {
    return struct {
        const Self = @This();
        pub const RingType = Ring(size);

        base: usize,
        index: u16,
        ring: *RingType,
        last_used: u16 = 0,

        /// Tells the device where this queue's rings are and marks it ready.
        /// Must happen before DRIVER_OK.
        pub fn setup(base: usize, index: u16, ring: *RingType) Error!Self {
            mmioWrite(base, .queue_sel, index);
            if (mmioRead(base, .queue_num_max) < size) return Error.QueueTooSmall;
            mmioWrite(base, .queue_num, size);

            const ring_addr = @intFromPtr(ring);
            const avail_addr = ring_addr + @offsetOf(RingType, "avail_flags");
            const used_addr = ring_addr + @offsetOf(RingType, "used_flags");
            mmioWrite(base, .queue_desc_lo, @truncate(ring_addr));
            mmioWrite(base, .queue_desc_hi, @truncate(ring_addr >> 32));
            mmioWrite(base, .queue_driver_lo, @truncate(avail_addr));
            mmioWrite(base, .queue_driver_hi, @truncate(avail_addr >> 32));
            mmioWrite(base, .queue_device_lo, @truncate(used_addr));
            mmioWrite(base, .queue_device_hi, @truncate(used_addr >> 32));
            mmioWrite(base, .queue_ready, 1);

            ring.avail_flags = 0;
            ring.avail_idx = 0;
            ring.used_idx = 0;
            return .{ .base = base, .index = index, .ring = ring };
        }

        /// Puts the chain starting at descriptor `head` on the available ring.
        /// The caller has already filled the descriptors.
        pub fn offer(self: *Self, head: u16) void {
            self.ring.avail_ring[self.ring.avail_idx % size] = head;
            fence();
            self.ring.avail_idx +%= 1;
            fence();
        }

        /// Rings the doorbell for this queue.
        pub fn notify(self: *Self) void {
            mmioWrite(self.base, .queue_notify, self.index);
        }

        /// The next completion, or null if the device has published none.
        pub fn take(self: *Self) ?UsedElem {
            const idx = @as(*volatile u16, @ptrCast(&self.ring.used_idx)).*;
            if (idx == self.last_used) return null;
            const e = self.ring.used_ring[self.last_used % size];
            self.last_used +%= 1;
            return e;
        }

        /// Spins until a completion arrives. Nothing here has interrupts yet.
        pub fn wait(self: *Self) UsedElem {
            while (true) {
                if (self.take()) |e| return e;
                asm volatile ("pause");
            }
        }
    };
}

/// Walks the device up to DRIVER_OK, taking VIRTIO_F_VERSION_1 and whatever
/// else the caller names in `want_low` (feature bits below 32). Every step is
/// checked, because a device that has silently refused looks exactly like one
/// that is working until the first transfer hangs.
///
/// Answers the status word so far; the caller adds its queues, then calls
/// `driverOk`.
pub fn negotiate(base: usize, want_low: u32) Error!u32 {
    mmioWrite(base, .status, 0); // reset
    var st: u32 = status_acknowledge;
    mmioWrite(base, .status, st);
    st |= status_driver;
    mmioWrite(base, .status, st);

    mmioWrite(base, .device_features_sel, 1);
    const hi = mmioRead(base, .device_features);
    if (hi & (@as(u32, 1) << (feature_version_1 - 32)) == 0) {
        mmioWrite(base, .status, status_failed);
        return Error.DeviceRefused;
    }
    mmioWrite(base, .device_features_sel, 0);
    const lo = mmioRead(base, .device_features);
    if (lo & want_low != want_low) {
        mmioWrite(base, .status, status_failed);
        return Error.DeviceRefused;
    }

    mmioWrite(base, .driver_features_sel, 1);
    mmioWrite(base, .driver_features, @as(u32, 1) << (feature_version_1 - 32));
    mmioWrite(base, .driver_features_sel, 0);
    mmioWrite(base, .driver_features, want_low);

    st |= status_features_ok;
    mmioWrite(base, .status, st);
    if (mmioRead(base, .status) & status_features_ok == 0) {
        mmioWrite(base, .status, status_failed);
        return Error.DeviceRefused;
    }
    return st;
}

pub fn driverOk(base: usize, st: u32) Error!void {
    mmioWrite(base, .status, st | status_driver_ok);
    if (mmioRead(base, .status) & status_failed != 0) return Error.DeviceRefused;
}

/// The interrupt this device raised, acknowledged. Polling drivers still have
/// to do this or the device stops raising them.
pub fn ack(base: usize) void {
    const s = mmioRead(base, .interrupt_status);
    if (s != 0) mmioWrite(base, .interrupt_ack, s);
}

pub const Error = error{ NoDevice, DeviceRefused, QueueTooSmall, TransferFailed };

// ---- the block device ----------------------------------------------------

const blk_t_in: u32 = 0; // read from the device
const blk_t_out: u32 = 1; // write to the device

/// The three status bytes virtio-blk answers with. **The floor's Disk door
/// invented an outcome; this is where the outcome comes from.**
pub const blk_s_ok: u8 = 0;
pub const blk_s_ioerr: u8 = 1;
pub const blk_s_unsupp: u8 = 2;

const BlkReqHeader = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
};

pub const Block = struct {
    pub const Q = Queue(8);

    base: usize,
    q: Q,
    header: *BlkReqHeader,
    status: *volatile u8,
    /// The device's size in 512-byte sectors, from its config space.
    capacity: u64,

    /// **WHAT THE DEVICE COST.** Every request counted, and the timestamp-counter
    /// ticks spent between offering it and seeing it done — so a host can say
    /// how much of a slow HTTP request was the disk, rather than guessing. The
    /// soak could only see the whole machine slowing down; these split it.
    requests: u64 = 0,
    busy_ticks: u64 = 0,

    /// `mem` is memory the caller owns and keeps for as long as the device is
    /// up; it must be identity-mapped, since what goes in a descriptor is a
    /// PHYSICAL address.
    pub fn init(base: usize, mem: *BlockMemory) Error!Block {
        const st = try negotiate(base, 0);
        const q = try Q.setup(base, 0, &mem.ring);
        try driverOk(base, st);
        return .{
            .base = base,
            .q = q,
            .header = &mem.header,
            .status = &mem.status,
            .capacity = configRead64(base, 0),
        };
    }

    /// One request, start to finish, polled to completion. The chain is the
    /// spec's three descriptors: the header the device reads, the data buffer,
    /// and the status byte the device writes.
    ///
    /// **`addr` IS A PHYSICAL ADDRESS AND THE DEVICE WRITES IT DIRECTLY.**
    /// That is the whole reason the door takes an address: the 512 bytes never
    /// pass through this function.
    fn transfer(self: *Block, kind: u32, lba: u64, addr: u64, len: u32) u8 {
        self.header.* = .{ .type = kind, .reserved = 0, .sector = lba };
        self.status.* = 0xFF; // so a device that writes nothing is not read as OK

        const d = &self.q.ring.desc;
        d[0] = .{ .addr = @intFromPtr(self.header), .len = @sizeOf(BlkReqHeader), .flags = desc_flag_next, .next = 1 };
        d[1] = .{
            .addr = addr,
            .len = len,
            .flags = desc_flag_next | (if (kind == blk_t_in) desc_flag_write else 0),
            .next = 2,
        };
        d[2] = .{ .addr = @intFromPtr(self.status), .len = 1, .flags = desc_flag_write, .next = 0 };

        const began = tsc.read();
        self.q.offer(0);
        self.q.notify();
        _ = self.q.wait();
        ack(self.base);
        self.busy_ticks +%= tsc.read() -% began;
        self.requests +%= 1;
        return self.status.*;
    }

    /// The sector at `lba` into the 512 bytes at `addr`.
    pub fn read(self: *Block, lba: u64, addr: u64) u8 {
        return self.transfer(blk_t_in, lba, addr, 512);
    }

    /// The most sectors one request asks for. virtio-blk lets a device state
    /// its own limit only through features this driver does not negotiate, so
    /// the number is ours: 64 KB, well inside what any device accepts in a
    /// single segment, and enough that a file's run of clusters is one request
    /// rather than one per sector.
    pub const max_sectors: u32 = 128;

    /// `count` sectors from `lba` into the `count` × 512 bytes at `addr`, as ONE
    /// request. **This is what makes reading a file cost a request per run of
    /// clusters rather than a request per 512 bytes** — the soak read a 200 KB
    /// transcript on every chat send, and at a sector per request that was four
    /// hundred round trips through the emulator.
    pub fn readMany(self: *Block, lba: u64, addr: u64, count: u32) u8 {
        if (count == 0 or count > max_sectors) return blk_s_unsupp;
        return self.transfer(blk_t_in, lba, addr, count * 512);
    }

    /// The 512 bytes at `addr` become the sector at `lba`.
    pub fn write(self: *Block, lba: u64, addr: u64) u8 {
        return self.transfer(blk_t_out, lba, addr, 512);
    }

    /// The `count` × 512 bytes at `addr` become `count` sectors from `lba`, as
    /// ONE request — what makes a 10 MB upload about 160 requests instead of
    /// twenty thousand.
    pub fn writeMany(self: *Block, lba: u64, addr: u64, count: u32) u8 {
        if (count == 0 or count > max_sectors) return blk_s_unsupp;
        return self.transfer(blk_t_out, lba, addr, count * 512);
    }
};

/// The memory a Block needs, which a caller places somewhere identity-mapped.
pub const BlockMemory = struct {
    ring: Block.Q.RingType align(16) = undefined,
    header: BlkReqHeader align(16) = undefined,
    status: u8 = 0,

    pub fn bring(self: *BlockMemory, base: usize) Error!Block {
        return Block.init(base, self);
    }
};
