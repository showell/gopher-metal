# Design: a kernel that sleeps until it is needed

metal-vmm QUEUE 228.1, and the part of 228.3 that shapes it. **Status:
design after three cold reviews** (the box, 2026-10-17), waiting on Steve's
two decisions (below), both now taken. **Built so far:** chunk 1 (the pure
decisions, `src/sleep.zig`, and webbox's `Wake`) and chunk 2 (the sleep on
metal, `longest_rest_ms`, the sleeper, metal-vmm's `sleeps.sh`) chunk 3
(the real-timer check, `droplet/sleeps.py`; rests classified by handler) and
chunk 4 (Linux's between thread on a doorbell) and chunks 5 and 6 (the
host's fetch, metal and Linux). An idle
gopher.elf's 60 s went from 307,564 exits to 6,781, and from 37,605 halts to
8.

## What it is for

The Observatory wakes every 60 s, fetches Dog Park's `/version`, writes a
line, and sleeps. Today no application can ask for that: a site's `between`
answers only "more" or "nothing", and the kernel's idle loop never halts for
longer than `interrupts.slice_ns` (1 ms), because waking every millisecond is
how it notices every timer it keeps.

**The goal, in Steve's words:** Linux and bare metal function the same; most
tests simulate time; a few measure real sleep in wall time; and "sleeping
60 ms is essentially the same problem as sleeping 60 seconds or 60 hours".

**Measured before (2026-10-17, gopher.elf at `69aa02b`, metal-vmm
`TRANSPORT=pci PATIENCE_S=60`, one `GET /` then idle):** 60 s of guest time
cost **307,564 exits** (halt 37,605, clock 189,302, mmio 38,441, msr 37,607)
and 5.3 s of wall time, about 88 µs a rest; the longest halt 0.8 ms.

## Decisions for Steve

1. **The longest rest: `longest_rest_ms` in the config, 10 s by default** (decided)
   (Steve, 2026-10-17: "Why can't the cap be configured for testing? ...
   if we get a 6ms wait working, we can get a 60s wait working"). Tests set
   it to a few ms, so the cap's path is exercised in real time in a fraction
   of a second; production keeps 10 s. See "Every rest is bounded".
2. **How a test Observatory run ends** (Steve, 2026-10-17: decided). Not a
   setting in the app: metal-vmm's `GUEST_S=s` ends a run cleanly after `s`
   seconds of guest time, as `PATIENCE_S` ends a quiet one. The test decides
   how long it watches; the app is what ships. (The Observatory is never
   quiet: it prints and writes every poll, so patience never ends it.)

## Phase 1: sleep long only when the machine is quiescent

The first review counted **seventeen** places whose time is noticed today
only because the loop wakes every millisecond (TCP's timers, five clocks in
the body drains, streams' pings, spilled responses, "due now" states with no
clock). Halting until the earliest of them all is phase 2, for when a busy
server earns it. Phase 1 is enough for the Observatory:

    if quiescent:  rest(min(app.wake, now + longest_rest))
    else:          rest(now + slice_ns)                // today's 1 ms

**The 60 s is counted from the last poll, not from the last quiet
moment.** Quiescence is only "may the machine sleep right now". A request
arriving at second 30 wakes the machine, is served, and the machine sleeps
again until the same second 60. A machine busy at second 60 still calls
`between` then, on its 1 ms slice.

**Quiescent** reads state that exists today:
- `table.inUse() == 0`: every slot closed and unclaimed (tcp.zig:657);
- `held_now == 0`, `draining_now == 0`, and no drain slot `holds()`;
- `serial.pending() == 0`;
- the application did not say `.more`;
- the host's fetch is not running (during ARP the client holds no slot).

**Checked by a second computation**, in coverage builds, at every quiescent
rest: quiescence recomputed from the arrays (every `conns[i]`, `held[]`,
`draining[]`, `drains.waits`) instead of the counters, and required to agree.
Two computations of one fact, gated against each other.

**Nothing unflushed sleeps, and nothing new makes it so.** A line written in
`between` has no response behind it, but every turn of the network flushes
(`streamTurn`'s `serviceStreams` calls `Io.durable`), and the loop turns after
every `between` call before it rests. Coverage kernels assert it at every
sleep. (Round 4's review thought one wake's line on prod's volume would keep
the machine on its slice; a flush added for it changed nothing a gate could
see, a plant showed, so it came out again. sleeps.sh's volume run holds the
behaviour: a flush a wake, and the machine asleep.)

**Idle work's quiet gate is in the minimum; its tasks' own times are not.**
`idle.turn` steps a task only once nothing has been busy for `quiet_ns`
(200 ms), so a machine that went quiescent sooner wakes when that gate opens
(`Idle.gateAt`). What a task then waits for (an hourly check) its `resting`
hides; the cap makes it at most 10 s late. A task with a tighter time would
need `Outcome.resting` to carry it; none has one today.

An Observatory between polls is quiescent; its 40 ms fetch runs on today's
1 ms slice. A machine holding a stream or a kept-alive connection keeps the
slice, so chat on its droplet gains little. TCP, streams and drains keep
their tested behaviour unchanged.

## Every rest is bounded

`interrupts.rest(until: i96)` replaces `rest()`, and **no rest is without a
deadline**:
- **The inner waits** (`stream.pumpOrRestOn` in a serve, the drain at the
  end, the goodbyes, net.zig's send-stall wait) pass `now + slice_ns`, as
  today.
- **The main loop's quiescent branch** passes `min(app.wake, now +
  longest_rest)`. A wake already past is a turn, not a rest.
- **The TSC deadline is computed from the boot's base** (`tsc_base +
  ticksOf(until)`), clamped to the cap first, never as "now plus a delta",
  which near saturation could wrap into the past and spin.
- **After a device ends a rest early, the deadline is disarmed** (0 to
  IA32_TSC_DEADLINE). A 10 s deadline left armed would fire during later
  work and end the next rest at once, counted wrongly.
- **The rest count says what ended a rest**: its deadline, the cap, or a
  device. One more count: **a rest the cap ended, after which the next pump
  took a frame**, a frame that came without its interrupt. On /admin/host.
- The main loop asserts the clock is started (`Io.awakeNs() orelse 0` at
  gopher.zig:724 would otherwise compute deadlines from 0).

**Why a cap, 10 s:**
- **Without one, a lost interrupt on a droplet sleeps until the next
  wake**, which for chat is never. Today it costs 1 ms, and nobody knows.
- **Without one, metal-vmm passes silently.** A halt with nothing armed and
  no frame due ends the run with exit 0 (metal-vmm main.zig:838). With a
  cap, every halt has a deadline, and runs end on `PATIENCE_S` as today, at
  most 10 s of guest time later (pair.sh's server at about 10 s, not 5; no
  judge reads that time).
- **Cost:** six wakes a minute instead of 37,605. 1 s would make long
  simulated runs ten times dearer for little gain.
- **Configured, not fixed:** `longest_rest_ms` (zig-metal-unikernel.conf),
  10,000 by default. The mechanism is the same at every length, so a test
  that sets 6 ms proves on real time what 10 s does in production.
- **What the cap does not check:** whether a real card's interrupt arrives.
  That is QEMU's job (Testing, step 4). metal-vmm models the card, so a
  wake it failed to deliver is its own property to add, host-side, later.

From the application's side, `.at` means the same with or without a cap.

## The application's side: `between` returns a wake

    pub const Wake = union(enum) {
        more,      // more to do now (today's `true`)
        at: i96,   // nothing before this time on the awake clock
        idle,      // nothing until something happens (today's `false`)
    };

**Today's sites change nothing.** webbox's `Site` checks `between`'s
return type at comptime: `bool` takes today's path, Unix seconds and all
(angry-gopher, Dog Park and their script routes read `now` as Unix seconds);
`Wake` takes the new one, and is handed the awake clock as well as the wall
clock.

**The contract, the same on both hosts:**
- **`.at` is a lower bound**, not an appointment. `between` may be called
  more often than asked, and checks its own clock.
- **The host calls it** when it said `.more`, when `now ≥ at`, when the
  application's fetch ended, and after every served request. That holds
  whether or not the machine is quiescent: today metal calls it only after
  a request and while `.more` (gopher.zig:745, :765), so a held stream would
  starve the Observatory's schedule.
- **After every call the network turns** before any rest: `between` may
  have queued bytes, published to a stream, or started a fetch.
- **`.at` lives within one boot or one process.** Metal's awake clock
  starts again at a restart. An application never stores it, and an
  Observatory that restarts polls at once.
- **The console's turn comes first**, so a large backlog can delay a due
  wake. That is allowed: `.at` is a lower bound.

## The host's fetch (chunks 5 and 6, done)

An application cannot reach the kernel's client: `between` gets no table and
no wire. On Linux the TCP stack is the operating system's, and a fetch inside
`between` would hold the turn. So **the host offers one fetch at a time**, the
same shape on both (zig-webbox `host_fetch.zig`):

    host_fetch.start(target, deadlines) → error{Busy, PathTooLong, NoFetch}!void
    host_fetch.result() → ?Result   // handed over once; the body lives until the next start

- **`Busy`** while one runs or its end is unread; **`PathTooLong`** past
  `path_most` (256), never a shorter path asked; **`NoFetch`** on a host that
  offers none.
- **`Result`** carries the outcome, the status, and a body the host keeps to
  `body_most` (64 KiB), past which the outcome is `too_long` and the
  connection is let go.
- **Its end is news:** `between` is called at once, on both hosts (metal: the
  loop's `betweenDue`; Linux: the fetch thread rings the between thread).

The outcomes are the kernel client's words, and each host says which it can
produce:

| outcome | metal | Linux |
|---|---|---|
| ok, bad_answer, short_answer, too_long, connect/idle/total deadline | yes | yes |
| refused | RST to the SYN | ECONNREFUSED |
| reset | RST when established | ECONNRESET, EPIPE |
| no_arp | no ARP reply | EHOSTUNREACH |
| given_up | the retransmit timer ran out | no twin: the deadlines end a Linux fetch, never its own retries |
| no_route | off the lease's network, or a lease with no mask | ENETUNREACH, EADDRNOTAVAIL |

**Metal (zig-metal-unikernel `2f7ccfa`, `d2b9359`, `0e1b2dc`):**
- **One `fetch.Client` in the serving table**, stepped on every turn of the
  network (`streamTurn`), the turns inside a serve included, so a long serve
  never runs a fetch's deadlines out unstepped. ARP replies reach it through
  `stream.on_arp`; the network's turn transmits.
- **How it ended is its own connection's.** Each slot keeps its last
  connection's end (`Conn.ended`: closed, reset by the peer, or abandoned
  and why), past its reset. The client knows its connection by role and its
  own port, and **holds its slot** (`claim`) until it has read that end: the
  first free slot is the next SYN's, and a stranger's could otherwise take
  it, end too, and write its end over ours. The table's counters, which
  every connection moves, are never read.
- **A whole answer is the outcome**, however the connection closes after
  (our FIN never acknowledged, a reset after a whole response): pair.sh's
  eat0-25 once said `idle_deadline` for a whole page.
- `reserved_for_initiated = 1`, so a SYN flood cannot starve it; its ports
  start from a draw; `quiet()` never lets go of an initiated connection.
- On-link only, by the lease's mask: Dog Park is on the private network.
  Every poll re-ARPs, so `no_arp` is the first symptom of trouble there.

**Linux (zig-webbox `1b72ab4`, `linux_fetch.zig`):** one thread a fetch,
never taking the turn: a blocking socket whose send timeout bounds the
connect and whose receive timeout bounds each silence (never past what is
left of the total), the total checked between reads. Its own answer reader,
tested against the same shapes of answer as the kernel's. A host that stops
waits for at most one fetch's total deadline.

**Tested:**
- tier 0: the client against the kernel's own server in one table (a
  stranger's SYN taking the slot, another connection given up meanwhile, a
  whole answer then a deadline or a reset);
- webbox: Linux against servers on 127.0.0.1 (ok, short, not a 200, too
  long, idle, total, refused, the end said once and its ring);
- metal-vmm's `sleeps.sh`, two kernels: the sleeper fetching from gopher.elf
  every 60 s for ten minutes (`PAIR_DISK`), each poll `ok` and the page's
  size from a single-guest run; and the server silent from 180 s to 300 s
  (`WIRE_SILENT_S`, by its own time), polls 4 and 5 `no_arp`, the rest `ok`.

## Linux's between thread (chunk 4, done)

webbox's `betweenLoop` used to sleep `between_idle_ms` (50 ms) when there was
nothing to do: the Linux twin of the 1 ms slice. Now (zig-webbox `01a18aa`):
- **it sleeps until the wake**, on a doorbell: it reads the bell's count
  before calling `between`, then `futexWaitTimeout` until `.at`'s time on
  the awake clock, or `futexWait` for `.idle`;
- **every handler's end rings the bell, and so does a stop.** A ring that
  lands between "decide to sleep" and "wait" has changed the count, so the
  wait returns at once;
- **a `bool` site's false is `.idle` on Linux too**: called again after
  each request, as on metal. The 50 ms poll is gone.

Tested by counts: no call before the wake and one at it; a handler's end
wakes a far wake; a stop ends the thread at once; a request that starts a
run wakes an idle thread and the run is stepped. Red with the handler's ring
left out, and with the old poll. Dog Park's check, a background Shale run on
the Linux host included, passes on it.

## Testing, fast to slow

1. **Pure, tier 0, milliseconds.**
   - `ticksOf` (done).
   - The quiescent predicate.
   - The rest's deadline: the minimum, a past `.at`, the clamp, the TSC
     arithmetic from the base, `.at` saturated far past 60 h.
   - When the host must call `between`.
   - The comptime `bool`/`Wake` paths.
   - Linux's kick with a fake futex.
   - The fetch client against the kernel's own server in one table, with
     the slot handed to a stranger and another connection given up
     mid-fetch.
   - The Observatory's schedule.
2. **The arrays-versus-counters assertion**, in coverage builds, wherever
   the simulators and metal-vmm's coverage kernels reach a quiescent rest.
3. **metal-vmm, simulated time, seconds.** A halt there is an event: the
   clock jumps to the deadline.
   - **The idle kernel's exits, after** (the measure above, again).
   - **A sleeping test site**, waking every 60 s with one console line,
     for a simulated hour: 60 lines, each at its exact virtual time
     (shape, not rate: an hour proves what a day would).
   - **The judges as they are** (chat, Dog Park, pair, lossy, rough).
   - **The Observatory against dogpark.elf in pair mode**, N polls over
     simulated minutes, with Dog Park silenced for a stretch in the middle.
     It runs about 3-5 s.
4. **QEMU, real time, about 4 s, KVM and `TRANSPORT=pci` pinned** (on the
   microvm-shaped machine `rest` is a `pause`). This is the only check of a
   real TSC-deadline timer and a real MSI-X wake.
   - A test site wakes every 500 ms for 3 s. Each line prints the guest's
     awake ns and its rest counts. Between two lines there is exactly one
     rest ended by its deadline and none by the cap.
   - The host times each line's arrival on its own monotonic clock. A gap
     is never under 495 ms, and is late by under 100 ms.
   - The guest's gaps against the host's give the PIT calibration's skew,
     the droplet's real clock drift. It is reported, not gated.
   - A request from the host during a rest ends that rest by a device, well
     before the cap.
5. **Linux, by counts, about 0.2 s.** A site asks for `.at` 100 ms out.
   No `between` call comes before `at`, exactly one comes at or after it,
   and one comes at once for a request mid-sleep. The lateness is reported
   and bounded loosely (1 s): a loaded 2-core box is no place to gate
   milliseconds.

60 s and 60 h are never waited for in wall time: tier 0 holds the
arithmetic, metal-vmm the behaviour. A 10 s cap rest at metal-vmm's 2.5 GHz
already overflows a u64 product, so the u128 path runs on every rest there.

## The order of work

Builds are their own number; the times are test wall time.

| # | chunk | repo | checked by | test time |
|---|---|---|---|---|
| 1 | Pure decisions: `Wake` and the comptime paths in `Site`; the quiescent predicate; the rest's deadline. Red first | zig-webbox, kernel | tier 0 | ms |
| 2 | `rest(until)`, the cap, the rest-count enum and disarm; the quiescent branch; `between` on `.more`, `.at` and requests; a sleeping test site; the coverage assertion. Red first: the idle measure and the simulated hour | kernel | metal-vmm, then the judges once | ~3 s new |
| 3 | The real-time check, early, because a real MSI-X or TSC-deadline wake is the production risk | kernel | QEMU | ~4 s |
| 4 | Linux sleeps until the wake: futex, generation, kicks | zig-webbox | tier 0 + counts | ~0.2 s |
| 5 | The metal fetch: ARP routed, end reasons kept on the slot, `serial`, the reserved slot, `quiet()` skipping initiated connections, the fetch in the predicate | kernel | tier 0; one pair run | ~2 s |
| 6 | The Linux fetch: thread, deadlines, the handover, the kick | zig-webbox | refused port, a silent listener, 100 ms deadlines | ~0.5 s |
| 7 | Dog Park's `/version` (228.2) | dog-park | unit + its gates | <1 s new |
| 8 | The Observatory (228.3): schedule, Linux against a stalling server, pair mode against dogpark.elf | observatory | tier 0, Linux, metal-vmm | ~5 s |

## Chunk 3: on a real timer

`droplet/sleeps.py` (tier 1, about 10 s): the sleeper waking every 500 ms on
the droplet-shaped machine under KVM, each wake said on the console
(webbox's `host_facts.say`) and timed on the host's clock:
- the gaps between wakes, on the host's clock;
- the rests and sleeps across them (`/facts`);
- five requests sent 150-350 ms into a sleep, each timed to its first byte
  back;
- nothing ending a rest but the timer and the card, and no missed wake.

First runs (2026-10-17):
- host gaps 497.7-501.6 ms;
- 12 rests across 8 wakes, where the slice would be about 4,000;
- the guest's clock against the host's -180, -121 and +31 ppm on three
  boots, reported and not judged.

It is red against a kernel never armed (which pauses and counts no rest) and
one whose sleeps all ran to the longest rest. (Round 5's review: the first
version timed the requests' connects, which QEMU's user network completes on
the host by itself, so they said nothing about the guest.)

**What ended a rest is read off the handlers now, not the clock.** The timer
and the card each have a stub that counts before the shared end of interrupt
(`gm_irq_timer`, `gm_irq_wake`), and a halt compares the counts
(`rest_count.ended`). Before, a timer KVM delivered a hair early counted as a
device's, and the missed-wake count went blind.

**What is already raised is taken before the halt** (`sti; nop; cli`). That
covers a slice's deadline that fired during the work after it, and a frame
since the last turn. The stale timer is no one's; the frame ends the rest
without a halt, as the card's. After the halt, the handler's `iretq` turns
interrupts on until the `cli`, so whatever was raised with what ended it is
taken and counted there. (A first version read the card's bit in the APIC's
IRR after a timer-ended halt, reasoning that the timer's higher vector held
the card's back; it does not, past the `iretq`.)

## Phase 2, for later

Halt until the earliest of all seventeen deadlines even when busy, when a busy
server's 1 ms slice shows up as a cost. Its oracle: every clock condition here
is `now ≥ X`, monotone in time, so after each turn the timer-driven steps run
at `due - 1` must send nothing and change nothing; and `tcp_check` derives the
earliest clock from its own liveness rows, to compare with the table's.

## Noted on the way

- **DHCP is never renewed** (dhcp.zig:23). The lease's end goes on
  /admin/host; a long-lived Observatory is the first to care.
- `waitSeconds`, the restart's back-off, spins on `pause`. It could rest
  once the machine is armed.

## Rounds

**Round 1** found:
- a 17-row inventory of hidden deadlines;
- `rest()`'s inner waits;
- the Observatory unreachable through `between`;
- `quiet()` letting go of initiated connections;
- the rest count with no deadline;
- ticks' rounding;
- the Linux kick race;
- the "sleeper vs fidgeter" oracle, unsound;
- the quiescent alternative.

**Round 2** found:
- the "no clock" property was the predicate restated;
- `between` at `.at` on a busy machine;
- the fetch in the predicate;
- metal-vmm's silent pass at a halt with nothing armed;
- the fetch's slot identity, reserved slot, error mapping (EHOSTUNREACH is
  `no_arp`'s twin), body bound;
- `between`'s Unix seconds;
- Linux tested by counts;
- QEMU timed from the host.

**Round 3** cut scope:
- the one-point oracle (near-tautological when quiescent), replaced by
  arrays-versus-counters;
- the exact missed-wake detector: shared rx/tx vector, and a false positive
  under vhost. A count instead;
- idle work's due (the cap bounds it);
- plants per term (pure tests and behaviour cover them);
- the simulated day (an hour);
- the `Now` adapter (comptime instead);
- the Linux eventfd and poll;
- the 60 h run (metal-vmm refuses `PATIENCE_S` past a day, and every cap
  rest already runs the u128 path).

It found:
- the fetch's end reasons read from table-wide counters;
- deadlines wrapping near saturation;
- a stale deadline after an early wake;
- an unflushed volume at a rest;
- how a test Observatory run ends.

All taken, except the two decisions for Steve.

**Round 4** (a cold review of chunk 2's code) found:
- a flush it thought missing (above: it was not; asserted instead);
- sleeps.sh passing on unchecked runs: exits unread, an empty number
  read as no failure, and no halt bound, so a kernel that never slept but
  woke on time passed;
- the mid-sleep request landing next to a longest rest's end;
- the 6 ms and 10 s comparison proving little;
- idle work's gate;
- an unarmed machine's pauses counted as sleeps;
- a disarm write on every slice;
- the sleeper's swallowed write failures.

All taken; the rest's classification in chunk 3.

**Round 5** (a cold review of chunk 3's code) found:
- the connects that measured QEMU, not the guest;
- the IRR reasoning (above);
- a stale timer ending the next rest at once, counted as its deadline;
- missed wakes watched only after a longest rest, so never in the real-time
  check;
- rests ended by neither handler uncounted;
- stale wording in docs/admin-for-agents.md.

All taken.

**Round 6** (a cold review of chunk 5's code) found:
- a stranger's connection writing its end over the client's (the slot is
  held now);
- the client unstepped during a serve while its deadlines ran;
- a lease with no mask letting every target through;
- a long path truncated to a different URL;
- an unread result dropped by the next start;
- `too_long` reading on to the total deadline;
- the silent case tuned to frame counts (now by time: `WIRE_SILENT_S`);
- stale text on 256 connections.

All taken. pair.sh's eat0-25, red in tier 3 the same day, was this chunk's
own: a whole answer reported by how the connection closed.
