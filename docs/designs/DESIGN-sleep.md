# Design: a kernel that sleeps until it is needed

metal-vmm QUEUE 228.1, with the part of 228.3 that shapes it. **Status:
design, round 3** (the box, 2026-10-17). Code so far: `apic_rule.ticksOf`
(`b9d5d15`). The rounds with cold reviewers are at the end.

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

## Phase 1: sleep long only when the machine is quiescent

Round 1 counted **seventeen** places whose time is noticed today only because
the loop wakes every millisecond (TCP's timers, five clocks in the body
drains, streams' pings, spilled responses, "due now" states with no clock).
Halting until the earliest of them all is phase 2, for when a busy server
earns it. Phase 1 is enough for the Observatory:

    if quiescent:  rest(min(app.wake, idle.nextDue(), now + longest_rest))
    else:          rest(now + slice_ns)                     // today's 1 ms

**Quiescent**, read from state that exists today:
- `table.inUse() == 0`: every slot closed and unclaimed (tcp.zig:657);
- `held_now == 0` and `draining_now == 0`;
- no drain slot `holds()` (drain.zig:269);
- `serial.pending() == 0`;
- the application did not say `.more`;
- **the host's fetch is not running**: during ARP the client holds no slot,
  so "every connection closed" is true mid-fetch.

An Observatory between polls is quiescent; its 40 ms fetch runs on today's
1 ms slice. A machine holding a stream or a kept-alive connection keeps the
slice, so chat on its droplet gains little. TCP, streams and drains keep
their tested behaviour unchanged.

## Every rest takes a deadline, and every deadline is bounded

`interrupts.rest(until: i96)` replaces `rest()`, and **no rest is without a
deadline**:
- **The inner waits** (`stream.pumpOrRestOn` in a serve, the drain at the
  end, the goodbyes, net.zig's send-stall wait) pass `now + slice_ns`, as
  today.
- **The main loop's quiescent branch** passes the minimum above, which
  `longest_rest` bounds.
- **Ticks** come from `ticksOf` (u128, rounded up, never 0: done).
- **The rest count says what ended a rest**, as an enum: its deadline, the
  cap, or a device.

### The longest rest, 10 s, the same in every kernel (the decision for Steve)

**Without a cap**, a quiescent machine whose card's interrupt went missing
would sleep until its next due, on chat's droplet idle work's hourly check;
today a lost interrupt costs 1 ms and nobody knows. It also changes every
metal-vmm run: a halt nothing can wake ends the run at once (metal-vmm
main.zig:838), so every idle judge run would end at its first such rest
instead of after `PATIENCE_S`, and every judge would need a re-baseline.

**With a 10 s cap** the kernel is never without a deadline, metal-vmm's
runs end as they do today, and a lost interrupt costs at most 10 s. The
cost is six wakes a minute instead of 37,605. A 60 h sleep is 21,600 rests,
about 2 s under metal-vmm. 1 s would make that about 19 s.

**A cap measures what it bounds**, so it is not a blanket. A **missed wake**
is a rest the cap or a deadline ended while a frame arrived during it
unannounced. It is detected exactly:
- the rx used-ring index is read just before `sti; hlt`;
- the wake vector's handler counts its interrupts;
- after the rest, if the index moved, the handler's count did not, and no
  MSI is pending in the APIC's IRR, that rest is a missed wake.

It is counted on /admin/host, and it is a property that fails every
metal-vmm judge. From the application's side, cap or no cap, `.at` means
the same.

## The application's side: `between` returns a wake

    pub const Wake = union(enum) {
        more,      // more to do now (today's `true`)
        at: i96,   // nothing before this time on the awake clock
        idle,      // nothing until something happens (today's `false`)
    };

    pub const Now = struct { awake_ns: i96, unix_s: i64 };
    pub fn between(io: Io, now: Now) Wake

`Now` carries both clocks because today's users read Unix seconds:
`script_route.sliceBackground` uses them for a script's `.now`,
`progress_every_s` and its log lines. So do Dog Park's app.zig:234 and
shale.zig:62, and angry-gopher's admin_script.zig:102. **The adapter for
today's sites** maps `true`/`false` to `.more`/`.idle` and hands them
`now.unix_s`, unchanged. It must not cast one clock into the other.

**The contract, the same on both hosts:**
- **`.at` is a lower bound**, not an appointment. `between` may be called
  more often than asked, and checks its own clock.
- **The host calls it** when it said `.more`, when `now ≥ at`, when the
  application's fetch ended, and after every served request. This holds
  **whether or not the machine is quiescent**. Today metal calls it only
  after a request and while `.more` (gopher.zig:745, :765), so a held
  stream would starve the Observatory's schedule.
- **After every call the network turns** before any rest: `between` may
  have queued bytes, published to a stream, or started a fetch.
- **`.at` is past already**: a turn, not a rest.
- **`.at` lives within one boot or one process.** Metal's awake clock
  starts again at a restart. An application never stores it, and an
  Observatory that restarts polls at once.
- **The console's turn comes first**, so a large backlog can delay a due
  wake. That is allowed: `.at` is a lower bound.

## The host's fetch

An application cannot reach the kernel's client: `between` gets no table and
no wire, and gopher.zig never builds a `fetch.Client`. On Linux the TCP stack
is the operating system's, and a fetch inside `between` would hold the turn.
So **the host offers one fetch at a time**, the same shape on both hosts:

    host.fetch.start(target, deadlines) → error{Busy}!void
    host.fetch.result() → ?Result     // handed over once; the body lives until the next start

`Result` carries the outcome, the status, and a body bounded by the host
(`body_max`, with its own outcome word, `too_long`). The outcomes are
`fetch.Outcome`'s words. Each host says which it can produce:

| outcome | metal | Linux |
|---|---|---|
| ok, bad_answer, short_answer, too_long, connect/idle/total deadline | yes | yes |
| refused | RST to the SYN | ECONNREFUSED |
| reset | RST when established | ECONNRESET, EPIPE |
| no_arp | no ARP reply | EHOSTUNREACH |
| given_up | the retransmit timer ran out | no twin: Linux's own retries never end a fetch, the deadlines do |
| no_route | no twin: on-link only | ENETUNREACH, EADDRNOTAVAIL |

**Metal** (the review's 5a-g):
- One `fetch.Client`, **split from the table**: pump routes ARP replies to
  it (today it answers only ARP requests, stream.zig:168). Its step,
  called from the main loop after pump, queues, consumes and finishes. It
  never calls `transmit` or `handle` itself; pump does.
- It keeps its slot's `serial` and checks it every turn. Without that, a
  reset followed by a SYN in one batch can hand its slot to a stranger.
- `reserved_for_initiated = 1`, so a SYN flood cannot starve it.
- `quiet()` skips initiated connections, as `nextReady` does. Without that,
  a slow server is let go behind the client's back.
- `ephemeral_next` is seeded as probe/fetch.zig seeds it.
- On-link targets only for v1: Dog Park is at 10.100.0.3, on the private
  network. `no_route` is the outcome for anything else.

**Linux:**
- One thread a fetch, never taking the turn; its result is published
  atomically, and `result()` reads it under the turn.
- A non-blocking connect, and `poll` for the three deadlines. Linux's own
  SYN retries (about 127 s) never end a fetch.
- `poll` also watches an eventfd that `stop` signals, so a host stops at
  once.
- The thread's end kicks `between`.

## Linux's between thread

Today `betweenLoop` sleeps `between_idle_ms` (50 ms) when there is nothing to
do: the Linux twin of the 1 ms slice.
- **It sleeps until the wake**, on a futex. It reads a generation counter
  before calling `between`, then `Futex.timedWait(&gen, seen, at - now)`.
- **A handler's end, a fetch's end and `stop` each kick it**:
  `gen +%= 1; wake`. A kick that lands between "decide to sleep" and
  "wait" changes the counter, so the wait returns at once.
- **No cap here:** Linux's own timers do not depend on this thread.

## Idle work's next due

`idle.turn` refuses to step while `now - last_busy < quiet_ns` (200 ms). A
task's time is learned only by stepping it, and stepping does the work. So:
- `Outcome.resting` becomes `resting: ?i96` (null: nothing scheduled).
  It is mandatory, so a new task cannot hide its time. `idle_check` hands
  over its `next_at` and `reweigh_at`.
- `turn` records the earliest `resting` time among the tasks it tried. A
  task that worked is due at once.
- `nextDue = max(last_busy + quiet_ns, what turn recorded)`.

## Testing, fast to slow

1. **Pure, tier 0, milliseconds.**
   - `ticksOf` (done).
   - The quiescent predicate, and the minimum, from state built by hand.
   - `Idle.nextDue`, the quiet gate included.
   - The `Wake` adapter, which keeps Unix seconds for today's sites.
   - When the host must call `between`: `.more`, a passed `.at`, an
     `.at` already past, a fetch's end, and `.at` saturated far past 60 h.
   - Linux's kick with a fake futex.
   - The fetch client against the kernel's own server (as fetch.zig:457
     does), including the slot handed to a stranger.
   - The missed-wake rule from recorded indices and counts.
   - The Observatory's schedule (228.3).
2. **The one-point oracle, in coverage builds.** At each quiescent rest, run
   the real step functions once at the rest's deadline against a recording
   wire: `table.transmit`, `serviceStreams`, `serviceDraining`, each drain
   slot's step, and the fetch's step. Each must send nothing and change
   nothing. This is phase 2's oracle at a single point. It needs no
   `nextDue`, and it is not the predicate restated: it runs the code that
   would act, not the flags that say it won't.
3. **Plants**, one per term: drop the app's wake, idle's tasks or its quiet
   gate from the minimum, call a busy machine quiescent, or leave the fetch
   out of the predicate. Each must turn tier 0 or the oracle red. Without
   them every check above is "green because it never ran".
4. **metal-vmm, simulated time, seconds.** A halt there is an event: the
   clock jumps to the deadline.
   - **The idle kernel's exits, after** (the measure above, again).
   - **A sleeping test site** (wakes every 60 s, one console line each) over
     a simulated day: 1,440 lines, each at its exact virtual time.
   - **60 h in one `.at`**, `PATIENCE_S` past 216,000: the u128 path end to
     end, about 2 s.
   - **The judges as they are** (chat, Dog Park, pair, lossy, rough), now
     with the missed-wake property.
   - **The Observatory against dogpark.elf in pair mode** (228.3). While the
     other guest slices at 1 ms, the Observatory's halts are held to its
     pace, so its cost is measured, not assumed.
5. **Linux, counts, about 0.2 s.** A site asks for `.at` 100 ms out.
   - Gated on counts: no `between` call before `at`, exactly one at or after
     it, and one at once for a request mid-sleep.
   - The lateness is reported, bounded loosely (1 s), never gated tighter on
     a loaded 2-core box.
6. **QEMU, real time, about 4 s, KVM and `TRANSPORT=pci` pinned.** On the
   microvm-shaped machine `rest` is a `pause`. This is the only check of a
   real TSC-deadline timer and a real MSI-X wake.
   - A test site wakes every 500 ms for 3 s. Each line prints the guest's
     awake ns and its rest counts. Between two lines: exactly one rest
     ended by its deadline, none by the cap, none missed.
   - The host times each line's arrival on its monotonic clock: a gap is
     never under 495 ms and is late by under 100 ms.
   - The guest's gaps against the host's measure the PIT calibration's
     skew. That is the droplet's real clock drift, and the one real check
     of the awake clock against wall time.
   - Then a request from the host during a rest ends that rest by a
     device, well before the cap.

Nothing longer than a few seconds runs in wall time. 60 s and 60 h are
simulated, in step 4.

**Dropped:**
- The round-1 "sleeper and fidgeter send the same frames" check: a
  punctual retransmission changes everything after it.
- The round-2 property "quiescent means no clock": it restated the
  predicate and could never fail.

## Phase 2, for later

Halt until the earliest deadline of all seventeen even when busy, checked by
the one-point oracle run after every turn (not only quiescent ones), plus
`tcp_check` deriving the earliest clock from its own liveness rows to compare
against the table's.

## Small things noted on the way

- **DHCP is never renewed** (dhcp.zig:23). The lease's end goes on
  /admin/host: a 60 h sleeper is the first long-lived client.
- `waitSeconds`, the restart's back-off, spins on `pause`. It could rest
  once armed; not phase 1.

## Rounds

**Round 1** (cold review): a 17-row inventory of hidden deadlines;
`rest()`'s inner waits; the Observatory unreachable through `between`;
`quiet()` letting go of initiated connections; the rest count with no
deadline; ticks rounding; the Linux kick race; the equivalence oracle
unsound; the quiescent alternative. All taken.

**Round 2** (a second, fresh cold review):
- the "no clock" property was the predicate restated, replaced by the
  one-point oracle;
- idle work's quiet gate;
- `between` at `.at` when the machine is not quiescent;
- the fetch in the predicate;
- metal-vmm ends a run at a halt with no deadline, which, with the exact
  missed-wake rule, settled the cap at 10 s;
- the fetch's slot identity, split from the table, reserved slot, error
  mapping (EHOSTUNREACH is `no_arp`'s twin), body bound, shutdown;
- `between`'s Unix seconds;
- tests by counts, not wall time, on Linux;
- QEMU's timestamps from the host.

All taken. The cap stays Steve's call.
