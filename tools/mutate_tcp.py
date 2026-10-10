#!/usr/bin/env python3
"""Breaks src/tcp.zig one way at a time and reports every break that
`zig build test` does not notice (TCP_TESTING.md §10).

    tools/mutate_tcp.py                 every mutant
    tools/mutate_tcp.py NAME...         just these
    tools/mutate_tcp.py --list          their names and what each breaks

The oracle is `zig build test`. That runs:

  - tcp_test at every starting sequence number of §6, including the state ×
    event matrix of §7;
  - tcp_check's own tests, and its invariants after every step of every
    scenario (§1);
  - tcp_sim's seeds (§3).

A mutant is **killed** when that fails, and it **survives** when that
passes: then the change it made is a property nothing checks. A mutant that
does not compile says nothing about the tests and is reported apart. So is
one whose text is no longer in tcp.zig, which means the list here has
fallen behind the code.

Each mutant is applied to the committed tcp.zig, and the file is put back
with `git checkout <rev> -- src/tcp.zig` after every one, interrupted or
not. It refuses to start if tcp.zig has uncommitted changes, which it would
otherwise throw away.

Host only. Each mutant takes one `zig build test`: about half a minute, so
the whole list takes a quarter of an hour.

Exit 0 when every mutant is killed, 1 when any survives or is out of date,
2 on a usage error.
"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TARGET = "src/tcp.zig"
TIMEOUT_S = 600

# (name, what it breaks, the text, its replacement, which occurrence when the
# text is not unique). Each is one plausible bug: a comparison off by one, a
# timer not armed, a rule skipped, a reset forgotten.
MUTANTS = [
    # ── the send side's timers ─────────────────────────────────────────────
    ("expiry-strict", "a timer fires only after its deadline, not at it",
     "const expired = if (c.rto_at) |at| now >= at else false;",
     "const expired = if (c.rto_at) |at| now > at else false;", None),
    ("probe-timer-unarmed", "a shut window with bytes queued arms no probe timer",
     "                if (probe == .none) {\n                    if (c.rto_at == null) c.rto_at = now + c.rto_ns;\n",
     "                if (probe == .none) {\n", None),
    ("data-timer-unarmed", "bytes sent arm no retransmission timer",
     "            c.high = @max(c.high, c.sent);\n            if (c.rto_at == null) c.rto_at = now + c.rto_ns;\n",
     "            c.high = @max(c.high, c.sent);\n", None),
    ("fin-timer-unarmed", "our FIN sent arms no retransmission timer",
     "            c.fin.fire(.fin_emitted);\n            if (c.rto_at == null) c.rto_at = now + c.rto_ns;\n",
     "            c.fin.fire(.fin_emitted);\n", None),
    ("synack-timer-unarmed", "a SYN-ACK arms no retransmission timer",
     "            c.heard_at = now;\n            c.rto_at = now + c.rto_ns;\n            self.arrivals += 1;",
     "            c.heard_at = now;\n            self.arrivals += 1;", None),
    ("handshake-timer-kept", "completing the handshake leaves the SYN-ACK's timer armed",
     "            c.wl2 = number;\n            c.rto_at = null;\n            c.retries = 0;",
     "            c.wl2 = number;\n            c.retries = 0;", None),
    ("ack-clears-timer", "an acknowledgement disarms the timer even with bytes still in flight",
     "c.rto_at = if (c.highest() != c.una) now + c.rto_ns else null;",
     "c.rto_at = null;", None),
    ("resend-no-timer", "a fast retransmit does not restart the timer",
     "        c.timed_at = null; // Karn, the same as after a timeout\n        c.rto_at = now + c.rto_ns;\n",
     "        c.timed_at = null; // Karn, the same as after a timeout\n", None),

    # ── going back, and Karn ───────────────────────────────────────────────
    ("go-back-no-rewind", "a timeout sends again from where it was, not from una",
     "            c.sent = 0;\n            if (c.fin.is(.sent)) c.fin.fire(.timed_out);\n            c.timed_at = null; // Karn: no telling",
     "            if (c.fin.is(.sent)) c.fin.fire(.timed_out);\n            c.timed_at = null; // Karn: no telling", None),
    ("go-back-keeps-fin", "a timeout does not send our FIN again",
     "            c.sent = 0;\n            if (c.fin.is(.sent)) c.fin.fire(.timed_out);\n            c.timed_at = null; // Karn: no telling",
     "            c.sent = 0;\n            c.timed_at = null; // Karn: no telling", None),
    ("karn-off", "a timeout keeps timing a segment it is about to send again",
     "            c.timed_at = null; // Karn: no telling which copy is answered\n",
     "", None),
    ("never-probe", "a shut window is never probed",
     # Always true, but not known at compile time: `true` would leave the code
     # after the break unreachable, which Zig refuses to compile.
     "                if (probe == .none) {", "                if (probe == .none or c.state != .closed) {", None),

    # ── the clock ──────────────────────────────────────────────────────────
    ("rto-small-variance", "the timeout leaves out the variation's factor of four",
     "c.srtt_ns + 4 * c.rttvar_ns", "c.srtt_ns + c.rttvar_ns", None),
    ("rto-no-floor", "the timeout has no 200 ms floor",
     "c.rto_ns = @min(@max(c.srtt_ns + 4 * c.rttvar_ns, min_rto_ns), max_rto_ns);",
     "c.rto_ns = @min(c.srtt_ns + 4 * c.rttvar_ns, max_rto_ns);", None),
    ("no-backoff", "a timeout does not double the next wait",
     "c.rto_ns = @min(c.rto_ns * 2, max_rto_ns);", "c.rto_ns = @min(c.rto_ns, max_rto_ns);", None),
    ("retries-one-more", "one more timeout before giving up than max_retries",
     "if (c.retries >= max_retries) return false;", "if (c.retries > max_retries) return false;", None),
    ("sample-too-early", "an acknowledgement one byte short of the timed segment is taken as its sample",
     "if (!sq.atOrAfter(number, c.timed_seq)) return; // not there yet",
     "if (!sq.atOrAfter(number, c.timed_seq -% 1)) return; // not there yet", None),

    # ── acknowledgements and the window ────────────────────────────────────
    ("ack-past-flight", "an acknowledgement one past anything sent is taken",
     "if (advance > flight) return false;", "if (advance > flight + 1) return false;", None),
    ("window-rule-off", "an older segment's window overrules a newer one's",
     "const updated = sq.after(seq, c.wl1) or (seq == c.wl1 and !sq.after(c.wl2, number));",
     "const updated = true;", None),
    ("window-edge-drifts", "the right edge moves with una when the window was not updated",
     "        if (!updated) c.wnd -= @min(c.wnd, advance);\n", "", None),
    ("fin-acked-early", "acknowledging every byte is taken as acknowledging our FIN too",
     "if (advance > bytes) {", "if (advance >= bytes) {", None),
    ("fast-retransmit-off", "three duplicate acknowledgements send nothing again",
     "if (c.dupacks == dupacks_before_resend and c.duplicates == .counting)", "if (false)", None),
    ("dupacks-kept", "new data acknowledged does not reset the duplicate count",
     "                c.dupacks = 0;\n                c.duplicates = .counting;\n",
     "                c.duplicates = .counting;\n", None),
    ("dupacks-one", "one duplicate acknowledgement sends everything again",
     "pub const dupacks_before_resend: u8 = 3;", "pub const dupacks_before_resend: u8 = 1;", None),

    # ── the receive side ───────────────────────────────────────────────────
    ("rst-in-window", "a reset anywhere in the window resets, not only at RCV.NXT",
     "if (seq == c.rcv_nxt) return self.close(i);",
     "if (seq == c.rcv_nxt or c.ahead(seq)) return self.close(i);", None),
    ("no-challenge-ack", "a reset in the window is ignored rather than challenged",
     "            if (c.ahead(seq)) self.emit(wire, i, flag_ack, c.highest(), \"\");\n", "", None),
    ("window-edge-inclusive", "a segment at the window's right edge counts as ahead",
     "return seq != self.rcv_nxt and sq.within(seq, self.rcv_nxt, @max(self.window(), 1));",
     "return seq != self.rcv_nxt and sq.within(seq, self.rcv_nxt, @as(u32, @max(self.window(), 1)) + 1);", None),
    ("everything-behind", "a segment past the window is taken as one from behind",
     "const behind = !sq.after(seq, c.rcv_nxt);", "const behind = true;", None),
    ("handshake-any-ack", "the handshake completes on any acknowledgement number",
     "if (number != c.una +% 1) {", "if (false) {", None),
    ("peer-fin-forgotten", "the peer's FIN is acknowledged but not recorded",
     "            c.peer_done = true;\n", "", None),
    ("fin-wait-unbounded", "our FIN acknowledged starts no wait for the peer's",
     # `now` is then unused, which Zig refuses; `_ = now;` keeps it compiling.
     "        c.fin_wait_until = now + fin_wait_ns;\n", "        _ = now;\n", None),
    ("fin-wait-strict", "the wait for the peer's FIN ends after its deadline, not at it",
     "if (c.fin_wait_until) |until| if (now >= until) {",
     "if (c.fin_wait_until) |until| if (now > until) {", None),

    # ── the window we offer ────────────────────────────────────────────────
    ("never-compact", "consumed bytes at the front are never reclaimed until the buffer empties",
     "} else if (self.start > self.rx.len / 2) {", "} else if (false) {", None),
    ("never-announce", "a reopened window the reader did not announce is never announced",
     "if (c.tight(c.told_wnd) and !c.tight(c.window())) {", "if (false) {", None),
    ("never-repeat", "a reopened window is said once and never repeated",
     # Inside the .repeating arm, so always true at run time.
     "if (c.updates >= max_retries) {", "if (c.window_news == .repeating) {", None),
    ("data-not-heard", "data from the peer does not settle the window debt",
     "            if (n > 0) c.heard();\n", "", None),
    ("news-for-done-peer", "a window is owed to a peer that has sent its FIN",
     "if (c.tight(w) or c.peer_done) {", "if (c.tight(w)) {", None),

    # ── slots ──────────────────────────────────────────────────────────────
    ("claimed-slot-reused", "a slot the host still holds is handed to a new connection",
     "if (c.state == .closed and !c.claimed) return i;", "if (c.state == .closed) return i;", None),
]


def git(*args, check=True):
    return subprocess.run(["git", *args], cwd=ROOT, check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def apply(source, old, new, nth):
    count = source.count(old)
    if count == 0 or (nth is None and count != 1) or (nth is not None and nth >= count):
        return None
    if nth is None:
        return source.replace(old, new, 1)
    at = -1
    for _ in range(nth + 1):
        at = source.index(old, at + 1)
    return source[:at] + new + source[at + len(old):]


def run_tests():
    """(outcome, seconds, tail of the output)."""
    began = time.time()
    try:
        p = subprocess.run(["zig", "build", "test"], cwd=ROOT, text=True, timeout=TIMEOUT_S,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except subprocess.TimeoutExpired:
        return "killed (timeout)", time.time() - began, ""
    out = p.stdout
    took = time.time() - began
    if p.returncode == 0:
        return "SURVIVED", took, out
    # A compile error is reported against a line of the mutated file.
    if re.search(rf"{re.escape(TARGET)}:\d+:\d+: error:", out):
        return "did not compile", took, out
    return "killed", took, out


def main(argv):
    if "--list" in argv:
        for name, what, *_ in MUTANTS:
            print(f"{name:24} {what}")
        return 0
    wanted = [a for a in argv[1:] if not a.startswith("-")]
    names = {m[0] for m in MUTANTS}
    unknown = [w for w in wanted if w not in names]
    if unknown:
        print(f"no such mutant: {', '.join(unknown)} (see --list)", file=sys.stderr)
        return 2
    if git("status", "--porcelain", "--", TARGET).strip():
        print(f"{TARGET} has uncommitted changes; commit or stash them first: this restores it from git",
              file=sys.stderr)
        return 2

    rev = git("rev-parse", "HEAD").strip()
    path = os.path.join(ROOT, TARGET)
    with open(path) as f:
        source = f.read()

    print(f"tcp.zig at {rev[:10]}: checking the unmutated tree first")
    outcome, took, out = run_tests()
    if outcome != "SURVIVED":
        print(f"zig build test fails before any mutation ({outcome}); nothing to judge:\n{out[-2000:]}")
        return 2
    print(f"  green in {took:.0f} s\n")

    results = []
    try:
        for name, what, old, new, nth in MUTANTS:
            if wanted and name not in wanted:
                continue
            mutated = apply(source, old, new, nth)
            if mutated is None:
                results.append((name, "out of date", what))
                print(f"  {name:24} out of date: its text is not in tcp.zig (once)")
                continue
            with open(path, "w") as f:
                f.write(mutated)
            try:
                outcome, took, out = run_tests()
            finally:
                git("checkout", rev, "--", TARGET)
            results.append((name, outcome, what))
            print(f"  {name:24} {outcome:18} {took:5.0f} s  {what}")
            if outcome == "did not compile":
                for line in out.splitlines():
                    if "error:" in line:
                        print(f"      {line.strip()}")
                        break
    finally:
        git("checkout", rev, "--", TARGET)

    survived = [r for r in results if r[1] == "SURVIVED"]
    stale = [r for r in results if r[1] == "out of date"]
    broken = [r for r in results if r[1] == "did not compile"]
    killed = [r for r in results if r[1].startswith("killed")]
    print(f"\n{len(killed)} killed, {len(survived)} survived, {len(broken)} did not compile, "
          f"{len(stale)} out of date, of {len(results)}")
    for name, _, what in survived:
        print(f"  SURVIVED {name}: {what}. No test checks this.")
    return 1 if survived or stale else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
