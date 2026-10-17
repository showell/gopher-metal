# Design: a kernel that sleeps until it is needed

metal-vmm QUEUE 228.1. **Status: design, round 2** (the box, 2026-10-17). No
code yet. The rounds with a cold reviewer are at the end.

## What it is for

The Observatory wakes every 60 s, fetches Dog Park's `/version`, writes a
line, and sleeps. Today no application can ask for that: a site's `between`
answers only "more" or "nothing", and the kernel's idle loop never halts
for longer than `interrupts.slice_ns` (1 ms), because waking every
millisecond is how it notices every timer it keeps.

**The goal, in Steve's words:** Linux and bare metal function the same; most
tests simulate time; a few measure real sleep in wall time; and "sleeping
60 ms is essentially the same problem as sleeping 60 seconds or 60 hours".

**Measured before (2026-10-17, gopher.elf at `69aa02b`, metal-vmm
`TRANSPORT=pci PATIENCE_S=60`, one `GET /` then idle):** 60 s of guest time
cost **307,564 exits** (halt 37,605, clock 189,302, mmio 38,441, msr 37,607)
and 5.3 s of wall time; the longest halt 0.8 ms.

## Why not "halt until the earliest deadline", in one step

Round 1 proposed exactly that: every source reports its next deadline and
the loop halts until the earliest. The review counted **seventeen** places
whose time is noticed today only because the loop wakes every millisecond:
TCP's four timers, the client's deadlines, five clocks in the body drains,
held streams' pings and their stuck clients, spilled responses, idle work's
hourly checks, and "due now" states with no clock at all (a FIN owed, a
reopened window not yet announced). Leave one out and it is served late by
however long the machine sleeps. It also found that `rest()` serves the
waits *inside* a serve, whose deadlines live on the stack: there "halt until
nothing" would hang the machine mid-request.

So the design takes the same idea in two phases, and phase 1 is enough for
the Observatory.

## Phase 1: sleep only when the machine is quiescent

**Quiescent** means nothing is in motion: every connection closed, no held
stream, nothing draining, no body being read, no console backlog, and the
application not asking for `.more`. In that state only two things can be
due: **the application's wake** and **idle work's next step**. Both are
pure and both are small. So:

    if quiescent:   rest(min(app.wake, idle.nextDue()))   // may be never
    else:           rest(now + slice_ns)                  // today's 1 ms

- **An Observatory between polls is quiescent**: its fetch is closed. A 40
  ms fetch runs on today's 1 ms slice; then the machine sleeps 60 s in one
  rest.
- **TCP, streams and drains keep today's tested behaviour**, unchanged.
- **What it gives up:** a machine holding a stream (a Dog Park or chat
  browser) or a kept-alive connection keeps the 1 ms slice. So chat on the
  droplet gains little; an idle Observatory gains everything.
- **Kept honest, not assumed:** in coverage builds, at every quiescent rest,
  the table, the streams and the drains are each asked for their own
  earliest clock and must all say "none" (a property, which the
  simulators and metal-vmm's coverage kernels check on every rest).

**Phase 2**, the full earliest-deadline rest, waits until something earns
it (a busy server whose 1 ms slice shows up as a cost), and comes with the
oracle the review proposed (below, "Phase 2's oracle").

## Every rest takes a deadline

`interrupts.rest(until: ?i96)` replaces `rest()`. Every caller passes one:

- **The inner waits** (`stream.pumpOrRestOn` in a serve, the drain at the
  end, the goodbyes, net.zig's send-stall wait) pass `now + slice_ns`, as
  today. They never pass null.
- **Only the main loop's quiescent branch** may pass null: a halt that only
  a frame ends.
- **Ticks from nanoseconds** become `ticksOf(tsc_hz, ns)`: u128, rounded
  **up** (a deadline one tick early would wake before the app asked), and
  never 0, which disarms IA32_TSC_DEADLINE. Tests at 60 ms, 60 s, 60 h,
  saturation and the counter's wrap. It replaces `sliceTicks`, which is
  right only for an `ns` that divides 1e9.
- **The rest count says which ended it**, as an enum: the deadline, a
  device, or a device during a rest with no deadline. Today a rest with no
  deadline would count every frame as the timer's.
- `waitSeconds`, the restart's back-off, spins on `pause`; once the
  machine is armed it can rest instead. A small free win, not phase 1.

## The application's side: `between` returns a wake

    pub const Wake = union(enum) {
        /// More to do now: call again on the next free turn (today's `true`).
        more,
        /// Nothing before this time on the awake clock.
        at: i96,
        /// Nothing until something happens (today's `false`).
        idle,
    };

    pub fn between(io: Io, now: i96) Wake   // `now`: the awake clock

**The contract, the same on both hosts:**
- **`.at` is a lower bound**, not an appointment. `between` may be called
  at any time, more often than asked, and must check its own clock. The
  host calls it **no earlier than nothing forces it, and as soon as it can
  after**: when it said `.more`, when `now ≥ at`, when a host event the
  application owns arrives (its fetch ended: below), and after every
  served request.
- **After every call the network turns** before the machine rests:
  `between` may have queued bytes, published to a held stream, or started
  a fetch.
- **`now` is the awake clock**, passed in, so the application stays pure
  and its schedule is unit-tested with numbers. Today `between` gets Unix
  seconds; a site that wants the wall time reads it from `io`.
- **The awake clock, not the wall clock**, for `.at`: the wall clock can be
  set; the awake clock only moves forward.
- **Today's `bool` sites keep working** through a one-line adapter in
  webbox's `Site` (`true` → `.more`, `false` → `.idle`).

## The host's fetch: what the Observatory actually needs

Round 1 missed the part the Observatory cannot do without. An application
cannot reach the kernel's client: `between` gets no table and no wire, and
gopher.zig never builds a `fetch.Client`. On Linux the TCP stack is the
operating system's, and a blocking fetch inside `between` would hold the
turn and stall every request. So **the host offers a fetch**, the same
shape on both:

    host.fetch.start(target, deadlines) → ?Handle   // one at a time is fine for v1
    host.fetch.result(handle) → ?Result              // null while running

with `Result` carrying `fetch.Outcome` (the same words on both hosts: `ok`,
`connect_deadline`, `no_arp` …), the status, and a bounded body.

- **Metal:** the kernel owns one `fetch.Client`, turned inside
  `stream.pump`, with ARP replies routed to it (today pump answers only ARP
  requests). Its end is a host event: the application is due at once.
  `quiet()` must skip initiated connections, as `nextReady` already does,
  or a slow server is let go as "(no request)" behind the client's back:
  a latent bug today, a real one the day gopher initiates.
- **Linux:** a thread does the fetch on a socket with the same three
  deadlines, maps its ending to the same `Outcome`, and kicks `between`.
  `no_arp` has no Linux twin; the mapping says which outcomes each host can
  produce.
- **A fetch in flight is not quiescent**, so it runs on the 1 ms slice.

This is QUEUE 228.3's plumbing, but its shape decides `Wake`'s contract, so
it is designed here.

## Linux

The host's `betweenLoop` sleeps `between_idle_ms` (50 ms) when there is
nothing to do: the Linux twin of the 1 ms slice.

- **It sleeps until the wake**, on a futex: a generation counter is read
  before calling `between`, then `Futex.timedWait(&gen, seen, at - now)`.
  A handler's end and a fetch's end do `gen +%= 1; wake`. A kick that lands
  between "decide to sleep" and "wait" changes the counter, so the wait
  returns at once: no lost kick.
- **`stop` kicks too**: today the thread notices it only after 50 ms (the
  test at linux_host.zig:2405 encodes that).
- The kick decision is tier 0, with a fake futex and a fake clock.

## The one decision for Steve: a longest rest, or none

With nothing capping a rest, a quiescent machine whose card's interrupt
went missing would sleep until its next due: on chat's droplet, idle work's
hourly check. Today a lost interrupt costs 1 ms and nobody would ever know.

- **No cap**: the purest. metal-vmm turns a missed wake into a loud end
  (a halt with nothing due), so tests find it. A droplet finds nothing.
- **A cap of, say, 1 s, the same in every kernel, and counted** (my lean):
  each rest the cap ended that found a frame waiting is a **missed wake**,
  on /admin/host and a property that fails every metal-vmm judge. That is
  a detector, not a blanket: it measures what it bounds. Cost: one wake a
  second, 60 a minute instead of 37,605, and a 60 h sleep is 216,000 rests
  (fine on a droplet, about 10 s under metal-vmm).

From the application's side the two are identical: `.at` is honoured
either way.

## Testing, fast to slow

1. **Pure, tier 0, milliseconds.**
   - `ticksOf`: 60 ms, 60 s, 60 h, rounding up, never 0, the TSC's wrap.
   - The quiescent decision and `min(app.wake, idle.nextDue)`, from state
     built by hand.
   - **Idle work's `resting` carries its time**: `Outcome.resting` becomes
     `resting: ?i96` (null: nothing scheduled), mandatory, so a new idle task
     cannot hide its time. `idle_check`'s `next_at` and `reweigh_at` come out.
   - The `Wake` adapter; Linux's kick with a fake futex.
   - The Observatory's own schedule (QUEUE 228.3): due, late, one at a time.
2. **Plants, one per source** (plant.zig): drop the app's wake from the
   minimum, drop idle work's, call a non-quiescent machine quiescent. Each
   must turn the checks below red. Without them the checks are "green
   because they never ran".
3. **The simulators**, unchanged in shape: the coverage property "quiescent
   means table, streams and drains have no clock" runs on every rest they
   reach.
4. **metal-vmm, simulated time, seconds.** A halt there is an event: the
   clock jumps to the deadline, so a 60 s rest costs a handful of exits.
   - **The idle kernel's exits, after** (the measure above, again).
   - **A sleeping test site** (wake every 60 s, one console line each) over
     a simulated day, `PATIENCE_S` above the period: 1,440 lines, each at
     its exact virtual time.
   - **One 60 h sleep**: the u128 path end to end.
   - **A halt with nothing due names itself**: in coverage kernels a line
     before a rest with no deadline says every source was empty, so an
     unexpected end of the run reads as what it is.
   - **The judges as they are** (chat, Dog Park, pair, lossy, rough).
5. **Real time, Linux, about 1 s.** A site asks for a wake 300 ms out:
   measured on the real clock, never early, late by under a bound. A
   request mid-sleep gets its `between` at once.
6. **Real time, QEMU, a few seconds.** The only check of a real
   TSC-deadline timer and a real MSI-X wake. A test site waking every
   500 ms for 3 s: six timer wakes, not thousands (read off the rest
   count). Then one quiescent rest with no deadline, ended by a request
   from the host: the frame's interrupt is what wakes it, the risk the cap
   question is about.

Nothing longer than a few seconds runs in wall time. 60 s and 60 h are
simulated, in step 4.

**Dropped from round 1:** the "sleeper and fidgeter send the same frames"
simulator check. It is unsound: a punctual retransmission changes the round
trip samples and everything after, and the simulated world would need its
own deadline list to jump at all.

## Phase 2's oracle, for later

When phase 2 comes: every clock condition here has the form `now ≥ X`, so
it is monotone in time. If any action is owed before `due`, it is owed at
`due - 1`. After each turn in the simulators, snapshot the connections, run
every timer-driven step at `due - 1` against a recording wire, and require
no frame and no change. Second, independent: `tcp_check` derives the
earliest clock from its own liveness rows, and it must equal the table's.

## Rounds

**Round 1** (cold review, 2026-10-17): a 17-row inventory of hidden
deadlines; `rest()`'s inner waits; the Observatory unreachable through
`between`; `quiet()` letting go of initiated connections; when `between`
runs; the rest count with no deadline; ticks rounding; the Linux kick race;
the equivalence oracle unsound; the quiescent alternative. All taken; the
cap is put to Steve.
