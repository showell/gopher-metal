//! Bringing this machine's clocks up from its own hardware, in one call:
//!
//!   1. how fast the timestamp counter runs — measured against the PIT;
//!   2. what time it is — read from the CMOS clock, at the moment its seconds
//!      tick over, with the timestamp counter captured at that same moment.
//!
//! After `start`, `Io.Clock.now(.awake)` measures real durations and
//! `Io.Clock.now(.real)` answers Unix time, which is what angry-gopher's
//! session expiry, creation times and last-seen need. Before it, both refuse.
//!
//! It costs up to a second, spent waiting for the edge. That is the price of an
//! anchor accurate to the polling delay instead of to the RTC's one-second
//! resolution.

const io = @import("io.zig");
const pit = @import("pit.zig");
const rtc = @import("rtc.zig");
const tsc = @import("tsc.zig");

pub const Error = pit.Error || rtc.DeviceError || rtc.DecodeError;

pub const Started = struct {
    /// Timestamp-counter ticks per second, as measured.
    tsc_hz: u64,
    /// The Unix time the RTC reported at the edge.
    unix: i64,
};

pub fn start() Error!Started {
    const hz = try pit.calibrate();
    io.startClock(hz);

    var at: u64 = 0;
    const raw = try rtc.readAtEdge(&at, capture);
    const unix = rtc.toUnix(try rtc.decode(raw));
    io.setRealTimeAt(unix, at);
    return .{ .tsc_hz = hz, .unix = unix };
}

fn capture(at: *u64) void {
    at.* = tsc.read();
}
