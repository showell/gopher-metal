# Review: two disks, read as an adversary

This review covers `c22d4c8` ("Two disks: the site on the boot disk, chat's
data on the volume"):

- `src/io.zig`'s routing: `placeOf`, `volumeAt`, `reading`, `writing`,
  `keepData`, and every `Dir`/`File` entry point that uses them;
- `probe/gopher.zig`'s boot path: `bootDisk`, `dataVolume`, `mountFat`;
- how `droplet/chat.py` splits the images.

The question is whether any path, spelling or sequence can read from or
write to the wrong disk, or write past the refusal. Nothing is fixed here.
Each finding names the failure it would cause and whether the application
can reach it today.

The application side was read in a fresh `port.sh` copy of angry-gopher:

- every `Io.Dir` call site;
- `roots.point`;
- the stores' path builders;
- the `deleteTree` callers.

## What holds up

These were checked and found sound, so the findings below are not about them:

- **Every mutating entry point is routed through `writing`.** That is
  `writeFile`, `createFile`, `createDirPath`, `deleteFile`, `deleteTree` and
  `File.writePositionalAll`. A `File` routes each read and write by the
  path it stored, not by where it was opened, so a handle cannot change
  disks.
- **Nothing on the host writes to a volume around `io.zig`.** `gopher.zig`
  calls no fat16 write API itself. It reads `gopher-metal.conf` after
  `keepData`, and from the boot disk.
- **Every application write lands in a data directory.** Every store path is
  built by `roots.point` from `data` or `auth`, or from `chat_root`
  (`data/chat`) for docs, code, images, chat state and uploads. The writes
  under `.zig-cache` belong to the application's own tests. So the refusal
  does not trip on anything the server legitimately does.
- **The application never uses a `Dir` it opened for anything but
  `iterate`.** Every other call is spelled `Io.Dir.cwd().…`, which is what
  makes finding 4 latent rather than live.
- **A misrouted read finds nothing.** `chat.py` moves `data/` and `auth/` off
  the boot image, so a read sent to the boot disk by mistake misses instead
  of serving a stale copy. That is true for images `chat.py` builds; finding
  1 is about what happens when that assumption meets a missing volume.
- **`deleteRecord` cannot be pointed at a root.** It refuses an unsafe id
  (`player.isSafeID`).

## Findings

In order of severity.

### 1. No volume means an empty site, and the writes made then are lost

**Fixed, with #2:** `volume = <FAT serial>` in `gopher-metal.conf`; the machine stops when that volume is missing.

**Where:** `gopher.zig`, `dataVolume` → `Io.keepData(&data_dirs, null)`.

**The problem:**

- When the SCSI controller has no disk, the machine says "no volume
  attached" and keeps the data on the boot disk.
- On an image from `chat.py`, the boot disk has no `data/` or `auth/` at all.

**Failure:**

- The server comes up with no accounts, no sessions and no conversations,
  and answers as if that were true.
- A visitor who signs up, or posts, writes to the boot disk.
- The next image erases it, silently.
- Meanwhile the real data sits on a volume nobody attached.

**How likely:** any boot where the volume is detached, still being attached,
or failed to attach. These are ordinary events on DigitalOcean, and none of
them is an error the machine notices.

**Fix shape: fail closed.**

- `chat.py` writes `volume = required` into the boot image's
  `gopher-metal.conf`.
- With that setting, `dataVolume` returning null stops the machine with a
  message saying so, rather than serving an empty site.
- Single-disk QEMU judging leaves the setting out and keeps today's
  behaviour.

### 2. Any FAT16 disk on the SCSI bus is taken as chat's data

**Fixed:** the identity is the FAT serial mkfs chose (as `blkid` shows it), so the live volume needed no marker file. A volume with another serial stops the machine.

**Where:** `dataVolume` takes the first disk `scsi.bring` finds, at any
target and LUN. `mountFat` asks only that its first data partition be FAT16.

**The problem:** nothing says this is *the* volume.

**Failure:** the server reads and writes whatever data is on whatever FAT16
disk it finds, for example:

- the judge's test-site volume attached to the production droplet, or the
  reverse;
- a freshly formatted volume, which serves an empty site exactly as in
  finding 1;
- two volumes attached, where the first by target/LUN wins. That order is
  not something DigitalOcean promises.

**How likely:** one wrong click in the control panel, or a second volume
added later for any reason.

**Fix shape:** an identity on the volume.

- The simplest is a marker file at the volume's root (`gopher-volume`, a few
  bytes of id) that `chat.py` writes once.
- `gopher-metal.conf` on the boot image names the id it expects.
- A volume without the marker, or with another id, stops the machine.
- The FAT volume label or serial number would do instead, but a file is
  easier to inspect from Linux.

### 3. The disk is chosen by the path as spelled, and fat16 resolves it differently

**Fixed:** `placeOf` refuses any path with a `.` or `..` component, for reads and writes, and compares the first directory ignoring case.

**Where:** `placeOf` looks at the raw first component and compares it
exactly. `fat16.Volume.open` then walks the whole path:

- names match case-insensitively (`eqlFold`);
- `.` and `..` are real directory entries in every subdirectory, so they
  resolve.

When the two disagree, a path is routed by one reading and resolved by the
other.

**a. `..` past the first component.** `data/../x` is routed to the volume, and
fat16 resolves it to `x` at the *volume's* root.

- **Reads** see the volume's root instead of the site. Linux would read the
  site's `x`.
- **Writes** are allowed, because the first component is `data`, and land
  outside `data/` and `auth/` on the volume. That is the case the refusal
  exists to stop.
- **`deleteTree("data/..")`** opens the `..` entry, whose cluster is the
  root, and runs `removeTreeAt(0)`. That deletes everything on the volume,
  `data/` and `auth/` alike.
- **Reachable?** Only if a `..` reaches `io.zig`:
  - the application's paths are joined from fixed roots and ids;
  - `deleteRecord` checks its id;
  - but `chat.zig`'s `SegIter` passes a `..` URL segment through, and not
    every store was audited for validation.

  On Linux the same traversal would be the application's own bug. Here it
  also crosses the boundary between the disks, where Linux's would not.

**b. A leading `./`.** `./data/x` is routed to the boot disk (first component
`.`).

- **Reads** miss where Linux finds the file.
- **Writes** are refused.
- **Reachable?** The application never spells a path this way, so this is
  latent.

**c. Case.** `Data/x` is routed to the boot disk.

- **With a volume,** reads miss, which agrees with Linux, and writes are
  refused, where Linux would create the file. That divergence is harmless.
- **Without one** (data on the boot disk), FAT's case-folding finds
  `data/x`, which Linux would not.
- **Reachable?** Latent.

**Fix shape:** normalize, or refuse, before routing.

- `io.zig` refuses any path with an empty, `.` or `..` component, for reads
  and writes alike (`FileNotFound` / `BadPathName`).
- It compares the first component with `eqlFold`, as fat16 does.
- That closes all three, keeps the routing and the resolution in agreement,
  and costs one pass over the path.

### 4. A `Dir` other than `cwd()` resolves from the root of whichever disk the name picks

**Fixed:** `Dir.fromRoot` panics, saying why, when a path is asked of any `Dir` but `cwd()`.

**Where:** every `Dir` method except `iterate` starts with `_ = self;`.

- It resolves `sub_path` from the root of the volume that `placeOf(sub_path)`
  picks.
- `openDir` records `.place` and `.cluster`, but only `iterate` uses them.

**Failure:**

- Suppose `const d = cwd().openDir("data/chat")`, then `d.openFile("x")`.
  That reads `x` at the *boot disk's* root, not `data/chat/x` on the volume.
- Before the split this was "the wrong directory". Now it is "the wrong
  disk".
- A write through such a `Dir` (`d.createFile("x")`) is refused, which is the
  better failure.

**How likely:** not reachable today, since the application uses non-`cwd`
`Dir`s only to iterate. It is the first thing a well-meaning change to the
application would break.

**Fix shape:** make it loud.

- Those methods return an error, or `@panic` with a message, when
  `self.cluster != 0` or `self.place != .site`.
- Or they honour the handle, by joining its path, now that `Dir` has to
  carry a place anyway.

### 5. Listing the root lists only the boot disk

**Recorded** in `Dir.iterate`'s comment.

**Where:** `cwd().iterate()` lists the site volume's root.

**Failure:** `data` and `auth` are missing from the listing when they live on
the volume.

**How likely:** latent, since the application never lists the root. It is
recorded so that a future "list everything" feature does not conclude the
data is gone.

### 6. The boot disk is the first virtio-blk device, by position

**Where:** `bootDisk` → `virtio.find(device_id_block)`.

**The problem:** on a droplet the boot disk is the only virtio-blk device, and
volumes arrive on SCSI. Nothing checks that the disk found is the one the
machine booted from.

**Failure:** on a machine with a second virtio-blk disk, which some QEMU
setups and other hosts have, the site could be read from the wrong one.

**How likely:** not on a droplet as DigitalOcean builds them today.

**Fix shape:** confirm the boot disk by what it holds. The loader can pass
the disk's GPT GUID, or the kernel can look for its own image in partition
1. Or record the assumption in a comment beside `bootDisk`.

## Suggested order, when fixing

1. **#1, `volume = required`.** It is the one most likely to happen, and its
   failure is silent data loss.
2. **#3, normalize or refuse `.`, `..` and case before routing.** It is
   small, and it closes the only route by which the refusal can be passed.
3. **#2, a volume identity.** It needs `chat.py` to write the marker, and a
   decision on what the id is.
4. **#4, a loud failure for relative `Dir` use.** Cheap insurance.
5. **#5 and #6:** a comment each, unless a feature makes them real.
