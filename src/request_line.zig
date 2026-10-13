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

/// `2026-10-13T14:02:07.123Z`: Unix milliseconds as UTC, ISO 8601.
pub fn writeTime(w: *std.Io.Writer, ms: i64) std.Io.Writer.Error!void {
    // Years 0 to 9999 only (189's minor 11): a clock past them is said as
    // its raw count, never a panic.
    if (ms < year0_ms or ms > year9999_end_ms) return w.print("(unix ms {d})", .{ms});
    const c = civil.fromUnix(@divFloor(ms, std.time.ms_per_s));
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u32, @intCast(c.year)), c.month, c.day, c.hour, c.minute, c.second, @as(u32, @intCast(@mod(ms, std.time.ms_per_s))),
    });
}

pub fn write(w: *std.Io.Writer, l: Line) std.Io.Writer.Error!void {
    if (l.unix_ms) |ms| {
        try writeTime(w, ms);
        try w.writeByte(' ');
    }
    try w.print("request {d}: {s} -> {s}", .{ l.number, l.what, l.outcome });
    if (l.status != 0) try w.print(", {d}", .{l.status});
    if (l.took_ns) |ns| {
        // Tenths of a millisecond, rounded down: 0.2 ms is under 0.3.
        const tenths = ns / (std.time.ns_per_ms / 10);
        try w.print(" in {d}.{d} ms", .{ tenths / 10, tenths % 10 });
    }
}

/// **WHAT A REQUEST WAS: ITS METHOD AND PATH** (metal-vmm QUEUE 194.5),
/// for the route's line and a refusal's alike, so /admin/log's `path=`
/// finds a request refused at its head too. `path` is without its query;
/// past 256 bytes it is cut.
pub fn what(buf: []u8, method: []const u8, path: []const u8, refused_at_head: bool) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {s}{s}", .{
        method,
        path[0..@min(path.len, 256)],
        if (refused_at_head) " (refused at its head)" else "",
    }) catch "(unprintable)";
}

/// 0000-01-01T00:00:00.000Z and 9999-12-31T23:59:59.999Z, in Unix ms.
const year0_ms: i64 = -62_167_219_200_000;
const year9999_end_ms: i64 = 253_402_300_799_999;

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

test "the plants (metal-vmm QUEUE 189.6): a line of each kind the log writes, carrying each kind of secret, comes out of the ring redacted, and a message's text is never in it" {
    const log_ring = @import("log_ring.zig");
    const uploads_seen = @import("uploads_seen.zig");
    var ring_buf: [8192]u8 = undefined;
    var ring = log_ring.Ring.init(&ring_buf);
    // A request line for each secret a target or an outcome may carry.
    const targets = [_][]const u8{
        "/login/full?password=hunter2&next=/chat",
        "/login/full?passwd=hunter2",
        "/admin/apikey?key=0123456789abcdef",
        "/x?token=s3cret-token",
        "/x?session=s3cret-session",
        "/x?secret=s3cret-secret",
        "/x?bcrypt=$2b$12$abcdefghijklmnopqrstuv",
        "/chat/c/1_2/T/uploads/00112233445566778899aabbccddeeff.png",
        // A message posted in its query: its text is the query's, never kept.
        "/chat/c/1_2/T/send?markdown=meet+me+at+the+old+mill+at+noon",
    };
    var line: [512]u8 = undefined;
    for (targets, 0..) |t, i| {
        var w: std.Io.Writer = .fixed(&line);
        try write(&w, .{ .number = i, .unix_ms = 1_791_900_127_123, .what = log_ring.withoutQuery(t), .outcome = "ok", .status = 200, .took_ns = 1 });
        ring.write("  ");
        ring.write(w.buffered());
        ring.write("\n");
    }
    // Lines the kernel writes that carry a header or a key in their text.
    for ([_][]const u8{
        "  Cookie: __Host-gopher_auth=MQ.1791900127.AAAA; gopher_uid=7\n",
        "  set-cookie: __Host-gopher_auth=MQ.1791900127.BBBB; HttpOnly\n",
        "  Authorization: Bearer 0123456789abcdef0123456789abcdef\n",
        "  uploader: password: hunter2\n",
    }) |l| ring.write(l);
    // An upload's line, its path naming the upload.
    const u: uploads_seen.Upload = .{
        .number = 99,
        .unix_ms = 1_791_900_127_123,
        .path = .of("/chat/c/1_2/T/uploads/ffeeddccbbaa99887766554433221100.jpg"),
        .kind = .of("image/jpeg"),
        .bytes = 9,
        .arrival_ms = 1,
        .turn_ms = 1,
        .disk_requests = 1,
        .status = 200,
        .outcome = .ok,
    };
    var w: std.Io.Writer = .fixed(&line);
    try u.write(&w);
    ring.write("    upload: ");
    ring.write(w.buffered());
    ring.write("\n");

    var out: [8192]u8 = undefined;
    const held = ring.read(&out);
    for ([_][]const u8{
        "hunter2",       "0123456789abcdef",                 "s3cret",
        "$2b$",          "00112233445566778899aabbccddeeff", "ffeeddccbbaa99887766554433221100",
        "MQ.1791900127", "old mill",                         "meet",
        "markdown",
    }) |secret| if (std.mem.indexOf(u8, held, secret) != null) {
        std.debug.print("a secret survived: {s}\nin:\n{s}\n", .{ secret, held });
        return error.TestUnexpectedResult;
    };
    // And the lines are still there to read: each request, and the upload.
    try testing.expect(std.mem.indexOf(u8, held, "request 8: /chat/c/1_2/T/send -> ok, 200") != null);
    try testing.expect(std.mem.indexOf(u8, held, "/uploads/[redacted].jpg, image/jpeg, 9 bytes") != null);
}

test "a request refused at its head says its method and path, as the route's line does (metal-vmm QUEUE 194.5)" {
    var buf: [300]u8 = undefined;
    try testing.expectEqualStrings("POST /chat/c/1_2/T/upload (refused at its head)", what(&buf, "POST", "/chat/c/1_2/T/upload", true));
    try testing.expectEqualStrings("GET /docs", what(&buf, "GET", "/docs", false));
    var long: [400]u8 = @splat('a');
    long[0] = '/';
    try testing.expectEqual(@as(usize, 4 + 256), what(&buf, "GET", &long, false).len);
}

test "writeTime of any i64 does not panic: years 0 to 9999 as a time, past them the raw count (189's minor 11)" {
    var buf: [64]u8 = undefined;
    for ([_]i64{ std.math.minInt(i64), year0_ms - 1, year0_ms, -1, 0, year9999_end_ms, year9999_end_ms + 1, std.math.maxInt(i64) }) |ms| {
        var w: std.Io.Writer = .fixed(&buf);
        try writeTime(&w, ms);
    }
    var w: std.Io.Writer = .fixed(&buf);
    try writeTime(&w, year0_ms);
    try testing.expectEqualStrings("0000-01-01T00:00:00.000Z", w.buffered());
    w = .fixed(&buf);
    try writeTime(&w, year9999_end_ms);
    try testing.expectEqualStrings("9999-12-31T23:59:59.999Z", w.buffered());
    w = .fixed(&buf);
    try writeTime(&w, -1);
    try testing.expectEqualStrings("1969-12-31T23:59:59.999Z", w.buffered());
}
