//! **THE PAGE CACHE AGAINST A MODEL OF THE DISK** (metal-vmm QUEUE.md item
//! 34). `page_cache.zig` is pure: it imports only `std`, and io.zig tells it
//! every change the data takes. So it can be driven exactly as io.zig drives
//! it, by a seed, against a disk that is only a list of files.
//!
//! Each run is one seed. The seed chooses a budget (1 to 12 pages), the
//! largest file kept, how big files run (around the largest, and around page
//! sizes), whether memory runs out part-way, and a sequence of what io.zig
//! does:
//!
//! - **a read**: `get`, and on a miss the disk's bytes, `put`;
//! - **a whole-file write**: on the disk, then `replaced`; or failed, and the
//!   disk holds the old file, the new, or neither, and `forget`;
//! - **an append or an overwrite**: on the disk, then `wrote`; or failed
//!   part-way (or past the end, which the disk refuses), and `forget`;
//! - **a rename** over whatever was at the new name, then `renamed`; or
//!   failed, and `forget` both;
//! - **a remove**, `forget`; **a tree removed**, `forgetTree` and then the
//!   disk, which may stop part-way; **a remount**, `clear`.
//!
//! Every path is spelled as FAT would take it: any case, doubled and
//! trailing slashes, and now and then one too long to key.
//!
//! **THE ORACLES**, after every operation:
//!
//! - **Exact, or absent.** Every file the cache holds is the disk's file
//!   under that name, byte for byte, and every read it answers is.
//! - **Bounded.** The memory it holds is the sum of its files' pages, never
//!   over the budget; no file is longer than `largest`; no name twice.
//! - **A read is kept.** A file read whole that fits (no larger than
//!   `largest`, its pages within the budget, its name short enough) is kept
//!   after the read, unless memory ran out.
//!
//! The model is the disk, not the cache turned around: names are matched by
//! folding case and dropping empty parts, written here from disk_fat's rules,
//! not from `keyOf`.

const std = @import("std");
const PageCache = @import("page_cache.zig").PageCache;
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const page = PageCache.page;

/// The files, as the application names them. Two of them are a file and a
/// directory of one name, and one shares a prefix with another's directory.
const paths = [_][]const u8{
    "data/a",
    "data/B.txt",
    "data/chat/plan.md",
    "data/chat/messages.jsonl",
    "data/users/7/profile",
    "data/users/7/games/1/state",
    "data/users/70/profile",
    "data/users/7",
    "data/uploads/picture",
};
/// The trees a run removes.
const trees = [_][]const u8{ "data/users/7", "data/chat", "data/users", "data" };

const Op = enum { read, write, write_fails, append, append_fails, rename, rename_fails, remove, remove_tree, remount };

const Scenario = struct {
    budget: usize,
    largest: usize,
    /// Files run up to about this many bytes.
    max_bytes: usize,
    ops: usize,
    /// Memory runs out after this many allocations, for good.
    fail_after: ?usize,

    fn choose(rng: std.Random) Scenario {
        const budget = rng.intRangeAtMost(usize, 1, 12) * page;
        // The largest file kept: around a page boundary, sometimes past the
        // budget itself, which no file can fit.
        const largest = switch (rng.uintLessThan(u8, 4)) {
            0 => rng.intRangeAtMost(usize, 1, 3) * page,
            1 => rng.intRangeAtMost(usize, 1, 3) * page + rng.intRangeAtMost(usize, 0, 2) -% 1,
            2 => budget + page,
            else => rng.intRangeAtMost(usize, 1, budget),
        };
        return .{
            .budget = budget,
            .largest = @max(largest, 1),
            .max_bytes = largest + page,
            .ops = rng.intRangeAtMost(usize, 50, 600),
            .fail_after = if (rng.uintLessThan(u8, 8) == 0) rng.uintLessThan(usize, 60) else null,
        };
    }
};

/// **THE DISK**: files by name, matched as FAT matches them.
const Disk = struct {
    const File = struct { name: []u8, bytes: std.ArrayList(u8) };
    files: std.ArrayList(File) = .empty,
    gpa: std.mem.Allocator,

    /// Whether two names are one file: the same parts, ignoring ASCII case
    /// and empty parts.
    fn same(a: []const u8, b: []const u8) bool {
        var pa = std.mem.tokenizeScalar(u8, a, '/');
        var pb = std.mem.tokenizeScalar(u8, b, '/');
        while (true) {
            const x = pa.next();
            const y = pb.next();
            if (x == null or y == null) return x == null and y == null;
            if (!std.ascii.eqlIgnoreCase(x.?, y.?)) return false;
        }
    }

    /// Whether `name` is `tree` or under it.
    fn under(name: []const u8, tree: []const u8) bool {
        var pn = std.mem.tokenizeScalar(u8, name, '/');
        var pt = std.mem.tokenizeScalar(u8, tree, '/');
        while (pt.next()) |t| {
            const n = pn.next() orelse return false;
            if (!std.ascii.eqlIgnoreCase(n, t)) return false;
        }
        return true;
    }

    fn find(self: *const Disk, name: []const u8) ?usize {
        for (self.files.items, 0..) |f, i| if (same(f.name, name)) return i;
        return null;
    }

    fn get(self: *const Disk, name: []const u8) ?[]const u8 {
        const i = self.find(name) orelse return null;
        return self.files.items[i].bytes.items;
    }

    fn set(self: *Disk, name: []const u8, bytes: []const u8) !void {
        if (self.find(name)) |i| {
            const f = &self.files.items[i];
            f.bytes.clearRetainingCapacity();
            try f.bytes.appendSlice(self.gpa, bytes);
            return;
        }
        var f: File = .{ .name = try self.gpa.dupe(u8, name), .bytes = .empty };
        try f.bytes.appendSlice(self.gpa, bytes);
        try self.files.append(self.gpa, f);
    }

    fn remove(self: *Disk, i: usize) void {
        var f = self.files.swapRemove(i);
        self.gpa.free(f.name);
        f.bytes.deinit(self.gpa);
    }

    fn removeName(self: *Disk, name: []const u8) void {
        if (self.find(name)) |i| self.remove(i);
    }

    fn deinit(self: *Disk) void {
        while (self.files.items.len > 0) self.remove(0);
        self.files.deinit(self.gpa);
    }
};

const Sim = struct {
    seed: u64,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    sc: Scenario,
    disk: Disk,
    failing: std.testing.FailingAllocator,
    cache: *PageCache,
    step: usize = 0,
    broken: ?[]const u8 = null,

    fn init(self: *Sim, seed: u64) !void {
        self.seed = seed;
        self.prng = std.Random.DefaultPrng.init(seed);
        self.rng = self.prng.random();
        self.sc = Scenario.choose(self.rng);
        self.disk = .{ .gpa = std.testing.allocator };
        self.failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = self.sc.fail_after orelse std.math.maxInt(usize),
        });
        self.cache = try std.testing.allocator.create(PageCache);
        self.cache.* = PageCache.init(self.failing.allocator(), self.sc.budget, self.sc.largest);
        self.step = 0;
        self.broken = null;
    }

    fn deinit(self: *Sim) void {
        self.cache.clear();
        std.testing.allocator.destroy(self.cache);
        self.disk.deinit();
    }

    fn fault(self: *Sim, what: []const u8) void {
        if (self.broken == null) self.broken = what;
    }

    /// A path from the pool, spelled any way FAT takes it; now and then one
    /// too long to key.
    fn spell(self: *Sim, buf: []u8, name: []const u8) []const u8 {
        const r = self.rng;
        if (r.uintLessThan(u8, 40) == 0) {
            const long = PageCache.max_key + r.uintLessThan(usize, 8);
            if (long == PageCache.max_key + 1) {
                // A lone part one byte past the key, with nothing before
                // it: the edge of `keyOf`'s first check (MUTATION.md P1).
                @memset(buf[0..long], 'x');
                return buf[0..long];
            }
            @memcpy(buf[0..name.len], name);
            buf[name.len] = '/';
            @memset(buf[name.len + 1 ..][0..long], 'x');
            return buf[0 .. name.len + 1 + long];
        }
        var n: usize = 0;
        if (r.uintLessThan(u8, 8) == 0) {
            buf[n] = '/';
            n += 1;
        }
        for (name) |c| {
            buf[n] = if (r.uintLessThan(u8, 6) == 0) std.ascii.toUpper(c) else if (r.uintLessThan(u8, 6) == 0) std.ascii.toLower(c) else c;
            n += 1;
            if (c == '/' and r.uintLessThan(u8, 8) == 0) {
                buf[n] = '/';
                n += 1;
            }
        }
        if (r.uintLessThan(u8, 8) == 0) {
            buf[n] = '/';
            n += 1;
        }
        return buf[0..n];
    }

    /// A file's new bytes: often at a page's edge or the largest's.
    fn bytesFor(self: *Sim, buf: []u8) []u8 {
        const r = self.rng;
        const largest = self.sc.largest;
        const len = switch (r.uintLessThan(u8, 6)) {
            0 => largest,
            1 => largest + 1,
            2 => r.intRangeAtMost(usize, 1, 3) * page + r.intRangeAtMost(usize, 0, 2) -% 1,
            3 => r.uintLessThan(usize, 64),
            else => r.uintLessThan(usize, self.sc.max_bytes + 1),
        };
        const n = @min(len, buf.len);
        r.bytes(buf[0..n]);
        return buf[0..n];
    }

    /// The name a cache slot holds is a file the disk has, with its bytes.
    fn check(self: *Sim) void {
        const c = self.cache;
        var held: usize = 0;
        for (0..c.count) |i| {
            const key = c.keys[i][0..c.key_lens[i]];
            const kept = c.bufs[i][0..c.lens[i]];
            held += c.bufs[i].len;
            if (c.bufs[i].len % page != 0 or c.bufs[i].len < @max(c.lens[i], 1))
                self.fault("a kept file's memory is not whole pages that hold it");
            if (c.lens[i] > self.sc.largest) self.fault("a kept file is larger than the largest");
            for (0..i) |j| if (Disk.same(c.keys[j][0..c.key_lens[j]], key)) self.fault("a name is kept twice");
            const disk = self.disk.get(key) orelse {
                self.fault("the cache keeps a file the disk does not have");
                continue;
            };
            if (!std.mem.eql(u8, disk, kept)) self.fault("the cache keeps bytes that are not the disk's");
        }
        if (held != c.held) self.fault("the memory counted is not the memory held");
        if (c.held > c.budget) self.fault("the cache holds more than its budget");
    }

    fn keptUnder(self: *const Sim, name: []const u8) bool {
        const c = self.cache;
        for (0..c.count) |i| if (Disk.same(c.keys[i][0..c.key_lens[i]], name)) return true;
        return false;
    }

    fn keyable(name: []const u8) bool {
        // Folded and joined, the name must fit `max_key`: the parts and the
        // slashes between them.
        var n: usize = 0;
        var parts = std.mem.tokenizeScalar(u8, name, '/');
        var first = true;
        while (parts.next()) |p| {
            n += p.len + @intFromBool(!first);
            first = false;
        }
        return n <= PageCache.max_key;
    }

    fn outOfMemory(self: *const Sim) bool {
        return self.failing.has_induced_failure;
    }

    fn run(self: *Sim) !void {
        var spelled: [PageCache.max_key + 64]u8 = undefined;
        var other: [PageCache.max_key + 64]u8 = undefined;
        var data: [16 * page]u8 = undefined;
        while (self.step < self.sc.ops and self.broken == null) : (self.step += 1) {
            const r = self.rng;
            const name = paths[r.uintLessThan(usize, paths.len)];
            const path = self.spell(&spelled, name);
            const c = self.cache;
            const evicted = c.evicted;
            const op: Op = switch (r.uintLessThan(u8, 100)) {
                0...39 => .read,
                40...54 => .write,
                55...59 => .write_fails,
                60...71 => .append,
                72...75 => .append_fails,
                76...82 => .rename,
                83...85 => .rename_fails,
                86...92 => .remove,
                93...97 => .remove_tree,
                else => .remount,
            };
            switch (op) {
                .read => {
                    const disk = self.disk.get(path);
                    const was_kept = self.keptUnder(path);
                    if (c.get(path)) |kept| {
                        props.reachable(@src(), "page_sim: a read is answered from the cache", null);
                        if (!std.mem.eql(u8, name, path)) props.reachable(@src(), "page_sim: another spelling of a kept file finds it", null);
                        const d = disk orelse {
                            self.fault("a read was answered for a file the disk does not have");
                            break;
                        };
                        if (!std.mem.eql(u8, kept, d)) self.fault("a read was answered with bytes that are not the disk's");
                    } else if (disk) |d| {
                        if (was_kept) self.fault("a kept file was not found by its name");
                        // io.zig reads it whole, and keeps it.
                        c.put(path, d);
                        const fits = d.len <= self.sc.largest and std.mem.alignForward(usize, @max(d.len, 1), page) <= self.sc.budget and keyable(path);
                        const kept = self.keptUnder(path);
                        if (fits and !kept and !self.outOfMemory()) self.fault("a file read whole that fits was not kept");
                        if (fits and !kept and self.outOfMemory()) props.reachable(@src(), "page_sim: memory that cannot be had leaves a file uncached", null);
                        if (kept and d.len == self.sc.largest) props.reachable(@src(), "page_sim: a file as large as the largest is kept", null);
                        if (d.len == self.sc.largest + 1) props.reachable(@src(), "page_sim: a file a byte past the largest is not kept", null);
                    }
                },
                .write => {
                    const bytes = self.bytesFor(&data);
                    const was_kept = self.keptUnder(path);
                    try self.disk.set(path, bytes);
                    c.replaced(path, bytes);
                    if (was_kept and self.keptUnder(path)) props.reachable(@src(), "page_sim: a whole-file write replaces a kept copy", null);
                    if (!was_kept and self.keptUnder(path)) self.fault("a whole-file write brought a file in");
                },
                .write_fails => {
                    // The disk holds the old file, the new, or neither.
                    const bytes = self.bytesFor(&data);
                    switch (r.uintLessThan(u8, 3)) {
                        0 => {},
                        1 => try self.disk.set(path, bytes),
                        else => self.disk.removeName(path),
                    }
                    c.forget(path);
                },
                .append, .append_fails => {
                    const d = self.disk.get(path) orelse continue;
                    const len = d.len;
                    const was_kept = self.keptUnder(path);
                    const pages_before = if (was_kept) self.pagesOf(path) else 0;
                    const bytes = self.bytesFor(&data);
                    // At the end, mostly; inside it, as an overwrite; or
                    // past it, which the disk refuses.
                    const offset = switch (r.uintLessThan(u8, 5)) {
                        0 => r.uintLessThan(usize, len + 1),
                        1 => len + 1 + r.uintLessThan(usize, 100),
                        else => len,
                    };
                    if (offset > len or op == .append_fails) {
                        if (offset <= len) {
                            // Failed part-way: some of it may have landed.
                            const landed = bytes[0..r.uintLessThan(usize, bytes.len + 1)];
                            try self.overwrite(path, offset, landed);
                        }
                        c.forget(path);
                        continue;
                    }
                    try self.overwrite(path, offset, bytes);
                    c.wrote(path, offset, bytes);
                    if (was_kept and !self.keptUnder(path) and offset + bytes.len > self.sc.largest)
                        props.reachable(@src(), "page_sim: an append past the largest drops a kept copy", null);
                    if (was_kept and self.keptUnder(path) and self.pagesOf(path) > pages_before)
                        props.reachable(@src(), "page_sim: an append grows a kept copy into more pages", null);
                },
                .rename, .rename_fails => {
                    const to_name = paths[r.uintLessThan(usize, paths.len)];
                    const to = self.spell(&other, to_name);
                    if (Disk.same(path, to)) continue;
                    if (op == .rename_fails or self.disk.get(path) == null) {
                        // disk_fat's rename may fail having removed the old
                        // `to`; io.zig forgets both.
                        if (r.boolean()) self.disk.removeName(to);
                        c.forget(path);
                        c.forget(to);
                        continue;
                    }
                    const was_kept = self.keptUnder(path);
                    self.disk.removeName(to);
                    // The file moves: same bytes, the new name.
                    const f = &self.disk.files.items[self.disk.find(path).?];
                    self.disk.gpa.free(f.name);
                    f.name = try self.disk.gpa.dupe(u8, to);
                    c.renamed(path, to);
                    if (was_kept and self.keptUnder(to)) props.reachable(@src(), "page_sim: a rename carries a kept copy to its new name", null);
                    if (self.keptUnder(path)) self.fault("a renamed file is still kept under its old name");
                },
                .remove => {
                    self.disk.removeName(path);
                    c.forget(path);
                },
                .remove_tree => {
                    const tree = self.spell(&other, trees[r.uintLessThan(usize, trees.len)]);
                    var kept_under = false;
                    for (0..c.count) |k| if (Disk.under(c.keys[k][0..c.key_lens[k]], tree)) {
                        kept_under = true;
                    };
                    c.forgetTree(tree);
                    if (kept_under and keyable(tree)) props.reachable(@src(), "page_sim: a tree removed takes a kept file under it", null);
                    // Then the disk, which may stop part-way.
                    var k: usize = 0;
                    while (k < self.disk.files.items.len) {
                        if (Disk.under(self.disk.files.items[k].name, tree) and r.uintLessThan(u8, 8) != 0) {
                            self.disk.remove(k);
                        } else k += 1;
                    }
                },
                .remount => c.clear(),
            }
            if (c.evicted != evicted) props.reachable(@src(), "page_sim: a file is pushed out to make room", null);
            self.check();
        }
        props.sometimes(@src(), self.cache.evicted > 0, "page_sim: some run pushes a file out", .{ .seed = self.seed });
        if (self.broken) |what| {
            std.debug.print("page_sim seed {d} failed at operation {d}: {s}\n  budget {d} pages, largest {d} B, files to {d} B, {d} operations, memory out after {?d} allocations\n", .{
                self.seed, self.step, what, self.sc.budget / page, self.sc.largest, self.sc.max_bytes, self.sc.ops, self.sc.fail_after,
            });
            return error.SimulationFailed;
        }
    }

    fn pagesOf(self: *const Sim, name: []const u8) usize {
        const c = self.cache;
        for (0..c.count) |i| if (Disk.same(c.keys[i][0..c.key_lens[i]], name)) return c.bufs[i].len / page;
        return 0;
    }

    /// `bytes` at `offset` of the disk's file, which grows to hold them.
    fn overwrite(self: *Sim, name: []const u8, offset: usize, bytes: []const u8) !void {
        const i = self.disk.find(name).?;
        const f = &self.disk.files.items[i];
        const end = offset + bytes.len;
        if (end > f.bytes.items.len) try f.bytes.resize(self.disk.gpa, end);
        @memcpy(f.bytes.items[offset..end], bytes);
    }
};

/// Runs one seed; an error, with the scenario printed, if any oracle fails.
pub fn runSeed(seed: u64) !void {
    const sim = try std.testing.allocator.create(Sim);
    defer std.testing.allocator.destroy(sim);
    try sim.init(seed);
    defer sim.deinit();
    try sim.run();
}

/// Seeds that once failed, kept as regression tests, each under what it
/// found.
pub const regressions = [_]u64{};

test "the page cache against a model of the disk, a handful of seeds" {
    for (1..33) |seed| try runSeed(seed);
    for (regressions) |seed| try runSeed(seed);
}
