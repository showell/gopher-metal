//! **A VOLUME'S CHECK, IN IDLE TIME** (essay `idle-time-on-metal`): the
//! boot's check (`disk_fat.Volume.check`) asked again while the machine
//! serves, a slice per idle step (`disk_fat.Volume.CheckRun`), so production
//! says what is wrong with its volumes now, not only what was wrong at boot.
//!
//! It reads and writes nothing else: the findings go to `/admin/host` as
//! counts. One full check, then a rest of `period_ns`, then again. A write to
//! the volume under a check starts it again; a read that fails ends this
//! one, counted, and the next starts after the rest.

const std = @import("std");
const props = @import("coverage");
const disk_fat = @import("disk_fat.zig");
const idle = @import("idle.zig");

pub const VolumeCheck = struct {
    vol: *disk_fat.Volume,
    /// The marks (`checkBytes` long), owned by the caller, kept between steps.
    seen: []u8,
    /// FAT runs read a step (`run_sectors` sectors, each copy): two disk
    /// requests a run, ~12 ms on production's volume.
    runs_per_step: u32 = 8,
    period_ns: u64 = std.time.ns_per_hour,
    task: idle.Task = undefined,
    run: disk_fat.Volume.CheckRun = .{},
    state: enum { waiting, running } = .waiting,
    /// When the next check may start; the first is due once the machine
    /// first goes quiet.
    next_at: i96 = 0,

    /// Checks finished, started again because the volume changed, and ended
    /// by a read that failed.
    finished: u64 = 0,
    restarts: u64 = 0,
    failed: u64 = 0,
    /// The last finished check: when, and what it found.
    last: ?struct { at: i96, health: disk_fat.Health, tally: disk_fat.Volume.CheckRun.Tally } = null,

    /// Its task, for `idle.Idle.add`. `self` must not move afterwards.
    pub fn init(self: *VolumeCheck, name: []const u8) *idle.Task {
        self.task = .{ .name = name, .ctx = self, .stepFn = step };
        return &self.task;
    }

    fn step(ctx: *anyopaque, now: i96) idle.Outcome {
        const self: *VolumeCheck = @ptrCast(@alignCast(ctx));
        if (self.state == .waiting) {
            if (now < self.next_at) return .resting;
            self.run.begin(self.vol, self.seen) catch {
                self.failed += 1;
                self.next_at = now + self.period_ns;
                return .resting;
            };
            self.state = .running;
        }
        const outcome = self.run.step(self.runs_per_step) catch {
            // A read that failed: nothing found is said, and the next check
            // waits its period.
            props.reachable(@src(), "idle: a volume's check ends on a read that failed", null);
            self.failed += 1;
            self.state = .waiting;
            self.next_at = now + self.period_ns;
            return .worked;
        };
        switch (outcome) {
            .more => {},
            .changed => {
                self.restarts += 1;
                self.state = .waiting; // due at once: next_at has passed
            },
            .done => {
                self.finished += 1;
                self.last = .{ .at = now, .health = self.run.health(), .tally = self.run.tally };
                self.state = .waiting;
                self.next_at = now + self.period_ns;
            },
        }
        return .worked;
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_disk = @import("test_disk.zig");

var clock_now: i96 = 0;
fn clock() i96 {
    return clock_now;
}

test "idle check: a volume is checked in quiet moments, a slice a step, then again after its period" {
    const d = try test_disk.Disk.make("idle-check", test_disk.small32, true);
    defer d.deinit();
    try d.mount(true);
    try d.vol.writeFile("data/a.md", "hello");
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var check: VolumeCheck = .{ .vol = &d.vol, .seen = seen, .runs_per_step = 1, .period_ns = std.time.ns_per_s };
    var q: idle.Idle = .{};
    try q.add(check.init("the volume's check"));

    var now: i96 = std.time.ns_per_s;
    var steps: u32 = 0;
    while (check.finished == 0) : (steps += 1) {
        clock_now = now;
        try testing.expect(q.turn(now, clock));
        try testing.expect(steps < 10_000);
    }
    try testing.expect(steps >= 2);
    try testing.expect(check.last.?.health.clean());
    try testing.expectEqual(@as(u32, 0), check.last.?.tally.damage);
    try testing.expectEqual(@as(u32, 1), check.last.?.health.files);
    // Waiting out its period: the turn takes no step, so the loop rests.
    try testing.expect(!q.turn(now, clock));
    now += std.time.ns_per_s;
    clock_now = now;
    try testing.expect(q.turn(now, clock));
}

test "idle check: a write under a check starts it again, and the next one finishes" {
    const d = try test_disk.Disk.make("idle-check-changed", test_disk.small32, true);
    defer d.deinit();
    try d.mount(true);
    try d.vol.writeFile("data/a.md", "hello");
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var check: VolumeCheck = .{ .vol = &d.vol, .seen = seen, .runs_per_step = 1 };
    var q: idle.Idle = .{};
    try q.add(check.init("the volume's check"));
    const now: i96 = std.time.ns_per_s;
    clock_now = now;
    try testing.expect(q.turn(now, clock)); // the walk
    try d.vol.writeFile("data/b.md", "a request wrote this");
    try testing.expect(q.turn(now, clock)); // finds the change
    try testing.expectEqual(@as(u64, 1), check.restarts);
    while (check.finished == 0) try testing.expect(q.turn(now, clock));
    try testing.expectEqual(@as(u32, 2), check.last.?.health.files);
}

test "idle check: damage is counted, the first kind said" {
    const d = try test_disk.Disk.make("damaged-idle-check", test_disk.small32, true);
    defer d.deinit();
    try d.mount(true);
    try d.vol.writeFile("short", "x" ** 1000);
    const e = try d.vol.open("short");
    // The entry's size on the disk, past what its chain holds.
    std.mem.writeInt(u32, d.bytes[e.lba * test_disk.sector + e.slot + 28 ..][0..4], 5000, .little);
    try d.mount(true);
    const seen = try testing.allocator.alloc(u8, d.vol.checkBytes());
    defer testing.allocator.free(seen);
    var check: VolumeCheck = .{ .vol = &d.vol, .seen = seen };
    var q: idle.Idle = .{};
    try q.add(check.init("the volume's check"));
    const now: i96 = std.time.ns_per_s;
    clock_now = now;
    while (check.finished == 0) try testing.expect(q.turn(now, clock));
    try testing.expectEqual(@as(u32, 1), check.last.?.tally.damage);
    try testing.expectEqual(disk_fat.Problem.short, check.last.?.tally.first.?.problem);
}
