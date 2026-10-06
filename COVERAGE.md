# Coverage properties

`always` and `sometimes` properties of a whole run, from
[zig-coverage-sdk](https://github.com/showell/zig-coverage-sdk). Its README
covers the API, the catalog, and where it differs from Antithesis. This file
covers what gopher-metal does with it. Started 2026-10-05.

**The SDK is a path dependency** (`build.zig.zon`) on a sibling checkout,
`../zig-coverage-sdk`. Its scanner reads `tcp.zig` and `tcp_sim.zig`, so their
properties are in the catalog even in code a program never calls; every module
that compiles either imports `"coverage"` and `"coverage_catalog"`.

## Decisions

- **A FAIL fails every tier.** A FAIL is a broken `always`, or an
  `unreachable` that was reached. **A MISS** (a property the run never got
  to) **fails only the long tier, and only for a property on its floor**
  (`coverage/`). Antithesis treats the two alike; we don't, on purpose
  (the SDK's README).
- **Three tiers, one set of properties.** `zig build test` runs eight
  plain and eight rough TCP seeds and eight FAT seeds; `zig build
  properties` 100 of each kind of TCP seed, 20 FAT seeds and the FAT
  regression seeds, in about a minute; `./long.sh` 10,000 TCP and 300 FAT
  seeds and the real kernel's lossy sweep, in about ten. Each reads the same
  properties with a bigger budget.
- **Debug for test code** (Steve, 2026-10-05): it builds in a fraction of
  the time. A sweep is nearly all running, about three times slower in
  Debug, so `long.sh` builds its with `-Dsweep-optimize=ReleaseSafe`.
  Shipping kernels are ReleaseSafe, as they always were.
- **QEMU stays mostly on the happy path.** The judge checks that metal
  answers as Linux does, on a clean network. **The budget for covering
  every scenario goes to metal-vmm**, where every frame, disk request and
  clock tick is ours to choose and a run repeats exactly. On Linux the
  same work is done by `tcp_sim.zig`.
- **Nothing deployed writes the lines.** `-Dcoverage` is off by default:
  the declarations alone would fill the log ring `/admin/host` shows. The
  counters are still kept, at the cost of one add per site reached.

## Running it

**On Linux, against the TCP and FAT simulators** (`src/properties.zig`):

    zig build properties                 # 100 TCP seeds, plain and rough; 20 FAT
    zig build properties -Dseeds=5000 -Dfat-seeds=300 -Dsweep-optimize=ReleaseSafe
    zig build properties -Dsdk-jsonl=out/sdk.jsonl

A seed whose oracle fails is a false `always` with its seed in the details,
and the sweep goes on. Only a FAIL fails the step. (zig's build runner prints
"failed command" for any test that writes to stderr, so read the summary
line instead.)

**On metal:**

    zig build gopher -Dcoverage
    COVERAGE_OUTPUT_DIR=out probe/run.sh gopher uploads
    ../zig-coverage-sdk/tools/report.py out/sdk.jsonl

The kernel writes each line to the serial port behind `coverage: `: the port
only, not the log ring. The judge appends every boot's lines to
`$COVERAGE_OUTPUT_DIR/sdk.jsonl`. `tools/coverage_jsonl.sh` does the same for
any serial log, such as a droplet's.

**The long tier, for bug hunting and before a deploy:**

    ./long.sh              # about 10 minutes
    SEEDS=50000 ./long.sh
    ./long.sh sim | metal  # one half

- **The simulators** (ReleaseSafe): 10,000 TCP seeds, plain and rough, and
  300 FAT seeds, against `coverage/floor-sim.txt` (`zig build properties
  -Dfloor=...`).
- **The real kernel**, gopher.elf built `-Dcoverage`, on metal-vmm's
  PC-shaped machine (`TRANSPORT=pci`: halting between frames and woken by
  interrupts, as on a droplet), over a 5 ms wire. For each of three routes
  the wire eats the guest's 1st frame, then its 2nd, through every frame the
  route sends, one deterministic run each, and **every run must still serve
  the page an unhurt run serves.** The runs' properties are judged against
  `coverage/floor-metal.txt` by the SDK's `tools/report.py --floor`.

A floor line naming no property fails too: a floor goes stale loudly.

## What the runs have said

There are 18 properties in `tcp.zig` (retransmission, probing, window
updates, resets, RTO bounds), and a few in `tcp_sim.zig` that confirm its
scenarios actually happened. There has been no FAIL anywhere.

**On day one, 500 plain seeds never reached four of the table's paths:**
- an exact reset closing a connection;
- an inexact in-window reset drawing a challenge ACK;
- giving up on a silent peer;
- a stuck half-open connection giving way to a new SYN.

Each had a unit test in `tcp_test.zig`, but none was ever run under loss
and reordering. The simulator's client reset only when it gave up itself,
and nothing ever competed for the table's two slots.

**So `tcp_sim.zig` has rough seeds** (`Rough`, `runRoughSeed`). A rough
seed is a plain seed whose peer, each by its own chance:
- resets mid-exchange, either exactly or off by up to 2000 (and so is
  challenged), then answers as a closed port;
- vanishes part-way through the answer;
- or floods the table with SYNs from addresses that never finish.

A second random generator, derived from the seed, makes those choices. So a
plain seed runs exactly as it did before, and its regression seeds still
reproduce. The give-up oracle now counts only the client's own connection:
under a flood, the table is right to give up on the spoofed ones.

**After that:** 5,000 seeds, each run plain and rough, took about a minute.
Every oracle held and every property was reached. In the first 500 rough
runs, the table alone gave up on a client that had left 45 times, and all 60
clients that stayed through a flood got their whole answer.
`zig build test` runs rough seeds 1–8 alongside the plain ones.

One judge gate on metal (`uploads`, under QEMU) reached 3 of the 18
properties, as expected on a clean network.

**The first lossy sweep of the real kernel** (2026-10-05): `/` in 32 frames,
`/steve-resume.pdf` in 57, `/login/full` in 11. Each frame was lost in turn,
100 runs, and every one served the same page. It reached 6 of the 18: the
table's recovery from its own losses (a lost SYN-ACK, the timer going back,
three duplicate ACKs resending at once, the RTO bounds). The rest need the
PEER to misbehave (reset, flood, stop reading, lose what it sends), which
metal-vmm's peer cannot yet do: its QUEUE.md item 7. Until then the
simulator's floor holds them.

## Next

- The last three of tcp.zig's eighteen on the real kernel: a peer sending
  past the window, a segment from behind (both wait on metal-vmm's QUEUE.md
  item 39), and a reopened window announced again (a large upload, the
  box's). The metal floor holds the other fifteen.
- Properties in FAT (`fat16.zig`), the page cache, and restart.
- An explorer: metal-vmm choosing faults, scored by which properties a run
  reaches. That's the long-term aim, and it isn't urgent.

## The floor, module by module

*(metal-vmm QUEUE items 76, 78 and 80: every refusal named with a
`reachable`, every invariant with an `always`, and each one reached by a
simulator or a host test, so a report says which any run has met. "Reached
by" names what reaches it in `zig build properties`; "under metal-vmm" means
only a real device reaches it, so it is off `floor-sim.txt` and listed
under "For the box" below.)*

| module | properties | reached | by what | errors it answers |
|---|---|---|---|---|
| `durable` | 4 | 4 | `durable_sim` | none: `step` and `settle` decide, and a failed synchronize is the caller's status byte |
| `gpt` | 8 | 8 | `floor_sim` (GPT built field by field, one field wrong) | `ReadFailed`, `NotGpt`, `NoPartition` |
| `page_cache` | 16 (one `unreachable`: room is always found for a file within the budget) | 15 | `page_sim`; `floor_sim` for every slot taken, a write past a copy's end, and no memory to grow one | none: it answers a copy or nothing, and refuses by not keeping |
| `virtio` (`Block.flush`) | 1 | 0 here | under metal-vmm | a SCSI status, as a virtio-blk status byte |
| `io` (`durable`) | 1 | 0 here | under metal-vmm | none: a failed flush is logged, counted, and the response goes out |

## For the box

Properties that only a real device reaches. Each one's knob, for a
metal-vmm run in `long.sh`; once a run reaches it, it goes on
`floor-metal.txt`. A refusal with no knob says so: that is a proposal for one.

| property | module | knob |
|---|---|---|
| virtio: a flush fails, is counted, and the disk stays unflushed | `virtio.zig` | `VOLUME=<copy> VOLUME_CACHE=1 VOLUME_SYNC_FAIL=1`, and a chat post |
| io: a flush failed, and the response goes out anyway | `io.zig` | the same, for the volume. **No knob fails a flush of the boot disk**: it is virtio-blk and writes through (virtio 1.2 §5.2.5.1), so nothing is sent; a knob would need metal-vmm's `DISK_CACHE` to offer FLUSH and fail it (a proposal) |
