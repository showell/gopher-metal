//! **THE PCI BUS: HOW A PC SAYS WHAT IS PLUGGED INTO IT.** QEMU's microvm puts
//! each device at an address you are told in advance; a PC, and so a
//! DigitalOcean droplet, puts them in numbered slots and expects you to ask.
//! Every slot answers through two I/O ports: write which slot and register to
//! 0xCF8, read the answer at 0xCFC. A slot with nothing in it answers 0xFFFF
//! as its vendor.
//!
//! Each device's registers say who made it, what it is, where its memory
//! windows (BARs) were put by the BIOS, and a chain of **capabilities**:
//! small records that, for a virtio device, say which window holds which of
//! its controls. This file reads all of that and knows nothing about virtio.
//!
//! Configuration mechanism #1 of the PCI Local Bus Specification 3.0, §3.2.2.3.2;
//! bus 0 only, because a droplet has one bus and no bridges.

const props = @import("coverage");
const port = @import("port.zig");

const address_port: u16 = 0xCF8;
const data_port: u16 = 0xCFC;

/// One function in one slot on bus 0.
pub const Function = struct {
    slot: u8,
    function: u8,

    fn address(self: Function, register: u8) u32 {
        return 0x8000_0000 | (@as(u32, self.slot) << 11) | (@as(u32, self.function) << 8) | (register & 0xFC);
    }

    pub fn read32(self: Function, register: u8) u32 {
        port.outl(address_port, self.address(register));
        return port.inl(data_port);
    }

    pub fn read16(self: Function, register: u8) u16 {
        return @truncate(self.read32(register) >> @intCast((register & 2) * 8));
    }

    pub fn read8(self: Function, register: u8) u8 {
        return @truncate(self.read32(register) >> @intCast((register & 3) * 8));
    }

    pub fn write16(self: Function, register: u8, value: u16) void {
        port.outl(address_port, self.address(register));
        port.outw(data_port + (register & 2), value);
    }

    pub fn vendor(self: Function) u16 {
        return self.read16(0x00);
    }

    pub fn device(self: Function) u16 {
        return self.read16(0x02);
    }

    pub fn subsystem(self: Function) u16 {
        return self.read16(0x2E);
    }

    /// **A DEVICE MAY NOT TOUCH MEMORY UNTIL IT IS TOLD IT MAY.** Bit 1 lets
    /// us reach its windows; bit 2 (bus master) lets it read and write ours,
    /// which is how a virtqueue works at all. QEMU refuses a device's memory
    /// accesses without it, so a forgotten bit 2 is a request that never
    /// completes.
    pub fn enable(self: Function) void {
        self.write16(0x04, self.read16(0x04) | 0x0006);
    }

    /// The physical address a BAR was given, or null for an I/O-port BAR or
    /// an empty one. A 64-bit BAR takes the next register for its top half.
    pub fn bar(self: Function, index: u8) ?u64 {
        if (index > 5) {
            props.reachable(@src(), "pci: a BAR past the sixth", null);
            return null;
        }
        const register = 0x10 + index * 4;
        const low = self.read32(register);
        if (low & 1 != 0) {
            props.reachable(@src(), "pci: an I/O-space BAR, which this driver does not map", null);
            return null; // I/O space
        }
        var at: u64 = low & 0xFFFF_FFF0;
        if ((low >> 1) & 3 == 2) {
            if (index == 5) {
                props.reachable(@src(), "pci: a 64-bit BAR in the last slot, with no register for its top half", null);
                return null;
            }
            at |= @as(u64, self.read32(register + 4)) << 32;
        }
        return if (at == 0) null else at;
    }

    /// The capability list, if the device has one: status bit 4 says so, and
    /// register 0x34 points at the first record.
    pub fn capabilities(self: Function) Capabilities {
        const has = self.read16(0x06) & 0x10 != 0;
        return .{ .function = self, .next = if (has) self.read8(0x34) & 0xFC else 0 };
    }
};

pub const Capabilities = struct {
    function: Function,
    next: u8,
    /// A record's id, and where it starts in configuration space. A list that
    /// loops is stopped after 48 records: there is room for no more.
    seen: u8 = 0,

    pub fn nextOne(self: *Capabilities) ?struct { id: u8, at: u8 } {
        if (self.next == 0 or self.seen == 48) return null;
        const at = self.next;
        self.seen += 1;
        self.next = self.function.read8(at + 1) & 0xFC;
        return .{ .id = self.function.read8(at), .at = at };
    }
};

/// Whether a vendor id means a device is there. **NOBODY IS EITHER ALL ONES
/// OR ALL ZEROES**: a real bus with an empty slot reads 0xFFFF, and a machine
/// with no bus at all may answer either (QEMU's microvm reads 0xFFFF;
/// metal-vmm answers every port it does not model with zeroes). Neither is a
/// vendor the PCI-SIG ever assigned.
fn someone(vendor_id: u16) bool {
    return vendor_id != 0xFFFF and vendor_id != 0x0000;
}

/// Whether this machine has a PCI bus at all: the host bridge in slot 0
/// answers.
pub fn present() bool {
    return someone((Function{ .slot = 0, .function = 0 }).vendor());
}

/// Every function on bus 0, in slot order.
pub const Scan = struct {
    slot: u8 = 0,
    function: u8 = 0,

    pub fn next(self: *Scan) ?Function {
        while (self.slot < 32) {
            const first = Function{ .slot = self.slot, .function = 0 };
            const f = Function{ .slot = self.slot, .function = self.function };
            // An empty slot reads all ones, header type included, so it is
            // empty before it is anything else. Only function 0 says whether
            // there are others (header type bit 7).
            const here = someone(first.vendor());
            const multi = here and first.read8(0x0E) & 0x80 != 0;
            if (self.function == 7 or !multi) {
                self.slot += 1;
                self.function = 0;
            } else {
                self.function += 1;
            }
            if (here and someone(f.vendor())) return f;
        }
        return null;
    }
};
