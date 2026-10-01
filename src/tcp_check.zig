//! **THE TABLE'S INVARIANTS, CHECKED FROM OUTSIDE IT.** `check` looks at every
//! slot of a `tcp.Table` and names the first rule it finds broken. The tests
//! call it after every `handle` and every `transmit` (TCP_TESTING.md §1), so
//! every scenario anyone writes is also a check of all of these, at every
//! step of it.
//!
//! Two kinds of rule:
//!
//! - **SAFETY**: the bookkeeping agrees with itself. Buffers are inside their
//!   bounds, what was sent is no more than what was queued, the state and
//!   where our FIN is say the same thing.
//! - **LIVENESS**: everything a connection owes is covered by a deadline, so
//!   no work can sit in the table with nothing to make it happen. This is the
//!   rule the bugs found by reading in October 2026 broke, and it is written
//!   as a table — `liveness` below — because a kind of debt with no row is
//!   exactly the kind nobody is paying.
//!
//! **WHEN IT IS LOOKED AT MATTERS.** Some debts are the next `transmit`'s to
//! pay: bytes just queued, a window just reopened. Every turn of the loop
//! calls `transmit`, so after `handle` owing them to it is enough. After
//! `transmit` it is not: whatever was the next turn's has been done, and
//! every deadline left is in the future.

const tcp = @import("tcp.zig");
const Conn = tcp.Conn;
const Table = tcp.Table;

pub const Phase = enum {
    /// Just after `handle` (or anything else the host does between turns).
    after_handle,
    /// Just after `transmit`: a turn of the send side has run.
    after_transmit,
};

pub const Rule = enum {
    // ── a free slot ─────────────────────────────────────────────────────────
    closed_holds_a_deadline,
    closed_holds_bytes,

    // ── safety ──────────────────────────────────────────────────────────────
    rx_out_of_bounds,
    tx_out_of_bounds,
    sent_past_high_or_queue,
    closing_disagrees_with_fin,
    fin_sent_before_queued,
    fin_acknowledged_with_bytes_left,
    handshake_with_bytes,
    peer_finished_during_handshake,
    retries_past_the_limit,

    // ── liveness: the rows of `liveness` ────────────────────────────────────
    handshake_without_a_timer,
    in_flight_without_a_timer,
    queued_without_a_timer,
    fin_queued_and_not_sent,
    fin_wait_without_a_deadline,
    reopened_window_not_timed,
    reopened_window_not_announced,

    // ── after a turn ────────────────────────────────────────────────────────
    deadline_passed,

    pub fn says(self: Rule) []const u8 {
        return switch (self) {
            .closed_holds_a_deadline => "a free slot still has a deadline armed",
            .closed_holds_bytes => "a free slot still holds bytes",
            .rx_out_of_bounds => "the receive buffer's start and end are out of order or past its end",
            .tx_out_of_bounds => "the send queue's start and end are out of order or past its end",
            .sent_past_high_or_queue => "sent <= high <= queued() does not hold",
            .closing_disagrees_with_fin => "the state is closing exactly when our FIN is queued, sent or acknowledged, and here it is not",
            .fin_sent_before_queued => "a FIN went on the wire though none is queued",
            .fin_acknowledged_with_bytes_left => "our FIN is acknowledged with bytes still queued or in flight",
            .handshake_with_bytes => "a connection still in its handshake has bytes queued or received",
            .peer_finished_during_handshake => "the peer's FIN was taken before the handshake completed",
            .retries_past_the_limit => "more timeouts than max_retries without giving up",
            .handshake_without_a_timer => "a SYN-ACK is unanswered and nothing will send it again",
            .in_flight_without_a_timer => "bytes or a FIN are on the wire unacknowledged and nothing will send them again",
            .queued_without_a_timer => "bytes are queued and unsent, a turn has passed, and no timer will probe for room",
            .fin_queued_and_not_sent => "our FIN is queued behind nothing, and a turn passed without sending it",
            .fin_wait_without_a_deadline => "our FIN is acknowledged and nothing bounds the wait for the peer's",
            .reopened_window_not_timed => "a reopened window was announced and a turn passed without timing its repeat",
            .reopened_window_not_announced => "the peer last saw a shut window, there is room now, and a turn passed without saying so",
            .deadline_passed => "a deadline is in the past after a turn that should have acted on it",
        };
    }
};

pub const Violation = struct { conn: usize, rule: Rule };

/// The first rule broken by any slot of `table`, or null.
pub fn check(table: *const Table, now: i96, phase: Phase) ?Violation {
    for (table.conns, 0..) |*c, i| {
        if (checkConn(c, now, phase)) |rule| return .{ .conn = i, .rule = rule };
    }
    return null;
}

pub fn checkConn(c: *const Conn, now: i96, phase: Phase) ?Rule {
    if (c.state == .closed) return free(c);
    if (safety(c)) |rule| return rule;
    for (liveness) |row| {
        if (row.owes(c) and !row.covered(c, phase)) return row.rule;
    }
    if (phase == .after_transmit) {
        if (passed(c.rto_at, now) or passed(c.fin_wait_until, now) or passed(c.update_at, now))
            return .deadline_passed;
    }
    return null;
}

/// A slot that is free has been reset whole: nothing armed, nothing held.
fn free(c: *const Conn) ?Rule {
    if (c.rto_at != null or c.fin_wait_until != null or c.update_at != null or c.reopened)
        return .closed_holds_a_deadline;
    if (c.queued() != 0 or c.start != 0 or c.end != 0) return .closed_holds_bytes;
    return null;
}

fn safety(c: *const Conn) ?Rule {
    if (!(c.start <= c.end and c.end <= c.rx.len)) return .rx_out_of_bounds;
    if (!(c.tx_start <= c.tx_end and c.tx_end <= c.tx.len)) return .tx_out_of_bounds;
    if (!(c.sent <= c.high and c.high <= c.queued())) return .sent_past_high_or_queue;
    if ((c.state == .closing) != (c.fin != .none)) return .closing_disagrees_with_fin;
    if (c.fin_ever_sent and c.fin == .none) return .fin_sent_before_queued;
    if (c.fin == .acknowledged and (c.queued() != 0 or c.high != 0)) return .fin_acknowledged_with_bytes_left;
    if (c.state == .syn_received) {
        if (c.queued() != 0 or c.end != 0) return .handshake_with_bytes;
        if (c.peer_done) return .peer_finished_during_handshake;
    }
    if (c.retries > tcp.max_retries) return .retries_past_the_limit;
    return null;
}

/// **THE LIVENESS TABLE.** One row for each thing a connection can owe the
/// peer, and what guarantees it is done. A connection that owes none of them
/// is idle: established with nothing queued, waiting on its peer, and the
/// host's own `quiet()` (outside the table, bounded by `idle_ns`) is what
/// lets it go.
///
/// A new kind of debt is a new row here. A debt with no row is invisible to
/// every test — that is how a reopened window's lost announcement went
/// unnoticed until it was read for.
const Row = struct {
    rule: Rule,
    owes: *const fn (*const Conn) bool,
    covered: *const fn (*const Conn, Phase) bool,
};

const liveness = [_]Row{
    // Our SYN-ACK, until the handshake's last ACK comes: the retransmission
    // timer sends it again, and gives up after max_retries.
    .{ .rule = .handshake_without_a_timer, .owes = &inHandshake, .covered = &rtoArmed },
    // Bytes or a FIN on the wire, unacknowledged: the retransmission timer.
    .{ .rule = .in_flight_without_a_timer, .owes = &inFlight, .covered = &rtoArmed },
    // Bytes queued and not yet sent: the next turn sends what the window
    // allows; after it, what is left waits on a shut window, and the
    // retransmission timer probes it.
    .{ .rule = .queued_without_a_timer, .owes = &queuedUnsent, .covered = &nextTurnOrRto },
    // Our FIN, queued: once every byte has gone the next turn sends it, so
    // after a turn it may only still be queued behind bytes (the row above).
    .{ .rule = .fin_queued_and_not_sent, .owes = &finQueued, .covered = &nextTurnOrBehindBytes },
    // Our FIN acknowledged, the peer's not yet come: `fin_wait_ns`.
    .{ .rule = .fin_wait_without_a_deadline, .owes = &finAcknowledged, .covered = &finWaitArmed },
    // A reopened window just announced: the next turn starts the clock on
    // which it is repeated (`update_at`).
    .{ .rule = .reopened_window_not_timed, .owes = &reopenedFlag, .covered = &nextTurn },
    // A window the peer last saw shut, with room now, and nobody has said so
    // (the reader made room without calling `ack`): the next turn says it.
    .{ .rule = .reopened_window_not_announced, .owes = &reopenedUnsaid, .covered = &nextTurn },
};

fn inHandshake(c: *const Conn) bool {
    return c.state == .syn_received;
}
fn inFlight(c: *const Conn) bool {
    return c.highest() != c.una;
}
fn queuedUnsent(c: *const Conn) bool {
    return c.queued() > c.sent;
}
fn finQueued(c: *const Conn) bool {
    return c.fin == .queued;
}
fn finAcknowledged(c: *const Conn) bool {
    return c.fin == .acknowledged;
}
fn reopenedFlag(c: *const Conn) bool {
    return c.reopened;
}
fn reopenedUnsaid(c: *const Conn) bool {
    if (c.state != .established and c.state != .closing) return false;
    // Nothing more is coming from a peer that has finished: no window to owe.
    if (c.peer_done) return false;
    return c.tight(c.told_wnd) and !c.tight(c.window());
}

fn rtoArmed(c: *const Conn, _: Phase) bool {
    return c.rto_at != null;
}
fn finWaitArmed(c: *const Conn, _: Phase) bool {
    return c.fin_wait_until != null;
}
fn nextTurn(_: *const Conn, phase: Phase) bool {
    return phase == .after_handle;
}
fn nextTurnOrRto(c: *const Conn, phase: Phase) bool {
    return phase == .after_handle or c.rto_at != null;
}
fn nextTurnOrBehindBytes(c: *const Conn, phase: Phase) bool {
    return phase == .after_handle or c.queued() > c.sent;
}

fn passed(deadline: ?i96, now: i96) bool {
    const at = deadline orelse return false;
    return at <= now;
}

// ── the checker checked: each rule fires on the state it describes ─────────

const std = @import("std");
const testing = std.testing;

fn conn(rx: []u8, tx: []u8) Conn {
    return .{ .rx = rx, .tx = tx };
}

test "a fresh slot breaks nothing" {
    var rx: [64]u8 = undefined;
    var tx: [64]u8 = undefined;
    const c = conn(&rx, &tx);
    try testing.expectEqual(@as(?Rule, null), checkConn(&c, 0, .after_transmit));
}

test "bytes on the wire with no timer are a liveness violation" {
    var rx: [64]u8 = undefined;
    var tx: [64]u8 = undefined;
    var c = conn(&rx, &tx);
    c.state = .established;
    c.tx_end = 5;
    c.sent = 5;
    c.high = 5;
    try testing.expectEqual(@as(?Rule, .in_flight_without_a_timer), checkConn(&c, 0, .after_handle));
    c.rto_at = 100;
    try testing.expectEqual(@as(?Rule, null), checkConn(&c, 0, .after_handle));
    // And the timer must be in the future once a turn has run.
    try testing.expectEqual(@as(?Rule, .deadline_passed), checkConn(&c, 100, .after_transmit));
}

test "queued bytes are the next turn's, and after it a probe timer's" {
    var rx: [64]u8 = undefined;
    var tx: [64]u8 = undefined;
    var c = conn(&rx, &tx);
    c.state = .established;
    c.tx_end = 5; // queued, none sent, a shut window
    try testing.expectEqual(@as(?Rule, null), checkConn(&c, 0, .after_handle));
    try testing.expectEqual(@as(?Rule, .queued_without_a_timer), checkConn(&c, 0, .after_transmit));
}

test "a window the peer saw shut, with room again and nobody saying so, is owed" {
    // The bug a lost window update was: this state, and no row for it.
    var rx: [64]u8 = undefined;
    var tx: [64]u8 = undefined;
    var c = conn(&rx, &tx);
    c.state = .established;
    c.told_wnd = 0;
    try testing.expectEqual(@as(?Rule, null), checkConn(&c, 0, .after_handle));
    try testing.expectEqual(@as(?Rule, .reopened_window_not_announced), checkConn(&c, 0, .after_transmit));
    c.peer_done = true; // a finished peer is owed nothing
    try testing.expectEqual(@as(?Rule, null), checkConn(&c, 0, .after_transmit));
}

test "an acknowledged FIN with no bound on the wait for the peer's is owed" {
    var rx: [64]u8 = undefined;
    var tx: [64]u8 = undefined;
    var c = conn(&rx, &tx);
    c.state = .closing;
    c.fin = .acknowledged;
    c.fin_ever_sent = true;
    try testing.expectEqual(@as(?Rule, .fin_wait_without_a_deadline), checkConn(&c, 0, .after_handle));
    c.fin_wait_until = 30;
    try testing.expectEqual(@as(?Rule, null), checkConn(&c, 0, .after_transmit));
}

test "safety rules fire on inconsistent bookkeeping" {
    var rx: [64]u8 = undefined;
    var tx: [64]u8 = undefined;
    var c = conn(&rx, &tx);
    c.state = .established;
    c.fin = .queued; // queued, but the state says otherwise
    try testing.expectEqual(@as(?Rule, .closing_disagrees_with_fin), checkConn(&c, 0, .after_handle));

    c = conn(&rx, &tx);
    c.state = .established;
    c.sent = 3; // sent more than was ever queued
    c.high = 3;
    try testing.expectEqual(@as(?Rule, .sent_past_high_or_queue), checkConn(&c, 0, .after_handle));

    c = conn(&rx, &tx);
    c.rto_at = 5; // a free slot with a timer
    try testing.expectEqual(@as(?Rule, .closed_holds_a_deadline), checkConn(&c, 0, .after_handle));
}
