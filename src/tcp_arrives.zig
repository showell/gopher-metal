//! **SEGMENT ARRIVES** (RFC 9293 §3.10.7): what an arriving segment means
//! for a connection, decided purely, with no I/O and no clock. `Table`
//! (tcp.zig) acts on each answer; each has a table-driven test
//! (tcp_test.zig). Moved here from tcp.zig, unchanged (metal-vmm QUEUE 225,
//! chunks 2 and 3a).
//!
//! **THE RFC'S WORDS ARE QUOTED** (chunk 3b), on lines that begin `> `,
//! copied from `docs/rfc/rfc9293.txt` word for word (tcp_test.zig holds
//! every quote to that file): each decision's step first, then the code
//! that does it. A `DEPARTS:` line names each place the code does
//! otherwise.

const tcp = @import("tcp.zig");
const Conn = tcp.Conn;
/// Sequence numbers modulo 2^32 (seq.zig).
const sq = @import("seq.zig").Seq(u32);

/// **IS THE SEGMENT ACCEPTABLE?** (RFC 9293 §3.10.7.4, "First, check
/// sequence number"):
///
/// > o  Segments are processed in sequence.  Initial tests on
/// >    arrival are used to discard old duplicates, but further
/// >    processing is done in SEG.SEQ order.  If a segment's
/// >    contents straddle the boundary between old and new, only the
/// >    new parts are processed.
///
/// > o  There are four cases for the acceptability test for an
/// >    incoming segment:
/// >
/// >    +=========+=========+======================================+
/// >    | Segment | Receive | Test                                 |
/// >    | Length  | Window  |                                      |
/// >    +=========+=========+======================================+
/// >    | 0       | 0       | SEG.SEQ = RCV.NXT                    |
/// >    +---------+---------+--------------------------------------+
/// >    | 0       | >0      | RCV.NXT =< SEG.SEQ <                 |
/// >    |         |         | RCV.NXT+RCV.WND                      |
/// >    +---------+---------+--------------------------------------+
/// >    | >0      | 0       | not acceptable                       |
/// >    +---------+---------+--------------------------------------+
/// >    | >0      | >0      | RCV.NXT =< SEG.SEQ <                 |
/// >    |         |         | RCV.NXT+RCV.WND                      |
/// >    |         |         |                                      |
/// >    |         |         | or                                   |
/// >    |         |         |                                      |
/// >    |         |         | RCV.NXT =< SEG.SEQ+SEG.LEN-1         |
/// >    |         |         | < RCV.NXT+RCV.WND                    |
/// >    +---------+---------+--------------------------------------+
/// >
/// >                Table 6: Segment Acceptability Tests
///
/// > o  In the following it is assumed that the segment is the
/// >    idealized segment that begins at RCV.NXT and does not exceed
/// >    the window.  One could tailor actual segments to fit this
/// >    assumption by trimming off any portions that lie outside the
/// >    window (including SYN and FIN) and only processing further
/// >    if the segment then begins at RCV.NXT.  Segments with higher
/// >    beginning sequence numbers SHOULD be held for later
/// >    processing (SHLD-31).
///
/// Here, by its first sequence number only:
/// - `next`: it is RCV.NXT, the byte expected, and is taken;
/// - `ahead`: past RCV.NXT inside the window we advertise: acceptable, its
///   ACK and window count, and its bytes are held until the hole before
///   them fills (`Table.holdAhead`);
/// - `behind`: at or before RCV.NXT, a resend of what was taken;
/// - `beyond`: past the window, or half the circle away.
/// DEPARTS: the RFC also accepts a segment that starts behind and runs past
/// RCV.NXT, and trims it; here it is `behind`, and the peer resends. A
/// segment `ahead` is held for later (SHLD-31; tcp_held.zig, metal-vmm
/// QUEUE 226).
pub const Acceptability = enum { next, ahead, behind, beyond };

pub fn acceptability(c: *const Conn, seq: u32) Acceptability {
    if (seq == c.rcv_nxt) return .next;
    if (c.ahead(seq)) return .ahead;
    return if (sq.atOrAfter(c.rcv_nxt, seq)) .behind else .beyond;
}

/// **A RESET MUST NAME RCV.NXT EXACTLY** (RFC 9293 §3.10.7.4, "Second,
/// check the RST bit", the RFC 5961 checks this table implements):
///
/// > 1)  If the RST bit is set and the sequence number is outside
/// >     the current receive window, silently drop the segment.
/// >
/// > 2)  If the RST bit is set and the sequence number exactly
/// >     matches the next expected sequence number (RCV.NXT), then
/// >     TCP endpoints MUST reset the connection in the manner
/// >     prescribed below according to the connection state.
/// >
/// > 3)  If the RST bit is set and the sequence number does not
/// >     exactly match the next expected sequence value, yet is
/// >     within the current receive window, TCP endpoints MUST send
/// >     an acknowledgment (challenge ACK):
/// >
/// >     <SEQ=SND.NXT><ACK=RCV.NXT><CTL=ACK>
/// >
/// >     After sending the challenge ACK, TCP endpoints MUST drop
/// >     the unacceptable segment and stop processing the incoming
/// >     packet further.  Note that RFC 5961 and Errata ID 4772 [99]
/// >     contain additional considerations for ACK throttling in an
/// >     implementation.
///
/// `exact` is 2), which closes the connection; `challenge` is 3), which a
/// genuine peer answers with an exact reset; `ignore` is 1).
pub const ResetCheck = enum { exact, challenge, ignore };

pub fn resetCheck(c: *const Conn, seq: u32) ResetCheck {
    if (seq == c.rcv_nxt) return .exact;
    if (c.ahead(seq)) return .challenge;
    return .ignore;
}

/// **THE ACK FIELD** (RFC 9293 §3.10.7.4, "Fifth, check the ACK field"):
///
/// > o  SYN-RECEIVED STATE
/// >
/// >    +  If SND.UNA < SEG.ACK =< SND.NXT, then enter ESTABLISHED
/// >       state and continue processing with the variables below
/// >       set to:
/// >
/// >          SND.WND <- SEG.WND
/// >
/// >          SND.WL1 <- SEG.SEQ
/// >
/// >          SND.WL2 <- SEG.ACK
/// >
/// >    +  If the segment acknowledgment is not acceptable, form a
/// >       reset segment
/// >
/// >          <SEQ=SEG.ACK><CTL=RST>
/// >
/// >    +  and send it.
///
/// > o  ESTABLISHED STATE
/// >
/// >    +  If SND.UNA < SEG.ACK =< SND.NXT, then set SND.UNA <-
/// >       SEG.ACK.  Any segments on the retransmission queue that
/// >       are thereby entirely acknowledged are removed.  Users
/// >       should receive positive acknowledgments for buffers that
/// >       have been SENT and fully acknowledged (i.e., SEND buffer
/// >       should be returned with "ok" response).  If the ACK is a
/// >       duplicate (SEG.ACK =< SND.UNA), it can be ignored.  If
/// >       the ACK acks something not yet sent (SEG.ACK > SND.NXT),
/// >       then send an ACK, drop the segment, and return.
///
/// So:
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
/// (`highest`). The steps are the RFC's, in its order, each quoted in the
/// body before the code that does it.
/// DEPARTS: a simultaneous open (a SYN with no ACK) is dropped and counted
/// (`simultaneous_opens_refused`), with no reset, where the RFC answers it
/// with a SYN-ACK and enters SYN-RECEIVED.
/// DEPARTS: text or a FIN on the SYN-ACK is not taken, where the RFC
/// continues processing it at §3.10.7.4's sixth step; the peer sends it
/// again, since our ACK does not cover it.
pub const SynSent = enum { reset_it, drop, refused, established, simultaneous_open };

pub fn synSent(c: *const Conn, seg: tcp.Segment) SynSent {
    // > First, check the ACK bit:
    // >
    // > -  If the ACK bit is set,
    // >
    // >    o  If SEG.ACK =< ISS or SEG.ACK > SND.NXT, send a reset (unless
    // >       the RST bit is set, if so drop the segment and return)
    // >
    // >          <SEQ=SEG.ACK><CTL=RST>
    // >
    // >    o  and discard the segment.  Return.
    // >
    // >    o  If SND.UNA < SEG.ACK =< SND.NXT, then the ACK is acceptable.
    // >       Some deployed TCP code has used the check SEG.ACK == SND.NXT
    // >       (using "==" rather than "=<"), but this is not appropriate
    // >       when the stack is capable of sending data on the SYN because
    // >       the TCP peer may not accept and acknowledge all of the data
    // >       on the SYN.
    const acceptable: ?bool = if (!seg.ctl.ack) null else sq.after(seg.ack, c.una) and sq.atOrAfter(c.highest(), seg.ack);
    if (acceptable == false) return if (seg.ctl.rst) .drop else .reset_it;

    // > Second, check the RST bit:
    // >
    // > -  If the RST bit is set,
    // >
    // >    o  A potential blind reset attack is described in RFC 5961 [9].
    // >       The mitigation described in that document has specific
    // >       applicability explained therein, and is not a substitute for
    // >       cryptographic protection (e.g., IPsec or TCP-AO).  A TCP
    // >       implementation that supports the mitigation described in RFC
    // >       5961 SHOULD first check that the sequence number exactly
    // >       matches RCV.NXT prior to executing the action in the next
    // >       paragraph.
    // >
    // >    o  If the ACK was acceptable, then signal to the user "error:
    // >       connection reset", drop the segment, enter CLOSED state,
    // >       delete TCB, and return.  Otherwise (no ACK), drop the
    // >       segment and return.
    // A reset here is judged by its ACK, which only a peer that saw our SYN
    // can name; RCV.NXT is not yet set.
    if (seg.ctl.rst) return if (acceptable == true) .refused else .drop;

    // > Third, check the security:
    // >
    // > -  If the security/compartment in the segment does not exactly
    // >    match the security/compartment in the TCB, send a reset:
    // >
    // >    o  If there is an ACK,
    // >
    // >          <SEQ=SEG.ACK><CTL=RST>
    // >
    // >    o  Otherwise,
    // >
    // >          <SEQ=0><ACK=SEG.SEQ+SEG.LEN><CTL=RST,ACK>
    // >
    // > -  If a reset was sent, discard the segment and return.
    // Not applicable: there are no compartments.

    // > Fourth, check the SYN bit:
    // >
    // > -  This step should be reached only if the ACK is ok, or there is
    // >    no ACK, and the segment did not contain a RST.
    // >
    // > -  If the SYN bit is on and the security/compartment is
    // >    acceptable, then RCV.NXT is set to SEG.SEQ+1, IRS is set to
    // >    SEG.SEQ.  SND.UNA should be advanced to equal SEG.ACK (if there
    // >    is an ACK), and any segments on the retransmission queue that
    // >    are thereby acknowledged should be removed.
    // >
    // > -  If SND.UNA > ISS (our SYN has been ACKed), change the
    // >    connection state to ESTABLISHED, form an ACK segment
    // >
    // >       <SEQ=SND.NXT><ACK=RCV.NXT><CTL=ACK>
    // >
    // > -  and send it.  Data or controls that were queued for
    // >    transmission MAY be included.  Some TCP implementations
    // >    suppress sending this segment when the received segment
    // >    contains data that will anyways generate an acknowledgment in
    // >    the later processing steps, saving this extra acknowledgment of
    // >    the SYN from being sent.  If there are other controls or text
    // >    in the segment, then continue processing at the sixth step
    // >    under Section 3.10.7.4 where the URG bit is checked; otherwise,
    // >    return.
    // >
    // > -  Otherwise, enter SYN-RECEIVED, form a SYN,ACK segment
    // >
    // >       <SEQ=ISS><ACK=RCV.NXT><CTL=SYN,ACK>
    // >
    // > -  and send it.  Set the variables:
    // >
    // >       SND.WND <- SEG.WND
    // >
    // >       SND.WL1 <- SEG.SEQ
    // >
    // >       SND.WL2 <- SEG.ACK
    // >
    // >    If there are other controls or text in the segment, queue them
    // >    for processing after the ESTABLISHED state has been reached,
    // >    return.
    // `Table` sets RCV.NXT, SND.UNA, the window and SendMSS, and sends the
    // ACK (tcp.zig's `synSentArrives`).
    if (seg.ctl.syn) {
        if (acceptable == true) return .established;
        return .simultaneous_open;
    }

    // > Fifth, if neither of the SYN or RST bits is set, then drop the
    // > segment and return.
    return .drop;
}
