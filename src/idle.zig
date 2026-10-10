//! **IDLE TIME, SPENT A STEP AT A TIME** (essay `idle-time-on-metal`).
//!
//! Chat is bursty and the machine is idle most of the time. Work that is not
//! time-critical (a check of a volume, later others) is queued here as tasks,
//! and the kernel's loop gives the next task one step when it would otherwise
//! rest: nothing to serve, and nothing arrived for `quiet_ns`. A step is a
//! request with no client: bounded (`budget_ns`), and a request that arrives
//! meanwhile waits for at most one step. Steps run one task after another,
//! round-robin; a task with nothing to do now says so and costs nothing.
//!
//! Pure: the caller passes the time, so the host tests drive it with a fake
//! clock, and metal-vmm's sweeps reach it whenever a run goes quiet.

const std = @import("std");
const props = @import("coverage");

/// What one step did.
pub const Outcome = enum {
    /// It did some work; there may be more.
    worked,
    /// Nothing to do now (finished, or waiting for its time): no step taken.
    resting,
};

/// One piece of idle work. Its state lives behind `ctx`, never on the stack:
/// a step does a bounded slice and returns.
pub const Task = struct {
    name: []const u8,
    ctx: *anyopaque,
    stepFn: *const fn (ctx: *anyopaque, now: i96) Outcome,
    /// Steps that worked, and the longest of them.
    steps: u64 = 0,
    longest_ns: u64 = 0,
};

pub const max_tasks = 8;

pub const Idle = struct {
    tasks: [max_tasks]*Task = undefined,
    len: usize = 0,
    next: usize = 0,
    /// How long nothing must have arrived before a step runs: a burst (a
    /// page loading its assets, someone typing) is never cut into.
    quiet_ns: u64 = 200 * std.time.ns_per_ms,
    /// The most one step may take: past it, a property breaks and the step
    /// is counted (`overruns`).
    budget_ns: u64 = 200 * std.time.ns_per_ms,
    /// When something last arrived or was served.
    last_busy: i96 = 0,
    steps: u64 = 0,
    overruns: u64 = 0,

    pub fn add(self: *Idle, task: *Task) error{TooMany}!void {
        if (self.len == max_tasks) return error.TooMany;
        self.tasks[self.len] = task;
        self.len += 1;
    }

    /// Something arrived, or a request was served, at `now`.
    pub fn busy(self: *Idle, now: i96) void {
        self.last_busy = now;
    }

    /// One step of the next task with work to do, if the machine has been
    /// quiet long enough. `now` is when the turn starts and `clock` reads the
    /// time after the step. Answers whether a step ran.
    pub fn turn(self: *Idle, now: i96, clock: *const fn () i96) bool {
        if (self.len == 0 or now - self.last_busy < self.quiet_ns) return false;
        var tried: usize = 0;
        while (tried < self.len) : (tried += 1) {
            const task = self.tasks[self.next];
            self.next = (self.next + 1) % self.len;
            if (task.stepFn(task.ctx, now) == .resting) continue;
            const took: u64 = @intCast(@max(0, clock() - now));
            task.steps += 1;
            task.longest_ns = @max(task.longest_ns, took);
            self.steps += 1;
            if (took > self.budget_ns) self.overruns += 1;
            props.alwaysLessThanOrEqualTo(@src(), took, self.budget_ns, "idle: a step stays within its budget", null);
            props.reachable(@src(), "idle: a step runs in a quiet moment", null);
            return true;
        }
        return false;
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fake = struct {
    left: u32,
    cost_ns: i96 = 1_000_000,
    task: Task = undefined,

    var clock_now: i96 = 0;
    fn clock() i96 {
        return clock_now;
    }

    fn step(ctx: *anyopaque, now: i96) Outcome {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        if (f.left == 0) return .resting;
        f.left -= 1;
        clock_now = now + f.cost_ns;
        return .worked;
    }

    fn init(f: *Fake, name: []const u8) *Task {
        f.task = .{ .name = name, .ctx = f, .stepFn = step };
        return &f.task;
    }
};

test "idle: no step until nothing has arrived for quiet_ns, then one step a turn" {
    var idle: Idle = .{};
    var a: Fake = .{ .left = 3 };
    try idle.add(a.init("a"));
    idle.busy(1_000_000_000);
    try testing.expect(!idle.turn(1_000_000_000 + 100 * std.time.ns_per_ms, Fake.clock));
    try testing.expectEqual(@as(u32, 3), a.left);
    const quiet = 1_000_000_000 + 200 * std.time.ns_per_ms;
    try testing.expect(idle.turn(quiet, Fake.clock));
    try testing.expectEqual(@as(u32, 2), a.left);
    try testing.expect(idle.turn(quiet, Fake.clock));
    try testing.expect(idle.turn(quiet, Fake.clock));
    // Done: it rests, and the turn says no step ran, so the loop can rest.
    try testing.expect(!idle.turn(quiet, Fake.clock));
    try testing.expectEqual(@as(u64, 3), idle.steps);
    try testing.expectEqual(@as(u64, 3), a.task.steps);
}

test "idle: tasks take turns, and one resting costs the others nothing" {
    var idle: Idle = .{};
    var a: Fake = .{ .left = 2 };
    var b: Fake = .{ .left = 0 };
    var c: Fake = .{ .left = 2 };
    try idle.add(a.init("a"));
    try idle.add(b.init("b"));
    try idle.add(c.init("c"));
    const t: i96 = std.time.ns_per_s;
    for (0..4) |_| try testing.expect(idle.turn(t, Fake.clock));
    try testing.expectEqual(@as(u32, 0), a.left);
    try testing.expectEqual(@as(u32, 0), c.left);
    try testing.expect(!idle.turn(t, Fake.clock));
}

test "idle: a step past its budget is counted" {
    var idle: Idle = .{};
    var slow: Fake = .{ .left = 1, .cost_ns = 300 * std.time.ns_per_ms };
    try idle.add(slow.init("slow"));
    // The property breaks too, on purpose here; outside a coverage build
    // nothing reads it, and the count is what /admin/host says.
    const was = props.on_broken;
    props.on_broken = null;
    defer props.on_broken = was;
    try testing.expect(idle.turn(std.time.ns_per_s, Fake.clock));
    try testing.expectEqual(@as(u64, 1), idle.overruns);
    try testing.expectEqual(@as(u64, 300 * std.time.ns_per_ms), slow.task.longest_ns);
}

test "idle: a ninth task is refused" {
    var idle: Idle = .{};
    var fakes: [max_tasks + 1]Fake = undefined;
    for (fakes[0..max_tasks]) |*f| {
        f.* = .{ .left = 0 };
        try idle.add(f.init("f"));
    }
    fakes[max_tasks] = .{ .left = 0 };
    try testing.expectError(error.TooMany, idle.add(fakes[max_tasks].init("one too many")));
}
