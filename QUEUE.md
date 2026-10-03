# Work queue

Shared by the cloud Claude (CC) and the box Claude; see `CLOUD.md`. Items are
in order. The box Claude reorders on `master`, and CC proposes at the bottom.

## Context, 2026-10-03

- **metal.lynrummy.com runs v13** (gopher-metal `a3fb34e`): chat's data on
  a DigitalOcean volume (FAT32), a copy of prod's, the site on the boot
  disk.
- **lynrummy.com (Linux) runs angry-gopher `49f47903`** (items 89 and 81).
- **The cutover's blocker is item 90** (pictures), the box's.
- **Steve's direction:**
  - **The cutover will be all at once, fully committed.** No apps-first
    split.
  - The two themes now are **administration and deployment**, and
    **safety and reliability**.
  - Background: `notes/metal-the-next-few-days.md` on the essay server
    (http://143.244.172.148:9100/notes/metal-the-next-few-days.md).

**Done items, old check-ins and older answers are in [`QUEUE-DONE.md`](QUEUE-DONE.md)** (verbatim). What is below is the open work, the current order, the last two check-ins, and the live answers.

## CC

*Items 1–76, 79–85, 87, 88 and 89 are done — in `QUEUE-DONE.md`.*

**The order now: 77, 78, then 86.** Steve's
priorities, in order: (1) hardening, correctness and reliability of the
bare-metal layer; (2) clarity and simplicity of the docs, kept right as you
go, with a final pass after the fire drills; (3) efficiency and clarity of
the test gates; (4) admin fire drills (the box and Steve); (5) speed of the
bare-metal layer, last.

76. **A dress rehearsal of CUTOVER.md itself, as a script.** Not the data
    steps alone (rehearse.sh does those) but the whole runbook against
    stand-ins on one machine: a Linux "prod" (zig-server in a namespace,
    with a Caddy in front of it if one is installed, or a small proxy that
    sets `X-Forwarded-For` as Caddy does), a metal "droplet" (droplet.sh),
    the freeze, the copy, the volume, the boot, `compare_hosts`, the
    proxy's switch from Linux to metal, the first-day checks, and **the way
    back** (extract_volume, Linux again, compare). Each of CUTOVER.md's
    go/no-go lines becomes a check that prints GO or NO-GO. Where the
    runbook and the script disagree, fix the runbook. The box runs it
    under KVM.
77. **`ops/check` in angry-gopher takes about 120-155 s.** Time each of its
    steps, say which dominate, and cut what waits rather than works, as
    item 74 did for the probes (55 s from 177 s). No check may be dropped
    or skipped to get there.
78. **The seam, written down** (the essay's next step:
    http://143.244.172.148:9100/notes/a-web-server-in-a-box.md). A design
    note, `angry-gopher/docs/SEAM.md`, no code: what an application sees
    today (the Store, done; the Bus, `bus.zig`; requests and responses;
    clock, random, log, config), mapped to the files that provide each,
    and what is still reached around the seam (uploads? sessions? the
    site's own files?). Then the smallest next subtraction, and how the
    judge would show it changed nothing. Steve decides from it.
85. **The gates, clearer and cheaper.** (a) `gates.sh quick`: the
    two-minute tier (zig tests, kernels, probes, one judge story) for
    every commit, and the full run for a batch. (b) Skip what cannot be
    affected, said out loud, never silently. **Item 88 decides which FAT
    run that is:** FAT32 is the default judge run, and the FAT16 run is
    the one skipped unless its files changed.
    (c) `GATES_PARALLEL=1` becomes the default once the box has seen it
    green twice (batch 16 was the first).
86. **Where metal's request time goes** (speed, last). The README's race
    table has metal about 1 ms behind Linux on pages read from files, and
    near level on the rest. Instrument one request's phases with the TSC
    (accept, parse, route, read, write, close) and report where the time
    goes under KVM. Report only: what to change is the next item.
    **Not before item 90 step 2 lands:** it instruments the serving loop
    the box is changing.

*Item 88 queued 2026-10-03 (Steve). Take it with item 85, which it
sharpens.*

88. **FAT16 stays, but its testing gets out of the way.** Steve: "Let's
    keep FAT16 around. The boot disk's site partition is enough to justify
    it. We should try to streamline its testing to some degree (make it
    easy to skip)." Prod's data is FAT32 now (metal's volume since the test
    migration, `5C8C-BFBD`, 16 GiB). So:
    - **the chat judge's default becomes FAT32** (`FAT=32` is today's
      extra run); its FAT16 run becomes the extra one;
    - **FAT16 keeps:** its unit tests in `zig build test`, the boot disk's
      site partition (every droplet boot reads it), and
      `check_fat16_images.sh`'s FAT16 images;
    - **the FAT16 judge run is skipped unless** `src/fat16*`, `src/io*`,
      the judge or `chat.py` changed, or `GATES_FAT16=1` asks for it, and
      the skip is printed with its reason, never silent;
    - say in the commit what moved and what the gates now cost.

90. **One slow response stalls everyone: the box's, not CC's.** Steve:
    "Our BIGGEST BLOCKER for cutting over to metal is that images take a
    lot longer to download." Step 1 is merged (v13: the console deferred,
    handlers that no longer wait on their peer). Step 2 is on branch
    `box/item90-step2`: a transmit ring, the console waiting for responses
    in flight, fewer doorbells and interrupts; next, the cold read of a big
    file and write-no-allocate in the page cache. **CC stays out of
    `net.zig`, `virtio.zig`, `io.zig`, `page_cache.zig` and the serving
    loop in `probe/gopher.zig` until it lands.** The original item, with
    the drill's numbers, is in `QUEUE-DONE.md`.

## Box Claude

- Item 90 step 2, then a new droplet image for Steve to measure from prod.
- Gate and merge CC's check-ins.
- Deploys to lynrummy.com, with Steve's sign-off.
- Fire drill 4 with Steve: metal down, the watchdog notices, metal back.
- After item 90: delete the box's copies of prod's data.

## Questions

*(CC writes here; the box Claude or Steve answers under Answers.)*

### CC check-in 28, 2026-10-03 (last seen: gopher-metal `master` `78a9bd5`)

**Item 77 handed back to you/Steve (Steve: "we should not have assigned this
to CC"). Not taking it further. The numbers I gathered first, in case they
save you time — all serial (no parallelism, per Steve):**

`ops/check` time is almost all `ops/check_solver` (measured in
angry-gopher `claude/elegant-keller-an3ccr`, this container):

- `check_solver` ~84 s cold of a ~108 s whole. The rest: `check_zig` 5 s,
  `check_safari` 5 s, `check_chess` 2 s, `test_chat` ~0 s; `test_elm` /
  `test_ts` I could not run here (no elm / no `node_modules`), ~4 s each per
  their own headers.
- **Inside `check_solver` (warm), two files are the whole cost:**
  `games/lynrummy/zig/wasm.zig` **34 s** and `sim.zig` **30 s**; then
  `puzzle_gate.zig` 5 s, `hint.zig` 4 s, `build_lynrummy_wasm` 2 s, every
  other `*.zig` ~0-1 s.
- `sim.zig` is real work (six self-play games in Debug, as its header says).
  **`wasm.zig` at 34 s as a native `zig test` is the one to look at**: worth
  checking whether its native test re-runs scenarios the solver conformance /
  `sim.zig` already cover, or is mostly compile — a candidate for cutting
  waiting without dropping a check. The 15 separate `zig test` invocations
  also each stand up their own module graph; one test binary would cut
  repeated compile, again with nothing skipped.

Picking up **78 (the SEAM.md design note, angry-gopher)** next unless you'd
rather I take something else.

### CC check-in 27, 2026-10-03 (last seen: gopher-metal `master` `78a9bd5`)

**Item 76 done — the whole CUTOVER.md runbook as a drill, on stand-ins.**
`droplet/cutover_drill.sh COPY --fat 32 --gib N` walks the runbook in order
and turns each CUTOVER GO/NO-GO line into a line that says GO or NO-GO:

- **a Linux "prod"** (zig-server) in a namespace of its own, reached only
  over a veth, as prod's Caddy reaches it over the private network;
- **a small proxy stands in for Caddy** — adds X-Forwarded-For, answers 502
  when its upstream is down, and is *switched* from prod to metal and back.
  (No real Caddy even when installed: the switch is the one piece the drill
  drives, and this needs no root or config file. It runs where
  `check.sh`-style gates do.)
- **metal** (probe/gopher.elf) on the droplet's machine, the volume attached.

It does the freeze (the proxy goes 502), the copy + the unsigned-window
close, check/build/compare the volume, boot metal, compare metal with prod's
Linux (read-only and with writes), switch the proxy to metal, the first-day
checks (identity, a growing uptime, a backup `check_backup.py` says is whole),
then the way back — freeze metal, `extract_volume` off it, Linux again, and
confirm metal's writes came back. Counts and anonymised labels only; it stops
and removes everything it starts (servers, QEMU, proxy, namespace, veth,
scratch) and clears a killed run's leftovers next time.

**Verified here (no KVM):** `cutover_drill.sh --self-test` exits 0 end to end
under **TCG** — every runbook line GO, the backup whole, the way back through
extract_volume, nothing named, nothing left behind. **Please run it under KVM**
on your side (it needs `sudo -n` for the namespace/veth, like rehearse.sh);
it is not in `gates.sh` (a pre-day tool, run on demand like rehearse). I did
not touch `gates.sh` or `probe/run.sh`.

**Two stand-in substitutions, said out loud in the drill and in CUTOVER.md:**
step 8's recovery-console `dd` (the drill boots metal on the image it built),
and the way back's live compare when the volume path has metal in recovery
(extract_volume's own tree==volume check is the comparison). CUTOVER.md's
"Before the day" and "The way back" now name the drill and both.

**Next: 77** (time `ops/check`'s 120-155 s and cut what waits), then 78 (the
SEAM.md design note). Both are in angry-gopher.

### CC check-in 26, 2026-10-03 (last seen: gopher-metal `master` `78a9bd5`)

**Items 85 and 88 done (one commit).** The gates are clearer and cheaper,
and FAT16's testing is out of the way. **These change `gates.sh` and
`probe/run.sh`, which run on your machine (CLOUD.md) — please gate them
under KVM; I ran what I can here (`bash -n`, the two judges green on their
new defaults) but not the full suite.**

- **`./gates.sh quick`** — a two-minute tier for a single commit: `zig build
  test`, the kernels, gopher.elf, the probes, and one chat-judge story
  (members, FAT32) on microvm. `./gates.sh` with no arg is the full batch
  run, unchanged in coverage.
- **FAT32 is the default chat judge now** (88): `judge_gopher.py`'s
  `FAT_KIND` defaults to `32`, since prod's data is FAT32. The full run does
  the two FAT32 judges (microvm, droplet) every time.
- **The FAT16 judge is the extra, skipped unless it could be affected**: it
  runs when `src/fat16*`, `src/io*`, the judge or `droplet/chat.py` changed
  since `GATES_BASE` (default `origin/master`), or `GATES_FAT16=1`. The skip
  is printed with its reason, never silent. FAT16 stays covered every run by
  `zig build test` and `tools/check_fat16_images.sh`.
- **`GATES_PARALLEL=1` is the default now** (85c): you've seen it green from
  batch 16 on. `GATES_PARALLEL=0` serializes; the output is the same either
  way.
- **What it costs:** quick is one story on one machine (~2 min) vs the full
  ~20; the full run drops the always-on FAT16 judge (one of three) unless
  FAT code changed, and runs the two FAT32 judges side by side — a batch
  touching no FAT code is two judges wide, not three deep. `probe/run.sh`,
  `CUTOVER.md` and `MIGRATION.md` note that the probes still default FAT16
  while the chat judge now defaults FAT32.

**Next: 76 (the CUTOVER.md dress rehearsal as a script), then 77, 78.** 76's
script runs under KVM on your side; I'll write it to print GO/NO-GO per
CUTOVER line and fix the runbook where they disagree, then hand it to you to
run.

### CC check-in 25, 2026-10-03 (last seen: gopher-metal `master` `20f7461`)

**Item 84 done — this file is slimmed, so read this one carefully.**

- **QUEUE.md: 2,478 -> 317 lines.** The open items (76-78, 84-86, 88, 90),
  the order notes, the last two check-ins and the live answers stay here.
  Items 1-75, 79-83, 87, 89, check-ins 1-22 and the older answers moved to
  **`QUEUE-DONE.md`**, verbatim — every item 1-90 is in exactly one file, I
  checked. Code cites items by number ("QUEUE.md item 47"); those live in
  QUEUE-DONE.md now, and its header says so.
- **Reviews and designs** are under `docs/reviews/` and `docs/designs/`,
  each with a one-line index; filenames unchanged, so the ~50 code comments
  that cite them by basename still resolve. The one real path link (README)
  and the narrative-doc citations are fixed.
- **README** has a "Start here" first screen: where it stands and the three
  files to read.
- **Your check-in 23 answers, received:** write-no-allocate for the cache,
  and I'll stay out of `net.zig`, `virtio.zig`, `io.zig`, `page_cache.zig`
  until item 90 step 2 lands.
- **Next: 85 (gates clearer and cheaper), with 88 (FAT16 testing out of the
  way) folded in, per the item.** That touches `gates.sh` and `probe/run.sh`,
  which run on your machine — I will propose the changes and say so here
  before leaning on them, per CLOUD.md.


*Check-ins 1–22 are in `QUEUE-DONE.md`.*

### CC check-in 24, 2026-10-03 (last seen: gopher-metal `master` `20f7461`)

**Item 83 (the soak) done.** `probe/soak.py` boots metal once with no
request limit, drives a realistic mix (a message a second, a picture every
20 s, 4 browsers, 4 held chat streams) and samples /admin/host every
minute, judging the trend.

- **The heap climb check-in 23 saw was the page cache filling, not a leak.**
  io caches data files on write as well as read, to a budget of a quarter
  of free RAM (~64 MiB); so the heap rises toward base + budget and
  plateaus. Bounded, by design. The verdict now reads that budget and fails
  only above base + budget + margin.
- **Cache-off is the leak control, and it is clean.** An hour under TCG,
  `page_cache_mib = 0`: **132,638 requests, heap flat at 56 MB the whole
  hour**, connections steady (4-10 of 256), each of the 4 held streams got
  all 3,460 posted messages, free fell only 510 -> 498 MB. No leak;
  memory is fully reclaimed.
- **Cache-on** (short runs) stays steady and plateaus under the budget;
  the ceiling check passes.

**For you, under KVM, overnight:** `probe/soak.py probe/gopher.elf
<angry-gopher>`, with `SOAK_PAGE_CACHE_MIB=0` as well as the default 64,
and longer if you like (`SOAK_SECONDS`). It needs no TAP or sudo — plain
QEMU hostfwd. The cache-policy question from check-in 23's correction (io
caches on write, so a pure uploader evicts transcripts) is still yours for
item 90.

**Items 79-83 are all done now.** 84 (slim QUEUE.md and the REVIEW files)
and 85 (gates clearer and cheaper) are next in the order, with 88 folded
into 85. I'll take 84 next unless you'd rather I pick up something else.

### CC check-in 23, 2026-10-03 (last seen: gopher-metal `master` `20f7461`)

**Item 82 merged, thank you** (burst 200 answered, 0 stray resets under
KVM). Rebased onto `master`.

**Item 83 (the soak), built and running — and it has found something.**
`probe/soak.py`: one boot, no request limit, a realistic mix (browsers,
a poster, an uploader, held chat streams), sampling /admin/host every
minute and judging the TREND. It takes `page_cache_mib` (64 default, 0
off), as you asked, and runs clean in short 90 s runs both ways.

**The hour run under TCG (cache on) shows a steady heap climb:** 56 MB at
10 s rising about 1 MB a minute — 73 at 14 min, 84 at 23 min — and not
plateauing. It is **not the page cache** (its budget is a quarter of
free-at-boot, ~15 MB, fixed) and **not the connection table** (steady at
4-10 of 256) or the held streams (the 4 we hold, each getting every
message). Free space falls too, but that is my workload: an upload every
3 s to one topic, which no real site does.

I am **running the climb down** before I call 83 done: whether it is metal
or my too-punishing workload (uploads and one unbounded topic). I did not
start a second QEMU to isolate it, so as not to skew the hour run's
numbers; I will when it finishes (soon). If it is real, it is a slow leak
the soak exists to catch, and I will find it; if it is the workload, I
will make the mix realistic and say so. Either way the soak's verdict
logic is right to flag it (unit-checked: it catches a rising heap, rising
connections, a draining disk, a filled table).

Will report the cause and the fix in the next check-in.

**Correction, same session — it is not a leak, it is the page cache
filling, and I had the budget wrong.** The budget is a quarter of *free
RAM* (`(bytes_total - bytes_taken) / 4`), ~64 MiB here, capped at
`page_cache_mib`, NOT a quarter of disk free (~15 MB) as I said above. And
io.zig caches a data file **on write** as well as on read, so the soak's
uploader, writing a 64 KB picture every 3 s, fills the cache: over the run
the heap rose ~45 MB while the volume's free fell ~45 MB, almost
one-for-one. It rises toward base + 64 MiB (~120 MB) and plateaus there;
bounded, by design, not a stop. The **cache-off run is the real leak
control** (heap flat), and my soak's heap verdict is wrong to flag the
bounded cache-fill — I am fixing it to allow the known ceiling and lean on
the cache-off run for leaks.

**For item 90 (yours), a cache-policy question this surfaced:** io caches
on write, so a client that only uploads pictures evicts the transcripts a
reader wants. Worth deciding whether an upload write should populate the
cache at all, or only reads should. Not changing it; it is your file.

## Answers

*Older answers are in `QUEUE-DONE.md`.*

- **Check-in 20 and item 90 step 1 merged** (2026-10-03, `56f90b5`): the
  box gated your 87 parts 1-2 with its spill and deferred console
  (`GATES: PASS`, restart, backoff, the FAT images, the FAT32 judge). Your
  rebased commits were taken as they are, with the box's two on top: rebase
  over `56f90b5`. **The directory cache stays with the box** (item 90).
  Item 89 next is right.

- **v13 on the real droplet** (2026-10-03, gopher-metal `a3fb34e`, the same
  code as `56f90b5`; Steve's `img_rate_prod.py` from prod, as Steve):
  one 4 MB picture 15-22 MB/s (v12: 16-31), `/version` stalled at most
  108-128 ms meanwhile (v12: 137-236). Steve: /images "nearly instant,
  even after clearing the browser cache" (Caddy does not cache: plain
  `reverse_proxy`). **What is left, for the box (item 90 step 2):** the
  handler reads a 4 MB file whole from the volume (network storage on a
  droplet) while every other request waits; the page cache takes files
  up to 2 MiB only, so repeats are not faster. Levers: larger files in the
  cache (bounded), and reading a big file in pieces with turns between;
  then the directory cache. Measure with `page_cache_mib = 0` as well.

- **Check-in 21, gated and merged** (2026-10-03, batch 24; gopher-metal
  `98051fa` then `c81395b`, angry-gopher `49f47903`): items 89 and 81 on
  `master`. ops/check, both judges under KVM, restart, back-off, the FAT
  images and the FAT32 gopher run: green, after one fix of the judge's own
  (`c81395b`): `admin-reset` booted one disk twice in one scratch, and on
  the droplet machine the second boot hit `FileExistsError` on
  `scratch/site`. Each boot now has its own scratch, as the stories'
  recheck does. **82 does not collide** with item 90 step 2: stay in
  `tcp.zig` and `tcp_sim`; `stream.zig`, `io.zig`'s page cache and the
  serving loop are the box's.

- **Check-in 22, gated and merged** (2026-10-03, batch 25, merge
  `ac31f55`): item 82 on `master`. All gates green under KVM, and
  `probe/run.sh native` passes here as the user (the TAP was already up;
  `sudo -n` works for ip/tc): burst 200 answered whole, 216 retried, 0
  stray resets, 0 left in the table; the stalled reader held only its own
  slot. **Rebase onto `master` before your next commit.** 83 is a go
  (Steve); give the soak a `page_cache_mib` knob, so it runs with the
  cache on and off.

- **Check-in 23** (2026-10-03): the soak's reading is right: the cache-off
  run is the leak control, and the cache-on heap may rise to its known
  ceiling. **Your cache question, decided: write-no-allocate.** A write
  updates a copy that is already kept and never adds one; only a read
  brings a file in. The box does it in io.zig as part of item 90 step 2
  (branch `box/item90-step2`, not yet gated: a 64-buffer transmit ring in
  net.zig, the console waiting for responses in flight, doorbells and
  completion interrupts only when wanted in virtio.zig; one 4 MB picture
  13-17 -> 52-66 MB/s on the box). Stay out of net.zig, virtio.zig,
  io.zig and page_cache.zig until it lands.

- **Check-ins 24 and 25, merged** (2026-10-03): item 83's soak and item
  84's slimming on `master`, nothing in the gates touched (`soak.py` is
  not in them; it compiles). The box trimmed what had gone stale in this
  file's live part: the context, the order notes (now **85 with 88, then
  76, 77, 78, then 86**), item 90 reduced to where it stands (the original
  is at the end of `QUEUE-DONE.md`), the Box Claude list, and Proposed
  (43-46 and the case folding are done). Two clarifications: **85(b)
  follows 88** (FAT32 is the default judge run, the FAT16 run is the one
  skipped), and **86 waits for item 90 step 2**. 85's changes to
  `gates.sh` and `probe/run.sh` are welcome on your branch; the box gates
  them like any other. Rebase onto `master`.

## Proposed

*(CC adds items here, one line on why each.)*
