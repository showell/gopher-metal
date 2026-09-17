//! The network code that touches no device, as one module, for programs that
//! run it somewhere other than this machine — `native/serve.zig` runs it on
//! Linux behind a TAP device, with Linux's own TCP as the peer.

pub const proto = @import("proto.zig");
pub const arp = @import("arp.zig");
pub const tcp = @import("tcp.zig");
