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
| TCP | **works** — 256 connections; the peer's window and segment size respected, lost segments sent again, silent peers given up on; received in order only |
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
| many requests per boot | **works** — a 22-step story and 300 requests to one boot, judged against Linux; heaps steady |
| many connections, one loop | **works** — a request is served once its head has arrived |
| chat's live streams | **works** — held by the loop, pinged, budgeted, and ended when their tab leaves or stops reading |
| whole requests, uploads | next |

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

    mem_meter.init(base)        base: std's general-purpose allocator, on this
                                machine's pages
    roots.point(base, …)        data/ and auth/, on the volume
    a Bus over base
    an arena per request

— with the site on a GPT disk whose first partition is FAT16, and clocks from
its own hardware. Then it calls `router.route`: the application's real
dispatch, every page — one connection at a time, in a loop, each request with
its own heap that is reset afterwards. `gopher-metal.conf` on the volume says
how many requests to serve (`requests = N`); without it, forever. A request
that fails is logged and survived, as it is on Linux.

**It is judged against Linux.** `probe/judge_gopher.py` sends each request to
this kernel and to the ordinary Linux build of the same source over the same
files, each case starting from the same state on both sides. Status, Location, Set-Cookie, Content-Type and body
must match; files a request writes are read back through the Linux VFAT driver
and must match too; and a Unix time is only forgiven if it falls inside the
window in which that side handled the request.

```
ok    the story: 22 requests to ONE boot, each answered as Linux answered, and all 18 data files agree
ok    stamina: 300 requests to one boot, every answer the same, base heap steady at 72 live bytes, each request's heap the same every round (58498, 26768, 1807 bytes)
38 of 38 single requests, and both long-running boots, answered as Linux answered
```

Then two boots that serve many requests. **The story** is one visitor's
afternoon, told to one kernel and one Linux server — the name page, a game,
moves, a second game, a second visitor, the puzzles — with garbage and a silent
connection in the middle that must not stop it; afterwards the whole data tree
is compared. **Stamina** is 300 requests to one boot: every answer must equal
the first answer to the same request, the base heap must not grow, and each
request must use the same amount of its own heap every round.

The index read off the volume, the résumé and its 27 KB PDF, both admin
screens refusing a stranger, the name page, the player store, a staged game
session rendered in Eastern time, new game and puzzle sessions stamped with the
wall clock, a move appended to an action log, a new player's counter and row.

What it does not do yet is take two connections at once — a browser loading
`/game` opens three — or hold one open for SSE. Both want a scheduler.

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

**And the compiler is told, because it does not assume it.** A freestanding
target is *not* single-threaded by default, so std kept the threaded lowerings —
real atomic instructions, thread-local storage — for a machine with one core, no
preemption and no scheduler. Every kernel here builds with `single_threaded =
true`, and `probe/gopher.zig` refuses to compile if that ever stops being so:
the stubs above are only honest under it. Nothing named `std.Thread` appears in
`src/`, in the ported application, or in the linked ELF. The task pool that
serves requests on Linux lives in `server.zig`, which is a host — and this
machine has its own.

## The stack is 16 MB, and its depth is measured

The kernel ran on 64 KB. The same route table on Linux runs on a thread from
`std.Thread`'s pool, which gets `SpawnConfig.default_stack_size` — 16 MB, 250
times more. The frames are the same frames either way, and `/chat/recent` went
deeper than 64 KB: the machine triple-faulted, which is a reset with nothing in
the log, because a fault handler needs a stack too and there was none left.

So `src/stack.zig` declares the region at exactly std's own number, in `.bss` so
the 16 MB is a program header rather than 16 MB of zeros in the kernel image.
**The boot stub paints the whole thing with 0xA5A5A5A5A5A5A5A5 before it points
`%rsp` at it** — `rep stosq` over memory nothing is running on yet. Afterwards
the lowest word that is no longer painted is the high-water mark: everything
below it has never been written by any call this boot. That is the real depth of
the real route table on real requests, not an estimate. The serial log says it
the first time each new depth is reached, so a request that goes deeper than
every request before it is one line and a request that does not is silent.

The bottom 64 KB is a guard, and writing it stops the machine. Past the end of
the stack is `.bss` — the heaps, the virtqueues, the volume's sector buffer — so
a frame that runs off the end corrupts whatever it lands on and the machine
carries on lying. One blind spot, stated: a stack word that legitimately holds
the paint value reads as untouched, so the mark can only come out shallower than
the truth, never deeper.

## The memory seam: the kernel owns RAM, std does the rest

Every heap here used to be a fixed array in `.bss` — `var base_heap: [8 MB]u8`
— handed to a `FixedBufferAllocator`. That is a bump allocator: `free` reclaims
only the block it handed out last, so under any other order the memory is gone
for the life of the boot. A server that cannot reuse what it frees has a clock
on it, however little it leaks, and this one also ignored `-m` entirely: the
heap was the size somebody typed.

**The seam is the one zig already documents.** `std.heap.page_allocator` is
defined as `root.os.heap.page_allocator` when the root file declares one:

```zig
pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = metal.pages.allocator;
    };
};
```

That is the whole arrangement. From there, `std.heap.DebugAllocator` — std's
own general-purpose allocator, with its size-class buckets and its reuse — runs
unchanged on this machine's RAM. It is exactly what Linux does: there
`page_allocator` is `mmap` and the allocator above it is std's either way. What
a kernel has to supply is what Linux supplies, and no more.

So `src/pages.zig` is a page allocator and nothing else: a bitmap, one bit per
4 KB page, living in the front of the region it describes, so the size of the
heap is the size of the machine rather than a constant. A page's length is not
recorded anywhere — `std.mem.Allocator` hands `free` the same slice it was
given. Freeing a page twice, or a pointer that never came from here, panics:
the alternative is two owners of the same memory, and whichever writes second
wins.

**And the machine now knows how much RAM it has.** The PVH loader has been
handing us a memory map in `%ebx` since the first boot and we were throwing it
away. `src/pvh.zig` reads it — checking the magic, the version and every
region — and the linker marks `_kernel_start`/`_kernel_end` so the kernel's own
image is cut out of what gets handed around. QEMU is the judge, because it
knows what it was told:

```
     memory | -m 512: found 536472576 bytes, 389 KB of it the firmware's
     memory | -m 256: found 268037120 bytes, 389 KB of it the firmware's
     memory | -m 128: found 133819392 bytes, 389 KB of it the firmware's
```

**The question that decides deployability is whether the peak stops rising.**
Live bytes can sit flat forever while a bump allocator's consumption climbs, so
the machine reports both after every request, and `probe/memory.zig` puts sixty
rounds of a server's shape — allocate three hundred, free three hundred at
random — through std's allocator on these pages:

```
  every one of the 126703 pages taken and given back, twice
  churn: 18000 allocations, peak 1064960 bytes after 10 rounds, 1101824 after 60
  the heap is empty again, and std's allocator finds no leak
```

The same arrangement is checked on the host, where a heap-allocated buffer
stands in for the machine's RAM, against std's own four allocator conformance
suites — `testAllocator`, `testAllocatorAligned`, `testAllocatorLargeAlignment`
and `testAllocatorAlignedShrink`. Those found two bugs in the first version: a
search that gave up before it had covered the bitmap and reported a nearly
empty heap as full, and an over-page alignment checked against page indices
rather than addresses, which failed every 64 KB-aligned request on a region
that did not happen to start on that boundary.

## A file has a date, and chat's "recent" is built out of it

`/chat/recent` sorts every conversation and document by file modification time
and prints each one as RFC 3339. On this machine that read zero, so the page
came back listing 1970 and in the wrong order — the one thing in the whole route
table that the port could not answer.

FAT16 has exactly one timestamp: two 16-bit words per directory entry, the year
counted from 1980 and the seconds counted in **twos**. So `src/fat16.zig` writes
them — at creation, and again on every write that moves a file's size, which is
where every append and every replace already lands. The filesystem has no clock
and must not invent one, so the host hands it the machine's: `io.zig` points
`Volume.clock` at the wall clock, and it answers null until the RTC has been
read, so a probe kernel with no clock writes entries with no date rather than a
plausible wrong one.

**UTC, with no time zone anywhere.** DOS dates are local time by convention and
the Linux VFAT driver applies the mount's zone to them; nothing here has a zone,
and the application renders Eastern from a Unix time. So the driver is asked
with `tz=UTC`, and then it agrees:

```
     append | the Linux VFAT driver reads all 600 lines and the late append, byte for byte
     append | and dates the files it read within 0s of the kernel's own clock
```

That gate earns its keep. Stamping nothing puts 1980 on the files
(`-1474109717s from the kernel's clock`), and writing the two words in the
wrong order puts 2023 on them (`-99616450s`) — and the second of those passes
every host test of the packing, because the packing is right and the layout is
not. Each judge sees what the other cannot.

The calendar itself moved to `src/civil.zig`, because two things now need the
same dates to be the same instants: the CMOS chip and every directory entry.
Its round trip is checked for every day from 1980 to 2110.

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

## The disk, read a run at a time, with the FAT in memory

A soak of 5,251 chat requests passed every correctness check — and the machine's
own time to answer rose from 10 ms to 160 ms as the conversation grew, while
even a fixed 27 KB PDF got slower. Reading the code found two costs that grew
with the disk, not with the request:

- **No FAT in memory.** Every FAT lookup was a block read, and the free-cluster
  search started at cluster 2 on every allocation. A chat request replaces four
  tiny files (`last-seen`, `last-conv`, `lastauthor`, the session cursor), so
  each walked past every cluster the growing transcript held, one device round
  trip apiece.
- **One sector per request.** A 200 KB file was four hundred round trips
  through the emulator. And chat's `appendMessage` reads the whole transcript
  on every send, to count the messages and number the next one — cheap out of
  Linux's page cache, expensive here.

So `Volume.cacheFat` holds the FAT (64 KB for this volume, 130 KB at most for
FAT16), written through to every copy on each change — after checking that
every copy agreed with it, so it never silently "repairs" a second FAT. And
`readAt` reads a file as **runs** of consecutive clusters: whole sectors go
straight into the caller's buffer as one request per run, capped at 64 KB, and
only a sector the read starts or ends inside goes through the scratch sector.

**Judged three ways:**

- `replace` and `replace_cached` are one probe built twice, run from one
  formatted image, and must leave **byte-identical** volumes: the cache may
  change nothing that reaches the disk. (The first comparison failed on two
  bytes — mkfs's own timestamp on the volume label, from two formats a few
  seconds apart.) Writing only the first FAT copy is caught by fsck and by the
  comparison.
- `append` sweeps fifteen offsets against eleven lengths over a file whose chain
  breaks at every cluster and one that is a single run longer than a request
  may carry, and checks its own files have those shapes first. Its volume uses
  512-byte clusters, so its FAT is too big for one request — the only path that
  splits a read, which a mutation showed nothing else reached.
- Every HTTP request's log line now says how many disk requests it made and how
  long they took, so a slow answer can be split into the device's share and
  ours.

## Timing runs under KVM; the clock taught us two things getting there

Every boot here ran with the CPU emulated in software (TCG) — nothing passed
`-enable-kvm` — so every number was a number about the emulator. The soak now
asks for KVM, because its numbers are about speed and a deployed machine would
not be emulating its CPU; the correctness judges stay on TCG, and a timing run
that cannot get KVM fails rather than quietly measuring TCG under its name.

The first KVM boot hung at the clock, and it was two problems in one:

- **`-M microvm` leaves the CMOS clock out under KVM** unless asked
  (`rtc=auto` means on under TCG, off under KVM, where microvm expects the
  guest to use kvmclock). A port with nothing behind it reads 0xFF, and 0xFF in
  register A has the update-in-progress bit set — so a missing chip looked
  exactly like one forever mid-update. Every boot now asks for
  `rtc=on,pit=on` by name, and the kernel calls a 0xFF register A what it is:
  `NoChip`.
- **The RTC waits were spin counts** — "two billion spins, just over a second,
  generously counted". Under KVM a register read is two port writes that exit
  to the emulator, so a spin costs thousands of times more and "a second" is
  hours. They are durations of the (already calibrated) timestamp counter now,
  a missed edge reports how many polls it made and what the seconds register
  said, and polls are a quarter of a millisecond apart with nothing touched in
  between — how a real chip wants to be treated, at the cost of that much
  anchor precision.

## Every wait is a measured duration

A client that connects and then says nothing is this server's worst case,
because it takes one connection at a time: that client holds the whole site.
Both waits in `src/stream.zig` used to be bounded by spin counts — "two hundred
million turns of the loop, then give up" — which is some unknown number of
seconds that changes with the CPU, and which ended in a silent end-of-stream as
though the client had politely hung up.

Now that the machine has measured its own timestamp counter, they are
durations, and the one that matters is host configuration on the volume
alongside `requests`:

    requests = N            serve N and stop; absent, serve until stopped
    idle_timeout_ms = N     how long a connection may make no progress
    streams = N             how many live streams may be held at once
    lose_one_sent_in = N    lose every Nth TCP frame sent (a test switch)

"No progress" is the same measure in every direction: a read that gets no
bytes, a write whose peer acknowledges nothing, a close whose FIN is not
acknowledged. An unknown key stops the machine, because a timeout that was
silently not applied is exactly how a server ends up held open by one client. And
`std.Io.Reader` reports both a dead NIC and a quiet client as `ReadFailed`,
leaving the detail to the implementation — so the stream keeps it, and the log
can say which:

```
  request 1: (no request) -> the client stopped sending, and was let go
  request 2: GET / -> ok (base: 93 live bytes, ...)
```

**"It recovered" is not the claim.** The claim is that the configured number is
what governs, and the only way to show that is to change it and watch the answer
move. So the judge boots twice, holds a socket open with half a request line in
it, and times the caller queued behind it:

```
ok    a silent client is let go after the time the volume says: the caller behind it
      waited 6.1s at 2000 ms and 18.1s at 6000 ms, and the machine served it either way
```

## Many connections, one request at a time

Chat holds connections open: every conversation tab keeps three streams for as
long as it is open. The machine used to hold exactly one connection — a SYN that
arrived while one was open was ignored — so it could not serve even one person
using chat. The design decision (Steve, after
[the SSE essay](http://143.244.172.148:9100/notes/chat-over-http-and-sse.md)) is
**state machines, and one loop over them**: talk to the devices, move every
connection along, and serve whatever is ready. No threads, no fibers.

`src/tcp.zig` is now a **table of connections** — 256 of them, room for about
sixty tabs — each with its own state, its own receive buffer and its own send
queue, about 20 MB in all. A SYN takes a free slot; a full table drops it, as Linux
does when its accept queue is full, and counts it. The buffer is consumed as the
request is read, and the window advertises the room actually left, so a body
bigger than the buffer arrives in pieces instead of being cut short. A slot the
host is serving is never handed to a new connection until the host lets it go —
otherwise a reader part-way through a request could find a stranger's bytes.

The state machine is **pure**: frames go out through whatever "wire" the caller
supplies, and the initial sequence number and the time are passed in. So it is
tested on the host (`src/tcp_test.zig`) with a recording wire and a fake peer
that checks sequence numbers as a real client would, and nine mutations of it
(finding a connection by port alone, handing out a held slot, a constant window,
acknowledging more than was taken, never compacting, throwing away what arrived
with a FIN, accepting out-of-order data, a repeated SYN as a new connection, not
counting a full table) each fail one.

**The host serves a connection only once its request head has arrived**
(`src/ready.zig`, which asks `std.http.HeadParser` — the parser `receiveHead`
itself runs — so "ready" and "a whole head" cannot disagree). The oldest ready
connection is served start to finish; one that has been quiet for
`idle_timeout_ms` is let go; otherwise the network is polled, which moves every
connection at once. The next step makes "ready" mean the whole request, body
included, so a handler only ever reads memory.

```
ok    8 clients connected at once, each answered as Linux answered; the kernel
      held 8 at once and turned none away
ok    a silent client holds nobody up and is still let go when the volume says:
      closed after 2.1s at 2000 ms and 6.1s at 6000 ms, with the caller beside
      it answered first both times
```

That second gate used to prove the opposite: the caller queued behind a silent
client waited 6.1 s and 18.1 s.

## The machine keeps chat's live streams

A chat tab holds its conversation's stream open, and every message sent in that
conversation has to appear on it. angry-gopher's streams are now **described by
the application and kept by the host** (angry-gopher `950b7e34`): a stream
handler writes its head and backlog, then hands the host a `Kept` — its bus
subscriber, and how to render an event for this viewer — and returns. Linux
serves that on the connection's own task exactly as the handler's loop used to.

This machine keeps a **table of held streams**, indexed by the connection each
one lives on. A request that kept a stream leaves its connection open and
claimed. Every turn of the loop drains each held stream's mailbox and writes the
frames; one quiet for the application's keepalive gets a ping; one whose client
has gone — its FIN or reset seen by the connection table — is ended: subscriber
dropped, connection closed, slot released. No threads, no fibers: one loop over
state machines.

The judge holds a stream open on both hosts and requires the same story from
each:

```
ok    live stream on Linux: a stream held open got its backlog first, then the
      message sent on another connection, numbered 1
ok    live stream on the machine: (the same)
```

and on the machine, that the stream was ended because its client went away,
with one held and one ended by the end of the boot. Three mutants of the table
fail it: never draining, never noticing a client that left, and closing a kept
stream's connection anyway.

**A tab, as a browser holds it.** The judge opens one user's three streams at
once — her conversation, her notifications, her sidebar — and has another user
send on the conversation and then start a new topic. Each stream must get its
own event (the message marked as not hers, "Steve sent you a message", the
topic added), and after 27 quiet seconds each must be pinged: once, not in a
flood. A host that pinged on every turn would have delivered a ping too — the
mutant sent 15,339 in 28 seconds — so the gate also requires that none came
before the 25-second keepalive was due.

**Streams cannot starve requests.** A held stream occupies a connection slot
for as long as its tab is open, so `gopher-metal.conf` has a key for it,
`streams = N` (by default all but 64 of the 256 slots). When the budget is full,
a new stream ends the OLDEST: its browser reconnects, and a conversation stream
resumes from its last event. With a budget of two, the judge opens three,
checks the first was closed and the other two still receive.

**Nothing is kept per stream.** 5 streams and then 25, opened and closed one
after another — half by a polite FIN, half by a reset — must each be ended
because their client went away, leave nobody subscribed, and end two boots
holding the same number of live bytes. The first run differed by exactly one
byte: the kernel kept its own config file's text in the long-lived heap, and
`requests = 8` is one byte shorter than `requests = 28`. It frees the text now,
and both boots end at 490 bytes.

**A tab that stops reading loses its stream, not the site.** The loop never
waits on a stream. It takes the next event from a stream's mailbox only when
it has somewhere to put it (angry-gopher's `nextFrame`), queues as much of the
frame as the connection's send queue takes, and carries the rest to the next
turn; the events behind it wait in the mailbox, as they do on Linux while a
write blocks. A stream whose carry has not moved for the idle time is reset.
The judge holds two streams on one conversation, reads one and ignores the
other while 40 KB messages are published:

```
ok    a lagging stream: the stream nobody read was ended as not keeping up
      after 52 40 KB messages; the one being read got all 52
```

The first version ended a stream whenever a new frame did not fit beside the
last one, and the gate ended the reader too: a 40 KB frame still in flight is
not a lagging tab.

## The send side

Until this step, a response went onto the wire in 512-byte segments as fast as
the loop could write them, whatever the peer had room for, and nothing was
ever sent twice. On an emulated network that never loses anything and buffers
everything, that passed every gate. Now every connection has a **send queue**,
and `Table.transmit` — called on every turn of the loop — is a state machine
like the receive side:

- **The window.** Nothing goes past what the peer last said it has room for.
  A shut window is probed with one byte when the timer runs out.
- **The segment size.** The SYN-ACK says ours (1460); a peer's SYN says its,
  and a peer that says nothing is sent 536-byte segments.
- **Retransmission.** Bytes leave the queue only when acknowledged. What is
  not acknowledged within a second is sent again with everything after it,
  and the wait doubles, up to 5 s. A second is RFC 6298's starting value for a
  sender that measures no round trips; it began at Linux's 200 ms, which is a
  floor under a measured estimate, and raced slirp's delayed acknowledgements.
- **Giving up.** Six timeouts with no progress — about 27 s — and the
  connection is reset. That is how a peer that vanished without a FIN is
  noticed.
- **Every waiting frame before any timer.** A busy loop finds
  acknowledgements queued in the NIC's ring, and looking at the timers first
  calls those segments lost. It once sent a second SYN-ACK for a connection
  whose ACK was already waiting, and slirp sent nothing more on it until the
  request timed out — one POST in about thirty, seen only once a Debug kernel
  made the loop slow enough, and found with a packet capture
  (`JUDGE_CAPTURE=1` writes one per boot).
- **The FIN goes last**, and only its own acknowledgement closes the
  connection; the host's close waits for as long as the peer keeps
  acknowledging, not a fixed two seconds.
- **An abandoned connection is reset**, so a client still waiting for the rest
  of an answer is told.

The state machine is tested on the host with a peer that sends windows and
acknowledgements. On QEMU, three gates exercise what the others never could:

```
ok    bulk: 8 messages of 40 KB in, a 317376-byte transcript and a 4895-byte
      page out, all answered as Linux answered
ok    bulk, losing one frame sent in seven: (the same), 122 frames lost,
      19 timeouts resent
ok    slow readers: a reader that paused twice got all 3967477 bytes, with 10
      window probes sent while it paused; one that never read was let go and
      the next request answered 5.3 s later
```

**The loss switch loses only what this machine sends**
(`lose_one_sent_in`). Losing what arrives as well made each 40 KB request take
20 s and two of them time out — measured, and not the send side's doing: this
TCP takes received segments in order only, so one lost segment throws away
every one behind it, and the peer recovers each hole on its own timer. That
belongs to the receive-side step.

**The slow-reader gate needs a 4 MB answer.** A loopback client with a 2 KB
receive buffer still lets its sender queue 1.36 MB, and slirp holds more; with
the 317 KB transcript the machine's window never shut, and the gate — which
requires window probes — failed rather than passing on nothing.

## What the TCP does not do

No congestion control, no fast retransmit, no selective acknowledgement, no
window scaling, no out-of-order reassembly, no keep-alive. `zig-server`'s own
comment says keep-alive is deliberately off. The rest are allowed because this
box sits behind Caddy on a private network, and one of them is a measured cost:

- **In-order only.** A segment whose sequence is not exactly what we expect is
  dropped and re-acknowledged, which asks the peer to send it again — and
  under loss, that makes the peer resend everything after the hole.

## What lives elsewhere

The Roc side of this work stays in
[`roc-apps/floor`](https://github.com/showell/roc-apps): the platform whose
doors Roc programs call, the FAT16 that runs on it, and the fault modes. That
floor and this repo are two implementations of the same device set — which is
the arrangement that has already earned its keep twice, and is why the drivers
here are written against the same doors.
