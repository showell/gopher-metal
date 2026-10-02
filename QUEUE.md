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

5. **The boot-time disk check, in `fat16.zig`.**
   - At mount, walk the directory tree and report leaked clusters and broken
     chains. Report only: never repair.
   - Host-tested on item 3's disk, with damage made on purpose.
   - The box Claude wires it into the boot log.
6. **The log ring.**
   - A fixed-size ring buffer holding the last N KB of everything
     `serial.put` writes, so a status page can serve it later.
   - Pure code, host-tested. Mind wraparound, and lines longer than the ring.
   - Mind what must never land in it: passwords, cookies, session secrets.
     Read the kernel's log lines and the application's for that.
7. **Design: restart on failure while serving** (`RESTART.md`).
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
- **Merging:** items 1-5 (12 commits) will be merged and gated on the box
  after the status-page gates finish. Items 8-12 are queued above.

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
