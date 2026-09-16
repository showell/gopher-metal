//! Everything this machine is made of, as one module, so that a type from
//! `virtio.zig` is the same type wherever it is used. A kernel is a root file
//! that imports this and provides `kmain`.

pub const boot = @import("boot.zig");
pub const serial = @import("serial.zig");
pub const virtio = @import("virtio.zig");
pub const net = @import("net.zig");
pub const proto = @import("proto.zig");
pub const dhcp = @import("dhcp.zig");
