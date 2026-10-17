//! **HOW LONG THE MACHINE MAY SLEEP** (docs/designs/DESIGN-sleep.md, phase
//! 1). The main loop's decisions, pure, so tier 0 holds them: whether the
//! machine is quiescent, when its next rest ends, when the application's
//! `between` must be called, and the TSC deadline a rest writes.
//!
//! **Quiescent** is nothing in motion: no connection open, no stream held,
//! nothing draining or being read, no console backlog, no write left
//! unflushed, no fetch running, and the application not asking for more.
//! Then only the application's wake can be due, and the machine rests until
//! it, never longer than `longest_rest`. Otherwise it rests a slice, as it
//! always has: TCP's, the streams' and the drains' clocks are looked at
//! every `slice_ns`.

const std = @import("std");
const apic_rule = @import("apic_rule.zig");

/// What the loop reads each idle turn to decide.
pub const Facts = struct {
    /// Connections in the table, open or closing (`Table.inUse`).
    conns_in_use: usize,
    /// Streams held (a browser subscribed).
    held: usize,
    /// Responses spilled and draining to a slow reader.
    draining: usize,
    /// Body drains holding a connection's request.
    drains_holding: usize,
    /// Console lines waiting for idle turns.
    console_pending: usize,
    /// A volume with writes not yet flushed.
    unflushed: bool,
    /// The application's own fetch, running (it holds no slot while it asks
    /// ARP for its server).
    fetching: bool,
    /// The application last asked for more (`Wake.more`).
    wants_more: bool,
};

pub fn quiescent(f: Facts) bool {
    return f.conns_in_use == 0 and f.held == 0 and f.draining == 0 and
        f.drains_holding == 0 and f.console_pending == 0 and !f.unflushed and
        !f.fetching and !f.wants_more;
}

/// What the loop does next with nothing to serve.
pub const Rest = union(enum) {
    /// Do not rest: something is due already.
    turn,
    /// Rest until this time on the awake clock, or a frame.
    until: Until,
};

pub const Until = struct {
    at: i96,
    /// What chose `at`.
    by: enum {
        /// A busy machine's slice.
        slice,
        /// The application's wake.
        wake,
        /// The longest rest, sooner than the application's wake.
        longest,
    },
};

/// **WHAT THE MACHINE'S SLEEPS DID**, for /admin/host: every quiescent rest,
/// those a device ended, those the longest rest ended, and of those **a
/// missed wake**: the timer ended it, and the next turn of the network took
/// a frame, one that came without its interrupt. A slice's rests are
/// `rest_count`'s.
pub const Sleeps = struct {
    sleeps: u64 = 0,
    by_device: u64 = 0,
    by_longest: u64 = 0,
    missed: u64 = 0,
    /// The last sleep was the longest rest, ended by the timer: the next
    /// turn decides whether it missed a wake.
    watching: bool = false,

    pub fn slept(self: *Sleeps, by: @FieldType(Until, "by"), by_device: bool) void {
        self.sleeps += 1;
        if (by_device) self.by_device += 1;
        if (by == .longest and !by_device) self.by_longest += 1;
        self.watching = by == .longest and !by_device;
    }

    /// A turn of the network after a sleep: whether it took a frame.
    pub fn turned(self: *Sleeps, took_frame: bool) void {
        if (self.watching and took_frame) self.missed += 1;
        self.watching = false;
    }
};

/// The decisions over the application's answer, `Wake` (zig-webbox's
/// wake.zig): the kernel passes `webbox.site.Wake`, the unit tests the
/// pinned copy (`wake_rule`).
pub fn Over(comptime Wake: type) type {
    return struct {
        /// The next rest from `now`: a slice unless quiescent, and then
        /// until the application's wake, at most `longest_ns`. A wake
        /// already due is a turn.
        pub fn next(now: i96, quiet: bool, wake: Wake, slice_ns: u64, longest_ns: u64) Rest {
            if (!quiet) return .{ .until = .{ .at = now + slice_ns, .by = .slice } };
            const longest: Until = .{ .at = now + longest_ns, .by = .longest };
            return switch (wake) {
                .more => .turn,
                .at => |at| if (at <= now) .turn else if (at < longest.at) .{ .until = .{ .at = at, .by = .wake } } else .{ .until = longest },
                .idle => .{ .until = longest },
            };
        }

        /// Whether the application's `between` must be called now, whatever
        /// else the machine is doing: it asked for more, its time came, or
        /// its fetch ended. (After every served request it is called too, by
        /// the loop.)
        pub fn betweenDue(now: i96, wake: Wake, fetch_ended: bool) bool {
            return fetch_ended or switch (wake) {
                .more => true,
                .at => |at| now >= at,
                .idle => false,
            };
        }
    };
}

/// The TSC value for a rest ending at `until`, nanoseconds on the awake
/// clock, which counts from `tsc_base`. From the base, not from now plus a
/// length: rounded up (`ticksOf`), so the deadline never reads as before
/// `until`; never 0, which disarms the timer.
pub fn deadlineTicks(tsc_base: u64, tsc_hz: u64, until: i96) u64 {
    const ns: u64 = @intCast(std.math.clamp(until, 0, std.math.maxInt(u64)));
    const at = tsc_base +% apic_rule.ticksOf(tsc_hz, ns);
    return if (at == 0) 1 else at;
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const PinnedWake = @import("wake_rule").Wake;
const next = Over(PinnedWake).next;
const betweenDue = Over(PinnedWake).betweenDue;
const ms = std.time.ns_per_ms;
const s = std.time.ns_per_s;

const still: Facts = .{
    .conns_in_use = 0,
    .held = 0,
    .draining = 0,
    .drains_holding = 0,
    .console_pending = 0,
    .unflushed = false,
    .fetching = false,
    .wants_more = false,
};

test "sleep: quiescent only when nothing is in motion, and each thing in motion alone says no" {
    try testing.expect(quiescent(still));
    try testing.expect(!quiescent(with(still, .conns_in_use, @as(usize, 1))));
    try testing.expect(!quiescent(with(still, .held, @as(usize, 1))));
    try testing.expect(!quiescent(with(still, .draining, @as(usize, 1))));
    try testing.expect(!quiescent(with(still, .drains_holding, @as(usize, 1))));
    try testing.expect(!quiescent(with(still, .console_pending, @as(usize, 3))));
    try testing.expect(!quiescent(with(still, .unflushed, true)));
    try testing.expect(!quiescent(with(still, .fetching, true)));
    try testing.expect(!quiescent(with(still, .wants_more, true)));
}

fn with(f: Facts, comptime field: std.meta.FieldEnum(Facts), value: @FieldType(Facts, @tagName(field))) Facts {
    var g = f;
    @field(g, @tagName(field)) = value;
    return g;
}

test "sleep: a busy machine rests a slice, whatever the application asked" {
    const now: i96 = 5 * s;
    try testing.expectEqual(Rest{ .until = .{ .at = now + ms, .by = .slice } }, next(now, false, .{ .at = now + 60 * s }, ms, 10 * s));
    try testing.expectEqual(Rest{ .until = .{ .at = now + ms, .by = .slice } }, next(now, false, .idle, ms, 10 * s));
}

test "sleep: a quiescent machine rests until the application's wake, never past the longest rest" {
    const now: i96 = 5 * s;
    try testing.expectEqual(Rest{ .until = .{ .at = now + 6 * ms, .by = .wake } }, next(now, true, .{ .at = now + 6 * ms }, ms, 10 * s));
    try testing.expectEqual(Rest{ .until = .{ .at = now + 10 * s, .by = .longest } }, next(now, true, .{ .at = now + 60 * s }, ms, 10 * s));
    try testing.expectEqual(Rest{ .until = .{ .at = now + 10 * s, .by = .longest } }, next(now, true, .idle, ms, 10 * s));
    // The longest rest is a setting: 6 ms is the same path as 10 s.
    try testing.expectEqual(Rest{ .until = .{ .at = now + 6 * ms, .by = .longest } }, next(now, true, .{ .at = now + 60 * s }, ms, 6 * ms));
    // Far past 60 h: still the longest rest, no overflow.
    try testing.expectEqual(Rest{ .until = .{ .at = now + 10 * s, .by = .longest } }, next(now, true, .{ .at = std.math.maxInt(i96) }, ms, 10 * s));
}

test "sleep: a wake exactly at the longest rest is the longest rest's" {
    const now: i96 = 5 * s;
    try testing.expectEqual(Rest{ .until = .{ .at = now + 10 * s, .by = .longest } }, next(now, true, .{ .at = now + 10 * s }, ms, 10 * s));
    try testing.expectEqual(Rest{ .until = .{ .at = now + 10 * s - 1, .by = .wake } }, next(now, true, .{ .at = now + 10 * s - 1 }, ms, 10 * s));
}

test "sleep: a missed wake is a longest rest the timer ended, after which a frame was waiting" {
    var z: Sleeps = .{};
    z.slept(.longest, false);
    z.turned(true); // missed
    z.slept(.longest, true); // a device ended it: its frame was announced
    z.turned(true);
    z.slept(.wake, false); // the application's own time: a frame then is chance
    z.turned(true);
    z.slept(.longest, false);
    z.turned(false);
    z.turned(true); // a later turn's frame is not the sleep's
    try testing.expectEqual(Sleeps{ .sleeps = 4, .by_device = 1, .by_longest = 2, .missed = 1, .watching = false }, z);
}

test "sleep: a wake already due is a turn, not a rest" {
    const now: i96 = 5 * s;
    try testing.expectEqual(Rest.turn, next(now, true, .{ .at = now }, ms, 10 * s));
    try testing.expectEqual(Rest.turn, next(now, true, .{ .at = now - 1 }, ms, 10 * s));
    try testing.expectEqual(Rest.turn, next(now, true, .more, ms, 10 * s));
}

test "sleep: between is due when it asked for more, when its time comes, and when its fetch ends; never before" {
    const now: i96 = 60 * s;
    try testing.expect(betweenDue(now, .more, false));
    try testing.expect(betweenDue(now, .{ .at = now }, false));
    try testing.expect(betweenDue(now, .{ .at = now - 1 }, false));
    try testing.expect(!betweenDue(now, .{ .at = now + 1 }, false));
    try testing.expect(!betweenDue(now, .idle, false));
    try testing.expect(betweenDue(now, .idle, true));
    try testing.expect(betweenDue(now, .{ .at = now + 30 * s }, true));
}

test "sleep: a rest's TSC deadline counts from the base, never reads as before its time, and is never 0" {
    const hz: u64 = 2_500_000_000;
    try testing.expectEqual(@as(u64, 1000 + 25_000_000_000), deadlineTicks(1000, hz, 10 * s));
    // Read back as io.ticksToNs reads (truncated): never short.
    const until: i96 = 60 * s + 7;
    const t = deadlineTicks(0, hz, until);
    try testing.expect(@as(u128, t) * s / hz >= until);
    // Across the counter's wrap, and onto 0, which would disarm the timer.
    const base: u64 = std.math.maxInt(u64) - 100;
    try testing.expectEqual(@as(u64, 149), deadlineTicks(base, hz, 100));
    try testing.expectEqual(@as(u64, 1), deadlineTicks(std.math.maxInt(u64), 1_000_000_000, 1));
    // A time before the boot's base clamps to the base's first tick.
    try testing.expectEqual(@as(u64, 1001), deadlineTicks(1000, hz, -5));
}
