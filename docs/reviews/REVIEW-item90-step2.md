# Review: item 90 step 2, as an adversary

This review covers the newest code going live (gopher-metal `2b468f7`,
`4eafdf9`, `a96ff67` on `master`):

- `net.zig`'s transmit ring — `send`, `reclaim`, the `free` list and `lent`;
- `virtio.zig`'s `notifyIfWanted` and `interruptOnCompletion`, and the
  `fence` around them;
- `probe/gopher.zig`'s `consoleTurn` and the 256 KiB serial backlog
  (`serial.zig`);
- `fat16.zig`'s `dir_burst` and the early-stopping `find` (`Lister.load`,
  `current`, `Walk.sectorsLeftInRun`);
- the page cache's `replaced` (write-no-allocate) and its one caller in
  `io.zig`.

Nothing is fixed here (CLOUD.md's "Limits"). It is a reading, not a run;
"would" means the code allows it. The question held over every part was the
one the item asks: **can bytes meant for one connection, or one file, reach
another? Can anything here stall the machine?**

The short of it: the parts above hold up. One Low, defence-in-depth, is in
the findings. The one real open thing — the FAT32 `IncompleteRead` the item
names — I could not reproduce or pin to this diff; what I ruled out, and
where I think it lives, is the last finding, because the item is right that
it matters more than the rest.

## What holds up

These were checked and found sound, so the findings are not about them.

- **The doorbell race (the big one for a lost frame).** `send` →
  `tx.offer(id)` → `tx.notifyIfWanted()`. `offer` ends
  `avail_idx +%= 1; fence();`, and `notifyIfWanted` begins `fence(); flags =
  used_flags`. `fence()` is a real `mfence` (virtio.zig:135), so the store
  that publishes our avail entry is globally visible **before** the load of
  the device's `VIRTQ_USED_F_NO_NOTIFY` flag. x86's one permitted reordering
  (store-then-load to different addresses) is exactly what would let a stale
  "no doorbell needed" be read and a needed notify be skipped — and the
  `mfence` forbids it. This is the split-ring, no-`EVENT_IDX` driver side of
  virtio §2.7.7.2, done correctly. A skipped-but-needed doorbell (which would
  leave a frame sitting unsent and truncate a response) is not possible from
  this path. Same reasoning covers `rx.notifyIfWanted` in `recycle`.

- **Missed completion while the wait arms.** When `free_len == 0`, `send`
  does `interruptOnCompletion(true); reclaim(); while (free_len == 0) { rest();
  reclaim(); }`. The `reclaim()` after arming catches a completion that
  landed before the flag took effect; `rest()` is woken by the next one. A
  completion can be seen twice at most (harmless, below), never lost. This is
  the arm-then-recheck shape REVIEW-interrupts.md's timer and net rests use.

- **A transmit buffer handed out twice, or freed twice.** `free[0..free_len]`
  holds the buffers that are ours; `lent[id]` marks the device's. A buffer
  leaves `free` only in `send` (popped, `lent[id]=true`) and returns only in
  `reclaim`, guarded by `if (e.id >= tx_buffers or !self.lent[e.id])
  continue;`. So a duplicate or out-of-range completion is passed over, never
  pushed to `free` a second time (no `free` overflow), and a buffer still
  `lent` is never refilled by a later `send`. `free` and `lent` are sized
  `tx_buffers`, and at most `tx_buffers` buffers exist, so neither overruns.

- **The frame can't overrun its buffer into the next connection's.** `send`
  does `@memcpy(buf[12..][0..frame.len], frame)` into a 2048-byte buffer with
  no bound of its own — but `frame.len` is bounded upstream: a data segment's
  payload is `@min(..., c.mss)` (tcp.zig:656) and `c.mss` is capped at
  `our_mss` (1460) when the peer's SYN is parsed (`c.mss = @min(parseMss(...)
  orelse default_mss, our_mss)`, tcp.zig:876). So even a peer that advertises
  a huge MSS is held to 1460; the frame is at most `14 + 20 + 20 + 1460 =
  1514 < 2036`. The cap is what makes the `@memcpy` safe; see finding 1 for
  the fact that net.zig does not enforce it itself.

- **The directory burst, read for one lookup, believed for another.**
  `dir_burst` is one buffer on the `Volume`, used only by `find`, which is
  synchronous and single-threaded; each `find` makes a fresh `Lister` with
  `burst_n = 0`, so the first `load` (`lba >= burst_lba(0) and lba <
  burst_lba+burst_n(0)` → false) always reads rather than trusting a prior
  lookup's bytes. A listing the application holds open (`io.zig`'s iterator)
  uses its own `sector`, not `dir_burst`, so the two never cross.

- **The burst index, across a cluster boundary.** `Lister.load` caps the
  burst to `@min(b.len/sector_size, walk.sectorsLeftInRun())`, and
  `sectorsLeftInRun` is `sectors_per_cluster - in_cluster` (or `left_in_root`),
  so a burst never spans from one cluster into the next (non-contiguous) one.
  `load` runs before every `current()` (the `if (!loaded)` block), and
  guarantees `lba ∈ [burst_lba, burst_lba+burst_n)`, so `current`'s
  `b[(walk.lba - burst_lba)*sector_size..]` is always in range. Traced by
  hand on the 3-sector odd burst `test_disk.zig` installs (so a burst ends
  mid-cluster), at every run boundary, it holds.

- **A partially-read burst believed whole.** `readSectors` loops on
  `blk.readMany`, which returns the device's status and so has waited for the
  DMA; it returns an error rather than fewer sectors. `current` never reads a
  sector the device had not finished writing.

- **A cached copy not exactly the disk's (write-no-allocate).**
  `io.zig`'s `writeFile` refuses anything but a whole-file truncating write
  (`@panic` if `!truncate`), so `replaced(sub_path, data)` always gets the
  file's whole new contents — never an append's tail. `replaced` updates the
  kept copy only if the file is already kept (`if (self.find(key) == null)
  return;`), and a failed write calls `c.forget` first, so the cache cannot
  hold a copy the disk does not have. `replaced`'s own unit test pins both
  halves.

- **The console stealing a connection's turns.** `consoleTurn` returns false
  while any connection has `queued() > 0`, so the serial backlog is written
  only when nothing is on the wire (or the backlog is half full, to stay off
  the direct-write path). It gates the debug console alone; it touches no
  connection and carries no response bytes, so it cannot truncate one.

## Findings

### 1. `net.send` trusts, but does not check, that a frame fits its buffer (Low)

**Where:** `net.zig`, `send`:
`@memcpy(buf[@sizeOf(Header)..][0..frame.len], frame)` into
`mem.tx_bufs[id]`, which is `[buffer_size]u8` = 2048.

**The problem:** nothing in `net.zig` bounds `frame.len`. If a frame of more
than `buffer_size - @sizeOf(Header)` (2036) bytes ever reached `send`, the
copy would run off the end of `tx_bufs[id]` into `tx_bufs[id+1]` — a buffer
that may be in flight for, or lent to, another connection. That is the
review's central failure: one connection's bytes landing in another's frame
(and, at `id = 63`, past the array).

**The failure it causes, and how likely:** none today. It is unreachable as
the tree stands, because `c.mss` is capped at `our_mss` (1460) and the
payload is `@min(..., c.mss)`, so `frame.len ≤ 1514`. It is Low because the
safety is **non-local**: it lives in tcp.zig's MSS cap, two files away, and
in the fact that every other caller (ARP, DHCP) sends small frames. A future
change — negotiating a GSO/TSO feature, raising `our_mss`, a new caller — would
reach it with no compiler or test complaint.

**Fix shape:** make `net.zig` enforce its own invariant. Either
`std.debug.assert(@sizeOf(Header) + frame.len <= buffer_size);` at the top of
`send` (a loud stop in Debug, where the gates run), or clamp and drop an
over-size frame rather than overrun. A test that calls `send` with a
`buffer_size`-plus frame and expects the assert (or the drop) fails without
it. Not applied here: changing live `net.zig` the day before the cutover to
guard a path nothing reaches is the wrong trade; the assert is cheap to add
after.

### 2. The FAT32 `IncompleteRead`: not reproduced, and not pinned to this diff — what I ruled out, and where it likely lives (open)

**What it is:** the lost-frame bulk story failed once on FAT32 before passing
8 times in a row — `IncompleteRead`, 2,820 of 4,895 bytes. That is a
**content** truncation: the body ended short of its `Content-Length` and the
connection closed. The item is right that its cause is worth more than
anything above.

**What this review rules out** (the reasoning is under "What holds up"):

- **A skipped doorbell** leaving a segment unsent: the `mfence` in the
  `offer`/`notifyIfWanted` pair forbids the stale-flag read that would cause
  it.
- **A lost or double completion** stranding a transmit buffer: the `lent`
  guard and the arm-then-recheck make both safe.
- **A short or partial file read** feeding a `Content-Length` that the body
  then can't fill: `readSectors`/`readMany` are synchronous, the burst index
  is in range, and the page cache holds only whole-file copies. A `find` that
  returned a wrong entry would fail that file *every* time, not one run in
  nine, so the intermittence argues against the new `dir_burst` too.

**Where it likely lives:** `tcp.zig`'s retransmission or teardown under
injected loss — which is **outside this diff**. The new `send` returns as
soon as it has offered a frame, where the old one blocked until the device
took it; reliability was always tcp.zig's job (it keeps the data and
retransmits on the RTO), and nothing in the ring changes that, but the
timing around it has changed. A body that ends at 2,820/4,895 with the
connection closed is consistent with a FIN/teardown that raced ahead of a
segment still owed — a tcp.zig ordering question, not a net.zig one.

**The probe that would settle it** (for the box, under KVM): when it
reproduces, capture the wire (the recording ring the native judge already
has, or a pcap on the TAP) and read which of three happened — the missing
bytes were **never put on the wire** (a send/flow-control gap), were **sent
and lost and never retransmitted** (an RTO/retransmit gap), or a **FIN/RST
went out with data still unacknowledged** (a teardown-ordering gap). Each
points at a different file; the capture turns nine-runs-of-guessing into one
read. Worth doing before the cutover, since it is the one unknown in the code
going live.

## Summary

The item-90-step-2 code holds up against the "bytes crossing between
connections or files" and "stall the machine" questions: the doorbell is
correctly fenced, the transmit ring's accounting is safe against duplicate
and out-of-range completions, frames are bounded (by tcp.zig's MSS cap, not
by net.zig itself — finding 1), the directory burst is in-range and never
stale across lookups, and write-no-allocate keeps the cache honest. The one
Low is defence-in-depth. The `IncompleteRead` is not in this diff by my
reading; finding 2 says what to capture to prove it.
