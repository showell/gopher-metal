# zig-metal-unikernel

A small operating-system kernel, written in Zig, that runs one web
application on a cloud machine with nothing else under it. No Linux, no libc,
no system calls: the kernel boots the machine, drives the network card and the
disks, and serves HTTP itself. It has served
[lynrummy.com](https://lynrummy.com) since 2026-10-04, and
[dogpark.lynrummy.com](https://dogpark.lynrummy.com), a second application
on a droplet of its own, since 2026-10-16.

This repo was called **gopher-metal** until 2026-10-13. GitHub redirects the
old links, and dated documents here still use the old name.

## What it is

A **unikernel** is one program compiled together with just enough kernel to
run it, booted directly on a machine (real or virtual), with no general
operating system in between. This one is written in Zig 0.16 and targets
`x86_64-freestanding`, Zig's name for "no operating system".

What it does by itself, with no borrowed code below the application:

- **Boots a real cloud machine.** In production that is a DigitalOcean
  **droplet** (DigitalOcean's name for a virtual machine you rent). A droplet
  starts like an old PC: its BIOS runs the first sector of the disk. This repo
  has its own two-stage boot loader (`droplet/loader.S`) that takes it from
  there to the kernel, and its own disk-image builder (`droplet/image.zig`).
  Under QEMU the kernel is started directly through PVH, the entry point QEMU
  and other virtual-machine monitors use for 64-bit kernels.
- **Drives its own devices.** Virtio network cards and disks (virtio is the
  standard family of virtual devices a hypervisor offers), over both the PCI
  bus a droplet has and the simpler MMIO layout QEMU's small `microvm`
  machine has; DigitalOcean's attachable volumes (virtio-SCSI); the serial
  port; the VGA text screen DigitalOcean's web console shows; the CMOS clock;
  the interrupt controller and timer.
- **Speaks the network itself.** Its own DHCP, ARP, IPv4 and TCP. On top of
  its TCP it runs Zig's standard-library HTTP server, `std.http.Server`,
  unmodified.
- **Keeps files itself.** Its own FAT16 and FAT32 (the filesystem a USB stick
  uses), read and write, with long names and folders. FAT was chosen because
  Linux can read and write the same volume, which makes it easy to judge and
  to back up.

What it is not:

- **No processes and no shell.** One program is compiled into the kernel. You
  cannot log in to it or run anything else on it.
- **One core, no threads.** One loop moves every connection along and serves
  one request at a time, start to finish. There is no preemption.
- **No TLS.** It speaks plain HTTP/1.1. In production a separate Linux machine
  runs Caddy, which handles HTTPS and forwards requests to it over
  DigitalOcean's private network.
- **Not general purpose.** It runs Zig applications written against one
  library, zig-webbox (below), and nothing else.
- **Not for arbitrary hardware.** It has been made to work on one kind of
  machine: a DigitalOcean droplet, and QEMU set up the same way. It does
  not claim to run anywhere else. Virtio is a fairly common standard among
  hypervisors, so other virtual machines are a plausible next step. The
  kernel can be extended gradually as we get access to other kinds of
  hardware. There are no promises beyond that.

**Battle tested, and what that honestly means.** It has served
lynrummy.com since 2026-10-04 for about three regular daily users, who
upload from their phones. That is all the battle there has been. It has
never been under real load or stress. Caddy sits in front of it on a
private network, so production only exercises a well-behaved, happy-path
setup: one polite client and no hostile or lossy traffic. The harder cases
are tested elsewhere. The judges and metal-vmm's faults and sweeps drop,
delay and damage frames, stall and reset clients, fail and cut disks, and
check what the machine did about it.

## How it is used now

### The applications

Both applications are built on **[zig-webbox](https://github.com/showell/zig-webbox)**,
a small Zig library: the application supplies its routes, pages and data
rules, and the library does the HTTP, cookies, live streams and storage. The
library reaches the machine only through one module, `host_io`. On Linux that
module is the standard library's; here it is this kernel's
(`src/host_io_metal.zig`). No line of the application changes between the
two.

- **[angry-gopher](https://github.com/showell/angry-gopher)**, Steve
  Howell's personal site, lynrummy.com: a chat and a handful of small apps
  (Lyn Rummy, a two-player rummy game, among them). **In production on this kernel.**
- **[dog-park](https://github.com/showell/dog-park)**, a small herding
  game on zig-webbox. **In production on this kernel since 2026-10-16**, at
  dogpark.lynrummy.com, on its own droplet. dog-park builds its own image,
  with this repo as a dependency, through `addAppKernel` (below; metal-vmm
  QUEUE 215) and `droplet/app_image.py`, and runs its own QEMU gate. This
  repo neither builds nor judges it (8af778b: an application is not this
  repo's test of itself).

**The same source, the same answers.** angry-gopher builds as an ordinary
Linux program and as a kernel from this repo. The checks here send the same
requests to both, built from the same source over the same files, and require
the same answers: status, redirect, cookies, content type, and the body byte
for byte (times stamped by the clock are compared to the window each side
handled the request in). Files a request writes are read back from both sides
and must match. Linux is the reference: if the kernel disagrees with Linux,
the kernel is wrong.

### The repos

Six repos, kept separate, checked out side by side:

```
                    zig-webbox  (the library)
                    /          \
       angry-gopher              dog-park
     (lynrummy.com)        (dogpark.lynrummy.com)
           |                         |
           |                         | (builds its own image,
           |                         |  through addAppKernel)
              zig-metal-unikernel  (this repo: the machine)
                    /          \
            metal-vmm            zig-coverage-sdk
      (test hypervisor)          (coverage properties)
```

- **zig-metal-unikernel** (this repo): the kernel, its drivers, TCP, FAT, the
  boot loader, the release tools, and the checks that hold the kernel to the
  Linux builds.
- **[zig-webbox](https://github.com/showell/zig-webbox)**: the library both
  applications are written against.
- **[angry-gopher](https://github.com/showell/angry-gopher)**: the
  application this repo builds and serves, compiled from its checkout as it
  is; nothing is copied in. **[dog-park](https://github.com/showell/dog-park)**:
  an application this repo does not build; it builds itself into a kernel
  through `addAppKernel`, and its image through `droplet/app_image.py`.
- **[metal-vmm](https://github.com/showell/metal-vmm)**: a deterministic
  hypervisor of our own, on Linux's KVM, used only for testing. It runs the
  real kernel with time, the network and the disks under the test's control,
  so a run can lose a chosen packet or fail a chosen disk write, and the same
  seed gives the same run every time. It also holds the one shared work queue
  for all these repos (`QUEUE.md`).
- **[zig-coverage-sdk](https://github.com/showell/zig-coverage-sdk)**:
  **coverage properties**, assertions about a whole run rather than one
  moment. `always(...)` must hold every time it is reached; `sometimes(...)`
  must be true at least once, so a case the tests meant to exercise but never
  did is a failure. The checks here read them. Every build needs it.

### Where lynrummy.com runs

- A droplet booted from a custom image this repo builds, with no Linux on it.
  It listens only on its private network card. Caddy, on an older Linux
  droplet, terminates HTTPS and forwards to it.
- **Two disks.** The boot disk holds the kernel and the site's own files
  (pages, pictures, and a config file), and a new release replaces it. The
  application's data (chat, accounts) lives on a separate DigitalOcean volume,
  FAT32, which a new release does not touch. The kernel refuses writes
  outside the data folders, and refuses to serve at all if the volume it was
  built for (named by its FAT serial number) is missing or another is
  attached, rather than answer as an empty site.
- **Each boot checks both disks** before serving, and reports what it finds.
- **`/admin/host`** (behind the admin login) shows the running server: the
  application's half (its version, commit, memory, refused requests) and the
  kernel's (this repo's commit, uptime, clock, connections, memory, disks,
  disk work, and the newest lines of the kernel's log). Linux shows the same
  page with its own half.

**Dog Park runs the same way**, on a droplet of its own on the same private
network, behind the same Caddy, but with **one disk**: its image holds the
kernel, the site and the data together, so a new release starts its games
over (dog-park's DEPLOY.md). It is the first application in production that
this repo does not build.

## Using it

### What you need

- **Zig 0.16.0**, exactly.
- **Python 3**, for the judges and the release tools.
- **QEMU** (`qemu-system-x86_64`) and **KVM**, for anything that boots a
  kernel. Without KVM, the droplet-shaped machine runs under software
  emulation (`ACCEL=tcg`), slowly.
- **Disk tools:** mtools, `mkfs.vfat` and `fsck.fat` (dosfstools), `sgdisk`,
  and binutils' `as` and `ld` for the boot loader.
- **The sibling checkouts**, in one folder beside this one: `zig-webbox`,
  `angry-gopher`, `zig-coverage-sdk`, and, for the full checks,
  `metal-vmm`. `build.zig` finds them as `../<name>` (`-Dgopher-root`,
  `-Dwebbox-root` name another place). **One rule for
  every script too:** a sibling is `../<name>` beside the checkout running
  it, in this repo and in metal-vmm; an environment variable names another
  place (`GOPHER_ROOT`, `WEBBOX_ROOT`, `METAL_VMM`,
  `COVERAGE_SDK`, and metal-vmm's `GUESTS`, this repo's `probe/`).
- **The pinned zig-coverage-sdk commit.** `build.zig` names the SDK commit it
  was written against and refuses another, printing the `git checkout` that
  fixes it. `-Dcoverage-sdk-unpinned` builds anyway.

Without QEMU, KVM or any sibling but the SDK (a laptop, a cloud container)
you can still run `./tier0.sh`, which is most of what catches a bug.

### Building a kernel for an application

    zig build gopher       # angry-gopher as a kernel: probe/gopher.elf
    zig build kernels      # every small test kernel ("probe"), into probe/

An application is a root Zig file that exports `site` (its routes) and
`hosting` (what only it can say about its data), plus an `assets.zon` naming
the files it serves. The kernel around it is the same file for every
application, `probe/gopher.zig`, and `addAppKernel` in `build.zig` puts the
two together. The contract between an application and its host is
[`HOST.md`](HOST.md).

**Another repository builds its own application into a kernel** with
`addAppKernel`, a public function of this package's `build.zig`. It names
this checkout as a dependency (a sibling, as zig-webbox is), builds its
application module itself, with its own options and imports, and hands over
the module, its `assets.zon` and a name; it gets the kernel's compile step
back:

    // build.zig.zon: .zig_metal_unikernel = .{ .path = "../zig-metal-unikernel" },
    const zmu = @import("zig_metal_unikernel");
    const app = b.createModule(.{ .root_source_file = b.path("src/hosted.zig"), .imports = ... });
    const elf = zmu.addAppKernel(b, b.dependency("zig_metal_unikernel", .{}), .{
        .name = "app.elf",
        .module = app,
        .assets = b.path("assets.zon"),
        .optimize = .ReleaseSafe,
    });

The module names no target or optimize mode (it takes the kernel's) and
imports neither `host_io` nor `webbox`: `addAppKernel` adds this machine's
(webbox from `../zig-webbox`, or the dependency's `-Dwebbox-root`). Each
`.embedded` row of `assets.zon` is compiled in by name from its path,
relative to `assets.zon`, **unless the module already imports that name**:
a file the caller's own build makes (a wasm, say) is imported by the caller
from the step that makes it. The kernel's parts stay the kernel's: its root,
link script, `metal` and `gm_build`; `-Drestart` and `-Dcoverage` are
options of the dependency. `zig build gopher` goes through the same
function.

Useful options: `-Ddev` builds Debug kernels, which rebuild in seconds instead
of tens of seconds (releases are ReleaseSafe, and every run says which it
judged); `-Drestart=false` makes a crash halt the machine instead of
restarting it; `-Dcoverage` makes the kernel print its coverage properties.
`zig build --help` lists every step and option.

### Running it locally

There is no single "boot it and browse" command. A kernel is run by the
script that judges it:

    probe/run.sh                  # boot each test kernel under QEMU (~45 s)
    probe/run.sh clock            # just one
    probe/run.sh gopher           # boot the real server and judge it against Linux
    probe/run.sh gopher uploads   # one part ("gate") of that judge, in seconds
    droplet/boot.sh               # the test kernels, booted the way a droplet boots them

`probe/run.sh gopher` needs angry-gopher's Linux build too; it builds it.
A part name it does not know is an error that lists them all.
`droplet/droplet.sh` is QEMU laid out like a droplet (the same chipset and
devices in the same slots, recorded from a real one); its header lists its
settings, among them forwarding a local port to the guest's port 80.
`droplet/rehearse.sh` boots the release kernel on that machine against a copy
of real data and compares it with Linux, page by page.
[`docs/probes.md`](docs/probes.md) says what each test kernel checks.

### The checks, fastest to slowest

A **judge** is a script that runs the kernel and the Linux build side by side
and compares them. A **gate** is a script whose exit code is a verdict (0
passes) and whose last line names what failed. A **simulator** drives one
pure part of the kernel (the TCP table, the FAT, the cache, the store) on
Linux, with no devices, over many random seeds; a seed that fails replays
exactly.

**The checks come in tiers** (`tier0.sh` to `tier3.sh`). Each tier adds
exactly one kind of dependency to the one before, and each says, when it
starts, anything it needs that is missing. Tier 0 also lists what it did not
check and which tier does. `./gates.sh` runs the four tiers in order,
cheapest first, and stops at the first one that fails.

| tier | install | what it proves | about |
|---|---|---|---|
| `./tier0.sh` | zig 0.16, Python 3, and the SDK beside this checkout | the unit tests and short simulator runs; this repo's kernels and host programs type-check; `zig fmt` and the lints. No QEMU, no other repo, no network, no root. Run it on every change | ~2-3 min (1m40s with everything compiled) |
| `./tier1.sh` | + QEMU, dosfstools, gdisk, mtools, curl, binutils, `sudo -n` for loop mounts; KVM for the droplet boots (or `ACCEL=tcg`) | each test kernel ("probe") boots and works on virtual hardware; the judges' own tests; the droplet's boot loader and image | ~45 s of probes, then the droplet boots |
| `./tier2.sh` | + metal-vmm beside this checkout, and /dev/kvm | metal-vmm runs this checkout's probe kernels the same as QEMU does, and the same twice | minutes |
| `./tier3.sh` | + zig-webbox and angry-gopher beside this checkout | the library's tests and the limits it copies; the unit tests' pinned body rule is still the library's; gopher.elf type-checks, builds and is judged against its Linux build on QEMU's microvm and the droplet-shaped machine; the PC-shaped machine's rests and the timeouts on metal-vmm | ~20 min |
| `zig build properties` | as tier 0 | the simulators over many seeds, judged by their coverage properties: zig alone, but not in tier 0 for its time (20 min in Debug, 5 with `-Dsweep-optimize=ReleaseSafe`); long.sh runs it at 10,000 seeds | 5-20 min |
| `./gates.sh quick` | as tier 3 | tiers 0 and 1, then gopher.elf and one chat-judge story | |
| `./gates.sh` | as tier 3 | tiers 0 to 3, for a batch | |
| `./long.sh` | as tier 3 | before every release: the simulators at 10,000 seeds; the FAT16 judge; the real kernel on metal-vmm losing each packet it sends in turn, facing a misbehaving client, and under 100 seeded fault schedules over the network and disks, every run still serving the right page | longest |

A developer can defer every test against angry-gopher (tier 3)
and still have reasonable confidence in a change that tier 0 passes.

Each script's header says what it runs and why. `./release-check.sh <dir>`
runs the two in order, the long tier only after the gates pass, detached,
with their logs and a summary in `<dir>`. The coverage properties and
the floors a long run must reach are in [`COVERAGE.md`](COVERAGE.md).

**A verdict is for exact code.** A full `./gates.sh` and a whole `./long.sh`
each record their verdict against what they judged: this repo's commit, the
SDK's, and a hash of every application and library file the kernel compiles
(`tools/verdicts.py` calls that hash the **content id**). The quick tier and a
partial `long.sh` record nothing.

### A deploy

A **release** is one boot image, built from this repo and the applications'
commits, tagged `vN` in this repo. By hand, in this order:

1. **Both gates pass** for the exact code: `./gates.sh` and `./long.sh`.
2. **`droplet/chat.py <out.img>`** builds the boot image: the boot loader, the
   kernel, and the site's own files with a config naming the data volume
   (`droplet/volume-serial`). It refuses unless both trees are clean and both
   verdicts are PASS for exactly this code. `RELEASE_UNGATED=1` overrides
   that, for an emergency, and says so loudly. The disk itself is laid out
   by **`droplet/app_image.py <kernel.elf> <site-dir> <conf> <out.img>`**,
   any application's builder (Dog Park's too): the kernel in partition 1,
   the site folder and the conf in partition 2, with `--disk-mib`, `--fat`
   and `--label` for the site filesystem.
3. **gzip it** and put it where DigitalOcean can fetch it.
4. **Steve imports it as a custom image** and rebuilds the droplet from it.
   The data volume stays attached and untouched.
5. **Tag the commit** `vN`.

**The way back** is the previous tag's image: rebuild the droplet from it. The
last resort, moving the site back to Linux, is in [`CUTOVER.md`](CUTOVER.md),
"The way back"; it needs the data copied off the volume first, or everything
written since the cutover is lost.

### Release notes: the script route (metal-vmm QUEUE 200; serving since v30)

`POST /admin/script` runs a signed Shale script on the live site
(angry-gopher's `admin_script.zig`, zig-webbox's `script_route.zig`). It is
refused until a key is set, so a release with it changes nothing until
these steps. Once, after the release that carries it:

1. **On the box, make the key pair** (zig-webbox checkout):
   `zig build shale-sign -- keygen`. The private key is
   `~/.shale_signing_key`, mode 600; the program never prints it. It prints
   the public key's line, `public_key = <64 hex>`; `-- pubkey` prints it
   again.
2. **On the site, set it**: sign in as the admin, open `/admin/script-key`,
   paste the 64 hex digits, leave the target `lynrummy.com`, type the admin
   password, Set. (On Linux the same file can be written by hand instead:
   `<auth>/shale.conf` with `public_key = <hex>` and `target = <name>`.)
3. **The admin's API key** is the first lock: the one `/admin/host` takes
   (`/admin`, the admin's row, Generate), kept on the box as
   `SHALE_ADMIN_KEY` in the environment.
4. **A script**: `zig build shale-sign -- sign topics.shale lynrummy.com`
   writes `topics.shale.<sequence>.req` and prints the `curl` line that
   sends it. Each request runs once: a replay, an older number, one past
   its expiry (10 minutes by default) or for another target is refused.

5. **A long read, in the background** (from v32, metal-vmm QUEUE 222):
   `zig build shale-sign -- background topics.shale lynrummy.com` signs a
   `mode=background` run. It is answered at once (202, with its number),
   only reads (up to 10,000 reads, against an atomic run's 500), and is
   stepped a slice at a time between requests, so the site answers beside
   it. `GET /admin/script` (the same API key) says whether it is running
   or how the last one ended, with what it printed. One runs at a time: a
   second is refused (503 busy) while one runs, and
   `zig build shale-sign -- kill lynrummy.com` ends it.

Explore first with a script that only reads (it changes nothing), then
send the one that changes. Every run is logged under `auth/shale/` on the
volume (the log, and each run's source by its number). Changing the key is
step 2 again; the old key's scripts are refused from then on.

[`CUTOVER.md`](CUTOVER.md) is the record of the move from Linux on 2026-10-04,
with the tools it used, backups, and the way back.
`droplet/new_volume.py` builds a new, empty data volume.

## Where it stands (2026-10-16)

**Serving: tag `v30`**, deployed 2026-10-14: this repo at `1d8642c`,
angry-gopher at `2e560b2b`, zig-webbox at `92ea157`. The way back is `v29`.
`master` may be ahead of `v30`; what serves is always a tag, never a branch.
The tag's message (`git show v30 --no-patch`) has the image's checksum. The
script route's key is set (2026-10-14); its first three runs are in metal-vmm's FEEDBACK (2026-10-14, "v30 serves").

- **served**: in v30, on lynrummy.com.
- **master**: on `master`, newer than v30, not served yet.
- **test only**: exists for the checks, never deployed.
- **unmeasured**: built, but the number a reader would want has not been taken.

| | state | |
|---|---|---|
| booting a droplet | served | own BIOS boot loader, from a GPT disk; also tested on the droplet-shaped QEMU, on dirty memory |
| booting under QEMU and metal-vmm | test only | PVH entry, QEMU's `microvm` and `pc` machines, metal-vmm |
| the screen | served | everything the log says also goes to VGA text, which DigitalOcean's console shows |
| interrupts, and resting when idle | served | on the PCI machine a droplet is, the card wakes it (MSI-X), else a 1 ms timer. On the MMIO test machines it polls instead |
| virtio network, disk and SCSI volume drivers | served | over PCI on the droplet; over MMIO in tests |
| DHCP, ARP, TCP | served | up to 256 connections; the peer's window and segment size respected, lost segments resent, silent peers given up on. Segments that arrive out of order are not kept |
| HTTP | served | `std.http.Server`, unmodified |
| FAT16 and FAT32, read and write | served | long names, folders, append, replace, delete; checked by `fsck` and by Linux reading what it wrote. Production's volume is FAT32 |
| clocks and entropy | served | the CMOS real-time clock; the TSC's rate measured against the PIT; random bytes from virtio-rng where the machine has one, and RDRAND |
| angry-gopher's whole site | served | every route, judged equal to the Linux build, including chat's live streams and uploads |
| another repository's application as a kernel | served | Dog Park, on dogpark.lynrummy.com since 2026-10-16: dog-park's image `ab222a2`, built with this repo at `67faf97` (`master`, newer than v30), through `addAppKernel` and `droplet/app_image.py`; one disk, no volume. This repo neither builds nor judges any application but angry-gopher (an application is not this repo's test of itself); Dog Park's own QEMU gate and droplet rehearsal check its image |
| file contents kept in memory | served | after their first read, write-through (`page_cache_mib`, 64 MiB by default) |
| large disk requests | served | a run of contiguous clusters is one request of up to 1 MiB (the least of the disk's, the controller's and our own limit) |
| the FAT written a sector at a time | served | v29's measured disk requests for a 1.8 MB, 10 MB and 100 MB upload: 59, 26 and 115 (v28: 93, 218 and 2,017) |
| the FAT's two copies weighed at mount | served | if they differ, the cleaner copy wins and the other is rewritten from it |
| a mount whose FAT copies cannot be weighed | served | refuses writes until a weighing succeeds (a 503 with Retry-After) |
| an overwrite read back before the old copy is freed | served | |
| a disk check at every boot | served | both disks; a damaged disk is reported and still served |
| a disk check in idle time | served | after 200 ms with nothing arriving, the kernel checks the volume a slice at a time ([HOST.md](HOST.md), "Idle time"). Its cost on production's full volume: unmeasured here |
| exact accounting of what a failed write leaves | served | leaked clusters, orphaned name entries and long chains, counted on `/admin/host` |
| restarting after a crash | served | on by default since a droplet's reset was measured to restart it (2026-10-03); the last boot's log is kept across the restart, and a disk that stops answering restarts it too ([RESTART.md](RESTART.md)) |
| the log, on `/admin/host` and `/admin/log` | served | a 1.25 MiB ring, secrets removed as they are written; every request line with its time, status and duration; `/admin/host` shows the newest lines, `/admin/log` all of it as plain text for scripts; recent uploads and request counts ([docs/admin-for-agents.md](docs/admin-for-agents.md)) |
| the new name, and zig-webbox as its own checkout | served | `zig-metal-unikernel.conf`; the library built from `../zig-webbox` |
| `/admin/backup` | served | the whole data set as one tar, checked by `droplet/check_backup.py`; taken by hand with `droplet/backup.sh`. Routine backups were not yet scheduled as of 2026-10-08 ([CUTOVER.md](CUTOVER.md), "Backups") |
| speed against Linux | unmeasured | last measured 2026-10-01 on v4, before the caches ([docs/port.md](docs/port.md)) |

## Where things are

| where | what |
|---|---|
| `src/` | the kernel: boot, drivers, network, FAT, the `Io` the application calls (`io.zig`), the simulators (`*_sim.zig`) and `properties.zig` |
| `src/host_io_metal.zig` | the one file that hands the application this kernel's `Io` |
| `probe/gopher.zig` | the kernel around an application: one loop, the disks, `/admin/host`'s kernel half |
| `probe/*.zig` | small test kernels, one subsystem each |
| `probe/run.sh`, `probe/judge_*.py` | booting them under QEMU, and the judges |
| `droplet/` | the boot loader, the image builder, the droplet-shaped QEMU, and the release, backup and cutover tools |
| `tools/verdicts.py` | which code a gate judged, and the release rule |
| `coverage/` | the coverage floors `long.sh` holds runs to |
| `gates.sh`, `long.sh` | the gates |

## Documents

**Contracts:**
- [`HOST.md`](HOST.md): what Linux and this kernel both promise an
  application (one handler at a time, durability, limits, idle time).
- [`STORE.md`](STORE.md): the application's data, its operations and what
  each promises across a crash.

**Design**, in `docs/`:
- [`docs/port.md`](docs/port.md): how the application runs here unchanged,
  `std.http.Server`, one loop, the stack and the memory.
- [`docs/disk.md`](docs/disk.md): why our own FAT, and how it is judged.
- [`docs/tcp.md`](docs/tcp.md): the network loop, live streams, and what
  the TCP does not do.
- [`docs/probes.md`](docs/probes.md): the test kernels, and QEMU's traps.
- [`docs/admin-for-agents.md`](docs/admin-for-agents.md): reading
  `/admin/host` and `/admin/log`.
- [`docs/designs/`](docs/designs/README.md) and
  [`docs/reviews/`](docs/reviews/README.md): notes and adversarial reviews
  of particular changes.
- [`FAT32.md`](FAT32.md), [`RESTART.md`](RESTART.md),
  [`TCP_TESTING.md`](TCP_TESTING.md), [`COVERAGE.md`](COVERAGE.md),
  [`MUTATION.md`](MUTATION.md) (which deliberately planted bugs the tests
  catch).

**Operations:** [`CUTOVER.md`](CUTOVER.md) (the move from Linux, backups,
the way back), [`MIGRATION.md`](MIGRATION.md),
[`SECRET-LEAK.md`](SECRET-LEAK.md),
[`ADMIN-PASSWORD-LOST.md`](ADMIN-PASSWORD-LOST.md).

## Working on it

The work is done by Claude, on Steve's development machine and in Claude Code
cloud sessions, with Steve. [`CLAUDE.md`](CLAUDE.md) says who does what.

- **`master`** has everything. **`vN`** tags are releases; the newest
  serves. **`claude/*`** branches are cloud sessions' work, merged by the
  development machine; nobody else pushes `master` or a tag.
- **Live work** is in metal-vmm's
  [`QUEUE.md`](https://github.com/showell/metal-vmm/blob/master/QUEUE.md).
  Code comments and commits cite its items as "metal-vmm QUEUE N". A bare
  "QUEUE.md item N" means this repo's old queue, now retired
  (`git show 3cd662c:QUEUE.md`), whose numbers overlap.
