# gopher-metal

angry-gopher's chat server, on a machine with no operating system under it.

Everything here targets `x86_64-freestanding`: no kernel, no libc, no syscalls.
A kernel is one root file over `src/`, linked with a script that puts a PVH
note at the front, and booted by QEMU's `microvm` machine.

The plan is
[`notes/angry-gopher-without-linux.md`](http://143.244.172.148:9100/notes/angry-gopher-without-linux.md),
and its two load-bearing findings are worth repeating here:

- **Caddy on lynrummy.com fronts this box**, so TLS, certificates and HTTP/2
  stay on Linux where they already work. What runs here speaks plain HTTP/1.1
  on a private address with no public IP.
- **`std.Io` is the porting seam.** zig 0.16 passes all I/O through an
  interface, and `angry-gopher/zig-server` threads it everywhere — `Io.Dir`
  appears 121 times — so the port is one implementation of `Io`, not a rewrite
  of 14,423 lines. `std.http.Server` is built from a reader and a writer and
  needs no modification at all.

## Where it stands

| | |
|---|---|
| the boot | **works** — PVH, long mode, identity-mapped low 4 GB |
| virtio-blk over MMIO | **works** — reads, writes, and reads back |
| virtio-net over MMIO | **works** |
| DHCP | **works** — leases 10.0.2.15 from QEMU's server |
| ARP | **works** — answers, which is what makes the address reachable |
| TCP | **works** — one connection, in-order, no retransmit |
| HTTP, ours | **works** — `curl` gets a 200 from it |
| **`std.http.Server`, unmodified** | **works** — see below |
| GPT and FAT16, read side | **works** — against Cobblestone's own fixtures |
| FAT16 write | **works** — reproduces the ladder verdict byte for byte |
| long names and subdirectories | **works** — `fsck.vfat` finds no error |
| the backup story, both ways | **works** — Linux mounts it; we read what Linux wrote |
| entropy | **works** — virtio-rng and RDRAND, mixed |
| FAT16 append, replace, delete, delete-tree | **works** — `fsck.vfat` and Linux judge; fragmented directories forced on purpose |
| `Io.Dir` | **works** — see "the seam we first got wrong" |
| the TSC's rate | **works** — measured against the PIT, 0.001% from the host kernel's own figure |
| the wall clock | **works** — the CMOS RTC, anchored at a seconds edge; pinned leap-day, noon and 4 PM boots |
| **angry-gopher's whole route table** | **works** — 38 requests, each answered the same as the Linux build over the same files |
| more than one request per boot, SSE | next: a loop, then a scheduler |

    zig build test         # host unit tests for the pure parts of src/
    zig build kernels      # every kernel into probe/
    probe/run.sh           # boot each one under microvm (~45 s)
    probe/run.sh clock     # just one
    ./port.sh && zig build gopher && probe/run.sh gopher   # the real server, judged against Linux

```
PASS block |   wrote and read back sector 32767: 512 bytes match
PASS fat16 |   read 355840 bytes; first two: 4d5a
PASS fat16write | bin 1 2 3 254
     fat16write | console matches the ladder verdict for fat16-write
PASS stdio |   mutex: locked and unlocked twice, no contention possible
PASS vfat |   auth/damian: . .. api-key _session_secret
     vfat | fsck.vfat finds no error in what we wrote
     vfat | the Linux VFAT driver reads every name and byte we wrote
PASS restore |   auth/damian/_session_secret still reads: sixteen bytes!!!
PASS append |   createFile: .truncate = false keeps, the default empties
     append | fsck.vfat finds no error after 600 appends
     append | the Linux VFAT driver reads all 600 lines and the late append, byte for byte
PASS replace |   tree/: four levels with data, deleted whole
     replace | fsck.vfat finds nothing, and reclaims nothing
     replace | sessions/ is 7 clusters with 6 gap(s) and 2 straddling run(s); all 100 files read back byte for byte
PASS clock |   .real: the time it was told, advancing with .awake, re-anchored when told again
     clock | ok   unix 1789600584 is within the host's clock [1789600582, 1789600591]
     clock | ok   tsc_hz 2494162684 vs the host's 2494134000 (0.001%)
     clock | pinned to midnight, across a leap day: civil 2020-3-1 0:0:1, four formats agree
     clock | pinned to noon: civil 2020-3-1 12:0:1, four formats agree
     clock | pinned to 4 PM: civil 2020-3-1 16:0:1, four formats agree
PASS clock | refused as it must: the PIT would not calibrate the TSC
PASS realunset | refused as it must: PANIC: Io.Clock.now(.real) before setRealTime()
PASS rng |   over 4 KB: 16347 of 32768 bits set, commonest byte appears 25 times
PASS net |   server : 10.0.2.2
PASS http | curl got "hello from no Linux"
PASS stdhttp | curl got "hello from std.http.Server, with no Linux under it"
```

## The one that matters

`zig-server` builds its HTTP server like this, and so does `probe/stdhttp.zig`:

```zig
var server = std.http.Server.init(s.reader(), s.writer());
const req = try server.receiveHead();
try req.respond(body, .{});
```

A reader and a writer, and nothing else. So a TCP connection that can present
those two interfaces gets zig's entire HTTP/1.1 implementation for free — not
ported, not vendored, not adapted, the same code from the same standard
library, on a machine with no operating system:

```
gopher-metal std.http probe
  address: 10.0.2.15
  listening on port 80, with zig's own HTTP
  connected
  method: GET  target: /probe
  responded
```

`src/stream.zig` is what makes that true, and it is about a hundred lines,
because each interface needs exactly one function: a reader needs `stream`, a
writer needs `drain`, and everything else in both vtables has a default.

**A read there runs the event loop.** With one core and no preemption there is
nobody else to move the connection forward, so a read with no bytes yet polls
the NIC, answers ARP, feeds TCP and tries again. That is what "blocking" means
when there are no threads to block.

A probe is a kernel that is only a driver and a serial port. They exist so a
driver can be put on virtual hardware and checked before anything is built on
top of it.

**`block`** brings the device up, reads sector 0 and checks its boot signature,
then writes the last sector and reads all 512 bytes back. Reading proves bytes
moved; writing and comparing proves they moved **where we said**.

**`net`** brings the NIC up and takes a DHCP lease. QEMU's user-mode networking
answers DHCP at 10.0.2.2 with nothing configured, so the result needs no second
machine — and it is the same exchange Cobblestone's `dhcp-acquire` performs
through the Roc machine and an emulated NE2000. Two paths, one protocol, one
answer to compare.

**`http`** takes a lease, listens on port 80 and answers one request.
**Its verdict is not its own output** — QEMU forwards a host port to the
guest's 80, `run.sh` fetches from it, and what curl got back is what is
checked. The guest's console only says what it thought happened.

```
gopher-metal http probe
  address: 10.0.2.15
  listening on port 80
  request: GET / HTTP/1.1
  answered and closed
```

| where | what |
|---|---|
| `src/boot.zig` | the PVH note, the long-mode stub, and the page tables |
| `src/serial.zig` | COM1 and QEMU's exit door: the whole console |
| `src/virtio.zig` | the MMIO transport, the virtqueue, and the block device |
| `src/net.zig` | virtio-net: frames out, frames in |
| `src/proto.zig` | ethernet, IPv4 and UDP — enough to carry a datagram |
| `src/dhcp.zig` | DISCOVER, OFFER, REQUEST, ACK |
| `src/gpt.zig` | where the partition starts, because sector 0 is not the filesystem |
| `src/fat16.zig` | mount a volume, walk a directory, read a file, write one |
| `src/arp.zig` | answering "who has this address?", which is what makes one reachable |
| `src/tcp.zig` | one connection at a time: accept, read, answer, close |
| `src/stream.zig` | that connection as a `std.Io.Reader` and a `std.Io.Writer` |
| `src/io.zig` | `Io.Dir`, `Io.Clock`, `Io.Mutex`, `Io.Group` — the surface the application calls |
| `src/port.zig`, `src/tsc.zig` | x86 port I/O, and the timestamp counter |
| `src/pit.zig` | the interval timer, used once: to measure the TSC's rate |
| `src/rtc.zig` | the CMOS clock — the device half, and a pure half with host tests |
| `src/wallclock.zig` | both of those, in the order a host needs them |
| `probe/*.zig` | one kernel each; a root file with a `kmain` |
| `probe/link.ld` | the layout — the note first, and `.bss` treated as unwritten |
| `probe/run.sh` | boots each under `-M microvm`, maps QEMU's exit code back to the guest's |
| `probe/judge_*.py` | the outside verdicts: the host's clock, a raw FAT16 parse, and the Linux build of angry-gopher |

## Three things that cost time

Written down because each one looks like something else.

**QEMU's multiboot loader refuses a 64-bit ELF** outright: *"Cannot load x86-64
image, give a 32bit one."* PVH is the other door into the same machine, takes an
ELF of either width, and is what every modern microVM boots anyway.

**`virtio-mmio` defaults to the LEGACY interface.** Every transport reads
version 1 until `-global virtio-mmio.force-legacy=false`, and a driver that
speaks virtio 1.2 correctly refuses to talk to it.

**microvm has 24 transports and fills them from the top.** A single
`-device virtio-blk-device` lands on bus 23 at 0xFEB02E00, with slots 0–7
present but empty — which is indistinguishable from "no device at all" if you
only scan eight of them. `info qtree` answers this in one command; guessing does
not.

**There is no port 0x61.** The textbook TSC calibration gates PIT channel 2
through the PC speaker's port and reads its output there; `microvm` has no
speaker, and the port reads 0xFF. Channel 0's count, latched and read back,
needs neither.

**A request sent while the guest is still starting takes six seconds.** QEMU's
user-mode network accepts the host connection at once and forwards the SYN; a
guest with no NIC driver running yet drops it, and QEMU's own TCP retries only
about six seconds later. `judge_gopher.py` waits for the guest to print
"listening" first — that was 4½ of the first run's 5 minutes.

**Two FAT16 bugs that only a replace, and only a big directory, could show.**
Removing an entry freed its chain before tombstoning it, and the chain walk
reuses the machine's one scratch sector — so a FAT sector was written over the
directory. And a long name's parts were located by `lba += 1`, which past a
subdirectory's cluster edge is someone else's data. Our own reader agreed with
both; `fsck.vfat` and Linux did not. `probe/replace.zig` forces both shapes and
its judge checks, from the raw image, that it did.

## The oracle row

`probe/fat16write.zig` does not judge itself. It writes HELLO.TXT and BIN.DAT
to a FAT16 volume and prints the seven lines Cobblestone's `fat16-write` test
prints, and `run.sh` compares that console with **the test's own verdict** —
`probe/expect/fat16write.txt`, copied from the ladder, the same file
`roc-apps/floor`'s verify.sh uses to check the Roc implementation.

```
wrote True
exists True
readback Hello, disk!
size 12
wrote-bin True
bin 1 2 3 254
absent False
```

Two filesystems, in two languages, on one disk image, agreeing line for line.

The image they leave behind was also read back from outside, with neither
implementation involved: both copies of the FAT are identical, HELLO.TXT is at
cluster 4891 holding `Hello, disk!`, and BIN.DAT is at 4892 holding
`01 02 03 fe`. Agreeing with our own reader would have proved much less.

## The real server

`port.sh` copies angry-gopher's sources and changes one line in each file that
opens with `const Io = std.Io;`. Nothing else is touched.

`probe/gopher.zig` is a HOST in the sense angry-gopher's `router.zig` defines —
the contract any host meets before calling the route table:

    mem_meter.init(base)        base: a bump allocator over a 16 MB static block
    roots.point(base, …)        data/ and auth/, on the volume
    a Bus over base
    an arena per request

— with the site on a GPT disk whose first partition is FAT16, and clocks from
its own hardware. Then it calls `router.route`: the application's real
dispatch, every page.

**It is judged against Linux.** `probe/judge_gopher.py` sends each request to
this kernel (one boot each, since it serves one and stops) and to the ordinary
Linux build of the same source over the same files, each case starting from the
same state on both sides. Status, Location, Set-Cookie, Content-Type and body
must match; files a request writes are read back through the Linux VFAT driver
and must match too; and a Unix time is only forgiven if it falls inside the
window in which that side handled the request.

```
38 of 38 requests answered the same on bare metal as on Linux
```

The index read off the volume, the résumé and its 27 KB PDF, both admin
screens refusing a stranger, the name page, the player store, a staged game
session rendered in Eastern time, new game and puzzle sessions stamped with the
wall clock, a move appended to an action log, a new player's counter and row.

What it does not do yet is serve a second request. That, then SSE.

## The seam we first got wrong

`std.Io` looks like an interface. It is not one.

It has **117 function pointers and no defaults**. Its handles are literally
`std.posix.fd_t`. And `std.Io.Dir.cwd()` reaches for `std.posix.AT.FDCWD`,
which does not exist on a freestanding target — so it does not merely fail to
work there, **it fails to compile**, whatever vtable you supply. `std.Io` is a
portable spelling of the POSIX syscalls, not an abstraction over storage. The
one implementation zig ships, `Io.Threaded`, is 18,902 lines.

The real seam is one line higher, and the application hands it over. All 121 of
its filesystem calls are spelled `Io.Dir.cwd().something(io, ...)`, and 37 files
open with the same line:

```zig
const Io = std.Io;      //  ->  const Io = metal.io;
```

Point that at `src/io.zig` and **not one call site changes**. That is the port:
37 single-line edits, zero touched call sites, and a `Dir` answering the eleven
operations the application actually asks for.

```
gopher-metal std.Io probe
  readFileAlloc("HELLO.TXT") -> 12 bytes: Hello, disk!
  statFile -> 12 bytes, kind file
  clock advanced 547220635 ns over a spin
  iterate -> EFI/ CODEX.CDX HELLO.TXT
  mutex: locked and unlocked twice, no contention possible
```

**Note what this does not change.** `std.http.Server` still runs unmodified,
because `std.Io.Reader` and `std.Io.Writer` are genuine interfaces — one
required method each, defaults for the rest, no POSIX anywhere in their types.
Two designs in one standard library, and only one of them is a seam.

## No threads, and no wish for any

A large share of those 117 entries are the concurrency family: async,
concurrent, await, cancel, four more for groups, three futex operations,
batching, and cancellation plumbing through everything else. None of it applies.
One core, no preemption, one connection at a time — so "run this concurrently"
becomes "run this now", which loses no overlap a single core ever had. The
application is already built for it: its accept loop is single-threaded by its
own comment, and it already serves inline when its task pool is exhausted.

**The ten mutexes are free — and they say so out loud.** The temptation is to
delete the calls; that is worse than keeping them. Each lock marks a critical
section somebody identified, and when SSE arrives concurrency comes back — not
as threads, but as several connections interleaved in one event loop, which is
exactly when those sections matter again. Deleting the calls throws away the
map and keeps the territory.

So the lock is free but not silent: it records that it is held, and a second
lock without an unlock is real re-entrancy that would deadlock on a threaded
host. It cannot happen here — so if it does, the assumption this design rests
on is wrong, and the machine says so rather than carrying on.

## Long names, and the judge

The application stores `auth/<id>/api-key` and `_session_secret` and
`upload-bytes` and `last-seen`. Every one of those is refused by 8.3, and two
are two directories deep — so a volume that cannot hold them cannot hold the
data we already have, and nobody would have to re-register only because the
filesystem was too small for their filenames.

So `src/fat16.zig` grew VFAT long names, subdirectory writes, directory growth
and `mkdir`. **The verdict is `fsck.vfat`'s**, not ours: dosfstools has been
reading VFAT for decades and knows every way a long-name run can be wrong — the
checksum, the reverse ordering, the sequence numbers, orphaned entries, `.` and
`..`. `probe/run.sh` writes a volume with our code and hands it over.

```
PASS vfat |   auth/damian: . .. api-key _session_secret
     vfat | fsck.vfat finds no error in what we wrote
```

The checksum is the classic place to get this wrong, so it is written out where
it is used:

```zig
sum = (((sum & 1) << 7) | ((sum & 0xFE) >> 1)) +% short[i]
```

**And the first version passed fsck while being wrong.** The listing came back
`API-KEY`, because `api-key` *fits* in 8.3 and so no long name was written — and
8.3 is uppercase. Fitting is not enough; the name has to survive the round trip.
`needsLongName` now asks whether a name reads back as itself, which makes every
name with a lowercase letter a long one. That is the same bug Cobblestone's own
`Fat16` carries a paragraph about having had, found here by looking at the
output rather than at the checker.

## The backup story, both ways

Structure passing `fsck` is not the same as the data being reachable, so the
check does not stop there. It loop-mounts the volume with **the Linux kernel's
own VFAT driver** and compares what Linux sees with what we wrote:

```
./auth/damian/_session_secret      sixteen bytes!!!
./auth/damian/api-key              3-notarealkey
./users/damian/last-seen           1758038400
./users/damian/upload-bytes        4096
./blog-comments                    none yet
```

Every name exact — lowercase preserved, hyphens, the leading underscore — and
every byte. So `cp -r` off a mount gets the data out, which is the half of the
backup story people usually check.

Then the other half, which is the one that matters when something has gone
wrong: **Linux writes and we read**. The check has the kernel create a directory
and a long-named file, unmounts, and boots the machine again:

```
gopher-metal restore probe
  restored/written-by-linux.txt: 46 bytes
  contents: linux wrote this, with a name 8.3 cannot hold
  auth/damian/_session_secret still reads: sixteen bytes!!!
```

A backup taken on Linux restores here. And our own files survived Linux writing
to the volume, which a one-way check would not have noticed.

The mount needs root, so it is **skipped rather than failed** where there is
none — a check that cannot run must not look like one that passed.

## Why we wrote our own FAT16

Checked first, and the ecosystem is thinner than expected. The nearest thing is
[**zfat**](https://github.com/ZigEmbeddedGroup/zfat) — *bindings* to ChaN's
FatFs, a C library, not a native Zig implementation.
[**zig-osdev/disk-image-step**](https://github.com/zig-osdev/disk-image-step)
does FAT12/16/32 but at *build* time, to make images, not to read them at
runtime. `pluto`'s `mkfat32.zig` is likewise an image writer. The mature runtime
implementations — [fat_io_lib](https://github.com/ultraembedded/fat_io_lib),
gristle, SEGGER emFile — are all C.

So: our own, and crib tests from wherever they exist. The reasons hold up:

- The application above asks for **eleven whole-file operations**, no seeks and
  no partial writes, which is a small fraction of what FatFs does.
- A C dependency inside a freestanding kernel is a real cost, and FatFs brings
  a large configuration surface with it.
- There is already a FAT16 next door in `roc-apps/floor`, in Roc, green against
  these same fixtures — so we get an **oracle**, which a third-party library
  would not give us.

Revisit zfat if FAT32, long names, or robust crash-safe writing become
necessary. `disk-image-step` is worth remembering regardless: making fixtures
without mtools or loop mounts is a real convenience.

**What the fixtures taught us immediately:** sector 0 is not the filesystem.
Cobblestone's images are GPT disks with a protective MBR and one "EFI System"
partition at LBA 2048, which is why its `Fat16` cites a `Gpt` chapter — and why
a reader that mounts sector 0 finds a boot sector of zeros and concludes,
correctly and uselessly, that the volume is not FAT16.

## What the TCP does not do

No congestion control, no retransmission, no out-of-order reassembly, no
keep-alive, one connection at a time. That is not laziness about the general
case — it is the shape the thing above it already has. `zig-server`'s own
comment says keep-alive is deliberately off and its accept loop is
single-threaded.

Two of those are real assumptions about the wire, and both are only allowed
because this box sits behind Caddy on a private network:

- **In-order only.** A segment whose sequence is not exactly what we expect is
  dropped and re-acknowledged, which asks the peer to send it again.
- **No retransmit timer.** If something we send is lost the connection stalls
  rather than recovering. The day that stops being acceptable is the day this
  file grows a clock.

## What lives elsewhere

The Roc side of this work stays in
[`roc-apps/floor`](https://github.com/showell/roc-apps): the platform whose
doors Roc programs call, the FAT16 that runs on it, and the fault modes. That
floor and this repo are two implementations of the same device set — which is
the arrangement that has already earned its keep twice, and is why the drivers
here are written against the same doors.
