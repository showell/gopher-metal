//! **THE SLEEPER: AN APPLICATION THAT ONLY WAKES** (docs/designs/DESIGN-sleep.md).
//! The test of a sleeping kernel: its `between` asks to be woken every
//! `period_ms`, and each wake appends one line to `wakes.txt` in its data:
//!
//!     wake 3 due 180000000000 at 180000000412 unix 1789000180 lost 0
//!
//! `due` is when it asked to be woken and `at` when it was, both on the awake
//! clock in nanoseconds, so a judge reads how late each wake was from the
//! disk afterwards. It schedules from `due`, not from when it woke, so
//! lateness never accumulates (webbox's `periodAfter`). `lost` counts the
//! lines before it that could not be written. Its one page, `/`, is the
//! lines, while they are under 1 MiB (about nine days at 60 s; a test app's
//! life is minutes). Each line is also said on the host's console
//! (`host_facts.say`), where a test on real time reads when it came, and
//! `/facts` is the host's facts (its rests and sleeps among them).
//!
//! No tier runs a test of this file: it is an application, built only as a
//! kernel. What it does is judged by metal-vmm's sleeps.sh from its lines,
//! `period_ms = 5000` read from its conf included.
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
/// Lines that could not be written.
var lost: u64 = 0;
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
    const line = std.fmt.allocPrint(fba.allocator(), "wake {d} due {d} at {d} unix {d} lost {d}\n", .{ count, at, now.awake_ns, now.unix_s, lost }) catch unreachable;
    _ = webbox.store.append(io, fba.allocator(), wakes_path, line) catch {
        lost += 1;
    };
    webbox.host_facts.say(std.mem.trimEnd(u8, line, "\n"));
    due = webbox.site.periodAfter(at, period_ns, now.awake_ns);
    return .{ .at = due.? };
}

pub fn bodyLimit(_: []const u8) u64 {
    return 0;
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    if (std.mem.eql(u8, webbox.http.pathOf(try webbox.http.target(req, alloc)), "/facts")) {
        var text: std.ArrayList(u8) = .empty;
        for (try webbox.host_facts.facts(io, alloc)) |f| try text.print(alloc, "{s}: {s}\n", .{ f.label, f.value });
        return req.respond(text.items, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
    }
    const text = webbox.store.read(io, alloc, wakes_path, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    try req.respond(text, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }} });
}
