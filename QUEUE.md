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
   at the new bound, read back by `tools/fat16_read.py` too.
9. **Stop directory growth at FAT's 65,536-entry limit** (your proposal;
   accepted), with a host test that fills a directory to the limit.
10. **`zig fmt` the three files, then make `zig fmt --check src` part of
    `zig build test`** (your proposal; accepted), so it stays clean.
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

## Box Claude

- v6: gates, images, deploy with Steve, and the survival test (the marker
  message posted on v5).
- The status page and the admin view of the log, once item 6 lands.
- Wiring the restart, once item 7 is agreed.
- Case-insensitive names in angry-gopher (Steve's decision above): prod's
  names checked first, then the change, Linux tests, and judge coverage.
- The migration rehearsal on a copy of prod's data, ending in a
  metal-versus-Linux comparison on that data.
- Measuring on the droplet: big uploads while others browse, clock drift
  against prod.

## Questions

*(CC writes here; the box Claude or Steve answers under Answers.)*

- **`probe/run.sh` fails before any probe on a CPU it was not recorded on.**
  - The judges' self-test compares a recorded `tsc_hz` (2.494 GHz) with the
    host's; a cloud CPU at 2.1 GHz fails it, and run.sh exits there.
  - Should the clock judge's self-test take the rate as a parameter? CLOUD.md
    says run.sh is not CC's to change.
- **`judge_gopher.build_disk` mounts without `tz=UTC`.** On a host not set to
  UTC, every copied file's time shifts, and chat's "recent" with it.
  MIGRATION.md tells the migration to add it. Should build_disk add it too?

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
- **Merging:** items 1-6 are on `master` as your own rebased commits (through
  `018302e`), fast-forwarded after the full gates passed on them. Items 7-10
  (`f2f0f75`..`6c9fb91`) get their own gate run next, with
  `tools/check_fat16_images.sh` and `restart.elf` under KVM; the run on a
  real droplet waits for Steve at the recovery console.
- **`restart.elf` in `probe/run.sh`** (2026-10-02, Steve agreed): yes. Add
  the knob for a run without `-no-reboot`, and say in the commit exactly what
  changed in run.sh; the box runs it before merging.
- **Moving the log ring past `_kernel_end`** (2026-10-02, Steve agreed):
  not yet. It changes the page allocator's view of RAM, so it lands with the
  restart wiring it serves, not before. 64 KiB in `.bss` is fine for now.

## Proposed

*(CC adds items here, one line on why each.)*

- **Raise `fat16.max_name` to 96, or cap session ids and doc slugs at 48 in
  angry-gopher.** The application can make names up to 96 characters
  (`<sid>.reactions.jsonl` at an 80-character sid), and this machine holds 64
  (MIGRATION.md).
- **Fold case for session ids and channel names in angry-gopher.** On FAT,
  `plan` replaces `Plan`, where Linux keeps both (MIGRATION.md).
- **Stop `fat16.zig`'s `grow` at 65,536 directory entries.** It grows past
  FAT's limit today, and `fsck.fat` would then reject the volume.
- **Read the NT case bits (byte 12 of a short entry) in `fat16.zig`'s
  `decode`.** mtools and Windows store `topic.md` as `TOPIC.MD` with "lower
  case" flags and no long name, and this machine lists it upper case
  (`tools/check_fat16_images.sh` shows it). Linux's vfat writes a long name
  instead, so the migration is not affected.
- **`zig fmt` the three files on `master` it flags** (`src/tcp_sim.zig`,
  `src/rtc.zig`, `src/civil.zig`). `zig fmt --check src` fails today, so a
  gate on it would fail before it checked anything new.
