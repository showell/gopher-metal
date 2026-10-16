//! **THE RETRANSMISSION TIMEOUT** (RFC 9293 §3.8.1 and §3.10.8; RFC 6298,
//! "Computing TCP's Retransmission Timer"; RFC 5681 §3.2, fast retransmit):
//! the clock's bounds, its backoff, how a round trip is folded into it, and
//! how much may go back on the wire after a loss. Each is a function of the
//! connection alone: no I/O, no table. Moved here from tcp.zig, unchanged
//! (metal-vmm QUEUE 225, chunk 3a).
//!
//! **THE RFCS' WORDS ARE QUOTED** (chunk 3b), on lines that begin `> `,
//! copied from `docs/rfc/` word for word (tcp_test.zig holds every quote to
//! those files). A `DEPARTS:` line names each place the code does otherwise.

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
/// > (2.1) Until a round-trip time (RTT) measurement has been made for a
/// >       segment sent between the sender and receiver, the sender SHOULD
/// >       set RTO <- 1 second, though the "backing off" on repeated
/// >       retransmission discussed in (5.5) still applies.
///
/// > (2.4) Whenever RTO is computed, if it is less than 1 second, then the
/// >       RTO SHOULD be rounded up to 1 second.
///
/// > (2.5) A maximum value MAY be placed on RTO provided it is at least 60
/// >       seconds.
///
/// DEPARTS: the first wait (2.1) and the floor (2.4) are 200 ms, not one
/// second, for the reasons above.
/// DEPARTS: the ceiling is 5 s, under (2.5)'s 60 s, so a peer back from a
/// bad patch is heard from within seconds.
///
/// Each timeout doubles the wait up to `max_rto_ns`, and the connection is
/// reset after `max_retries` timeouts with nothing acknowledged: RFC 9293's
/// R2 (§3.8.3), counted in timeouts.
pub const min_rto_ns: u64 = 200 * tcp.ns_per_ms;
pub const first_rto_ns: u64 = min_rto_ns;
pub const max_rto_ns: u64 = 5 * tcp.ns_per_s;
pub const max_retries: u8 = 6;
/// **OUR SYN'S FIRST WAIT** (metal-vmm docs/TWO-KERNELS.md §8, decision 2):
/// 25 ms, doubling, for a connection of our own only. `min_rto_ns` is about a
/// peer that delays its ACKs, and nobody delays a SYN-ACK. The server's
/// SYN-ACK keeps the 200 ms floor.
///
/// > (5.7) If the timer expires awaiting the ACK of a SYN segment and the
/// >       TCP implementation is using an RTO less than 3 seconds, the RTO
/// >       MUST be re-initialized to 3 seconds when data transmission
/// >       begins (i.e., after the three-way handshake completes).
///
/// DEPARTS: once established, a connection whose SYN or SYN-ACK was sent
/// again has `first_rto_ns` (200 ms), not 3 s, until its first sample.
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
/// once what the timer would only guess a round trip later. RFC 5681 §3.2:
///
/// > The TCP sender SHOULD use the "fast retransmit" algorithm to detect
/// > and repair loss, based on incoming duplicate ACKs.  The fast
/// > retransmit algorithm uses the arrival of 3 duplicate ACKs (as defined
/// > in section 2, without any intervening ACKs which move SND.UNA) as an
/// > indication that a segment has been lost.  After receiving 3 duplicate
/// > ACKs, TCP performs a retransmission of what appears to be the missing
/// > segment, without waiting for the retransmission timer to expire.
///
/// DEPARTS: there is no congestion control (tcp.zig's header), so no fast
/// recovery, and no Limited Transmit: the first and second duplicate ACKs
/// send nothing new (§3.2, step 1, after RFC 3042).
pub const dupacks_before_resend: u8 = 3;

/// **ONE MORE TIMEOUT**: false once they have run out. RFC 6298 §5:
///
/// > (5.5) The host MUST set RTO <- RTO * 2 ("back off the timer").  The
/// >       maximum value discussed in (2.5) above may be used to provide
/// >       an upper bound to this doubling operation.
/// >
/// > (5.6) Start the retransmission timer, such that it expires after RTO
/// >       seconds (for the value of RTO after the doubling operation
/// >       outlined in 5.5).
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

/// **A ROUND TRIP OF `rtt` NS, FOLDED IN**, and the RTO from it, within its
/// bounds. RFC 6298 §2, with G, the clock's granularity, a nanosecond:
///
/// > (2.2) When the first RTT measurement R is made, the host MUST set
/// >
/// >          SRTT <- R
/// >          RTTVAR <- R/2
/// >          RTO <- SRTT + max (G, K*RTTVAR)
/// >
/// >       where K = 4.
/// >
/// > (2.3) When a subsequent RTT measurement R' is made, a host MUST set
/// >
/// >          RTTVAR <- (1 - beta) * RTTVAR + beta * |SRTT - R'|
/// >          SRTT <- (1 - alpha) * SRTT + alpha * R'
/// >
/// >       The value of SRTT used in the update to RTTVAR is its value
/// >       before updating SRTT itself using the second assignment.  That
/// >       is, updating RTTVAR and SRTT MUST be computed in the above
/// >       order.
/// >
/// >       The above SHOULD be computed using alpha=1/8 and beta=1/4 (as
/// >       suggested in [JK88]).
/// >
/// >       After the computation, a host MUST update
/// >       RTO <- SRTT + max (G, K*RTTVAR)
///
/// One segment is timed at a time, and never a retransmitted one (tcp.zig's
/// `time` and `measure`). RFC 6298 §3:
///
/// > TCP MUST use Karn's algorithm [KP87] for taking RTT samples.  That
/// > is, RTT samples MUST NOT be made using segments that were
/// > retransmitted (and thus for which it is ambiguous whether the reply
/// > was for the first instance of the packet or a later instance).  The
/// > only case when TCP can safely take RTT samples from retransmitted
/// > segments is when the TCP timestamp option [JBB92] is employed, since
/// > the timestamp option removes the ambiguity regarding which instance
/// > of the data segment triggered the acknowledgment.
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

/// **THE OLDEST SEGMENT AGAIN**, after a timeout or three duplicate ACKs: no
/// further past `una` than one segment (`recovery`), and at least one byte.
/// A shut window's timeout does not come here: it owes a probe, not a
/// recovery (tcp.zig, QUEUE 227). RFC 6298 §5:
///
/// > When the retransmission timer expires, do the following:
/// >
/// > (5.4) Retransmit the earliest segment that has not been acknowledged
/// >       by the TCP receiver.
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
