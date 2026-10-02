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
   2026-10-02.)*
   - For moving prod's chat data (about 215 MB, 801 files under `data/` and
     `auth/`) onto FAT16.
   - The checker reads a directory tree and lists everything that would not
     survive the copy.
   - Plain Python, no mounts.
2. **TCP_TESTING.md §10 as a script.** *(handed over 2026-10-02.)* It
   mutates `tcp.zig` one way at a time and reports every mutant the tests and
   `tcp_sim` miss.
3. **An in-memory disk for host tests.** A `virtio.Block` stand-in backed by
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

## Box Claude

- v6: gates, images, deploy with Steve, and the survival test (the marker
  message posted on v5).
- The status page and the admin view of the log, once item 6 lands.
- Wiring the restart, once item 7 is agreed.
- The migration rehearsal on a copy of prod's data, ending in a
  metal-versus-Linux comparison on that data.
- Measuring on the droplet: big uploads while others browse, clock drift
  against prod.

## Questions

*(CC writes here; the box Claude or Steve answers under Answers.)*

## Answers

## Proposed

*(CC adds items here, one line on why each.)*
