# gopher-metal

angry-gopher's server (chat, and the apps it serves: Lyn Rummy, Seattle
Delivery, Safari and the rest) on a machine with no operating system under it.

Everything here targets `x86_64-freestanding`: no kernel, no libc, no syscalls.
A kernel is one root file over `src/`, linked with a script that puts a PVH
note at the front. Tests boot it on QEMU's `microvm` machine, on metal-vmm,
and on a QEMU laid out like a DigitalOcean droplet; for real, it boots on a
droplet through our own BIOS loader.

## Start here

**Serving (2026-10-06): the tag `v18`** — gopher-metal `f592d4d` with
angry-gopher `7e3fbc5e` — at **https://lynrummy.com**, the whole site, on a
droplet with no Linux on it, with prod's real data, since the cutover of
2026-10-04 ([`CUTOVER.md`](CUTOVER.md)). `v17` (`4953f7e`) is the way back.
What serves is a tag, not a branch: `master` may be ahead of it.

**Branches and tags:**
- `master` — everything.
- `v17`, `v18`, … — released images, one tag per release; the newest serves. `antithesis-sdk`
  and `box/v18` are merged and retired.
- `claude/*` — a cloud session's work; the box merges it into `master`, and a
  cloud session never pushes `master` or a tag.

**Live work is in metal-vmm's [`QUEUE.md`](https://github.com/showell/metal-vmm/blob/master/QUEUE.md)**
on `master`: one queue for all four repos, with the cloud session's charter
beside it in `CLOUD_WORK.md`. This repo's own queue is retired
(`git show 3cd662c:QUEUE.md`) and its item numbers collide with metal-vmm's,
so this README says "metal-vmm QUEUE item N" for a live item and "the retired
gopher-metal queue, item N" for an old one. In code comments and commits, a
live item says "metal-vmm"; a bare "QUEUE.md item N" is the retired queue's.

**What needs what:**
- **QEMU and KVM** (the dev box): `./gates.sh`, `./long.sh`, `probe/run.sh`,
  every judge, `droplet/*.sh`, and metal-vmm.
- **zig and python only** (anywhere, a cloud session included): `zig build
  test`, `zig build properties`, `zig build kernels`, and the simulators.
- **Every build** needs `zig-coverage-sdk` checked out beside this repo
  (`build.zig.zon`: `.path = "../zig-coverage-sdk"`).

**The repos:** four, and they stay separate.
- **zig-coverage-sdk** — `always`/`sometimes` coverage properties
  ([`COVERAGE.md`](COVERAGE.md)); a required sibling checkout.
- **metal-vmm** — test-only: our own deterministic KVM hypervisor, which
  `gates.sh` and `long.sh` run (`METAL_VMM`); and the live queue.
- **gopher-metal** (this repo) — the machine: the kernel, drivers, FAT,
  TCP, the boot loader, the droplet tools, and the gates that judge metal
  against angry-gopher's Linux build.
- **angry-gopher** — the program: every route and app, written and tested
  on Linux. `port.sh` reads its `zig-server/src` from a sibling checkout
  (`GOPHER_SRC`) and swaps `std.Io` for this repo's `metal.io`.

A release is a new boot image from this repo carrying both repos' commits
("A deploy", below). prod's old Linux droplet runs only Caddy, which
proxies to metal, and the watchdog; its own server is stopped.

**What `v18` changed:** no response leaves before the writes ahead of it are
durable (SYNCHRONIZE CACHE on the volume when it says it caches; the cache
and the flush counts on `/admin/host`), SCSI's target and LUN read at the
spec's offsets, and the release rule as a script (`tools/verdicts.py`). On
metal-vmm, with the power cut after a chat post's 303
(`VOLUME_CUT_AT_EXIT`), v17 loses the message and v18 keeps it (metal-vmm
QUEUE item B14).

**Open (2026-10-06):**
- **Backups are not set up.** The plan, agreed with Steve, is in
  `CUTOVER.md` "Backups, after the cutover": a DigitalOcean volume snapshot
  every day at 20:00 UTC by a `doctl` cron on the dev box (it needs an API
  token from Steve), and the encrypted tar by hand with `droplet/backup.sh`
  on prod. Until then, chat's only copies are the live volume and prod's
  frozen pre-cutover data. v18 shipped without a volume snapshot (Steve's
  call).
- v19: the flush decision pulled out and simulated (`durable.zig`, metal-vmm
  QUEUE item 59), on the cloud session's branch, not yet merged.

**Files to read, in order:**
1. this README — what metal is, how it is built and tested, and where it
   stands.
2. [`CUTOVER.md`](CUTOVER.md) — the record of the cutover, and the
   last-resort way back to Linux. Restarting prod's Linux server loses
   everything written on metal since the cutover; the normal way back is the
   previous image.
3. `docs/` — the design, by topic ("The design", at the end).

**Who works on it:** Claude on the dev box, with Steve. A cloud session
works here on the simulators, the properties and the Store (metal-vmm QUEUE
items 76-81), through metal-vmm's `QUEUE.md` and `CLOUD_WORK.md`; see
[`CLAUDE.md`](CLAUDE.md).

## Where it runs: https://lynrummy.com

- **What:** angry-gopher's whole route table, so chat and every app
  (Lyn Rummy, Seattle Delivery, Safari, puzzles, chess). Steve's decision,
  2026-10-01: the apps are served from metal along with chat, not split off.
- **Where:** a droplet in nyc2, booted from a custom image, with
  no Linux on it. It listens on its **private** network card only
  (10.100.0.4). prod's Caddy (the old Linux droplet) proxies lynrummy.com to
  it (angry-gopher's `deploy/Caddyfile`), so TLS, certificates and HTTP/2
  stay on Linux; metal speaks plain HTTP/1.1 and does not answer on its
  public address.
- **Its data is on a DigitalOcean volume** (FAT32, 16 GiB, nyc2): chat's
  data (`data/`, `auth/`) on the volume, which a new image does not touch
  (`src/scsi.zig`), and the site's own files (`pages/`, `gallery/`,
  `gopher-metal.conf`) on the boot disk, where each new image updates them.
  The kernel mounts both and sends each path to one by its first directory
  (`src/io.zig`); it refuses, and logs, any write outside `data/` and
  `auth/`. **It serves one volume by name:** the boot image's
  `gopher-metal.conf` names the FAT serial `blkid` shows
  (`droplet/volume-serial`), and the machine stops rather than serve with
  that volume missing or another one attached, either of which would answer
  as an empty site and lose what was written. A path with `.` or `..` is
  refused. The volume was built from prod's data at the cutover
  (`droplet/build_volume.py`) and written from DigitalOcean's recovery
  console; a new image leaves it as it is.
- **Each boot checks both disks** before serving (the retired gopher-metal
  queue, item 13): files, folders, clusters in use, leaked clusters and
  problems, one line per disk in the log. A damaged disk is served from and
  reported, not refused.
- **How to see it:** `/admin/host` (admin login) shows the running server,
  the same page on Linux and on metal. Its first half is the application's
  (version, angry-gopher's commit, base heap, refused requests), and its
  second half is the host's own account of itself. On metal that covers:
  - this repo's commit, the boot time, uptime and clock;
  - requests, connections and streams;
  - memory, both disks' serials, free space and write caches;
  - disk work and NMIs;
  - **the log:** the newest 60 lines of the serial ring, with secrets taken
    out as they were written (the retired gopher-metal queue, item 32).
    Linux's page says it keeps no log to show yet.

  Each host hands its half over through angry-gopher's `host_status.provide`.

How fast, measured before the cutover (the same pages from both sites,
alternating, 40 rounds; first byte, median / 90th percentile; 2026-10-01, v4:
interrupts and the idle halt):

| | lynrummy.com | metal, through Caddy | Linux alone, on prod | metal alone, from prod |
|---|---|---|---|---|
| home page | 2.95 / 3.55 ms | 4.14 / 7.53 ms | 0.55 / 0.63 ms | 1.27 / 2.37 ms |
| a gallery picture | 2.72 / 3.31 ms | 4.12 / 5.27 ms | 0.28 / 0.38 ms | 1.23 / 1.66 ms |
| /delivery | 2.56 / 2.96 ms | 2.77 / 3.40 ms | 0.20 / 0.30 ms | 0.31 / 0.50 ms |
| /game (a redirect) | 2.52 / 3.20 ms | 2.75 / 3.43 ms | 0.23 / 0.29 ms | 0.30 / 0.50 ms |

Pages that need no file were within about 0.1 ms of Linux, at the median and
in the slow tenth. Pages read from files were about 1 ms slower. That run
predates the page cache (`src/page_cache.zig`) and the site cache
(`io.zig`'s `SiteCache`), which keep files in memory after their first read;
it has not been repeated since, so whether the gap remains is not measured.
One run, on one evening: DigitalOcean's neighbours vary.

## A deploy

By hand, in this order:

0. **Both gates pass for the pair.** `./port.sh`, then `./gates.sh` and
   `./long.sh` on the dev box; each records its verdict for the exact
   gopher-metal / angry-gopher commit pair it judged (`tools/verdicts.py`).
   `droplet/chat.py` refuses to build unless both trees are clean and both
   verdicts are PASS for that pair. `RELEASE_UNGATED=1` overrides it, for an
   emergency fix, and says so loudly.
1. `droplet/chat.py <out.img>` builds the boot disk: the loader,
   `probe/gopher.elf`, and the site's own files in partition 2, with a
   `gopher-metal.conf` naming the volume in `droplet/volume-serial`.
2. gzip it, and serve it somewhere DigitalOcean can fetch it.
3. Steve imports it as a custom image and rebuilds the droplet from it. The
   volume stays attached and is not touched.

A released commit is tagged `vN`; the way back is the previous tag's image.

**A new, empty volume** is once, by hand (the cutover's volume was built
from prod's data instead, CUTOVER.md step 4): `droplet/new_volume.py
<out.img>` builds the image and prints its serial; write it onto the volume
from the recovery console (the command is in the script); put the serial in
`droplet/volume-serial`; then deploy as above.

**The cutover's tools**, all without root (the full list is in
[`CUTOVER.md`](CUTOVER.md), with MIGRATION.md, FAT32.md, RESTART.md,
SECRET-LEAK.md and ADMIN-PASSWORD-LOST.md and when each is needed):
- `droplet/check_volume_tree.py` checks a copy of the data, and
  `build_volume.py` builds the volume;
- `compare_volume.py` compares a volume with its copy;
- `compare_hosts.py` compares two hosts page by page, with `--writes`;
- `extract_volume.py` turns a volume back into a Linux tree;
- `drift.py` compares two hosts' clocks, and `load.py` measures uploads
  while others browse.

**Known and open:**

- one boot here printed its first line and then nothing for a minute (1 of
  27, not reproduced since). [`REVIEW-first-line.md`](docs/reviews/REVIEW-first-line.md)
  finds nothing on that path that can wait. The likeliest cause was the
  serial port being given up on for good, silently, after one slow drain.
  A port given up on is now tried again on each write, and told how much
  of the log it missed when it drains.
- **The restart on failure is built but off** (`-Drestart`, RESTART.md).
  It waits on one measurement on a real droplet: that a guest's reset
  restarts it rather than powering it off (droplet/RESTART-TEST.md, the
  console test). Until then, a failure while serving halts the machine with
  its reason on the screen.

## Where it stands

| | |
|---|---|
| the boot | **works** — PVH, long mode, identity-mapped low 4 GB |
| a droplet's boot | **works** — `droplet/loader.S`, our own BIOS loader, from a GPT disk (`droplet/image.zig`); checked on the droplet-shaped QEMU by `droplet/boot.sh` and on real droplets |
| the screen | **works** — everything the console says is also in VGA text, which is what DigitalOcean's console shows (`droplet/screen.sh`) |
| interrupts, and resting when idle | **works on PCI** — the card wakes the machine by MSI-X, the APIC timer at 1 ms otherwise: on a droplet, the droplet-shaped QEMU, and metal-vmm's `TRANSPORT=pci` machine (`rest.sh` in gates.sh, the lossy sweep in long.sh). On virtio-mmio (microvm, metal-vmm's default machine) it spins. On the droplet it took the slow tenth of requests from 3-5 ms to 0.5 ms |
| virtio-blk over MMIO | **works** — reads, writes, and reads back |
| virtio-net over MMIO | **works** |
| virtio over PCI | **works** — disk and network found on a PC's bus, as a droplet has them |
| a DigitalOcean volume (virtio-SCSI) | **works** — found at any target and LUN; the chat judge keeps chat's data on one on the droplet-shaped QEMU and matches Linux; on a test droplet's real volume since v5 (FAT16), and prod's since the cutover (FAT32) |
| DHCP | **works** — from QEMU's server and DigitalOcean's, asking again with RFC 2131's backoff |
| ARP | **works** — answers, which is what makes the address reachable |
| TCP | **works** — 256 connections; the peer's window and segment size respected, lost segments sent again, silent peers given up on; received in order only |
| HTTP, ours | **works** — `curl` gets a 200 from it |
| **`std.http.Server`, unmodified** | **works** — [docs/port.md](docs/port.md) |
| GPT and FAT16, read side | **works** — volumes from `mkfs.vfat`, and from the FAT spec (`src/test_disk.zig`) |
| FAT16 write | **works** — `fsck.vfat` and Linux read back what we wrote |
| long names and subdirectories | **works** — `fsck.vfat` finds no error |
| the backup story, both ways | **works** — Linux mounts it; we read what Linux wrote |
| entropy | **works** — virtio-rng and RDRAND, mixed |
| FAT16 append, replace, delete, delete-tree | **works** — `fsck.vfat` and Linux judge; fragmented directories forced on purpose |
| `Io.Dir` | **works** — [docs/port.md](docs/port.md), "The seam we first got wrong" |
| the TSC's rate | **works** — measured against the PIT, 0.001% from the host kernel's own figure |
| the wall clock | **works** — the CMOS RTC, anchored at a seconds edge; pinned leap-day, noon and 4 PM boots |
| **angry-gopher's whole route table** | **works** — single requests and stories (members 40 steps, uids 10, caps 71, Lyn Rummy 17), each answered the same as the Linux build over the same files |
| many requests per boot | **works** — stories of up to 71 steps and 300 requests to one boot, judged against Linux; heaps steady |
| many connections, one loop | **works** — a request is served once the whole of it has arrived |
| chat's live streams | **works** — held by the loop, pinged, budgeted, and ended when their tab leaves or stops reading |
| uploads | **works** — a picture stored on the volume and read back byte for byte, judged against Linux; the request heap grows past what it keeps |
| the disk check at boot | **works** — both disks, every boot, judged by the oracle's count; a leaked cluster is reported and the disk still served |
| FAT32 | **works** — mount, read, write, root chain, FSInfo; agrees with the oracle and fsck on 103 images and 19 mtools volumes; the chat judges in gates.sh run on it; prod's volume is FAT32 ([FAT32.md](FAT32.md)) |
| a rewrite that survives a stop | **works on the host** — `fat16.rename` and the Store's `replace`: the disk stopped after every request in turn leaves the old record or the new, whole |
| restarting on failure | **built, off** — CMOS record, back-off, the last boot's log kept past the kernel; measured on QEMU's pc and microvm. Waits on a real droplet |
| the kept free count | **works** — `/admin/host`'s free space is a field read, equal to the oracle's count after every operation |
| `/admin/backup` | **works against Linux** — everything the Store keeps as one streamed tar, after the admin's password again, ending with a manifest that `droplet/check_backup.py` holds it to; the judge compares both hosts' archives member by member. Taken from metal over the private network by `droplet/backup.sh` (CUTOVER.md); routine backups are not set up (above) |
| the log on `/admin/host` | **built** — the serial ring's newest lines; the judge checks its shape |

## Running the gates

    ./gates.sh quick       # one commit: host tests, the kernels, the probes, one chat-judge story (~2 min)   [QEMU/KVM]
    ./gates.sh             # a batch, and before merging anything that touches the kernel                  [QEMU/KVM]
    ./long.sh              # bug hunting, and before every release (~10 min)                               [QEMU/KVM]
    zig build test         # host unit tests for the pure parts of src/, and short simulator runs          [anywhere]
    zig build properties   # the coverage properties over many simulator seeds (~1 min)                    [anywhere]

**What each gate is for** (their headers say it in full):
- `./gates.sh quick` is for a single commit. `./gates.sh` is the full run,
  for a batch: host tests, every probe, the chat judge on FAT32 on microvm
  and on the droplet-shaped machine side by side, the droplet boot checks,
  and metal-vmm's `check.sh`, `same.sh` and `rest.sh all`. It rebuilds
  `gopher.elf` and metal-vmm, but does not re-port: run `./port.sh` first.
- `./long.sh` is the long tier: the simulators at 10,000 seeds against
  `coverage/floor-sim.txt`, the chat judge on FAT16, and the real kernel on
  metal-vmm losing each of its frames in turn, and facing a peer that
  misbehaves, against `coverage/floor-metal.txt`.
- **A release needs both:** the full `./gates.sh` and a whole `./long.sh`
  each record a verdict for the commit pair (`tools/verdicts.py`), and
  `droplet/chat.py` builds only a pair with both PASS. The quick tier and a
  partial `long.sh` record nothing.
- Every gate's exit code is its verdict, and its last line names what failed.

**The pieces, one at a time** (all QEMU):

    zig build kernels      # every kernel into probe/
    probe/run.sh           # boot each one under microvm (~45 s)
    probe/run.sh clock     # just one
    ./port.sh && zig build gopher && probe/run.sh gopher   # the real server, judged against Linux
    probe/run.sh gopher uploads   # ONE gate of that judge, in seconds
    probe/run.sh gopher isolated  # a boot per single request
    probe/run.sh quick     # Debug kernels, every probe, the judge's quick tier
    probe/run.sh native    # the TCP table on Linux, judged by Linux's own TCP (~1 min)
    probe/run.sh ladder    # one operation many times, at a flat cost (LADDER_SCALE=10 for more)
    probe/run.sh soak      # one boot serving for a long time (SOAK_ROUNDS)

**One gate of the judge at a time.** `probe/run.sh gopher <gate>` runs one;
a name it does not know is an error that lists them all (the judge's `GATES`
in `probe/judge_gopher.py`), not a silently complete run. The single requests
go to one boot by default; `probe/run.sh gopher isolated` gives each its own
boot, which proves an answer owes nothing to an earlier one. Neither gate
script runs `isolated`; it is there to ask by hand.

**Two builds.** `-Ddev` builds the kernels in Debug — a rebuild of the real
server in seconds instead of ReleaseSafe's tens — and `run.sh quick` builds
that way and runs the judge with test-sized waits (a 3-second stream
keepalive, sub-second silent-client timeouts), one boot for the single
requests, and without the boots that exist to be long. Shipping kernels are
ReleaseSafe, and every run says which build it judged, read from a marker
each kernel carries.

## Simulators and properties

The pure parts of the machine — the TCP table, the FAT, the page cache,
`ready.zig` and the other pure modules — are driven by simulators on Linux,
with no QEMU: `src/tcp_sim.zig`, `fat_sim.zig`, `page_sim.zig`,
`ready_sim.zig` and `pure_sim.zig`. `src/properties.zig` runs them over many
seeds and judges zig-coverage-sdk's `always`/`sometimes` properties across
the whole run; `coverage/floor-sim.txt` and `coverage/floor-metal.txt` list
the properties a long run must reach. A simulator drives only code that needs
no I/O, which keeps those layers honest: code that reaches into a device
gets a seam, not a mock ([`CLAUDE.md`](CLAUDE.md)).
[`COVERAGE.md`](COVERAGE.md) has the decisions, the three tiers, and what the
runs have found.

## How it works

- **`std.http.Server` runs unmodified.** It is built from a reader and a
  writer, and `src/stream.zig` presents a TCP connection as both.
- **The port is one alias.** angry-gopher's filesystem calls are spelled
  `Io.Dir.cwd().something(io, ...)`; `port.sh` changes `const Io = std.Io;`
  to this repo's `io.zig` in each file that has it, and no call site moves.
  `std.Io` itself is not the seam: it does not compile on a freestanding
  target.
- **One loop, no threads.** One core, no preemption: the loop talks to the
  devices, moves every connection along, and serves whatever request has
  wholly arrived. Chat's live streams are held by the loop.

| where | what |
|---|---|
| `src/boot.zig` | the PVH note, the long-mode stub, and the page tables |
| `src/serial.zig` | COM1 and QEMU's exit door: the whole console |
| `src/virtio.zig` | the MMIO transport, the virtqueue, and the block device |
| `src/net.zig` | virtio-net: frames out, frames in |
| `src/proto.zig` | ethernet, IPv4 and UDP — enough to carry a datagram |
| `src/dhcp.zig` | DISCOVER, OFFER, REQUEST, ACK |
| `src/gpt.zig` | where the partition starts, because sector 0 is not the filesystem |
| `src/fat16.zig` | FAT16 and FAT32: mount a volume, walk a directory, read a file, write one |
| `src/arp.zig` | answering "who has this address?", which is what makes one reachable |
| `src/tcp.zig` | a table of connections: handshake, windows, retransmission, close |
| `src/stream.zig` | that connection as a `std.Io.Reader` and a `std.Io.Writer` |
| `src/io.zig` | `Io.Dir`, `Io.Clock`, `Io.Mutex`, `Io.Group` — the surface the application calls |
| `src/page_cache.zig` | the data's files kept whole in memory after their first read, write-through, below the application (the retired gopher-metal queue, item 87); `page_cache_mib` in `gopher-metal.conf`, 64 by default |
| `src/interrupts.zig` | the IDT, the local APIC timer, and resting until a frame or the timer |
| `src/port.zig`, `src/tsc.zig` | x86 port I/O, and the timestamp counter |
| `src/pit.zig` | the interval timer, used once: to measure the TSC's rate |
| `src/rtc.zig` | the CMOS clock — the device half, and a pure half with host tests |
| `src/wallclock.zig` | both of those, in the order a host needs them |
| `src/*_sim.zig`, `src/properties.zig` | the simulators and the properties over them |
| `probe/*.zig` | one kernel each; a root file with a `kmain` |
| `probe/link.ld` | the layout — the note first, and `.bss` treated as unwritten |
| `probe/run.sh` | boots each under `-M microvm`, maps QEMU's exit code back to the guest's |
| `probe/judge_*.py` | the outside verdicts: the host's clock, a raw FAT16 parse, the Linux build of angry-gopher, and the ladder's, the replace probe's and the soak's |
| `droplet/` | the loader, the image builder, the release and cutover tools |
| `tools/verdicts.py` | which commit pair a gate judged, and the release rule |

## The design

The engineering behind the table above lives in `docs/`, by topic:

- [`docs/port.md`](docs/port.md) — `std.http.Server` unmodified, the real
  server and its judge, the seam we first got wrong (`std.Io`), no threads,
  the 16 MB measured stack, the memory seam (std's allocator on our pages).
- [`docs/disk.md`](docs/disk.md) — why our own FAT, dates, long names, the
  backup story both ways, the FAT in memory and reads by runs.
- [`docs/tcp.md`](docs/tcp.md) — every wait a duration, many connections in
  one loop, chat's live streams, the send side, the ladder, the TCP table
  against Linux's TCP, and what the TCP does not do.
- [`docs/probes.md`](docs/probes.md) — what each probe checks, and the
  QEMU and clock traps that cost time.
- [`docs/designs/`](docs/designs/README.md) and
  [`docs/reviews/`](docs/reviews/README.md) — design notes and reviews of
  particular changes.
- [`FAT32.md`](FAT32.md), [`RESTART.md`](RESTART.md),
  [`TCP_TESTING.md`](TCP_TESTING.md) (finding the TCP table's bugs
  systematically), [`COVERAGE.md`](COVERAGE.md).

The plan this all started from is
[`notes/angry-gopher-without-linux.md`](http://143.244.172.148:9100/notes/angry-gopher-without-linux.md).
Parked 2026-09-18 with everything green, for want of a machine we could run
it on; unparked 2026-10-01 when the target became a DigitalOcean droplet,
booted from a custom image
([gopher chat on a droplet](http://143.244.172.148:9100/notes/gopher-chat-on-a-droplet.md)).
