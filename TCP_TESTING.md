# Finding bugs in the TCP table systematically

`src/tcp.zig` is pure: frames go in through `handle`, come out through a
`wire`, and time is a number the caller passes. That is the property that
makes everything below cheap. A test can own the clock, the network and the
peer, and replay any run exactly. The tests in `src/tcp_test.zig` already
use it, one hand-written scenario at a time. This note is about getting more
out of the same seam: checking properties over many generated runs, instead
of asserting outcomes in scenarios someone thought to write.

The bugs found by reading in October 2026 are the yardstick. Each strategy
below says which of them it would have caught:

- **A. The blocking close.** `close()` waited in the one-request loop for a
  FIN acknowledgement from a peer already known to be silent.
- **B. The early drain stop.** `pump` stopped reading the ring early, so
  timers ran with acknowledgements still unread.
- **C. The unrepeated window update.** A reopened window was announced once
  and never again, so a lost announcement left the peer waiting on its own
  persist timer.

All three are **liveness** bugs: nothing wrong was ever said on the wire, but
something owed was not done in time. Scenario tests rarely catch liveness
bugs, because a scenario stops when the author's expected outcome is reached.
The strategies below are ordered by value per effort.

## 1. Invariants checked after every step

**Implemented** in `src/tcp_check.zig`. `check(table, now, phase)` names
the first rule any slot breaks. Every test in `src/tcp_test.zig` drives the
table through `handle` and `transmit` wrappers that call it after each step,
so every existing test is an invariant test for free. A broken rule stops
the run with the rule, the connection and the time. Generated runs (§3, §4)
should reuse it. The code is the authoritative list; what follows is the
reasoning behind it.

`check` is told **when** it is looking. Some debts belong to the next
`transmit`, such as bytes just queued or a window just reopened. After
`handle` it is enough that they are owed to it. After `transmit` it is not:
that turn has run, and every deadline left must be in the future.

**Safety invariants**, per connection that is not `closed`:

- `start <= end <= rx.len` and `tx_start <= tx_end <= tx.len`
- `sent <= high <= queued()`, so what is in flight is at most the queue
  plus a SYN and a FIN
- `state == .syn_received` implies `queued() == 0` and `fin == .none`
- `fin != .none` implies `state == .closing`
- `fin == .acknowledged` implies `queued() == 0`
- `told_wnd` equals the window in the last segment the wire recorded for
  this connection (the recorder can check this)

**The liveness invariant** is the one that turns "are we waiting for stuff?"
from a question into an assertion:

> Every connection that is not `closed` either has an armed deadline, or is
> in a state where the host is the one who acts next, and the host has a
> deadline of its own.

Concretely, for a non-closed connection at least one of these must hold:

| the connection owes...                       | so this must be armed               |
|----------------------------------------------|-------------------------------------|
| bytes or a FIN in flight (`highest() != una`)| `rto_at`                            |
| queued bytes with a shut window              | `rto_at` (the probe)                |
| a handshake (`syn_received`)                 | `rto_at`                            |
| our FIN acknowledged, the peer's not yet come| `fin_wait_until`                    |
| a reopened window, said once (`window_news == .said_once`) | the next `transmit`, which times its repeat |
| a reopened window, said and not yet heard (`.repeating`)  | `update_at`                          |
| nothing (established, idle)                  | the host's `quiet()` (outside the table) |

Write the table as code. A row with no armed deadline is a failure, and the
message names the row. Bug C would have failed this check the first time a
test consumed a full buffer, because nothing in the table said "a window
update is owed". The row did not exist, and writing the table is what makes
someone notice the missing row.

**A debt needs a state of its own, or it cannot have a row.** The first
version of this table missed a mutant. It deleted the line in `announce`
that armed `update_at`, and no invariant fired. A reopened window was then
tracked by a `reopened` flag that `announce` cleared as it armed the timer.
Once the flag was clear, "said and not yet heard" was not a state the
checker could see, so nothing owed the timer. The fix was to make the debt
an enum, `window_news: none → said_once → repeating`, with a row for each
stage. The general rule: if a connection can owe something, some field must
say so for as long as it is owed. A timer is not that field, because a timer
nobody armed looks the same as a debt nobody has.

**Every deadline must also be in the future, or due now.** A deadline that
has passed without `transmit` acting on it is a timer that never fires.
After each `transmit(now)`, assert that no armed deadline is `<= now` unless
the matching action just happened.

## 2. Every queue has a drain: an audit, kept in the code

The systematic form of "find every place where work is queued but nothing
guarantees it happens soon" is a list. Every buffer, ring or flag that
holds work gets an entry with three answers:

| queue                                  | drained by            | what guarantees the drainer runs, and how soon        |
|----------------------------------------|-----------------------|--------------------------------------------------------|
| the machine itself, halted             | `interrupts.rest`     | the card's MSI-X interrupt, or the APIC timer at most `slice_ns` (1 ms) after the halt; a card on mmio cannot interrupt, so there nothing halts and every wait spins |
| NIC receive ring                       | `stream.pump`         | every loop turn, every read and write wait; while idle, every wake (≤ 1 ms) |
| a frame handed to the card (`Net.send`)| the device            | `send` rests until the card takes it: on a droplet the device's thread needs this processor, which the halt gives back |
| every table and stream timer           | `transmit`, `serviceStreams` | as often as `pump` runs: at least every `slice_ns` while idle, **not at all during a request that does not pump** (long disk work) |
| a connection's send queue (`tx`)       | `Table.transmit`      | every `pump`; bounded by `rto_at` / `max_retries`      |
| our FIN (`fin == .queued`)             | `transmitOne`         | after the last queued byte; same timers                |
| a reopened window                      | `announce`            | every `transmit`; `update_at`, at most `max_retries`   |
| a connection's received bytes (`rx`)   | the host's handler    | `nextReady` / `quiet()` with `idle_ns`                 |
| a ready connection                     | the main loop         | **one request at a time: only if nothing blocks**      |
| a held stream's `carry` and mailbox    | `serviceStreams`      | every `pump`, via `after_arrivals`                     |
| a closing connection                   | the table's timers    | `rto_at`, `fin_wait_ns`                                |

**Interrupts change the question.** Before them, "the drainer runs soon"
meant "the loop spins". Now the loop halts between turns, and it means "the
machine wakes". The 1 ms APIC timer is the floor under every deadline row:
`rest` arms it before every `hlt`, and the interrupt handlers do nothing
but end the interrupt, so all work happens when the loop looks again. An
interrupt can delay work by at most `slice_ns`; it cannot lose work. Two
things would break that, and both belong on the audit:

- a halt with no timer armed (`rest` before `arm` falls back to `pause`, so
  this is about future code);
- a halt while work is already owed. The main loop rests only when nothing
  arrived and nothing was served, and every wait in `Stream` rests only
  after a `pump` that found nothing.

The "ready connection" row is where bug A lived. Its guarantee holds only if no single
step of the main loop waits unboundedly, so every call that can wait inside
the loop needs its own row in a second list: who it waits for, and what
bounds the wait. `Stream.finish` would have had the answer "a peer already
known to be silent, bounded by `idle_ns`", which is plainly wrong once it is
written down.

Keep the table next to the code it describes, in `stream.zig`'s or
`gopher.zig`'s header, and make adding a queue without adding a row a review
rule.

## 3. A simulated network, many seeds

**Implemented** in `src/tcp_sim.zig`, with seeds 1–8 run by `zig build
test`. A failing seed prints its whole scenario and the counters on both
sides. To soak, add seeds to `seeds`; a seed that fails and is fixed stays
there, as a regression test. Where it departs from the sketch below:

- **The clock ticks a millisecond at a time**, as the kernel's slowest
  turn does, rather than jumping from event to event. The cost is a few
  seconds per hundred seeds, and it is simpler to believe.
- **Loss happens only in the first three seconds.** After that the path is
  clean, so a run that does not finish within 60 s is a bug, not bad luck.
- **The client takes segments in order only.** Holding later ones is a MAY
  in RFC 9293, so a client that does not is still a correct client. It
  makes the table's go-back retransmission do all the recovering.
- **The host is a model of `gopher.zig`'s**, not the real loop:
  - it reads at its own pace, stalling for up to 8 s;
  - it announces a reopened window, or leaves that to the table, by the seed;
  - it lets go of a connection after `idle_ns` without progress;
  - it closes without waiting.

Put a deterministic, seeded network between the table and a model peer:

```
Table  <->  SimWire (seeded PRNG)  <->  ModelPeer
             - drop with probability p
             - duplicate
             - delay, which reorders
             - corrupt a byte (exercises `damaged`)
```

The driver keeps a virtual clock and a priority queue of events: frames in
flight, the peer's own timers, and the table's next deadline. It jumps
straight to the next event, so a run covering two simulated minutes takes
milliseconds. Each run:

1. The peer connects and sends a request of random size, in random segment
   sizes.
2. The "host" consumes at a random pace: sometimes not at all for a while,
   sometimes all at once, sometimes a byte at a time.
3. The host queues a response of random size and calls `finish`.
4. The peer reads at a random pace (its window shuts and reopens), then
   closes, or vanishes without a word, or resets.

**The oracles:**

- `check()` from §1 after every step.
- **Exactly once, in order.** The bytes the host consumed are exactly what
  the peer sent, and the bytes the peer delivered to its application are
  exactly what the host queued.
- **Eventual quiescence.** Within a bound derived from the constants (about
  `max_retries` backoffs plus `fin_wait_ns`), every connection reaches
  `closed` or idle with nothing owed. A run that is still busy past the bound
  is a liveness bug, and the seed reproduces it.
- **Progress while the path is good.** Once loss stops, the transfer
  completes within a few RTOs. This catches "it recovers, eventually, after
  a minute", which the quiescence bound alone would allow.

Run a few thousand seeds in `zig build test`, and millions in a separate
soak step. When a seed fails, it becomes a named regression test.

**The model peer is the work.** It must behave like a real one: delayed ACKs
(slirp's 200 ms, Linux's 40 ms), its own retransmission, a **persist timer
with backoff** (without one, bug C cannot appear), and RFC 5961 handling of
our resets. Keep it small and separate from `tcp.zig`, so that it does not
share the table's misreadings of the RFC. A peer that is "the table, turned
around" will agree with the table's bugs.

Bug C falls out of this: loss of the one window update, plus a persist timer
that has backed off, gives a run that exceeds the progress bound.

## 4. Small-scope exhaustive exploration

Random simulation finds what is likely. Bounded model checking finds what is
possible. Shrink everything: `rx` and `tx` of 4–8 bytes, an MSS of 1–2, and
a fixture ISN. Then enumerate **every** sequence of up to N events (N = 8 to
12 is often enough) from this alphabet:

- the peer sends its next segment / a duplicate / one from the past
- the network drops / delivers the oldest frame in flight
- time advances to the table's next deadline
- the host consumes k bytes / queues k bytes / calls `finish` / `abandon`

Check §1's invariants at every node. Prune states already seen (hash the
`Conn` fields that matter), and the search is cheap. The small-scope
hypothesis is that most protocol bugs have a small counterexample. One of 8
bytes and 10 events is also far easier to read than a million-frame soak
log.

This is the strategy most likely to find the bugs nobody thought to ask
about: odd combinations of a go-back after a timeout, a late window update,
and a FIN.

## 5. Fuzz `handle` with structure-aware segments

`zig build test --fuzz` drives a test function with mutated byte strings.
Do not hand it raw frames: nearly all of them would fail the checksum and
test only the checksum. Decode the fuzz input as a list of *choices*
(flags, a sequence-number offset from `rcv_nxt`, an acknowledgement offset
from `una`, a window, a payload length, a time step), and build valid,
checksummed frames from those. Bias the offsets toward the edges:

- `0`, `±1`, the edges of our advertised window
- `2^31` exactly, and wraparound past `2^32`
- an acknowledgement just past `highest()`

The oracle is §1's invariants, plus "no panic". ReleaseSafe integer
overflow, and an out-of-range slice such as the `recycle(id)` in the old
`Net.poll`, are panics, so the fuzzer finds them without being told what to
look for.

## 6. Run the whole suite at awkward initial sequence numbers

**Implemented** in `build.zig`. `zig build test` runs `src/tcp_test.zig`
once per (our ISN, the peer's first sequence number) pair:

- `2000/5000`, where the tests were written
- `0/0`
- both 16 bytes before half-way
- both 16 bytes before the wrap
- each side at a different edge

`Fixture.init` resets `fakeIsn`, so every test's first connection starts
exactly there. Tests compare sequence numbers only to each other, never to
a literal. What follows is why.

`fakeIsn` used to start at 1000. Wraparound bugs (a `<` where `after()` belongs, or
`-` where `-%` belongs) cannot show up there. Make the starting ISN a
parameter of the fixture, and run every existing test at least at:

- `0`
- `0x7FFF_FFF0` (just below the half-way point)
- `0xFFFF_FFF0` (16 bytes before the wrap)

Do the same for the *peer's* sequence numbers in `Peer`. This is almost
free, and it multiplies the value of every hand-written test.

## 7. A state × event matrix against RFC 9293

RFC 9293 §3.10.7 is a table in prose: for each state, what each kind of
segment does. Turn it into an actual table in a test, with one row per
(state, segment class) pair:

- **states:** `syn_received`, `established`, `closing` with each value of
  `fin`, and closed
- **segment classes:** SYN, a SYN with data, RST (exact, in-window,
  outside), ACK (old, duplicate, new, from the future), data (in order,
  ahead, behind, past the window), FIN (with and without data)

Each cell says what must be sent and what the state becomes. Generate the
tests from the table. The value is less in the tests than in the empty
cells: a cell nobody can fill in is a question about the design, asked
before a peer asks it.

**Implemented** as `matrix_rows` in `src/tcp_test.zig`: 17 kinds of segment
× 7 states (no connection, SYN-RECEIVED, ESTABLISHED, FIN-WAIT-1 before and
after our FIN goes, FIN-WAIT-2, CLOSE-WAIT), each cell run on a fresh table.
It runs at every starting sequence number of §6, with §1's invariants
checked at every step. A null cell is one of the questions below. It stays
null, and untested, until the question has an answer; then the answer goes
in the cell.

Two cells are filled in with a decision rather than the RFC's letter, and
are recorded here so they are not mistaken for accidents:

- **A SYN repeated during the handshake gets the SYN-ACK again.** RFC
  9293's first check would answer it with a bare ACK, which is no use to a
  client whose copy of our SYN-ACK was lost. Linux does the same.
- **The peer's FIN in FIN-WAIT-2 closes the connection at once.** There is
  no TIME-WAIT, as `tcp.zig`'s header says. A FIN repeated after that is
  answered with a reset.

### The open questions

1. **A SYN inside the window during the handshake** (`syn_in_window` and
   `syn_with_data` × `syn_received`). The table repeats its SYN-ACK. RFC
   9293 §3.10.7.4 says a connection opened passively goes back to LISTEN:
   here, forget it and free the slot. Repeating is harmless to a confused
   peer. Freeing is what the RFC asks, and is cheaper under a SYN flood.
   Which?
2. **An acknowledgement of something never sent, on a synchronized
   connection** (`ack_future` × every state from ESTABLISHED on).
   - **What the table does:** ignores the acknowledgement silently. If the
     segment carries data, it still takes the data.
   - **What the RFCs say:** RFC 9293 says send an ACK and drop the segment.
     RFC 5961 §5 says drop it, so that a blind attacker who guessed the
     sequence number but not the acknowledgement cannot inject data.
   - Taking the data is the part that matters. Should the segment be
     dropped, and should the drop be answered with an ACK?
3. **Data ahead of RCV.NXT during the handshake** (`data_ahead` ×
   `syn_received`). The table acknowledges it and stays in SYN-RECEIVED,
   without looking at its acknowledgement. The RFC takes the acknowledgement
   first, which completes the handshake, and only then deals with the text.
   Today the handshake completes only on the peer's next in-order segment.
   Should an acceptable out-of-order segment complete it?
4. **Data that straddles RCV.NXT** (`data_straddling` × the states that
   take data). The table drops the whole segment and acknowledges, because
   it takes in-order segments only. The RFC trims the old part and takes
   the rest. The peer recovers by sending again from our acknowledgement,
   so nothing is lost but a round trip. Worth trimming?
5. **Outside the matrix, for the same reason:**
   - A segment with neither SYN, ACK nor RST, for a peer the table does not
     know, is answered with RST|ACK. RFC 9293 says LISTEN drops it
     silently.
   - A segment to any port other than ours is ignored without a reset,
     where a CLOSED port would send one. Both look intentional for a
     single-port server; neither is written down as such.

## 8. Differential testing against Linux, made adversarial

`native/serve.zig` and `native/judge_native.py` already run the table with
Linux's TCP as the peer, and `netem` already drops frames. Extend the
same harness:

- **netem's other knobs:** `reorder`, `duplicate`, `corrupt`, `delay` with
  jitter, and `rate`, which makes a path slow enough that windows actually
  shut.
- **Scapy instead of sockets** for the hostile cases a polite Linux client
  never produces: a final ACK that never comes (a half-open connection), an
  RST at every offset, overlapping retransmissions with different bytes,
  and a peer that advertises a zero window forever.
- **Capture both sides with `tcpdump`** and run the trace through a checker,
  such as Wireshark's TCP analysis (`tshark -z expert`), which flags
  retransmissions, zero windows, window updates and out-of-order segments
  without being told what we expected.

This is the only strategy that tests against a peer we did not write, so it
is the only one that catches a bug the model peer (§3) shares with the
table.

## 9. Host-loop latency as a measured invariant

Bugs A and B were not in `tcp.zig` at all. They were in the loop that drives
it. The table cannot be correct if its `transmit` is not called, so measure
whether it is:

- **The longest gap between two `pump` calls**, kept by `pump` itself and
  printed on the closing stats line.
- **The longest time a ready connection waited** for `nextReady` to pick it,
  beyond the serve time of the requests ahead of it.
- **Frames still waiting in the ring when `transmit` ran**: `pump` can count
  them by polling once more after its drain. Under §2's audit this must be
  zero, and bug B would have shown up as non-zero.

Then make the judge assert bounds on these numbers, as it already does for
the heaps. A gate with a silent client, a half-open client and a vanished
client would have shown bug A as a ready request waiting ten seconds, with
the longest-wait number pointing straight at it.

## 10. Check that the tests can fail: mutation testing

Every strategy above is only as good as its oracles. The check is to break
the code on purpose and see whether anything notices. Delete `c.heard()`,
swap `>=` for `>` in `transmitOne`'s expiry test, drop the `if (c.rto_at ==
null)` re-arm in the probe path, change `-%` to `-` in `after()`. Each
mutant that survives names a property no test checks. Done by hand with a
small script that applies each mutant, runs `zig build test`, and puts the
file back with `git checkout <rev> -- <file>`, a dozen mutants is an
afternoon. (`git checkout` names exactly the file and revision restored,
where `git stash` would also sweep up any unrelated work in progress.)

## Suggested order

1. §1 invariants, including the liveness table, wired into the existing
   fixture. **Done:** `src/tcp_check.zig`.
2. §6 awkward ISNs. **Done:** `build.zig`.
3. §2 the queue audit, written into the code headers.
4. §9 the loop-latency numbers and their judge bounds.
5. §3 the simulator and model peer: the biggest investment, and the biggest
   payoff.
6. §4, §5, §7, §8 and §10 as the simulator matures.
