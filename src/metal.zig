//! Everything this machine is made of, as one module, so that a type from
//! `virtio.zig` is the same type wherever it is used. A kernel is a root file
//! that imports this and provides `kmain`.

pub const boot = @import("boot.zig");
pub const stack = @import("stack.zig");
pub const serial = @import("serial.zig");
pub const virtio = @import("virtio.zig");
pub const net = @import("net.zig");
pub const proto = @import("proto.zig");
pub const dhcp = @import("dhcp.zig");
pub const arp = @import("arp.zig");
pub const tcp = @import("tcp.zig");
pub const stream = @import("stream.zig");
pub const gpt = @import("gpt.zig");
pub const fat16 = @import("fat16.zig");
pub const rng = @import("rng.zig");
pub const io = @import("io.zig");
pub const port = @import("port.zig");
pub const tsc = @import("tsc.zig");
pub const rtc = @import("rtc.zig");
pub const pit = @import("pit.zig");
pub const wallclock = @import("wallclock.zig");
