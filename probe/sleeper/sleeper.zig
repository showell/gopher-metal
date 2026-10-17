//! **THE SLEEPER: AN APPLICATION THAT ONLY WAKES** (docs/designs/DESIGN-sleep.md).
//! The test of a sleeping kernel: its `between` asks to be woken every
//! `period_ms`, and each wake appends one line to `wakes.txt` in its data:
//!
//!     wake 3 due 180000000000 at 180000000412 unix 1789000180
//!
//! `due` is when it asked to be woken and `at` when it was, both on the awake
//! clock in nanoseconds, so a judge reads how late each wake was from the
//! disk afterwards. It schedules from `due`, not from when it woke, so
//! lateness never accumulates. Its one page, `/`, is the lines.
//!
//! The period is `period_ms = N` in `sleeper.conf` in its data folder, 60000
//! when there is none: a test chooses it, the code does not.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");

pub const site = webbox.site.Site(@This());

pub const hosting = struct {
    pub const name = "the sleeper";
    pub const data_name = "the sleeper's wakes";
    pub const whole_read_max = 1024 * 1024;
    pub const cache_largest_most = 1024 * 1024;
    pub fn describeStart(r: StartReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("waking every {d} ms, its lines in {s}/wakes.txt\n", .{ r.period_ms, r.data_dir });
    }
};

pub const StartReport = struct { period_ms: u64, data_dir: []const u8 };

const default_period_ms = 60_000;

var data_root: []const u8 = "data";
var wakes_path: []const u8 = "data/wakes.txt";
var period_ns: i96 = default_period_ms * std.time.ns_per_ms;
/// When the next wake is due; null before the first call, which is due at
/// once.
var due: ?i96 = null;
var count: u64 = 0;
/// For a line's path and text: a wake holds nothing past its call.
var scratch: [4096]u8 = undefined;

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    if (roots) |r| data_root = r.data_dir;
    try webbox.store.makeDir(io, base, data_root);
    wakes_path = try std.fmt.allocPrint(base, "{s}/wakes.txt", .{data_root});
    const conf_path = try std.fmt.allocPrint(base, "{s}/sleeper.conf", .{data_root});
    var ms: u64 = default_period_ms;
    if (webbox.store.read(io, base, conf_path, .limited(256))) |text| {
        ms = periodOf(text) orelse return error.BadSleeperConf;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    period_ns = @as(i96, ms) * std.time.ns_per_ms;
    return .{ .period_ms = ms, .data_dir = data_root };
}

/// `period_ms = N`, N above zero; null for anything else.
fn periodOf(text: []const u8) ?u64 {
    const line = std.mem.trim(u8, text, " \t\r\n");
    const prefix = "period_ms";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = std.mem.trim(u8, line[prefix.len..], " \t");
    if (rest.len == 0 or rest[0] != '=') return null;
    const n = std.fmt.parseInt(u64, std.mem.trim(u8, rest[1..], " \t"), 10) catch return null;
    return if (n == 0) null else n;
}

pub fn between(io: Io, now: webbox.site.Now) webbox.site.Wake {
    const at = due orelse now.awake_ns;
    if (now.awake_ns < at) return .{ .at = at };
    count += 1;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const line = std.fmt.allocPrint(fba.allocator(), "wake {d} due {d} at {d} unix {d}\n", .{ count, at, now.awake_ns, now.unix_s }) catch unreachable;
    _ = webbox.store.append(io, fba.allocator(), wakes_path, line) catch {};
    due = nextDue(at, period_ns, now.awake_ns);
    return .{ .at = due.? };
}

/// The wake after one due at `at`: a period on from it, or, past a wake
/// missed whole, the first period boundary after `now`.
fn nextDue(at: i96, period: i96, now: i96) i96 {
    const next = at + period;
    if (next > now) return next;
    return at + period * (@divFloor(now - at, period) + 1);
}

pub fn bodyLimit(_: []const u8) u64 {
    return 0;
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const text = webbox.store.read(io, alloc, wakes_path, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    try req.respond(text, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}

test "sleeper: the period is read from its conf, and nothing else is one" {
    try std.testing.expectEqual(@as(?u64, 500), periodOf("period_ms = 500\n"));
    try std.testing.expectEqual(@as(?u64, 60000), periodOf("period_ms=60000"));
    try std.testing.expectEqual(@as(?u64, null), periodOf("period_ms = 0"));
    try std.testing.expectEqual(@as(?u64, null), periodOf("period = 5"));
    try std.testing.expectEqual(@as(?u64, null), periodOf("period_ms = five"));
}

test "sleeper: the next wake is a period on from the last one due, never from when it woke" {
    const s = std.time.ns_per_s;
    try std.testing.expectEqual(@as(i96, 120 * s), nextDue(60 * s, 60 * s, 60 * s + 400));
    // Woken late past a whole period: the next boundary after now.
    try std.testing.expectEqual(@as(i96, 240 * s), nextDue(60 * s, 60 * s, 200 * s));
    try std.testing.expectEqual(@as(i96, 180 * s), nextDue(60 * s, 60 * s, 120 * s));
}
