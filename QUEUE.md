# Work queue

Shared by the cloud Claude (CC) and the box Claude; see `CLOUD.md`. Items are
in order. The box Claude reorders on `master`, and CC proposes at the bottom.

## Context, 2026-10-02

- **metal.lynrummy.com runs v5:**
  - chat's data on a 2 GiB DigitalOcean volume, the site on the boot disk;
  - test data only.
- **v6 is being built:**
  - CC's virtio MSI-X fix;
  - the two-disk review's fixes;
  - the volume named by serial.
- **Steve's direction:**
  - **The cutover will be all at once, fully committed.** No apps-first
    split.
  - The two themes now are **administration and deployment**, and
    **safety and reliability**.
  - Background: `notes/metal-the-next-few-days.md` on the essay server
    (http://143.244.172.148:9100/notes/metal-the-next-few-days.md).

**Done items, old check-ins and older answers are in [`QUEUE-DONE.md`](QUEUE-DONE.md)** (verbatim). What is below is the open work, the current order, the last two check-ins, and the live answers.

## CC

*Items 1–75, 79–83, 87 and 89 are done — in `QUEUE-DONE.md`.*

*Items 76-78 queued 2026-10-03 (box Claude, keeping the queue full). The
cutover is rehearsed (MIGRATION.md, FAT16 and FAT32); what is left is
mostly Steve's (v9 on metal, the restart test at the console, the session
decision) and the day itself. These three are what the box would want
before that day.*

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
77. **`ops/check` in angry-gopher takes about 155 s.** Time each of its
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

*Items 79-86 queued 2026-10-03 morning. **Steve's priorities, in order:**
(1) hardening, correctness and reliability of the bare-metal layer;
(2) clarity and simplicity of the docs, kept right as you go, with a final
pass after the fire drills; (3) efficiency and clarity of the test gates;
(4) admin fire drills (the box and Steve); (5) speed of the bare-metal
layer, last. 76-78 stand; take 79-83 before them.*

84. **[CC: done; this file slimmed to the open items (the rest in `QUEUE-DONE.md`), reviews/designs under `docs/`, README's first screen]** **QUEUE.md and the REVIEW files, made light.** QUEUE.md is over a
    thousand lines; most of it is done. Move done items and old check-ins
    to `QUEUE-DONE.md` (verbatim, nothing lost), leaving open items, the
    current order, the last two check-ins and live answers. Gather the
    REVIEW-*.md and DESIGN-*.md files under `docs/reviews/` and
    `docs/designs/` with a one-line index each, and fix every link to
    them. The README's first screen should tell a newcomer what this is,
    where it stands, and which three files to read.
85. **The gates, clearer and cheaper.** (a) `gates.sh quick`: the
    two-minute tier (zig tests, kernels, probes, one judge story) for
    every commit, and the full run for a batch. (b) Skip what cannot be
    affected, said out loud, never silently: the FAT32 judge only when
    `src/fat16*`, `src/io*` or the judge changed, with the reason printed.
    (c) `GATES_PARALLEL=1` becomes the default once the box has seen it
    green twice (batch 16 was the first).
86. **Where metal's request time goes** (speed, last). The README's race
    table has metal about 1 ms behind Linux on pages read from files, and
    near level on the rest. Instrument one request's phases with the TSC
    (accept, parse, route, read, write, close) and report where the time
    goes under KVM. Report only: what to change is the next item.

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

*Item 90 queued 2026-10-03, found by fire drills 1 and 4. **FIRST, before
anything else, including 87 if you are mid-way: Steve, 2026-10-03: "Our
BIGGEST BLOCKER for cutting over to metal is that images take a lot longer
to download."** Park 87 on your branch if it is not done; 90 is next.*

**UPDATE, same morning: the box Claude takes item 90 itself** (Steve: it
needs him to judge whether pictures "feel" slow, and the real droplet).
**CC: do not start 90.** Carry on with 87 (the page cache), then the
rest in order. The box will say here what it finds, since 87's numbers
and 90's touch the same path.

**A lead to measure first, not a finding:** metal sends from a 64 KiB
buffer. If it fills that and then waits for an ACK, and Linux, as the
receiver, delays its ACK (about 40 ms in some cases: delayed ACK, and
Nagle on the sending side if it matters), the rate is 64 KiB per 40 ms,
about 1.6 MB/s: close to the 2 MB/s measured. If so, the fix is in how
metal handles ACKs and its window (send more before waiting, a larger
window, not waiting on a delayed ACK), not a redesign. Measure the gaps
between metal's segments and Linux's ACKs on a 10 MB transfer (a packet
capture on the tap, or `tcp_sim`'s clock) before changing anything.

90. **One slow response stalls everyone.** Measured on the real droplet
    (v12, prod's data), from prod over the private network:
    - the admin backup streamed at about 2 MB/s, and metal answered
      nothing else for its two minutes (known: REVIEW-admin-backup.md
      finding 3);
    - with Steve logging in and opening chat (pictures in the
      transcripts), three `GET /version` in a row from prod took **5 s
      (timed out), 1.46 s, 0.8 ms**. The watchdog's first look at metal
      timed out the same way.

    So one person loading a few pictures can stall the site for seconds.
    After the cutover that is everyone's site.
    - **Find where the time goes** in sending one large response: the
      send window, the segment size, waiting for each ACK, the 64 KiB send
      buffer, the loop turning only between whole responses. Measure on
      the droplet machine under QEMU with a 10 MB file, and say what
      Linux's TCP does differently for the same transfer.
    - **Then make a large response stop holding the machine:** interleave
      sending with serving other connections (the loop already turns
      while `sendAll` waits for room, so this may be close), and raise
      the single-connection rate toward what the private network allows.
    - **Test:** while a 10 MB response streams to a slow reader, other
      requests are answered within a bound you set and test (say 50 ms),
      on both hosts in the judge. Linux will pass it today; metal must.

## Box Claude

- v6: gates, images, deploy with Steve, and the survival test (the marker
  message posted on v5).
- The restart on a real droplet (`restart.elf` at the recovery console with
  Steve), which item 16 waits on before any deploy.
- Case-insensitive names in angry-gopher (Steve's decision above): prod's
  names checked first, then the change, Linux tests, and judge coverage.
- The migration rehearsal on a copy of prod's data, ending in a
  metal-versus-Linux comparison on that data.
- Measuring on the droplet: big uploads while others browse, clock drift
  against prod.

## Questions

*(CC writes here; the box Claude or Steve answers under Answers.)*

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

## Proposed

*(CC adds items here, one line on why each.)*

- **43. F1: an append near 4 GiB panics** (REVIEW-restart-fat32.md): a
  remote crash once game data is on FAT32.
- **44. R1: record the restart before logging it**, so the back-off holds
  for failures in the output path.
- **45. F2: `build_volume.py` refuses FAT32 below 3 GiB**, as
  `new_volume.py` does.
- **46. `probe/run.sh`: QEMU failing to start must not read as PASS**
  (check-in 9): exit 1 is both a probe's success and QEMU's own error.

- **Fold case for session ids and channel names in angry-gopher.** On FAT,
  `plan` replaces `Plan`, where Linux keeps both (MIGRATION.md).
