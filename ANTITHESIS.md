# Test properties, the Antithesis way

A proof of concept (2026-10-05): the **assertion** half of Antithesis's SDK
(https://antithesis.com/docs/properties_assertions/), in Zig, cribbed from
their Go and Rust SDKs, aimed at the metal layer first. No randomness, no
lifecycle calls, no guidance assertions yet.

## What it is

`src/antithesis.zig`. An assertion is a property of the whole run, not a
check that stops it:

| call | holds when |
|---|---|
| `always(@src(), cond, "msg", details)` | reached, and true every time |
| `alwaysOrUnreachable(...)` | true every time it is reached, if ever |
| `sometimes(@src(), cond, "msg", details)` | true at least once |
| `reachable(@src(), "msg", details)` | reached at least once |
| `@"unreachable"(@src(), "msg", details)` | never reached |

`details` is anything `std.json` can write, or `null`. The message is the
property's name and id, and must be comptime.

**The catalog.** Every call site is known before it runs, so a `sometimes`
that never ran is reported as failing — the point of the thing. As in Rust's
SDK (linkme), each site is a static in a linker section,
`antithesis_catalog`, bounded by `__start_`/`__stop_`. Three things found
getting there, each now commented where it lives:

- zig's own linker (Debug) leaves slack between statics, with old bytes in
  it, so the section is not an array: each Site is 64 bytes, aligned and
  tagged, and the walk takes only what carries the tag;
- ReleaseSafe's optimizer drops a site whose branch it proves dead — the one
  most worth reporting — unless the site is exported (hidden, unique name);
- a site is in the catalog when its function is *compiled*, and Zig compiles
  only what is referenced: an unreferenced function's assertions are absent.

**The wire** is Antithesis's own JSONL, as both SDKs write it: an
`antithesis_sdk` line and every site's declaration on the first event, then
the first pass and the first failure of each site. It goes to `sink`, a
function pointer; none is set by default, and the counters alone still
answer `report`.

## Running it

**On Linux, against the TCP simulator** (`src/tcp_properties.zig`):

    zig build properties                 # seeds 1..500, ~25 s cold, ~1 s warm
    zig build properties -Dseeds=5000
    zig build properties -Dsdk-jsonl=out/sdk.jsonl

Each seed is `tcp_sim.zig`'s run; a seed whose oracle fails is a false
`always` with its seed in the details, and the sweep goes on.

**On metal** (`-Dantithesis`, off by default and in anything deployed):

    zig build gopher -Dantithesis
    ANTITHESIS_OUTPUT_DIR=out probe/run.sh gopher uploads
    tools/antithesis_report.py out/sdk.jsonl

The kernel writes each line to the serial port behind `antithesis: ` — the
port only, not the ring `/admin/host` shows. The judge appends every boot's
lines to `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl`; `tools/antithesis_jsonl.sh`
does the same for any serial log (a droplet's).

**Reading a report.** `FAIL` is a property broken: an `always` seen false, an
`unreachable` reached. `MISS` is one never got to: a `sometimes` never true,
a `reachable` or an `always` never reached. Antithesis fails both; here only
a FAIL fails the step, because a MISS says the runs were short of the case,
not that the code is wrong.

## What the runs have said

18 properties in `tcp.zig` (retransmission, probing, window updates, resets,
RTO bounds), and a few in `tcp_sim.zig` that say its scenarios happened. No
FAIL anywhere.

**Day one: 500 plain seeds never reached four of the table's paths** — an
exact reset closing a connection; an inexact in-window reset drawing a
challenge ACK; giving up on a silent peer; a stuck half-open connection
giving way to a new SYN. Each had a unit test in `tcp_test.zig`, none a run
under loss and reordering: the simulator's client reset only when it gave up
itself, and nothing ever competed for the table's two slots.

**So `tcp_sim.zig` has rough seeds** (`Rough`, `runRoughSeed`): the same
seed, with a peer that, each by its own chance, resets mid-exchange (exactly,
or off by up to 2000 and so challenged) and then answers as a closed port;
vanishes part-way through the answer; or floods the table with SYNs from
addresses that never finish. A second generator chooses them, so a plain
seed runs exactly as before and its regressions still reproduce. The
give-up oracle now counts the client's own connection only, since the
table is right to give up on the flood's.

After that: 5,000 seeds, each plain and rough (about a minute), every oracle
held and every property was reached. The table alone gave up on a client
that left in 45 of the first 500 rough runs; a client that stayed through a
flood got its whole answer every time (60 of them in those 500). `zig build test` runs rough seeds 1–8
beside the plain ones.

One judge gate on metal (`uploads`, QEMU) reached 3 of the 18: a clean
virtual network exercises none of the recovery paths.

## Next, if it earns it

- A lossy run of the real kernel (QEMU, or metal-vmm's `WIRE_EAT`), so the
  recovery paths are reached on the machine, not only in the simulator.
- A long-tier script: thousands of seeds plus a floor list of `sometimes`
  that a pre-deploy run must reach.
- Properties in the rest of the metal layer: FAT (`fat16.zig`: the cached
  and on-disk FAT agree; a write past `data/`/`auth/` never happens), the
  page cache, the request heap, restart.
- The application layer: angry-gopher's server runs on Linux, where the sink
  is a file at `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl`.
- The rest of the SDK, if Antithesis itself is the target: `random` (from the
  hypervisor, so it can steer runs), `setup_complete`, the guidance
  assertions (`always_greater_than`, `sometimes_all`).
