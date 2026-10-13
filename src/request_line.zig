//! **A REQUEST'S LINE IN THE LOG** (metal-vmm QUEUE 189.2): when it was, in
//! UTC to the millisecond, then what it was and how it ended, its status
//! code and how long it took, so "what happened at 14:02" is a grep:
//!
//!     2026-10-13T14:02:07.123Z request 12: POST /gopher/upload -> ok, 200 in 41.3 ms
//!
//! The time leads, where a reader scans and an agent greps; `request N:`
//! and what follows are as they were, so a judge that reads them still
//! does. A part not known is left out: no clock (before the hardware clock
//! is read), no status (no answer went out), no duration (no request came).
//! The caller writes the rest of the line (the memory figures) and its end.

const std = @import("std");
const civil = @import("civil.zig");

pub const Line = struct {
    number: u64,
    /// Milliseconds since the Unix epoch, UTC, if the clock is known.
    unix_ms: ?i64,
    what: []const u8,
    outcome: []const u8,
    /// The answer's status code; 0 when none went out.
    status: u16 = 0,
    /// From the request's head to its answer, if a request came.
    took_ns: ?u64 = null,
};

pub fn write(w: *std.Io.Writer, l: Line) std.Io.Writer.Error!void {
    if (l.unix_ms) |ms| {
        const c = civil.fromUnix(@divFloor(ms, std.time.ms_per_s));
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z ", .{
            @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second, @as(u32, @intCast(@mod(ms, std.time.ms_per_s))),
        });
    }
    try w.print("request {d}: {s} -> {s}", .{ l.number, l.what, l.outcome });
    if (l.status != 0) try w.print(", {d}", .{l.status});
    if (l.took_ns) |ns| {
        // Tenths of a millisecond, rounded down: 0.2 ms is under 0.3.
        const tenths = ns / (std.time.ns_per_ms / 10);
        try w.print(" in {d}.{d} ms", .{ tenths / 10, tenths % 10 });
    }
}

const testing = std.testing;

fn formatted(buf: []u8, l: Line) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try write(&w, l);
    return w.buffered();
}

test "a request's line leads with its UTC time to the millisecond, and says its status and how long it took" {
    var buf: [256]u8 = undefined;
    // 2026-10-13 14:02:07.123 UTC.
    const at: i64 = 1_791_900_127_123;
    try testing.expectEqualStrings(
        "2026-10-13T14:02:07.123Z request 12: POST /gopher/upload -> ok, 200 in 41.3 ms",
        try formatted(&buf, .{ .number = 12, .unix_ms = at, .what = "POST /gopher/upload", .outcome = "ok", .status = 200, .took_ns = 41_300_000 }),
    );
    // Under a millisecond, and the millisecond's own zeros.
    try testing.expectEqualStrings(
        "2026-10-13T14:02:07.005Z request 3: GET / -> ok, 304 in 0.2 ms",
        try formatted(&buf, .{ .number = 3, .unix_ms = at - 118, .what = "GET /", .outcome = "ok", .status = 304, .took_ns = 249_999 }),
    );
}

test "a part not known is left out: no clock, no status, no request" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "request 1: (no request) -> the client stopped sending, and was let go",
        try formatted(&buf, .{ .number = 1, .unix_ms = null, .what = "(no request)", .outcome = "the client stopped sending, and was let go" }),
    );
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00.000Z request 2: GET /x -> the client stopped taking the response in 12.0 ms",
        try formatted(&buf, .{ .number = 2, .unix_ms = 0, .what = "GET /x", .outcome = "the client stopped taking the response", .took_ns = 12_000_000 }),
    );
}
