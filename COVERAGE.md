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
  to) **is reported, never gated on, until a long tier exists with a list
  of what it must reach.** Antithesis treats the two alike; we don't, on
  purpose (the SDK's README).
- **QEMU stays mostly on the happy path.** The judge checks that metal
  answers as Linux does, on a clean network. **The budget for covering
  every scenario goes to metal-vmm**, where every frame, disk request and
  clock tick is ours to choose and a run repeats exactly. On Linux the
  same work is done by `tcp_sim.zig`.
- **Nothing deployed writes the lines.** `-Dcoverage` is off by default:
  the declarations alone would fill the log ring `/admin/host` shows. The
  counters are still kept, at the cost of one add per site reached.

## Running it

**On Linux, against the TCP simulator** (`src/tcp_properties.zig`):

    zig build properties                 # 500 seeds, each plain and rough
    zig build properties -Dseeds=5000    # about a minute
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

## Next

- **metal-vmm runs today's kernel.** It was built when the kernel took no
  interrupts; since v4 it takes them, at `sti; hlt` only. After that,
  metal-vmm is where the recovery paths get reached on the machine.
- A long-tier script: thousands of seeds, plus a list of `sometimes` that a
  pre-deploy run must reach.
- Properties in FAT (`fat16.zig`), the page cache, and restart.
- An explorer: metal-vmm choosing faults, scored by which properties a run
  reaches. That's the long-term aim, and it isn't urgent.
