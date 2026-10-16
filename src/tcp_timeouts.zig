//! **THE RETRANSMISSION TIMEOUT** (RFC 9293 §3.8.1 and §3.10.8; RFC 6298,
//! "Computing TCP's Retransmission Timer"; RFC 5681 §3.2, fast retransmit):
//! the clock's bounds, its backoff, how a round trip is folded into it, and
//! how much may go back on the wire after a loss. Each is a function of the
//! connection alone: no I/O, no table. Moved here from tcp.zig, unchanged
//! (metal-vmm QUEUE 225, chunk 3a).

const tcp = @import("tcp.zig");
const Conn = tcp.Conn;
const props = @import("coverage");

// Every property in this file, in the catalog, called or not (COVERAGE.md).
comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() @import("std").builtin.SourceLocation {
    return @src();
}

/// **THE RETRANSMISSION CLOCK IS MEASURED** (RFC 6298): one segment timed at
/// a time, RTO = SRTT + 4 * RTTVAR. The handshake is the first sample, so the
/// first byte of a response already goes out under a measured clock.
///
/// **THE FLOOR IS ABOUT THE PEER'S DELAYED ACKS, NOT THE PATH.** A peer may
/// hold an ACK for tens of milliseconds (Linux) or up to 200 (slirp). Waiting
/// less turns a delay into a "loss" and resends a whole window for nothing,
/// so the floor is Linux's `TCP_RTO_MIN`, not RFC 6298's one second (2.4).
/// It is also the first, unmeasured wait: over a private network to Caddy,
/// RFC 6298's second is a thousand round trips.
///
/// Each timeout doubles the wait up to `max_rto_ns` (RFC 6298 (5.5); the
/// RFC's ceiling is at least 60 s), and the connection is reset after
/// `max_retries` timeouts with nothing acknowledged: RFC 9293's R2 (§3.8.3),
/// counted in timeouts.
pub const min_rto_ns: u64 = 200 * tcp.ns_per_ms;
pub const first_rto_ns: u64 = min_rto_ns;
pub const max_rto_ns: u64 = 5 * tcp.ns_per_s;
pub const max_retries: u8 = 6;
/// **OUR SYN'S FIRST WAIT** (metal-vmm docs/TWO-KERNELS.md §8, decision 2):
/// 25 ms, doubling, for a connection of our own only. `min_rto_ns` is about a
/// peer that delays its ACKs, and nobody delays a SYN-ACK. The server's
/// SYN-ACK keeps the 200 ms floor.
pub const syn_first_rto_ns: u64 = 25 * tcp.ns_per_ms;

/// **HOW LONG A CONNECTION OF OUR OWN MAY TAKE** (RFC 9293 §3.10.8, "USER
/// TIMEOUT", which leaves the value to the user; TWO-KERNELS.md §5): to be
/// established (`connect_ns`, from the SYN), with nothing heard from the
/// peer (`idle_ns`), and in all (`total_ns`, from the SYN). No defaults: each
/// caller says what its run can wait, and a test's values are not a
/// production run's.
pub const Deadlines = struct { connect_ns: u64, idle_ns: u64, total_ns: u64 };

/// Which of a connection's `Deadlines` has passed.
pub const Deadline = enum { connect, total, idle };

/// **THE FIRST OF `c`'s DEADLINES TO HAVE PASSED BY `now`**, or null: none
/// has, or `c` has none (an accepted connection, which the host bounds).
/// `connect` counts only while SYN-SENT; `total` is named before `idle`
/// when both have passed.
pub fn pastDeadline(c: *const Conn, now: i96) ?Deadline {
    const d = c.deadlines orelse return null;
    if (c.state == .syn_sent and now >= c.opened_at + d.connect_ns) return .connect;
    if (now >= c.opened_at + d.total_ns) return .total;
    if (now >= c.heard_at + d.idle_ns) return .idle;
    return null;
}

/// Duplicate ACKs that mean a segment is lost (RFC 5681): the peer says at
/// once what the timer would only guess a round trip later.
pub const dupacks_before_resend: u8 = 3;

/// One more timeout (RFC 6298 (5.5), (5.6)): false once they have run out.
pub fn backoff(c: *Conn, now: i96) bool {
    if (c.retries >= max_retries) return false;
    c.retries += 1;
    c.rto_ns = @min(c.rto_ns * 2, max_rto_ns);
    props.always(@src(), c.rto_ns <= max_rto_ns, "tcp: a backed-off RTO stays under the cap", .{ .rto_ns = c.rto_ns });
    props.sometimes(@src(), c.rto_ns == max_rto_ns, "tcp: backoff reaches the RTO cap", null);
    props.alwaysLessThanOrEqualTo(@src(), c.retries, max_retries, "tcp: a connection's timeouts stay within its retries", null);
    c.rto_at = now + c.rto_ns;
    return true;
}

/// A round trip of `rtt` ns, folded into SRTT and RTTVAR as RFC 6298 §2
/// says (alpha 1/8, beta 1/4), and the RTO from them, within its bounds.
pub fn fold(c: *Conn, rtt: u64) void {
    if (c.srtt_ns == 0) {
        c.srtt_ns = rtt;
        c.rttvar_ns = rtt / 2;
    } else {
        const off = if (c.srtt_ns > rtt) c.srtt_ns - rtt else rtt - c.srtt_ns;
        c.rttvar_ns = (3 * c.rttvar_ns + off) / 4;
        c.srtt_ns = (7 * c.srtt_ns + rtt) / 8;
    }
    c.rto_ns = @min(@max(c.srtt_ns + 4 * c.rttvar_ns, min_rto_ns), max_rto_ns);
    props.always(@src(), c.rto_ns >= min_rto_ns and c.rto_ns <= max_rto_ns, "tcp: a measured RTO is within its bounds", .{ .rto_ns = c.rto_ns });
    props.sometimes(@src(), c.srtt_ns > rtt, "tcp: a round trip comes in faster than the estimate", null);
}

/// **THE OLDEST SEGMENT AGAIN** (RFC 6298 (5.4): "Retransmit the earliest
/// segment that has not been acknowledged by the TCP receiver"), after a
/// timeout or three duplicate ACKs: no further past `una` than one segment
/// (`recovery`), and at least one byte. A shut window's timeout does not
/// come here: it owes a probe, not a recovery (tcp.zig, QUEUE 227).
pub fn recover(c: *Conn) void {
    c.recovery = @max(1, @min(@as(usize, c.mss), c.high));
}

/// **RECOVERY GROWS BY TWICE WHAT WAS ACKNOWLEDGED**: `advance` new bytes
/// acknowledged make the allowance `(recovery - advance) + 2 * advance`,
/// doubling it each round trip, and it ends once it covers all that was
/// sent (`high`, after this ACK).
pub fn recovered(c: *Conn, advance: u32) void {
    const cap = c.recovery orelse return;
    const grown = (cap -| advance) + 2 * @as(usize, advance);
    c.recovery = if (grown >= c.high) null else grown;
}
