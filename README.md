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
| HTTP | **works** — `curl` gets a 200 from it |
| `Io` over the floor | the stage that proves the thesis |

    zig build kernels      # every kernel into probe/
    probe/run.sh           # boot each one under microvm
    probe/run.sh net       # just one

```
PASS block |   wrote and read back sector 32767: 512 bytes match
PASS net |   server : 10.0.2.2
PASS http | curl got "hello from no Linux" over TCP from a machine with no OS
```

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
| `src/arp.zig` | answering "who has this address?", which is what makes one reachable |
| `src/tcp.zig` | one connection at a time: accept, read, answer, close |
| `probe/*.zig` | one kernel each; a root file with a `kmain` |
| `probe/link.ld` | the layout — the note first, and `.bss` treated as unwritten |
| `probe/run.sh` | boots each under `-M microvm`, maps QEMU's exit code back to the guest's |

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
