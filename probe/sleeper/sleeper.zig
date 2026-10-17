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
//! Its conf is `sleeper.conf` in its data folder, a setting a line, every one
//! optional: `period_ms = N` (60000 when absent), and `fetch = <ip>:<port>
//! <path>`, a GET at each wake through the host (`host_fetch`), whose end is
//! a line too:
//!
//!     fetch 3 ok 200 1185 at 180004000412
//!
//! A test chooses them; the code does not.

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

/// What it fetches at each wake, if `fetch = <ip>:<port> <path>` says.
var target: ?webbox.host_fetch.Target = null;
var target_path: [128]u8 = undefined;
/// Each fetch's bounds: generous for a test's wire, short for a dead one.
const deadlines: webbox.host_fetch.Deadlines = .{ .connect_ms = 150, .idle_ms = 1000, .total_ms = 3000 };

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    if (roots) |r| data_root = r.data_dir;
    try webbox.store.makeDir(io, base, data_root);
    wakes_path = try std.fmt.allocPrint(base, "{s}/wakes.txt", .{data_root});
    const conf_path = try std.fmt.allocPrint(base, "{s}/sleeper.conf", .{data_root});
    var ms: u64 = default_period_ms;
    if (webbox.store.read(io, base, conf_path, .limited(512))) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            if (valueOf(line, "period_ms")) |v| {
                ms = std.fmt.parseInt(u64, v, 10) catch return error.BadSleeperConf;
                if (ms == 0) return error.BadSleeperConf;
            } else if (valueOf(line, "fetch")) |v| {
                target = targetOf(v) orelse return error.BadSleeperConf;
            } else return error.BadSleeperConf;
        }
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    period_ns = @as(i96, ms) * std.time.ns_per_ms;
    return .{ .period_ms = ms, .data_dir = data_root };
}

/// `name = value`'s value, or null for another name.
fn valueOf(line: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, name)) return null;
    const rest = std.mem.trim(u8, line[name.len..], " \t");
    if (rest.len == 0 or rest[0] != '=') return null;
    return std.mem.trim(u8, rest[1..], " \t");
}

/// `10.0.2.15:80 /path`.
fn targetOf(v: []const u8) ?webbox.host_fetch.Target {
    const space = std.mem.indexOfScalar(u8, v, ' ') orelse return null;
    const where = v[0..space];
    const path = std.mem.trim(u8, v[space..], " \t");
    const colon = std.mem.indexOfScalar(u8, where, ':') orelse return null;
    var ip: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, where[0..colon], '.');
    for (&ip) |*b| b.* = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null or path.len == 0 or path.len > target_path.len) return null;
    @memcpy(target_path[0..path.len], path);
    return .{ .ip = ip, .port = std.fmt.parseInt(u16, where[colon + 1 ..], 10) catch return null, .path = target_path[0..path.len] };
}

/// A line on its disk and the host's console.
fn note(io: Io, comptime fmt: []const u8, args: anytype) void {
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const line = std.fmt.allocPrint(fba.allocator(), fmt ++ "\n", args) catch unreachable;
    _ = webbox.store.append(io, fba.allocator(), wakes_path, line) catch {
        lost += 1;
    };
    webbox.host_facts.say(std.mem.trimEnd(u8, line, "\n"));
}

pub fn between(io: Io, now: webbox.site.Now) webbox.site.Wake {
    // A fetch that ended since the last call: its line, at once.
    if (webbox.host_fetch.result()) |r| {
        note(io, "fetch {d} {t} {d} {d} at {d}", .{ count, r.outcome, r.status, r.body.len, now.awake_ns });
    }
    const at = due orelse now.awake_ns;
    if (now.awake_ns < at) return .{ .at = at };
    count += 1;
    note(io, "wake {d} due {d} at {d} unix {d} lost {d}", .{ count, at, now.awake_ns, now.unix_s, lost });
    if (target) |t| webbox.host_fetch.start(t, deadlines) catch |e| note(io, "fetch {d} not started: {t}", .{ count, e });
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
