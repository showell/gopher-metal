# Review: the boot that printed its first line and stopped

QUEUE.md item 41, in REVIEW-interrupts.md's shape. README, "Known and
open": one boot printed `gopher-metal: angry-gopher's route table, with no
Linux under it` and then nothing for a minute. That was 1 of 27, and has
not been reproduced.

**What was read:** the path from the loader's handoff to that line and the
one after it (`ram: ...`):
- `boot.zig`'s start (the stack painted with one bounded `rep stosq`, long
  mode, the trampoline);
- `kmain`'s first lines, `serial.init`, `screen.attach`;
- `boot.memoryMap` → `pvh.read`, `pvh.largestFree`, `pages.bring` →
  `Pages.init`, and `serial.putPort`.

**What was run:** host tests of the fix; probe/run.sh restart.

## What holds up

**Nothing on that path can wait a minute.** Every loop in it is bounded:
- the stack paint, by the stack's size;
- `screen.attach`'s PCI scan, by the bus;
- `pvh.largestFree` and `totalRam`, by the loader's memory-map entries;
- `Pages.init`, by one `@memset` of the bitmap: 32 KiB for 1 GiB of RAM.

None of them waits for a device. The loader's own waits (BIOS disk reads)
all come before the first line, so they cannot explain a gap after it.

## Findings

### 1. The serial port was given up on for good, and silently (medium: the likeliest cause)

**Where:** `serial.putPort`, before this item:
- each byte waits at most 100,000 reads of the line status register;
- after one such wait, `serial_dead` was set and never cleared;
- nothing said so.

**The problem:** a boot whose port was full for that long, at that moment,
went on running with the screen and the ring, and sent the port nothing
more. A port's reader can be slow to drain it for a moment: QEMU behind a
pipe or file, the judge's reader busy, DigitalOcean's console logger.
Whoever watched the port saw exactly what was reported: the first line,
then nothing, until whatever was waiting gave up after its minute.
- The first line is the first burst after `serial.init` turns the FIFO
  on, so a slow drain bites there first.
- The wait is bounded, but giving up was permanent and unannounced.
- Nothing else on this path fits: by the section above, nothing on it can
  stop for a minute.

**How likely:** rare, and dependent on the host: 1 in 27 is consistent with
it. Whether the stopped boot went on serving was not recorded. If it did,
this is the cause.

**Fix:** the commit after this one, below.

### 2. A loader's memory map is trusted for its length (low)

**Where:** `pvh.read` returns `memmap_entries` entries from the start
info, and `largestFree` and `totalRam` loop over them.

**The problem:** a garbage count, from a loader bug, would make those
loops long, though not endless (a u32 count). Both of this machine's
loaders write the map themselves, and nothing else hands it one.

**Fix shape:** refuse a count over a sane bound (128), with a message, in
`pvh.read`. Left for later: no evidence it happens.

## The fix (commit `serial: a full port is skipped until it drains, then told what it missed`)

`src/serial_gate.zig`, host-tested:
- **A port given up on is tried again.** Each later write starts with one
  status read and no waiting; while the port stays full, the bytes are
  counted.
- **When it drains, the gap is announced first:** `[serial: the port was
  full; N bytes of the log were dropped here]`. Then the write goes on as
  normal.
- **The screen and the ring are untouched:** they always had every byte.

So a reader of the port now sees where the log has a hole and how big it
is, instead of a log that ends.

**What that settles and what it does not:** a boot that stops at the first
line on the port alone, while serving, now shows the note on the port when
it drains. One that stops on the screen too was not this, and would need
the loader's side looked at again.
