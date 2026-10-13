//! **THE KERNEL'S BODY DRAINS, UNDER A SEED** (metal-vmm QUEUE 171).
//! `drain.zig` is pure decisions over the bytes, the clock and the slots, so
//! it can be driven as the kernel's loop drives it: connections opening in
//! the table's slots, their requests arriving at any rate (some stopping, as
//! a dropped phone does; some closing short), the loop's pass over every
//! connection, the oldest ready one served, and every turn a stretch of time
//! the clocks are paused for. Allocations fail now and then, as the
//! machine's heap can.
//!
//! **THE REFERENCE IS THE SIMULATOR'S**: it wrote each request, delivered
//! its bytes and kept its own clock of the time the loop was free (the
//! module's `now` less the turns), so it knows, without asking the module,
//! what each answer may be:
//!
//! - **memory is the wire**: what a drain holds is the request's bytes, in
//!   order, from its first; a body handed over whole is exactly its body;
//! - **no refusal early**: a 408 for a body not after its deadline of free
//!   time from its head (or, for an upload, its slot), a stall not before 30
//!   s of free time without a byte, a slot's 503 not before 30 s of free
//!   time waiting (unless an allocation failed or the asker could not be
//!   told), a 409 only with a newer upload of the same human, a 413 only for
//!   a chunked body past what is kept;
//! - **no honest body refused**: with the budget not in play, a body that
//!   came whole in time is served whole;
//! - **the books balance at every pass**: the slots held are the waits that
//!   say so, one a human; the budget's charge is the sum of the small drains'
//!   room, and the small drains (heads aside) never hold more than it; an
//!   upload's room is its exact length;
//! - **everything ends**: no request waits past the longest the rule allows
//!   (a slot's wait, then an upload's five minutes), in free time and, with
//!   what turns may add, on the wall (175.1); at the end every byte of
//!   memory and every slot is given back.
//! - **each 503 by its cause** (177.5): the budget's only in a seed whose
//!   budget is tight, memory's only where an allocation failed, a slot
//!   wait's only after the slot wait, whatever the budget.

const std = @import("std");
const drain = @import("drain.zig");
const body_rule = @import("body_rule");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const conns = 10;
/// The longest turn a pass may take (`runSeed`).
const turn_most_ms = 10_000;
/// The most the wall moves between two passes: a step and a turn.
const step_most_ms = 35_000 + turn_most_ms;
/// The wall's bound on a request (`noneForgotten`): its clocks twice over,
/// a turn for every connection served ahead of it, and a minute's slack.
const wall_most_ms = 2 * (body_rule.slot_wait_ms + body_rule.upload_ms) + conns * turn_most_ms + 60_000;
const D = drain.Drains(body_rule, conns);
const ns_per_ms = std.time.ns_per_ms;

/// Routes as the simulator has them: `/up` an upload, `/doc` the largest
/// small cap, `/x` 64 KiB.
fn caps(target: []const u8) u64 {
    if (std.mem.startsWith(u8, target, "/up")) return 101 << 20;
    if (std.mem.startsWith(u8, target, "/doc")) return body_rule.before_turn_most;
    return 64 << 10;
}

const Kind = enum { small, chunked, upload };

/// One client on one connection.
const Client = struct {
    serial: u64,
    kind: Kind,
    bytes: []u8,
    head_len: usize,
    /// The body's own bytes (for a chunked one, decoded), for the whole
    /// hand-over's check.
    body_from: usize,
    body_len: usize,
    expect: bool,
    /// Who it uploads as: a human's key, a stranger, or one the store cannot
    /// tell.
    who: drain.Who,
    /// How many of its bytes have arrived, how many the host took.
    sent: usize = 0,
    taken: usize = 0,
    capacity: usize,
    /// Bytes a second of free time.
    rate: u64,
    /// It sends nothing past this (a dropped phone), or closes there (FIN).
    stop_at: usize,
    closes: bool,
    continued: bool = false,
    /// The free clock (ms) when its head was first seen by the module, its
    /// drain began, its slot wait began, its last byte arrived.
    head_seen: ?Mark = null,
    drain_began: ?Mark = null,
    slot_wait_began: ?Mark = null,
    last_arrival: Mark,
    opened: u64,
    /// The module's clock when it opened: the wall's bound is judged by it
    /// (177.5).
    opened_now: i96,
    /// When the module first said it is to be served: what it decided is
    /// judged by then, not by its turn to be served, one a pass.
    ready_at: ?Mark = null,
    /// An allocation failed while it waited, or its asker could not be told.
    excused_busy: bool = false,
    /// When it asked who it is (`Sim.asks`).
    asked: u64 = 0,
    /// Every byte arrived by this free time (null: not yet).
    all_by: ?u64 = null,

    fn finished(c: *const Client) bool {
        return c.closes and c.sent == c.stop_at and c.sent <= c.taken + c.capacity;
    }
    fn pending(c: *const Client) []const u8 {
        return c.bytes[c.taken..@min(c.sent, c.taken + c.capacity)];
    }
};

/// The machine's heap, failing now and then.
const Flaky = struct {
    backing: std.mem.Allocator,
    rng: std.Random,
    /// One in this many allocations fails (0: none).
    one_in: u32,
    failed: bool = false,

    fn allocator(f: *Flaky) std.mem.Allocator {
        return .{ .ptr = f, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn fails(f: *Flaky) bool {
        if (f.one_in == 0 or f.rng.uintLessThan(u32, f.one_in) != 0) return false;
        f.failed = true;
        return true;
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const f: *Flaky = @ptrCast(@alignCast(ctx));
        if (f.fails()) return null;
        return f.backing.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const f: *Flaky = @ptrCast(@alignCast(ctx));
        if (n > m.len and f.fails()) return false;
        return f.backing.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const f: *Flaky = @ptrCast(@alignCast(ctx));
        if (n > m.len and f.fails()) return null;
        return f.backing.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const f: *Flaky = @ptrCast(@alignCast(ctx));
        f.backing.rawFree(m, a, ra);
    }
};

/// When something happened, on both clocks.
const Mark = struct { free: u64, now: i96 };

const Sim = struct {
    gpa: std.mem.Allocator,
    rng: std.Random,
    seed: u64,
    d: D,
    clients: [conns]?Client = @splat(null),
    next_serial: u64 = 1,
    /// The module's clock (ns) and the free clock (ms): the first moves
    /// through turns, the second does not.
    now: i96 = 0,
    free_ms: u64 = 0,
    /// The budget in play: small enough that drains wait for it.
    tight_budget: bool,
    served: u64 = 0,
    /// Uploads asked who they are, in order, and each human's latest: a
    /// retry is the one that asks later, whatever its connection's age.
    asks: u64 = 0,
    latest_ask: [3]u64 = @splat(0),

    fn mark(s: *const Sim) Mark {
        return .{ .free = s.free_ms, .now = s.now };
    }

    /// How long a wait begun at `from` has waited as the module counts it
    /// (175.1): the wall's time less the turns it was credited, at most its
    /// own length, `cap_ms`.
    fn waited(s: *const Sim, from: Mark, cap_ms: u64) u64 {
        const wall = s.now - from.now;
        const free: i96 = @as(i96, s.free_ms - from.free) * ns_per_ms;
        const credited = @min(wall - free, @as(i96, cap_ms) * ns_per_ms);
        return @intCast(@divTrunc(wall - credited, ns_per_ms));
    }

    fn fail(s: *Sim, comptime fmt: []const u8, args: anytype) error{Oracle} {
        std.debug.print("drain_sim seed {d} at {d} ms free: " ++ fmt ++ "\n", .{ s.seed, s.free_ms } ++ args);
        return error.Oracle;
    }

    fn open(s: *Sim, i: usize) !void {
        const r = s.rng;
        const kind = r.enumValue(Kind);
        const expect = r.uintLessThan(u8, 6) == 0;
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(s.gpa);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(s.gpa);
        var decoded_len: usize = 0;
        const target: []const u8 = switch (kind) {
            .small => if (r.boolean()) "/doc" else "/x",
            .chunked => "/x",
            .upload => "/up",
        };
        switch (kind) {
            .small, .upload => {
                // Sizes that reach every edge (past the buffer, past the
                // budget in a tight seed, slower than the deadline) and keep a
                // seed under a second: an upload is past the line by its
                // route's cap, not its size.
                const most: usize = if (kind == .upload) 256 << 10 else if (target[1] == 'd') 100_000 else 70_000;
                // Now and then past the cap: refused from its head.
                const n = if (r.uintLessThan(u8, 3) == 0) r.uintLessThan(usize, 2000) else r.uintLessThan(usize, most);
                try body.ensureTotalCapacity(s.gpa, n);
                for (0..n) |k| body.appendAssumeCapacity(@truncate(k *% 7 +% s.seed));
                decoded_len = n;
            },
            .chunked => {
                // Tiny chunks now and then, to pass what is kept of one.
                const tiny = r.uintLessThan(u8, 10) == 0;
                const chunks = r.uintLessThan(usize, if (tiny) 20_000 else 40);
                for (0..chunks) |_| {
                    const n = if (tiny) 1 else 1 + r.uintLessThan(usize, 4000);
                    try body.print(s.gpa, "{x}\r\n", .{n});
                    for (0..n) |k| try body.append(s.gpa, @truncate(k));
                    try body.appendSlice(s.gpa, "\r\n");
                    decoded_len += n;
                }
                try body.appendSlice(s.gpa, "0\r\n\r\n");
            },
        }
        try head.print(s.gpa, "POST {s} HTTP/1.1\r\nHost: sim\r\n", .{target});
        if (kind == .chunked) try head.appendSlice(s.gpa, "Transfer-Encoding: chunked\r\n") else try head.print(s.gpa, "Content-Length: {d}\r\n", .{body.items.len});
        if (expect) try head.appendSlice(s.gpa, "Expect: 100-continue\r\n");
        try head.appendSlice(s.gpa, "\r\n");
        const bytes = try s.gpa.alloc(u8, head.items.len + body.items.len);
        @memcpy(bytes[0..head.items.len], head.items);
        @memcpy(bytes[head.items.len..], body.items);
        const who: drain.Who = switch (r.uintLessThan(u8, 10)) {
            0 => .stranger,
            1 => .unknown,
            // Three humans, so their uploads overlap and take over.
            else => |k| .{ .who = k % 3 },
        };
        const capacity: usize = switch (r.uintLessThan(u8, 3)) {
            0 => 2048,
            1 => 16 * 1024,
            else => 64 * 1024,
        };
        const rate: u64 = switch (r.uintLessThan(u8, 5)) {
            0 => 2_000, // slower than the rule's link: late
            1 => 64 * 1024,
            2 => 400_000,
            else => 10_000_000,
        };
        const dropped = r.uintLessThan(u8, 6) == 0;
        const closes = r.uintLessThan(u8, 6) == 0;
        // The head always whole: one that stops mid-head is the quiet path,
        // the loop's, not this module's.
        const stop_at = if (dropped or closes) head.items.len + r.uintLessThan(usize, body.items.len + 1) else bytes.len;
        s.clients[i] = .{
            .serial = s.next_serial,
            .kind = kind,
            .bytes = bytes,
            .head_len = head.items.len,
            .body_from = head.items.len,
            .body_len = decoded_len,
            .expect = expect,
            .who = who,
            .capacity = capacity,
            .rate = rate,
            .stop_at = stop_at,
            .closes = closes,
            .last_arrival = s.mark(),
            .opened = s.free_ms,
            .opened_now = s.now,
        };
        s.next_serial += 1;
        // The head arrives at once (one segment's worth or the buffer).
        s.clients[i].?.sent = head.items.len;
    }

    fn close(s: *Sim, i: usize) void {
        s.d.release(i);
        if (s.clients[i]) |c| s.gpa.free(c.bytes);
        s.clients[i] = null;
    }

    /// Bytes arrive for `ms` of time, into each buffer's room.
    fn deliver(s: *Sim, ms: u64) void {
        for (&s.clients) |*slot| if (slot.*) |*c| {
            // A head waiting for 100 Continue holds its body back a second.
            if (c.expect and !c.continued and s.free_ms - c.opened < 1000 and c.sent >= c.head_len) continue;
            const room = (c.taken + c.capacity) -| c.sent;
            const want = @min(c.stop_at - c.sent, room, @max(1, c.rate * ms / 1000));
            if (want > 0) {
                c.sent += want;
                c.last_arrival = s.mark();
            }
            if (c.sent == c.bytes.len and c.all_by == null) c.all_by = s.free_ms;
        };
    }

    /// One pass of the loop: every connection decided, the oldest ready one
    /// served (its turn `turn_ms`).
    fn pass(s: *Sim, turn_ms: u64) !void {
        var best: ?usize = null;
        for (&s.clients, 0..) |*slot, i| {
            const c = if (slot.*) |*cc| cc else continue;
            _ = s.d.of(i, c.serial);
            const ready = try s.decide(i, c);
            if (ready and (best == null or c.serial < s.clients[best.?].?.serial)) best = i;
        }
        try s.books();
        if (best) |i| {
            try s.serve(i);
            s.close(i);
            s.served += 1;
            // The turn: the clock moves, the free clock does not (bytes that
            // arrive meanwhile are the next tick's).
            if (turn_ms > 0) {
                s.now += @as(i96, turn_ms) * ns_per_ms;
                s.d.pause(@as(i96, turn_ms) * ns_per_ms);
            }
        }
    }

    fn decide(s: *Sim, i: usize, c: *Client) !bool {
        const flaky: *Flaky = @ptrCast(@alignCast(s.d.gpa.ptr));
        while (true) {
            flaky.failed = false;
            const next = s.d.step(i, .{ .serial = c.serial, .pending = c.pending(), .peer_done = c.finished(), .capacity = c.capacity }, s.now);
            if (flaky.failed) c.excused_busy = true;
            if (next.consumed > c.pending().len) return s.fail("consumed {d} of {d} pending", .{ next.consumed, c.pending().len });
            c.taken += next.consumed;
            const w = &s.d.waits[i];
            if (w.head_at != null and c.head_seen == null) {
                if (c.sent < c.head_len) return s.fail("a head timed before it was whole", .{});
                c.head_seen = s.mark();
            }
            if (w.drain != null and c.drain_began == null) c.drain_began = s.mark();
            if (w.slot_wait_since != null and c.slot_wait_began == null) c.slot_wait_began = s.mark();
            switch (next.then) {
                .wait => return false,
                .serve => {
                    if (c.ready_at == null) c.ready_at = s.mark();
                    return true;
                },
                .send_continue => {
                    if (c.continued) return s.fail("told to send twice", .{});
                    // The send queue full now and then: asked again.
                    if (s.rng.uintLessThan(u8, 4) != 0) {
                        s.d.continued(i);
                        c.continued = true;
                        props.reachable(@src(), "drain_sim: a head is told to send its body", null);
                    }
                    return false;
                },
                .ask_who => {
                    if (c.kind != .upload) return s.fail("asked who uploads a small body", .{});
                    if (c.who == .unknown) c.excused_busy = true;
                    s.asks += 1;
                    c.asked = s.asks;
                    if (c.who == .who) s.latest_ask[c.who.who] = s.asks;
                    s.d.know(i, c.who);
                },
            }
        }
    }

    /// The books, after every pass.
    fn books(s: *Sim) !void {
        var held: usize = 0;
        var charged: usize = 0;
        var small: usize = 0;
        for (s.clients, 0..) |slot, i| {
            const c = slot orelse continue;
            const w = &s.d.waits[i];
            if (w.serial != c.serial) continue;
            if (w.slot) |k| {
                held += 1;
                const holder = s.d.slots.held[k] orelse return s.fail("a wait holds slot {d}, which nobody holds", .{k});
                if (c.who != .who or c.who.who != holder) return s.fail("slot {d} held by {d} for another", .{ k, holder });
                const sc = s.d.slot_conn[k] orelse return s.fail("slot {d} has no connection", .{k});
                if (sc.i != i or sc.serial != c.serial) return s.fail("slot {d} names another connection", .{k});
            }
            if (w.drain) |d| {
                if (d.charged) charged += d.bytes.len;
                // A head kept to be answered from (want 0) is charged, never
                // held to the budget.
                if (d.charged and d.want > 0) small += d.bytes.len;
                if (d.upload and d.bytes.len != d.most) return s.fail("an upload's room {d} is not its length {d}", .{ d.bytes.len, d.most });
                // Its bytes are judged when it is served (`serve`): every pass
                // over megabytes was most of the sweep's time.
                // A head kept to answer from is copied, never consumed.
                const head_only = d.want == 0 and d.most == d.head_len;
                if (!head_only and d.len > c.taken) return s.fail("a drain holds more than was taken", .{});
            }
        }
        if (held != s.d.slots.inUse()) return s.fail("{d} slots held, {d} waits say so", .{ s.d.slots.inUse(), held });
        if (charged != s.d.charged) return s.fail("charged {d}, drains hold {d}", .{ s.d.charged, charged });
        if (small > s.d.budget) return s.fail("small drains hold {d}, past the budget {d}", .{ small, s.d.budget });
        // **THE BUDGET HOLDS EVERYTHING CHARGED** (175.3's claim, judged
        // directly, 177.5): heads kept to answer from as well.
        if (s.d.charged > s.d.budget) return s.fail("charged {d}, past the budget {d}", .{ s.d.charged, s.d.budget });
    }

    fn serve(s: *Sim, i: usize) !void {
        const c = &s.clients[i].?;
        const w = &s.d.waits[i];
        const age = s.free_ms - c.opened;
        if (w.memory()) |m| if (!std.mem.eql(u8, m, c.bytes[0..m.len])) return s.fail("served bytes other than came", .{});
        if (w.refusal()) |r| switch (r) {
            .too_slow => {
                props.reachable(@src(), "drain_sim: a body too slow is 408", null);
                const from = if (c.kind == .upload) c.drain_began else c.head_seen;
                const deadline: u64 = if (c.kind == .upload) body_rule.upload_ms else blk: {
                    const head = std.http.Server.Request.Head.parse(c.bytes[0..c.head_len]) catch unreachable;
                    break :blk body_rule.plan(&head, caps(head.target)).read().?.deadline_ms;
                };
                const t = from orelse return s.fail("408 with no clock begun", .{});
                const ms_waited = s.waited(t, deadline);
                if (ms_waited < deadline) return s.fail("408 after {d} ms waited, its deadline {d}", .{ ms_waited, deadline });
                // **NOR LATE ON THE WALL** (175.1, judged here by 177.5): turns
                // move a clock on by at most its own length, so a 408 comes
                // by twice its deadline, and a step's slack.
                const wall: u64 = @intCast(@divTrunc(c.ready_at.?.now - t.now, ns_per_ms));
                if (wall > 2 * deadline + step_most_ms) return s.fail("408 after {d} ms of the wall, its deadline {d}", .{ wall, deadline });
            },
            .stalled => {
                props.reachable(@src(), "drain_sim: a dropped phone's upload stalls, 408", null);
                if (c.kind != .upload) return s.fail("a small body stalled", .{});
                // The wall's time: turns never hold a stall (175.1).
                const since: u64 = @intCast(@divTrunc(s.now - c.last_arrival.now, ns_per_ms));
                if (since < body_rule.upload_stall_ms) return s.fail("stalled {d} ms after a byte", .{since});
                const by: u64 = @intCast(@divTrunc(c.ready_at.?.now - c.last_arrival.now, ns_per_ms));
                // A stall clock is never moved by turns: the stall comes by
                // its 30 s from the byte taken (a pass after it came) and the
                // pass that sees it.
                if (by > body_rule.upload_stall_ms + 2 * step_most_ms) return s.fail("stalled only {d} ms of the wall after a byte", .{by});
            },
            .busy => {
                props.reachable(@src(), "drain_sim: an upload told the host is busy, 503", null);
                // **EACH 503 BY ITS OWN CAUSE** (177.5): a tight budget's
                // excused only in a tight seed, never a slot wait's.
                switch (w.busy_why) {
                    .none => return s.fail("503 with no cause", .{}),
                    // A full budget is a 503 at once (175.2), for a small body
                    // or a head kept to answer from; only a tight budget fills.
                    .budget => if (!s.tight_budget) return s.fail("the budget's 503 with the budget out of play", .{}),
                    .memory => if (!c.excused_busy) return s.fail("a 503 for memory with no allocation failed", .{}),
                    .asking => if (c.who != .unknown) return s.fail("a 503 for an asker who could be told", .{}),
                    .slot_wait => {
                        const t = c.slot_wait_began orelse return s.fail("a slot wait's 503 with no slot wait", .{});
                        const ms_waited = s.waited(t, body_rule.slot_wait_ms);
                        if (ms_waited < body_rule.slot_wait_ms) return s.fail("503 after {d} ms waiting for a slot", .{ms_waited});
                    },
                }
            },
            .replaced => {
                props.reachable(@src(), "drain_sim: a human's retry takes over their upload, 409", null);
                // A newer upload by the same human asked for a slot (it may be
                // gone since: a retry reset before the old one was served).
                const human = switch (c.who) {
                    .who => |k| k,
                    else => return s.fail("409 for an upload by no human", .{}),
                };
                if (s.latest_ask[human] <= c.asked) return s.fail("409 with no newer upload by its human", .{});
            },
            .too_large => {
                props.reachable(@src(), "drain_sim: a chunked body past what is kept is 413", null);
                if (c.kind != .chunked) return s.fail("413 for a body not chunked", .{});
                const most = body_rule.chunkedRawMost(caps("/x"));
                if (c.bytes.len - c.head_len <= most) return s.fail("413 for a chunked body of {d}, within {d}", .{ c.bytes.len - c.head_len, most });
            },
        } else {
            // Served for its route: whole, or from the buffer, or short and
            // refused by std from memory.
            switch (w.handover()) {
                .whole => |b| {
                    props.reachable(@src(), "drain_sim: a drained body is handed over whole", null);
                    if (!std.mem.eql(u8, b, c.bytes[c.body_from..][0..c.body_len])) return s.fail("handed over other bytes than its body", .{});
                },
                .memory => if (w.verdict == .stranger) {
                    props.reachable(@src(), "drain_sim: a stranger is served from the head", null);
                    if (c.who != .stranger) return s.fail("served as a stranger", .{});
                    if (w.memory().?.len != c.head_len) return s.fail("a stranger's body was kept", .{});
                } else if (c.kind == .chunked) {
                    props.reachable(@src(), "drain_sim: a chunked body is read from memory", null);
                } else {
                    props.reachable(@src(), "drain_sim: a body cut short is read from memory, to be refused", null);
                    if (!c.closes) return s.fail("a short body served with its client still sending", .{});
                },
                .network => {},
            }
        }
        // **NO HONEST BODY REFUSED**: the budget out of play and no heap
        // failure, a body all here well within its deadline is not 408.
        if (!s.tight_budget and !c.excused_busy and w.late) if (c.all_by) |t| if (c.head_seen) |h| {
            if (c.kind != .upload and t - h.free + 1000 < body_rule.small_base_ms) return s.fail("408 for a body all here {d} ms after its head", .{t - h.free});
        };
        if (age > body_rule.slot_wait_ms + body_rule.upload_ms + 60_000) return s.fail("served {d} ms after it opened", .{age});
    }

    /// No request has waited past the longest the rule allows: in free
    /// time, a slot's wait then an upload's five minutes; on the wall,
    /// each of those plus at most its own length again, what turns may add
    /// (175.1, judged by the wall's clock, 177.5), and the turns of the
    /// requests served ahead of it.
    fn noneForgotten(s: *Sim) !void {
        for (s.clients) |slot| if (slot) |c| {
            const age = s.free_ms - c.opened;
            if (age > body_rule.slot_wait_ms + body_rule.upload_ms + 60_000) return s.fail("a request still waits {d} ms after it opened", .{age});
            const wall: u64 = @intCast(@divTrunc(s.now - c.opened_now, ns_per_ms));
            if (wall > wall_most_ms) return s.fail("a request still waits {d} ms of the wall after it opened", .{wall});
        };
    }
};

pub fn runSeed(seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var flaky: Flaky = .{ .backing = std.testing.allocator, .rng = r, .one_in = if (seed % 4 == 0) 40 else 0 };
    const tight = seed % 3 == 0;
    // **A BUSY LOOP** (177.5): every pass a long turn, as one busy client
    // makes, so what turns may add to a wait (175.1) is judged on the wall.
    const busy_loop = seed % 5 == 2;
    var s: Sim = .{
        .gpa = std.testing.allocator,
        .rng = r,
        .seed = seed,
        .d = .{ .gpa = flaky.allocator(), .limit = caps, .budget = if (tight) 256 * 1024 else body_rule.small_budget },
        .tight_budget = tight,
    };
    defer for (0..conns) |i| s.close(i);
    const steps = 600 + r.uintLessThan(usize, 600);
    for (0..steps) |_| {
        // New connections in free slots.
        for (0..conns) |i| if (s.clients[i] == null and r.uintLessThan(u8, 3) == 0) try s.open(i);
        // A client gone now and then (a reset): its memory and slot back.
        if (r.uintLessThan(u8, 30) == 0) {
            const i = r.uintLessThan(usize, conns);
            if (s.clients[i] != null) s.close(i);
        }
        const dt: u64 = switch (r.uintLessThan(u8, 8)) {
            0 => 5_000 + r.uintLessThan(u64, 30_000),
            1, 2 => 1 + r.uintLessThan(u64, 2_000),
            else => 1 + r.uintLessThan(u64, 50),
        };
        s.free_ms += dt;
        s.now += @as(i96, dt) * ns_per_ms;
        s.deliver(dt);
        const turn: u64 = if (busy_loop) turn_most_ms - r.uintLessThan(u64, 1_000) else if (r.uintLessThan(u8, 5) == 0) r.uintLessThan(u64, turn_most_ms) else r.uintLessThan(u64, 20);
        try s.pass(turn);
        try s.noneForgotten();
    }
    // Then no new connections: everything left ends.
    var rounds: usize = 0;
    while (rounds < 20_000) : (rounds += 1) {
        var any = false;
        for (s.clients) |c| any = any or c != null;
        if (!any) break;
        s.free_ms += 1_000;
        s.now += 1_000 * ns_per_ms;
        s.deliver(1_000);
        try s.pass(0);
        try s.noneForgotten();
    }
    for (0..conns) |i| s.close(i);
    if (s.d.charged != 0) return s.fail("{d} bytes still charged at the end", .{s.d.charged});
    if (s.d.slots.inUse() != 0) return s.fail("{d} slots still held at the end", .{s.d.slots.inUse()});
}

test "drain.zig under a seed, a handful of seeds" {
    // **FOUR IN TIER 0** (metal-vmm QUEUE 198.11): each is about a second
    // in Debug; `zig build properties` sweeps 100 and long.sh 10,000.
    for (1..5) |seed| try runSeed(seed);
}
