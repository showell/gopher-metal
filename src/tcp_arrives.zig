//! **SEGMENT ARRIVES** (RFC 9293 §3.10.7): what an arriving segment means
//! for a connection, decided purely, with no I/O and no clock. `Table`
//! (tcp.zig) acts on each answer; each has a table-driven test
//! (tcp_test.zig). Moved here from tcp.zig, unchanged (metal-vmm QUEUE 225,
//! chunks 2 and 3a).

const tcp = @import("tcp.zig");
const Conn = tcp.Conn;
/// Sequence numbers modulo 2^32 (seq.zig).
const sq = @import("seq.zig").Seq(u32);

/// **IS THE SEGMENT ACCEPTABLE?** (RFC 9293 §3.10.7.4, first check), by its
/// first sequence number only:
/// - `next`: it is RCV.NXT, the byte expected, and is taken;
/// - `ahead`: past RCV.NXT inside the window we advertise, so acceptable to
///   the RFC, but this table takes only the next byte (its ACK and window
///   still count);
/// - `behind`: at or before RCV.NXT, a resend of what was taken;
/// - `beyond`: past the window, or half the circle away.
/// DEPARTS: the RFC also accepts a segment that starts behind and runs past
/// RCV.NXT, and trims it; here it is `behind`, and the peer resends.
pub const Acceptability = enum { next, ahead, behind, beyond };

pub fn acceptability(c: *const Conn, seq: u32) Acceptability {
    if (seq == c.rcv_nxt) return .next;
    if (c.ahead(seq)) return .ahead;
    return if (sq.atOrAfter(c.rcv_nxt, seq)) .behind else .beyond;
}

/// **A RESET MUST NAME RCV.NXT EXACTLY** (RFC 9293 §3.10.7.4, second check,
/// after RFC 5961 §3): `exact` closes the connection; `challenge`, one
/// elsewhere in the window, draws a challenge ACK, which a genuine peer
/// answers with an exact reset; `ignore`, one outside it, changes nothing.
pub const ResetCheck = enum { exact, challenge, ignore };

pub fn resetCheck(c: *const Conn, seq: u32) ResetCheck {
    if (seq == c.rcv_nxt) return .exact;
    if (c.ahead(seq)) return .challenge;
    return .ignore;
}

/// **THE ACK FIELD** (RFC 9293 §3.10.7.4, fifth check):
/// - in SYN-RECEIVED, `new` when it is ISS + 1, which completes the
///   handshake, and `reset_it` otherwise ("form a reset segment
///   <SEQ=SEG.ACK><CTL=RST>");
/// - in a synchronized state, `new` when it acknowledges bytes past
///   SND.UNA, `duplicate` when it is SND.UNA, and `ignore` when it names
///   what was never sent, or is from before SND.UNA (a wrap past `highest`).
/// DEPARTS: the RFC answers an ACK of something never sent with an ACK and
/// drops the segment; here only its ACK is ignored (`acknowledge`).
pub const AckCheck = enum { reset_it, ignore, duplicate, new };

pub fn ackCheck(c: *const Conn, number: u32) AckCheck {
    if (c.state == .syn_received) return if (number == c.una +% 1) .new else .reset_it;
    const flight = sq.offset(c.una, c.highest());
    const advance = sq.offset(c.una, number);
    if (advance > flight) return .ignore;
    return if (advance == 0) .duplicate else .new;
}

/// **IF THE STATE IS SYN-SENT** (RFC 9293 §3.10.7.3): what the answer to our
/// SYN means. In SYN-SENT, `una` is ISS and SND.NXT is ISS + 1
/// (`highest`). The steps are the RFC's, in its order (its words to be
/// quoted in chunk 3b; paraphrased here):
/// - **First, the ACK bit.** If it is set and SEG.ACK =< ISS or SEG.ACK >
///   SND.NXT, the ACK is not acceptable: a reset is sent, <SEQ=SEG.ACK>
///   <CTL=RST>, unless the segment is itself a reset, which is dropped. If
///   SND.UNA < SEG.ACK =< SND.NXT, the ACK is acceptable.
/// - **Second, the RST bit.** With an acceptable ACK, the connection is
///   refused ("error: connection reset") and closed; with no ACK, the
///   segment is dropped.
/// - **Third, the security**: not applicable; there are no compartments.
/// - **Fourth, the SYN bit.** With an acceptable ACK, the connection is
///   ESTABLISHED and our ACK is sent; with no ACK, the RFC enters
///   SYN-RECEIVED (a simultaneous open).
/// - **Fifth**, neither SYN nor RST: the segment is dropped.
/// DEPARTS: a simultaneous open (a SYN with no ACK) is dropped and counted
/// (`simultaneous_opens_refused`), with no reset, where the RFC answers it
/// with a SYN-ACK and enters SYN-RECEIVED.
/// DEPARTS: text or a FIN on the SYN-ACK is not taken, where the RFC queues
/// it; the peer sends it again, since our ACK does not cover it.
pub const SynSent = enum { reset_it, drop, refused, established, simultaneous_open };

pub fn synSent(c: *const Conn, seg: tcp.Segment) SynSent {
    // First, the ACK bit: acceptable when SND.UNA < SEG.ACK =< SND.NXT.
    const acceptable: ?bool = if (!seg.ctl.ack) null else sq.after(seg.ack, c.una) and sq.atOrAfter(c.highest(), seg.ack);
    if (acceptable == false) return if (seg.ctl.rst) .drop else .reset_it;
    // Second, the RST bit.
    if (seg.ctl.rst) return if (acceptable == true) .refused else .drop;
    // Third, the security: not applicable.
    // Fourth, the SYN bit.
    if (seg.ctl.syn) {
        if (acceptable == true) return .established;
        return .simultaneous_open;
    }
    // Fifth, neither SYN nor RST.
    return .drop;
}
