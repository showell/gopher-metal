//! host_io for this machine: its own `Io` (io.zig), where the application's
//! files would have std's. The build hands the application's unchanged
//! sources this file as their `host_io` module; on Linux their own build
//! hands them std's (angry-gopher's src/host_io_std.zig). It reaches the
//! machine as the `metal` module, which the judges' builds point at their
//! simulated world instead.
pub const Io = @import("metal").io;
