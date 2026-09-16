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
| virtio-blk over MMIO | **works** — reads, writes, and reads back |
| the boot | **works** — PVH, long mode, identity-mapped low 4 GB |
| virtio-net | next |
| TCP/IP | after that |
| `Io` over the floor | the stage that proves the thesis |

    zig build probe        # the kernel into probe/probe.elf
    probe/run.sh           # boot it under microvm against a disk image

`probe/` is a kernel that is only the driver and a serial port. It exists so a
driver can be put on virtual hardware and checked before anything is built on
top of it: it brings the device up, reads sector 0 and checks its boot
signature, then writes the last sector and reads all 512 bytes back. Reading
proves bytes moved; writing and comparing proves they moved **where we said**.

| where | what |
|---|---|
| `src/virtio.zig` | the MMIO transport, the virtqueue, and the block device on it |
| `probe/kernel.zig` | the probe: the PVH note, the long-mode stub, a serial port, and the checks |
| `probe/link.ld` | the layout — the note first, and `.bss` treated as unwritten |
| `probe/run.sh` | boots it under `-M microvm` and maps QEMU's exit code back to the guest's |

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

## What lives elsewhere

The Roc side of this work stays in
[`roc-apps/floor`](https://github.com/showell/roc-apps): the platform whose
doors Roc programs call, the FAT16 that runs on it, and the fault modes. That
floor and this repo are two implementations of the same device set — which is
the arrangement that has already earned its keep twice, and is why the drivers
here are written against the same doors.
