# Design: a kernel that sleeps until it is needed

metal-vmm QUEUE 228.1. **Status: design, round 1** (the box, 2026-10-17). No
code yet. The rounds with a cold reviewer are at the end.

## What it is for

The Observatory wakes every 60 s, fetches Dog Park's `/version`, writes a
line, and sleeps. Today no application can ask for that: a site's `between`
answers only "more" or "nothing", and the kernel's idle loop never halts
for longer than `interrupts.slice_ns` (1 ms), because that is how it notices
every timer it keeps. So an idle gopher.elf wakes about 1,250 times a
second, and a quiet minute under metal-vmm costs millions of exits.

**The goal, in Steve's words:** Linux and bare metal function the same; most
tests simulate time; a few measure real sleep in wall time; and "sleeping
60 ms is essentially the same problem as sleeping 60 seconds or 60 hours".

## The one idea: the loop asks "when is the next thing due?"

The kernel halts until **the earliest of every deadline it keeps**, or an
interrupt (a frame). Today that earliest deadline is approximated by "1 ms
from now, look again". The design replaces the approximation with the
answer:

    due = min( table.nextDue(),          // TCP: rto_at, update_at, closing timers
               streams.nextDue(),        // held streams' pings, body deadlines
               quiet.nextDue(),          // heard_at + idle_ns, for let-go
               drains.nextDue(),
               idle_work.nextDue(),      // last_busy + quiet_ns, a task's own next_at
               app.wake )                // what `between` asked for
    interrupts.restUntil(due)            // null: only an interrupt wakes it

**Every source is pure and says its own next deadline**, tested with a fake
clock as each is today. The minimum is pure too (`due.zig`), so the whole
decision "how long may the machine sleep" is a tier-0 function.

**The danger is a source left out.** A deadline nobody reports is served
late, by however long the machine sleeps: 1 ms today, 60 s tomorrow. That
is the class of bug this feature can plant, and most of the testing below
is aimed at it.

## The application's side: `between` returns a wake

    pub const Wake = union(enum) {
        /// More to do now: call again on the next free turn (today's `true`).
        more,
        /// Nothing until this time on the awake clock, unless a request
        /// comes first (a request may start new work: see below).
        at: i96,
        /// Nothing until a request (today's `false`).
        idle,
    };

- **The awake clock, not the wall clock**: a wall clock can be set or
  jump; the awake clock (`Io.awakeNs` on metal, `Io.Clock.awake` on Linux)
  only moves forward. The Observatory says `.{ .at = last_poll + 60 s }`.
- **No earlier than asked, as soon as possible after.** That is the whole
  promise, the same on both hosts. How late "as soon as possible" is, is
  measured, never promised to the millisecond.
- **A request always gets a `between` after it** (it does today on metal;
  on Linux see below): a request that starts work (a background Shale run)
  is never left waiting for an old wake.
- **Today's `bool` sites keep working** through a one-line adapter
  (`true` → `.more`, `false` → `.idle`) in webbox's `Site`, so chat and
  Dog Park change nothing until they want to.

## Metal

- **`interrupts.restUntil(due: ?i96)`**: writes the TSC deadline for `due`
  (or none: a halt only an interrupt ends), halts, notes the rest.
- **Ticks from nanoseconds, in u128.** `apic_rule.sliceTicks` multiplies
  in u64 today; 60 hours at 3 GHz is about 6.5e23 tick-nanoseconds, past
  u64. The conversion becomes `ticksOf(tsc_hz, ns)` in u128, saturating,
  with tests at 60 ms, 60 s, 60 h and the counter's wrap.
- **No cap on a rest, on purpose.** A cap (say 1 s) would make a missing
  source late by at most a second, which hides it; the design would
  rather find it (doctrine: eliminate, don't paper over). A rest that
  ended late, past its own deadline by more than a bound, is counted on
  /admin/host.
- **The console drains first**, as today: a rest never starts with lines
  waiting.

## Linux

The host's `betweenLoop` thread sleeps `between_idle_ms` (50 ms) when there
is nothing to do. That poll is the Linux twin of the 1 ms slice, and it
hides the same class of bug: a request that starts background work is
noticed within 50 ms, not because anything told the thread.

- **The thread sleeps until the wake** (or forever for `.idle`), on a
  timed wait that a handler can **kick**: every handler's end kicks it,
  which is the Linux form of metal's "a `between` after every request".
- The TCP stack is Linux's, so there are no other kernel sources.

## Testing, fast to slow

The aim: almost every test runs on simulated time and takes milliseconds;
a handful measure real sleep, each at most a few seconds.

1. **Pure, tier 0, milliseconds.**
   - Each source's `nextDue`: from state built by hand, the exact time.
   - `due.zig`: the minimum, nulls, the past (due already: rest 0).
   - `ticksOf`: 60 ms, 60 s, 60 h, saturation, the TSC's wrap.
   - The `Wake` adapter, and Linux's wait decision with a fake clock and a
     fake kick.
2. **"A sleeper does what a fidgeter does", in the simulators.** The
   strongest check that no source is missing. tcp_sim and the other
   simulators drive the table on simulated time; run each world twice,
   once stepping every 1 ms (today) and once jumping straight to
   `nextDue()`; the frames sent must be the same, in the same order, and
   none later in the jumping run. A deadline missing from `nextDue` shows
   up as a frame sent late or never. Plus one `tcp_check` invariant: **at
   every wake, nothing is overdue** by more than the step.
3. **metal-vmm, simulated time, seconds.** A halt is an event there: the
   clock jumps to the deadline, so a 60 s sleep costs one exit.
   - **Exits of an idle kernel, before and after** (QUEUE 228.1's
     measure): gopher.elf idle for 600 simulated seconds.
   - **A sleeping test site** (wake every 60 s, a line each time) over a
     simulated day: 1,440 lines, each at its exact virtual time, in a few
     seconds of ours.
   - **The judges as they are** (chat, Dog Park, pair, lossy, rough): a
     missed TCP deadline shows up as a stall there too, now that nothing
     papers over it.
4. **Real time, Linux, about 1 s.** A site that asks for a wake 300 ms
   out: measured on the real clock, no earlier, and late by less than a
   bound. A request mid-sleep gets its `between` at once (the kick).
5. **Real time, QEMU, a few seconds.** One boot of a test site that wakes
   every 500 ms for 3 s, its console lines timestamped by the host:
   proves the TSC deadline and the halt on a real processor's timer,
   which metal-vmm only models.

What does NOT get a wall-time test: anything longer than a few seconds.
60 hours is simulated time, in step 3.

## Open questions (for the cold reviewer, then Steve)

- Is the source list complete? (The reviewer's first job.)
- `due` in awake nanoseconds (i96) everywhere, or TSC ticks on metal?
- Is the simulator equivalence check sound when the jumping run is *more*
  punctual (a timer served at its deadline, not up to 1 ms after)? Its
  frames' times differ, and an earlier retransmission can change what
  follows.
- Should idle work's "resting" outcome carry a time (`resting_until`)?
  `idle_check` already keeps `next_at` and `reweigh_at` and hides them.

## Rounds
