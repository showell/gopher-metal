//! **A STATE THAT CHANGES ONLY BY A NAMED EVENT** (metal-vmm STATE_TRACKING.md,
//! QUEUE item 140). A machine declares its states, its events and the edges
//! between them; code reads the state freely and changes it only by `fire`,
//! which looks the next state up. Nothing chooses a state but the table.
//!
//! **EVERY CELL IS A COVERAGE SITE.** `fire` is one `switch` over every
//! (state, event) pair, each prong compiled with its own message, so the
//! catalog holds one site per cell:
//! - an edge is a `reachable`: a sweep that never took it reports it unhit,
//!   a legal transition no test drives;
//! - a pair with no edge is an `unreachable`: reached, it breaks, and a unit
//!   test fails at it (`on_broken`). The state is left as it was.
//!
//! The messages are regular, so a reader greps them:
//! `machine tcp.Fin: sent --timed_out--> resending` and
//! `machine tcp.Fin: nothing leaves acknowledged on timed_out`.
//!
//! **BUILT TO MOVE** (the box's vote: local first, promoted on its second
//! user): it imports nothing of gopher-metal's, only the coverage SDK, and
//! makes its sites the way the SDK makes them. Moving it is a file and an
//! import.
//!
//! **ONLY `fire` WRITES THE STATE.** `machine_state` is a field, since Zig
//! has none private; `tools/lint_machine.py` refuses an assignment to it
//! anywhere else, and `startingAt` (a machine made at a given state) outside
//! a test.
const std = @import("std");
const props = @import("coverage");

pub fn Edge(comptime State: type, comptime Event: type) type {
    return struct { from: State, on: Event, to: State };
}

/// A machine named `name` (in its sites' messages), over `State` and
/// `Event`, both enums, with `edges` its only transitions. Two edges from
/// one state on one event are refused at compile time.
pub fn Machine(
    comptime name: []const u8,
    comptime State: type,
    comptime Event: type,
    comptime initial: State,
    comptime edges: []const Edge(State, Event),
) type {
    comptime {
        for (edges, 0..) |a, i| {
            for (edges[i + 1 ..]) |b| {
                if (a.from == b.from and a.on == b.on) @compileError(std.fmt.comptimePrint(
                    "machine {s}: two edges leave {t} on {t}",
                    .{ name, a.from, a.on },
                ));
            }
        }
    }
    return struct {
        const Self = @This();

        /// Read it with `get` or `is`; only `fire` writes it.
        machine_state: State = initial,

        pub const Of = State;
        pub const On = Event;

        /// **A MACHINE MADE AT A GIVEN STATE**, not reached by its edges:
        /// for tests that build a case directly. The lint refuses it
        /// outside a test.
        pub fn startingAt(state: State) Self {
            return .{ .machine_state = state };
        }

        pub fn get(self: Self) State {
            return self.machine_state;
        }

        pub fn is(self: Self, state: State) bool {
            return self.machine_state == state;
        }

        /// The edge from `from` on `on`, if the table has one.
        pub fn target(comptime from: State, comptime on: Event) ?State {
            for (edges) |e| {
                if (e.from == from and e.on == on) return e.to;
            }
            return null;
        }

        /// **THE ONLY WAY THE STATE CHANGES.** An event with no edge from
        /// the state it finds breaks that cell's `unreachable` and changes
        /// nothing.
        pub fn fire(self: *Self, event: Event) void {
            switch (self.machine_state) {
                inline else => |from| switch (event) {
                    inline else => |on| {
                        if (comptime target(from, on)) |to| {
                            props.reachable(@src(), comptime edgeMessage(from, on, to), null);
                            self.machine_state = to;
                        } else {
                            props.@"unreachable"(@src(), comptime noEdgeMessage(from, on), null);
                        }
                    },
                },
            }
        }

        fn edgeMessage(comptime from: State, comptime on: Event, comptime to: State) [:0]const u8 {
            return std.fmt.comptimePrint("machine {s}: {t} --{t}--> {t}", .{ name, from, on, to });
        }

        fn noEdgeMessage(comptime from: State, comptime on: Event) [:0]const u8 {
            return std.fmt.comptimePrint("machine {s}: nothing leaves {t} on {t}", .{ name, from, on });
        }
    };
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

const Door = Machine("test.Door", enum { shut, open, locked }, enum { push, pull, lock, unlock }, .shut, &.{
    .{ .from = .shut, .on = .push, .to = .open },
    .{ .from = .open, .on = .pull, .to = .shut },
    .{ .from = .shut, .on = .lock, .to = .locked },
    .{ .from = .locked, .on = .unlock, .to = .shut },
});

test "a machine moves only along its edges" {
    var d: Door = .{};
    try testing.expect(d.is(.shut));
    d.fire(.push);
    try testing.expectEqual(Door.Of.open, d.get());
    d.fire(.pull);
    d.fire(.lock);
    try testing.expect(d.is(.locked));
    d.fire(.unlock);
    try testing.expect(d.is(.shut));
}

test "an event with no edge breaks its cell and changes nothing" {
    const was = props.on_broken;
    props.on_broken = null; // broken on purpose
    defer props.on_broken = was;
    props.reset();
    defer props.reset();

    var d = Door.startingAt(.locked);
    d.fire(.push);
    try testing.expect(d.is(.locked));

    var broken: usize = 0;
    var it = props.catalog();
    while (it.next()) |site| if (site.broken()) {
        broken += 1;
        try testing.expectEqualStrings("machine test.Door: nothing leaves locked on push", std.mem.span(site.message));
    };
    try testing.expectEqual(@as(usize, 1), broken);
}

test "every cell is a site in the catalog, each edge a reachable and each other pair an unreachable" {
    var edge_sites: usize = 0;
    var no_edge_sites: usize = 0;
    var it = props.catalog();
    while (it.next()) |site| {
        const message = std.mem.span(site.message);
        if (!std.mem.startsWith(u8, message, "machine test.Door: ")) continue;
        if (std.mem.indexOf(u8, message, "-->") != null) edge_sites += 1 else no_edge_sites += 1;
    }
    try testing.expectEqual(@as(usize, 4), edge_sites);
    try testing.expectEqual(@as(usize, 3 * 4 - 4), no_edge_sites);
}
