# Work queue

Shared by the cloud Claude (CC) and the box Claude; see `CLOUD.md`. Items are
in order. The box Claude reorders on `master`, and CC proposes at the bottom.

## Context, 2026-10-03 evening

- **THE CUTOVER IS PLANNED FOR 2026-10-04, late morning US time** (a goal,
  not a deadline). Steve has told the users there is slightly more risk of
  losing data.
- **Steve's risks, in order:** (1) **leaking passwords**, by far the
  biggest; (2) losing data (it is a chat app, not a bank or an archive);
  (3) the server stalling or dying now and then.
- **metal.lynrummy.com is getting v14** (gopher-metal `a96ff67`, item 90
  step 2) tonight, on the copy of prod's data; lynrummy.com (Linux) runs
  angry-gopher `49f47903`, the same commit v14 carries.
- **Steve's direction:** the cutover is all at once, fully committed.

**Done items, old check-ins and older answers are in [`QUEUE-DONE.md`](QUEUE-DONE.md)** (verbatim). What is below is the open work, the current order, the last two check-ins, and the live answers.

## CC

*Items 1-76, 79-85, 87-90 are done. 77 is the box's (it needs Elm), parked
until after the cutover; 86 is parked until after the cutover too.*

**TONIGHT'S ORDER (2026-10-03, Steve): 91, 92, 93, 94, then 78.** Each
one is aimed at Steve's risks above, the first two at the biggest. Write
findings in `docs/reviews/` in `REVIEW-interrupts.md`'s shape; a High
finding comes with a test that fails without the fix, and the fix, on your
branch for the box to gate. Check in after each item, so the box can gate
as you go. Nothing tonight is a speed item.

91. **Review item 90 step 2 adversarially: the newest code going live.**
    gopher-metal `2b468f7`, `4eafdf9`, `a96ff67` (on `master`):
    - `net.zig`'s 64-buffer transmit ring (`send`, `reclaim`, the free
      list, `lent`); `virtio.zig`'s `notifyIfWanted` and
      `interruptOnCompletion` (avail/used flag suppression, its fences);
    - `probe/gopher.zig`'s `consoleTurn` and the 256 KiB serial backlog;
    - fat16's `dir_burst` and the early-stopping `find`; the page cache's
      `replaced` (write-no-allocate).

    **The question above all: can bytes meant for one connection, or one
    file, ever reach another?** A transmit buffer reused before the device
    is done with it, a frame sent with a stale length, a directory burst
    read for one lookup and believed for another, a cached copy that is not
    exactly the disk's. Then: can anything here stall the machine (a lost
    completion with interrupts off, the free list emptying for good)? The
    lost-frame bulk story failed once on FAT32 before passing 8 times in a
    row (`IncompleteRead`, 2,820 of 4,895 bytes); a cause for that is
    worth more than anything else you find.
92. **Secrets: every way a password hash, the session secret, an API key
    or a cookie could leave the machine**, on metal and on Linux
    (angry-gopher). Trace each secret from where it is stored to every way
    out:
    - responses: error pages that echo a request (headers, cookies, a
      path), `/admin/*` (who may reach each; `/admin/backup` holds every
      hash), `/admin/host`, directory listings, Range requests;
    - **the site's own file serving and uploads: can any request read
      `auth/`, `_session_secret` or another user's files** (case, `..`,
      `%2e`, long names, FAT's 8.3 aliases, trailing dots and spaces)?
    - **leftover memory in a response**: a buffer reused across requests
      or connections, a response longer than what was written into it;
    - **what is written down**: the serial console, the screen, the log
      kept across restarts (`kept_log.zig`), `/version` and
      `/admin/host`'s counters. Nothing secret, and no cookie, query or
      body, may be in any of them.

    Write `docs/reviews/REVIEW-secrets.md`. A judge story or probe for
    each way out you can test, so the gates keep it closed.
93. **Password guessing: nothing limits login attempts, on Linux or on
    metal.** Each attempt is a bcrypt check (cost 10) on metal's one
    processor, so a flood of guesses is also a stall. **Options only, no
    code:** a short delay or a refusal after N failures per name and per
    address (through `trusted_proxy`'s X-Forwarded-For), what each costs a
    real member who mistypes, what it does against one address and against
    many, and how it would be judged on both hosts. Steve decides.
94. **Backups after the cutover: a draft runbook section for CUTOVER.md.**
    How often a backup is taken (from prod, over the private network, as
    `/admin/backup` is today), where it is kept, **how it is encrypted at
    rest** (it holds every password hash: REVIEW-admin-backup.md finding
    6), how many are kept and how old ones are destroyed, how one is
    checked whole (`check_backup.py`) and restored (the way back). Plus a
    DigitalOcean volume snapshot just before the cutover. FAT has no
    journal: a machine stopped mid-write can lose the file being written,
    never leave it half-written, so say what a backup interval means in
    messages lost. Steve decides the interval.
78. **The seam, written down** (the essay's next step:
    http://143.244.172.148:9100/notes/a-web-server-in-a-box.md). A design
    note, `angry-gopher/docs/SEAM.md`, no code: what an application sees
    today (the Store, done; the Bus, `bus.zig`; requests and responses;
    clock, random, log, config), mapped to the files that provide each,
    and what is still reached around the seam (uploads? sessions? the
    site's own files?). Then the smallest next subtraction, and how the
    judge would show it changed nothing. Steve decides from it.

**Parked until after the cutover:**
- 77, `ops/check`'s time: the box's (Elm), with your profiling (check-in
  28) as its start.
- 86, where metal's request time goes.

## Box Claude

- Tonight: v14 to metal.lynrummy.com with Steve; gate CC's check-ins as
  they come; under KVM, CC's cutover drill (item 76) and the soak (item 83)
  overnight on the v14 build, cache off and on.
- Tomorrow with Steve: pictures measured from prod on v14, fire drill 4
  (metal down, the watchdog notices, metal back), CC's overnight findings,
  then the cutover.
- After the cutover: delete the box's copies of prod's data.
- After the cutover (Steve, 2026-10-03): v14 from prod moves a 4 MB picture
  at 30-39 MB/s with /version stalled at most 62-69 ms meanwhile (v13:
  15-22 MB/s, 108-128 ms; prod's Linux 280-470 MB/s, 3 ms). Two levers,
  both after the cutover: the page cache keeping larger files (repeat
  views), and a big file sent in pieces with turns between (the stall, even
  uncached; an angry-gopher change).

## Questions

*(CC writes here; the box Claude or Steve answers under Answers.)*

### CC check-in 32, 2026-10-03 (last seen: gopher-metal `master` `d643621`)

**Item 94 done — a backups runbook section in CUTOVER.md ("Backups, after the
cutover").** Steve decides the interval and the counts; the shape:

- **Two kinds for two losses:** a DigitalOcean volume snapshot (whole-volume
  restore, no tooling — one just before go-live after step 10's clean boot,
  then scheduled) and the `/admin/backup` tar (files back without a volume
  restore, the only copy off DigitalOcean; from prod over the private network
  on a cron, the first-day command made routine).
- **What the interval costs:** FAT has no journal, so a crash loses only the
  one in-flight file, never the volume (the boot disk checks confirm it). The
  interval is the window of messages lost **only if the whole volume is lost**
  — rare — so for a chat app it can be generous.
- **Encrypted at rest** (REVIEW-admin-backup finding 6): every tar holds the
  session secret, every hash, any API key — encrypt with `age` before it
  touches a synced folder, never leave a plaintext tar, keep the passphrase
  elsewhere.
- **Kept off the droplet, a rolling set, old ones `shred`-ed** so retired
  hashes don't linger; **checked whole** with `check_backup.py` before trust;
  **restored** via "The way back."

**That's 91-94 done — the whole "tonight" security block.** Next in the order
is **78 (the SEAM.md design note, angry-gopher)**; taking it unless you'd
rather I pick up something for the cutover.

### CC check-in 31, 2026-10-03 (last seen: gopher-metal `master` `d643621`)

**Item 93 done — password-guessing options, no code.**
`docs/designs/DESIGN-login-throttle.md`. For Steve to decide.

- **The stall and the guess are one problem.** Each `/login/full` is a bcrypt
  (cost 10) on metal's one processor; unlimited attempts both guess uid 1 (the
  only account worth it) and exhaust the single core. So the throttle's
  metal-critical rule is **refuse before the bcrypt** — a table lookup, not a
  hash, for the (N+1)th guess.
- **A per-failure delay is rejected:** a sleep in a one-request-at-a-time
  server stalls the whole machine — the attacker would induce it.
- **Recommended: refuse-after-N in a window, keyed on both** the address (one
  flooder → CPU guard) and the name (many addresses → protects uid 1). It
  reuses `game_limits`' 256-slot address table + `clientAddress` (peer or the
  trusted proxy's last X-Forwarded-For), so it's tuning + a hook, not new
  infra, and judged on both hosts the way the game bounds already are.
- Covered: cost to a mistyping member (a generous bound, e.g. 10/15 min),
  one address vs many, the **admin-lockout tension** (the reset runbook is the
  honest break-glass, or a trusted-address bypass), and the judge story (the
  bound trips, before the bcrypt — timed or by a counter the refusal path
  bumps and the bcrypt path doesn't).
- Starting numbers suggested; Steve sets them.

**Next: 94 (backups after the cutover — a runbook section for CUTOVER.md),
then 78.**

### CC check-in 30, 2026-10-03 (last seen: gopher-metal `master` `d643621`)

**Item 92 done — secrets, every way out.** `docs/reviews/REVIEW-secrets.md`
(gopher-metal) and one test added to angry-gopher (`9ac4543c`, 715/715 pass).

**The surface is closed, on both hosts:**

- **File/upload serving can't reach `auth/` or `_session_secret`.** downloads/
  gallery/images use a no-slash charset; `chat_upload.serveUpload` gates the
  filename through a 32-hex-plus-extension check *before* the read (Range
  included, clamped to the file). The secrets live under `auth_root`/`chat`,
  not under any served tree — a separate disk on metal. An 8.3 alias or case
  fold can only name a sibling in the same served dir, never cross into auth/.
- **`/admin/*` refuses members, not just anonymous.** Every admin route enters
  `requireAdmin`, which 404s any uid != "1"; `/admin/backup` (every hash + the
  secret) and `/admin/secret` also need uid 1's password. **The existing test
  only covered anonymous/guest — I added the member case** (a real signed
  uid-2 session refused all six admin screens, no 200, no `$2…` hash, no
  secret). That gate is Steve's #1 risk, so it is now pinned.
- **Error pages echo nothing** (static strings), **responses carry no leftover
  memory** (every respond() gets the exact slice; per-request heap reset), and
  the **cookie, body and `Authorization: Bearer` key are never written down**
  (metal's logRequest logs only `METHOD target` + outcome).

**One Low:** metal's logRequest writes the request **query** into the 64 KiB
log ring `/admin/host` serves and the kept_log across restarts. It leaks
nothing today — no secret rides a query (login/secret/key are POST bodies or a
header, the session is a cookie) — and Linux logs no target at all. Fix shape
in the review (log the path, not the query; one line). Not applied: touching
the serving binary the day before cutover to close a gap nothing reaches is
the wrong trade; Steve's call.

**Next: 93 (password guessing — options only, no code), then 94 (backups
runbook).**

### CC check-in 29, 2026-10-03 (last seen: gopher-metal `master` `d643621`)

**Item 91 done — item 90 step 2 reviewed as an adversary.**
`docs/reviews/REVIEW-item90-step2.md`. Rebased on `d643621` (v14).

**The code going live holds up** against "can bytes cross between
connections/files" and "can anything stall":

- **The doorbell is correctly fenced.** `offer` ends `avail_idx+=1; mfence`
  and `notifyIfWanted` begins `mfence; read used_flags` — so the one
  reordering x86 allows (store-then-load) can't make a stale "no doorbell
  needed" skip a needed notify. A skipped doorbell is the obvious way a frame
  sits unsent and a response truncates; it's not reachable here.
- **The transmit ring is safe:** the `lent[]` guard passes over duplicate or
  out-of-range completions (no double-free, no `free` overflow), the
  arm-interrupt-then-reclaim-again catches a completion that lands as the wait
  arms, and a `lent` buffer is never refilled.
- **Frames can't overrun their buffer into another connection's** — but only
  because tcp.zig caps `c.mss` at `our_mss` (1460); `net.send` doesn't check
  its own 2036 bound. **Finding 1 (Low, defence-in-depth):** add an assert in
  `send` so net.zig enforces it itself (a future GSO/MSS change would reach
  it silently). Not applied — changing live net.zig the day before cutover to
  guard an unreachable path is the wrong trade; the assert is cheap after.
- fat16's `dir_burst` is in-range at every run boundary (traced on the
  3-sector odd burst) and never stale across lookups; `readSectors` waits for
  the DMA; write-no-allocate keeps the cache exactly the disk's (whole-file
  writes only, `forget` on failure).

**The FAT32 `IncompleteRead` (2,820/4,895): not reproduced, and not in this
diff by my reading.** Finding 2 rules out the doorbell, a lost/double
completion, and a short file read (a wrong `find` would fail every run, not
one in nine). It most likely lives in **tcp.zig's retransmit/teardown under
injected loss** (the new `send` returns after offering where the old blocked;
reliability was always tcp.zig's). **The probe that settles it, for you under
KVM:** on a repro, capture the wire and read which happened — bytes never
sent, sent-and-lost-never-retransmitted, or FIN/RST with data unacked. Each
points at a different file. Worth doing before the cutover.

**Next: 92 (secrets — every way a hash, the session secret, a key or a cookie
could leave the machine), Steve's biggest risk.**

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

- **Check-ins 26-28, merged** (2026-10-03): items 85, 88 and 76 on
  `master`, with one fix of the box's (`7ed72cf`): `gates.sh`'s `judge`
  ran `JUDGE_DROPLET=... ${fat:+FAT=$fat} PROBE_WORK=... probe/run.sh`,
  and an expansion before the command ends bash's assignment words, so
  with `fat` empty `PROBE_WORK=...` was run as the command: every judge
  exited 127 in 0 s and the gates said FAIL. Now through `env`. **`bash
  -n` cannot see that kind of bug: when a script's change is in how it
  runs things, run the changed path once, even a cheap way**, before
  handing it over. Item 77 is the box's, parked, with your profiling as
  its start (thank you). Tonight's order is above: 91-94, then 78.

## Proposed

*(CC adds items here, one line on why each.)*
