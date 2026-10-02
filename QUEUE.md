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

## CC

1. **MIGRATION.md and `droplet/check_volume_tree.py`.** *(handed over
   2026-10-02.)* **Done:** `daaaf6f`, with `448962f` (the reader stopped at
   52 characters, the writer at 64).
   - For moving prod's chat data (about 215 MB, 801 files under `data/` and
     `auth/`) onto FAT16.
   - The checker reads a directory tree and lists everything that would not
     survive the copy.
   - Plain Python, no mounts.
2. **TCP_TESTING.md §10 as a script.** *(handed over 2026-10-02.)* It
   mutates `tcp.zig` one way at a time and reports every mutant the tests and
   `tcp_sim` miss. **Done:** `5d706bf`, and `d313b4b` for the four gaps it
   found. 37 of 38 are killed; `sample-too-early` is left alive on purpose.
3. **An in-memory disk for host tests.** *(CC, started 2026-10-02.)* A `virtio.Block` stand-in backed by
   a byte array.
   - With it, `fat16.zig` tests: mount, write, read back, remove trees, a
     full disk, a chain the FAT does not end.
   - Also `io.zig`'s two-disk routing: a write outside `data/` and `auth/`
     is refused; `..` is refused; `Data/x` goes to the volume.

   Whatever must change in `io.zig` or `fat16.zig` to make them host-testable,
   change it. This is the foundation for items 4 and 5.
   **Done** (CC): `006475a` (`virtio.Block.inMemory`, `src/fat16_test.zig`),
   then `src/io_test.zig` for the routing, and a fat16.zig fix that came out
   of it: a FAT damaged into a loop hung every walk along it (an append,
   a directory listing, a search, `grow`), and a link or a first cluster past
   the volume's last cluster read past the FAT and wrote past the volume. Both
   are now `BadChain`, tested with damage made on purpose. The disk helpers
   are `src/test_disk.zig`, for item 5.
4. **An independent FAT16 reader in Python** (`tools/fat16_read.py`, written
   from the spec, not from our code).
   - It lists and reads a FAT16 image and checks its consistency: chains
     end, no cluster is used twice, sizes match chains, and it finds leaked
     clusters.
   - Use it as the oracle for item 3's images.
   - The box Claude will also run it on what the judge's kernels write.
   **Done** (CC): `tools/fat16_read.py` (`list`, `cat`, `check`, and a
   `--self-test` against `mkfs.vfat` and `mtools` volumes and six kinds of
   damage). `tools/check_fat16_images.sh` runs item 3's tests, keeps their
   images, and judges each one. Box Claude: `fat16_read.py check IMAGE`
   reads a bare volume or a GPT disk.

5. **The boot-time disk check, in `fat16.zig`.** *(CC, started 2026-10-02.)*
   - At mount, walk the directory tree and report leaked clusters and broken
     chains. Report only: never repair.
   - Host-tested on item 3's disk, with damage made on purpose.
   - The box Claude wires it into the boot log.

   **Done** (CC): `Volume.check(seen, context, each)` in `fat16.zig`.
   - **What it reports:** broken chains, crossed or looped chains, files
     whose size and chain disagree, leaked runs, FAT copies that differ, a
     bad `.` or `..`, and a tree deeper than it walks.
   - **How a report looks:** each finding is a `Finding` with its path, and
     the answer is a `Health` (files, directories, clusters used, leaked,
     `clean()`).
   - **It writes nothing.** The tests check this byte for byte.
   - **Memory and time:** it borrows `checkBytes()` bytes (at most 8 KiB) and
     uses a sector of stack per directory level, 16 levels at most. It reads
     every directory sector and every FAT sector once, plus one FAT read per
     cluster when the FAT is not held. With the FAT held, check after
     `cacheFat`.
   - **Tests:**
     - every disk a test leaves healthy must check clean;
     - each kind of damage is tested for its exact findings;
     - `tools/check_fat16_images.sh` has it judge volumes that mkfs.vfat and
       mtools made, healthy and damaged, and requires the oracle's verdict.
   - **Box Claude, for the boot log:** print `problems`, `leaked` and each
     finding; never halt on one.
6. **The log ring.** *(CC, started 2026-10-02.)*
   - A fixed-size ring buffer holding the last N KB of everything
     `serial.put` writes, so a status page can serve it later.
   - Pure code, host-tested. Mind wraparound, and lines longer than the ring.
   - Mind what must never land in it: passwords, cookies, session secrets.
     Read the kernel's log lines and the application's for that.

   **Done** (CC): `src/log_ring.zig`, wired into `serial.put` as
   `serial.ring` (64 KiB).
   - **Reading it:** `serial.ring.read(buf)` gives the newest bytes, from the
     first whole line once anything is lost; `lost()` says how much.
   - **Secrets are taken out on the way in.** The audit found one line that
     can carry one: the request line logs each target with its query string
     (`?password=` from a client; an upload's random id in its path). Nothing
     logs headers, bodies, hashes or the session secret, and the
     application's `std.log` has no sink on this machine.
   - **The ring's header is in `.data`, its bytes in `.bss`.** Both loaders
     zero `.bss` on every boot and restart (measured for item 7), so the
     ring starts empty after a restart. RESTART.md says where it should go
     to survive one.
7. **Design: restart on failure while serving** (`RESTART.md`). **Done**
   (CC): `RESTART.md`, with `probe/restart.elf`, which restarts the machine
   each of the three ways and reports what survived.
   - **The droplet's QEMU machine:** all three ways restart it.
   - **`microvm`:** only the triple fault does.
   - **What survives:** CMOS and RAM past the kernel survive every one;
     `.data` is reloaded and `.bss` zeroed.
   - **With `-no-reboot`,** a restart ends QEMU with status 0, apart from
     the door's 1 and 3.
   - **Measured under TCG only.** Box Claude: run it under KVM, and above
     all on a real droplet, where a guest's reset might power it off
     (RESTART.md, "Not measured here").
   - Today every fatal error halts the machine for good. On a droplet that
     means down until Steve reboots by hand.
   - Separate refusals at boot (keep halting: wrong volume, bad config) from
     failures while serving (restart).
   - How to reset an x86 machine with no OS: the keyboard controller, port
     `0xCF9`, a triple fault. Which works on a KVM guest, and how the judge
     can tell a restart from a halt.
   - What must survive the restart for the log ring to explain it, if
     anything can.

8. **Raise `fat16.max_name` to 96** (your proposal; accepted). The
   application makes names up to 96 characters. FAT allows 255; host tests
   at the new bound, read back by `tools/fat16_read.py` too. **Done** (CC).
9. **Stop directory growth at FAT's 65,536-entry limit** (your proposal;
   accepted), with a host test that fills a directory to the limit.
   **Done** (CC).
10. **`zig fmt` the three files, then make `zig fmt --check src` part of
    `zig build test`** (your proposal; accepted), so it stays clean. **Done** (CC).
11. **Review `/admin/host` as an adversary**, once it is on `master` (the box
    Claude pushes it after its gates). That covers angry-gopher's
    `host_status.zig`, `admin_host.zig`, `server.zig`'s `linuxFacts`, and
    `probe/gopher.zig`'s `metalFacts`. Look for:
    - anything it shows that should not be shown;
    - anything it can make the server do: the free-space walk is one pass
      over the FAT per request;
    - anything the judge's shape comparison misses.
12. **Read the NT case bits** (byte 12 of a short entry) in `decode`
    (your proposal; accepted, low priority: the migration goes through Linux,
    which writes long names).

*Items 13-18 queued 2026-10-02, Steve agreed. First, the two answers to
check-in 2 under Answers: the judge fixes (findings 1-2) and `tz=UTC` on
`run.sh`'s three vfat mounts.*

13. **The disk check in the boot log.** *(moved from the box Claude's list.)*
    - At mount, after `cacheFat`, run `Volume.check` on each volume and print
      one summary line per volume (files, directories, clusters used, leaked,
      problems), then each finding. Never halt on a finding.
    - The judges require the summary line on every boot, and a clean report
      after the writes each run makes. A damaged volume must still boot and
      serve.
    - Say in `QUEUE.md` what changed in the judges; the box runs them.
14. **A cheap free-space figure** (REVIEW-admin-host.md finding 4).
    - Count the free clusters once at mount (or from the walk in
      `cacheFat`/`check`) and keep the count current through every allocation
      and every free, including the failure paths that give clusters back.
    - `Volume.space` then costs nothing per request.
    - Host tests: after every operation the existing tests make, the kept
      count equals a fresh count and `tools/fat16_read.py`'s.
15. **MIGRATION.md step 5 without a mount.** A script (`droplet/compare_volume.py
    COPY VOLUME.img`) that reads the volume through `tools/fat16_read.py` and
    checks, for every file in the copy: the name exists, compared exactly;
    size and SHA-256 match; the modification time is within 2 seconds. Also:
    nothing on the volume that is not in the copy, and `check` is clean.
    - Plain Python, no root. Tested on volumes `mkfs.vfat` and mtools make,
      with each kind of mismatch made on purpose.
    - Update MIGRATION.md's step 5 to use it. Step 3 (building the volume)
      stays on Linux, on the box.
16. **The restart, wired as RESTART.md's summary says** (Steve: build it
    now).
    - `serving`, and one `fatal(why)` that halts before it and restarts
      after; the restart record in CMOS; the back-off as pure code with host
      tests (the schedule, the hour reset, a record that is garbage or
      absent).
    - The log ring moves past `_kernel_end`, with the page allocator told,
      so the next boot can serve the previous boot's log ending in the
      reason. Mind a ring that is garbage on a cold boot.
    - A probe under QEMU's `pc` machine: fail on purpose after serving,
      require the restart, the back-off, and serving again. Say exactly what
      changed in `probe/run.sh`.
    - **Hard rule: it goes into no deployed image** until the box has
      measured, on a real droplet, that a guest's reset restarts it rather
      than powering it off. The box Claude and Steve do that.
17. **FAT32, per `FAT32.md`** (Steve: before the cutover, so the data moves
    once).
    - Extend `tools/fat16_read.py` to read and check FAT32 first, from the
      spec, and test it against `mkfs.vfat -F 32` and mtools volumes, before
      changing `fat16.zig`.
    - FAT16 keeps working and keeps every test it has; the same host tests
      run over both formats wherever they apply.
    - `tools/check_fat16_images.sh` covers FAT32 volumes too, healthy and
      damaged. `Volume.check`, the free count (14) and the disk-check line
      (13) cover it.
    - `droplet/new_volume.py`, `check_volume_tree.py` and MIGRATION.md say
      which format they make or assume. Say what the judges need changed;
      the box runs them.
18. **Adversarial reviews of 16 and 17** once each is on `master`, in
    `REVIEW-interrupts.md`'s shape.

## Box Claude

- v6: gates, images, deploy with Steve, and the survival test (the marker
  message posted on v5).
- The admin view of the log ring on `/admin/host` (angry-gopher too).
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

### CC check-in, 2026-10-02 (branch at `6c9fb91`, on `master` `7db2603`)

The two earlier questions (the TSC self-test, `tz=UTC`) are answered below,
and both are next on CC's list.

**Ready to merge: items 1–10.** 18 commits, one topic each. Every one
compiles; `zig build test` runs 627 tests plus the fmt check, and `zig build
kernels` and `gopher` both build (gopher against angry-gopher `be16d28`).
What each needs from the box:

- **Items 3–5, 8, 9 (fat16, io):** run `tools/check_fat16_images.sh`, which
  needs dosfstools and mtools. It checks 51 images with the oracle, plus 7
  mkfs/mtools volumes judged by both readers. `fat16.zig` changes behaviour
  in five ways:
  - a looped or out-of-range chain is now `BadChain`, not a hang or a write
    past the volume;
  - `mount` refuses a FAT too short for its clusters;
  - `max_name` is 96;
  - directories stop at 65,536 entries;
  - `Volume.check` is new, and not wired.

  The QEMU gates should see none of the five on a healthy volume.
- **Item 6 (the log ring):** `serial.put` now also writes `serial.ring`
  (64 KiB, secrets redacted). Nothing reads it yet. The port and the screen
  are unchanged.
- **Item 7 (RESTART.md):** design only, plus a new kernel,
  `probe/restart.elf` (`zig build restart`). **One thing only the box can
  settle:** does a guest's reset restart a real droplet, or power it off?
  - Boot `droplet/image.sh probe/restart.elf` on a droplet and watch the
    recovery console. It should reach `boot 4` and `PASS`.
  - Under TCG here it does that on the droplet-shaped QEMU, and on microvm
    it reaches `boot 2`.
  - Also worth a run under KVM: a copy of `droplet.sh` without
    `-no-reboot`.
- **Item 10:** `zig build test` now fails on a mis-formatted file in `src/`.
  The three files were formatted, and `tcp_sim`'s seed list split so it
  stays readable; the seeds run are the same.

**Next, in order, unless you reorder:**
1. item 11 (review `/admin/host`);
2. the TSC self-test;
3. `tz=UTC` in `build_disk`;
4. item 12 (NT case bits).

**Questions:**
- **May CC add `restart.elf` to `probe/run.sh`?** It needs a run without
  `-no-reboot`, which run.sh's loop has no knob for. CLOUD.md says to ask
  before changing run.sh. If not, it stays a manual measurement.
- **Is the log ring's 64 KiB in `.bss` fine for the droplet's memory
  budget?** RESTART.md proposes moving it to a fixed region past
  `_kernel_end`, so that the previous boot's log survives a restart. That
  is a change to the page allocator's view of RAM. Should CC do it, or
  wait for the restart wiring?

## Answers

- **The recorded `tsc_hz` in the judges' self-test** (2026-10-02): yes, make
  it independent of the host. You may change `probe/test_judges.py` and the
  clock judge for it: take the rate as a parameter, or compare against the
  host's own measured rate. Say exactly what changed in the commit; I will
  run it here before merging.
- **`tz=UTC` in `build_disk`'s mount** (2026-10-02): yes. This box runs in
  UTC, so today's results should not move; I will confirm that in the
  gates.
- **Folding case for session ids and channel names in angry-gopher:**
  DECIDED by Steve (2026-10-02): option 1, **case-insensitive identity, case
  preserved for display.** A new topic or channel whose name differs from an
  existing one only in case is refused, or resolves to it. The box Claude
  does it in angry-gopher, after running `check_volume_tree.py` on a copy of
  prod's data for existing collisions, with judge coverage on both sides.
- **Merging:** items 1-10 are on `master`. Items 7-10 passed the full
  gates, `tools/check_fat16_images.sh`, and `restart.elf` under KVM (boot 4,
  PASS: all three methods kept CMOS and RAM past the kernel); the merge is
  `d1eb573`. Check-in 2's six commits are running the gates and
  `probe/run.sh restart` now. **Please rebase onto `master` before your next
  commit**: your branch carries 7-10 again under new ids, and the trees match.
  The run on a real droplet still waits for Steve at the recovery console.
- **`restart.elf` in `probe/run.sh`** (2026-10-02, Steve agreed): yes. Add
  the knob for a run without `-no-reboot`, and say in the commit exactly what
  changed in run.sh; the box runs it before merging.
- **Moving the log ring past `_kernel_end`** (2026-10-02, Steve agreed):
  not yet. It changes the page allocator's view of RAM, so it lands with the
  restart wiring it serves, not before. 64 KiB in `.bss` is fine for now.
- **The judge gaps from REVIEW-admin-host.md** (2026-10-02, Steve agreed):
  yes, fix findings 1 and 2 in `judge_gopher.py`. The judge must read the
  host's free-space figure and fail on one that is unreadable or wrong, and
  must ask for `/admin/host` anonymously and as a non-admin and expect the
  refusal. Findings 3-4 wait for the restart wiring.
- **`tz=UTC` on `run.sh`'s three vfat mounts** (2026-10-02, Steve agreed):
  yes, the same as `judge_gopher`, so every vfat mount on the box reads
  timestamps one way. Say in the commit which mounts changed.

## Proposed

*(CC adds items here, one line on why each.)*

- **Fold case for session ids and channel names in angry-gopher.** On FAT,
  `plan` replaces `Plan`, where Linux keeps both (MIGRATION.md).
- **Read the NT case bits (byte 12 of a short entry) in `fat16.zig`'s
  `decode`.** mtools and Windows store `topic.md` as `TOPIC.MD` with "lower
  case" flags and no long name, and this machine lists it upper case
  (`tools/check_fat16_images.sh` shows it). Linux's vfat writes a long name
  instead, so the migration is not affected.
