# Review: the restart (item 16) and FAT32 (item 17), as an adversary

QUEUE.md item 18, in REVIEW-interrupts.md's shape; nothing is fixed here.
Both items are CC's own work, so this is read as someone else's would be.

**What was read:**
- `src/restart.zig`, `src/restarting.zig`, `src/reset.zig`,
  `src/kept_log.zig`, `serial.on_fatal`, and the restart's wiring in
  `probe/gopher.zig`;
- `src/fat16.zig`'s FAT32 paths (mount, entries, root chain, FSInfo, the
  cursor, writes), and the tools that make FAT32 volumes.

All of it as on `master` and this branch, 2026-10-02.

**What was run:** one throwaway host test (finding F1), and one
`mkfs.vfat` (finding F2). The rest, R1 included, was found by reading.

## The restart (item 16)

### What holds up

- **The record cannot be invented by chance.** CMOS that powered up holding
  zeros, 0xFF or anything else reads as no record: the magic, a rotating
  checksum that a run of equal bytes fails, and a count of zero are all
  refused. The test throws 10,000 random records at it.
- **The kept log is checked, not trusted.** A header needs its magic, a
  checksum, and a head and count that fit the slot. The slots alternate, so
  a boot never writes over the log it is there to explain. An unsealed
  slot is cleared at boot, so a hang never shows an older log as the last.
- **It is armed late and placed safely.** The restart is armed only at
  `serving()`, just before the main loop: a failure at boot still halts
  with its reason, which is right for a refused volume. Its state is in
  `.data`, the kept region is reserved from the page allocator, and the
  whole thing is off unless built with `-Drestart=true`.
- **Every way to reset is tried.** The reset control register, then the
  keyboard controller, then a triple fault, which cannot fail to happen.

### R1. The restart logs before it records, so a fault while logging loses the back-off (medium-low)

**Where:** `restarting.fatal` does, in order:
1. `serial.put` the reason (the port, the screen, the ring);
2. `seal` the kept log;
3. read the clock;
4. only then write the CMOS record.

**The problem:** the back-off exists for a crash loop. If the failure being
handled is in the output path (the screen driver, the ring, the serial
port), step 1 faults again. With interrupts off and the handlers in place,
that becomes a triple fault: a reset, before step 4. The machine restarts
with no record, so the count never grows and the back-off never starts. A
loop that crashes in its own logging then restarts at full speed forever,
which is the case the back-off was built for. The same happens if the
clock read in step 3 faults.

**How likely:** low. It needs a fault in the output or clock path while
serving, but those are exactly the paths a failure report goes through.

**Fix shape:** write the CMOS record first, with the time taken as cheaply
as possible (or as unknown, which only ever waits longer), then log, then
seal.

### R2. NMIs stay masked on a real chipset (low; mostly pre-dating item 16)

**Where:** `rtc.zig`'s `readReg` and `restarting.cmosRead`/`cmosWrite`
write port 0x70 with bit 7 set, and nothing ever writes it clear.

**The problem:** on a real chipset, bit 7 of port 0x70 masks NMIs until it
is written clear. After the first RTC read at boot, NMIs are masked for the
whole uptime. QEMU's chipsets do not model the mask, which is why NMIs
still arrive and are counted on `/admin/host`.

**How likely:** no effect on DigitalOcean's KVM as far as is known. It
matters only on hardware.

**Fix shape:** after the last access, write the index once with bit 7
clear, in both places.

### R3. Not yet measured where it counts (information)

Item 16's rule holds: no deployed image restarts until the box has measured,
on a real droplet, that a guest's reset restarts it rather than powering it
off. Three more things to look at in that same session, all measured only
under QEMU:
- whether RAM past the kernel survives DigitalOcean's restart (the kept
  log);
- whether CMOS survives it (the record);
- whether a power cycle from DigitalOcean's console clears CMOS. If it does
  not, a record left by the last image makes a new one wait when it comes
  up within the hour.

### R4. While it waits, the site is down (information)

**Where:** `begin`'s back-off runs before anything listens.

**What happens:** after the fourth restart in an hour, Caddy answers 502
for 1, then 5, then 15 minutes at a time. That is the design: "never a
halt", and a crash loop must not spin. But with a crash any visitor can
trigger, the site is mostly down until someone fixes it. The first-day
watch in CUTOVER.md is how someone notices.

## FAT32 (item 17)

### What holds up

- **The kind is decided as the spec decides it, by cluster count**, and a
  volume whose fields disagree with its count is refused at mount. A
  FAT16-by-count volume with no root entries, or a FAT32 one with a 16-bit
  FAT size or a root directory count, is `BadBootSector`. F2's 1 GiB volume
  is refused, not misread.
- **Volumes this machine cannot write safely are refused**, each with its
  own error: FAT mirroring off, a FAT32 version other than 0, a root
  cluster outside the data, a volume past 2^32 sectors.
- **Entries keep their reserved top four bits.** FSInfo's free count and
  hint are marked unknown in both copies on the first write, so nothing
  this machine does leaves them wrong.
- **The root is a chain and grows**, and a first-level folder's `..` is
  cluster 0 as the spec requires.
- **Judged against the oracle.** It agrees with the reader written from the
  spec, and with fsck, on 103 images and 19 mtools volumes. It served the
  chat judge from FAT32 under TCG with clean results.

### F1. An append to a file within a cluster of 4 GiB panics (medium)

**Where:** `fat16.writeInto`:
- `have = (old_size + cluster_bytes - 1) / cluster_bytes`, and the same
  for `need`, in `u32`. The check before them (`reach > 0xFFFF_FFFF` →
  `TooBig`) does not stop it.
- `writeFileIn`'s `@intCast(bytes.len)`.

**The problem:** rounding a size up to whole clusters adds up to a cluster
less one byte. For a file whose size is within one cluster of 4 GiB, that
overflows. Run here, with a file whose entry says 4 GiB less 100 bytes:
an append of four bytes **panics with "integer overflow"**, where it should
answer `TooBig`. gopher.elf is built ReleaseSafe, so a panic ends the
machine: a halt, or, with the restart on, a restart.

**How likely:** reachable only with a file that big, but nothing caps one.
A game session's `actions.dsl` grows with every append, at 64 KB a request
(GROWTH-game-store.md: about 130 MB/s on loopback). After the cutover the
game's data is on the volume, so on a FAT32 volume of 5 GiB or more one
client can bring a file to the edge and then stop the machine. FAT16 is
safe here: 2 GiB holds no 4 GiB file.

**Fix shape:**
- Round in `u64` and refuse past 4 GiB with `TooBig`, in `writeInto` and
  `writeFileIn`.
- A host test of exactly this: an entry's size set near 4 GiB, as run
  here.
- The application-side cap from GROWTH-game-store.md bounds it as well.

### F2. `build_volume.py --fat 32` makes volumes this machine refuses (low)

**Where:** `droplet/build_volume.py`. `new_volume.py` requires
`--gib 3` or more for FAT32; `build_volume.py` does not.

**The problem:** `mkfs.vfat -F 32 -s 64` makes a 1 GiB volume without a
word (exit 0, tried here), with 32,768 clusters. Linux calls it FAT32,
because its 16-bit FAT size is zero. The spec, and this machine, count its
clusters and call it FAT16, so the mount refuses it (`BadBootSector`). The
build's own judge then fails, but its findings (every file "missing") do not
say why.

**How likely:** only with `--gib 1` or `2`. The cutover plans 16.

**Fix shape:** `build_volume.py` refuses FAT32 below the size that gives
65,525 clusters at its cluster size (3 GiB at 32 KiB), as `new_volume.py`
does, and says so.

### F3. Nothing tells the operator the FAT budget is near (information)

`gopher.zig`'s `fat_budget_bytes` (32 MiB) refuses a FAT larger than it
can hold in memory. That is 64 GiB of volume at 32 KiB clusters. A volume
grown in the DigitalOcean console past that would be refused at the next
boot, a halt with its reason. Nothing warns before the grow. CUTOVER.md
plans 16 GiB. The reason belongs in MIGRATION.md's "Which FAT" next to the
number.

## Summary

1. **Fix F1 first.** It is a remote crash once the game's data is on a
   FAT32 volume, and the fix is a widened sum plus a test.
2. **Then R1:** record before reporting, so the back-off holds for the
   very failures it is meant for.
3. **F2 is one check in a script.** R2 is a one-line write in two places.
4. **R3 and R4** are for the droplet session and the first-day watch, which
   are already planned.
