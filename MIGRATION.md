# Moving prod's chat data onto a FAT16 volume

Prod's chat data is about 215 MB in 801 files under `data/` and `auth/`. It
lives on Linux, whose filesystem allows almost anything in a name or a tree.
It is going onto a FAT16 volume that two different programs will handle:

- **Linux's vfat driver writes the volume.** The volume is made the way
  `droplet/chat.py` and `judge_gopher.build_disk` make one: `mkfs.vfat -F 16`,
  loop-mount, copy.
- **This machine's own `src/fat16.zig` and `src/io.zig` read it afterwards**,
  and write it from then on.

This note lists what Linux allows and one of those two cannot hold, says
which of those the application itself can produce, and gives the copy step
by step. `droplet/check_volume_tree.py <dir>` finds every case in a real
tree before anything is copied.

## The short version

1. Run `droplet/check_volume_tree.py <copy of prod's data>` (the directory
   holding `data/` and `auth/`). Fix or decide on everything it lists.
2. Build the volume as `chat.py` does, but **mount it with `tz=UTC`**.
3. Copy with `shutil.copytree` (it keeps modification times), unmount, and
   run `fsck.vfat -n`.
4. Compare every name, size, hash and modification time with the source:
   `droplet/compare_volume.py <copy> <volume.img>`, which needs no mount.
   Then boot this machine on it and let the chat judge's read gates look.

The application can produce exactly one of the hazards below: **names that
differ only in case**. It could also produce **names too long for
`fat16.zig`** until `max_name` went from 64 to 96 (QUEUE.md item 8). The
other hazards would have to come from something other than the application.

## What the application builds

From angry-gopher's own code (`roots.zig`, `chat_store.zig`, `users.zig`,
`player.zig`, `storage.zig`, `docs_store.zig`, `chat_upload.zig`,
`chat_state.zig`, `chat_links.zig`):

| part of a path | rule (from the validator) | where it appears |
|---|---|---|
| session id | `[A-Za-z0-9]+(-[A-Za-z0-9]+)*`, 1–80 chars, **either case**, chosen in the URL (`validSessionID`) | `sessions/<sid>.md`, `.count`, `.lastauthor`, `.reactions.jsonl`, `<sid>.uploads/` |
| channel name | a letter, then up to 39 of `[A-Za-z0-9-]`, **either case** (`validChannelName`) | `data/chat/channels/<name>/`, `<name>.channel` |
| doc slug | `[a-z0-9]+(-[a-z0-9]+)*`, 1–80, lower case (`validDocSlug`) | `data/chat/users/<uid>/docs/<slug>.md` |
| upload | 16 random bytes in hex, `.` extension | `<sid>.uploads/<32 hex>.<ext>` |
| user, player, conversation | digits; `p<n>`; `<a>_<b>` | `auth/<id>/`, `data/players/<id>/`, `data/chat/<a>_<b>/` |
| fixed names | `_session_secret`, `next-id.txt`, `last-seen` (users and players), `upload-bytes`, `admin`, `api-key`, `password`, `name`, `code.md`, `images.md`, `last-conv` | |
| placed by hand | `links.md`: `chat_links.zig` reads it, and nothing in the application writes it | `data/chat/users/<uid>/links.md` |

Every name is ASCII from `[A-Za-z0-9._-]`. No name ends in a dot or a space.
The deepest path is about 200 bytes and seven levels:
`data/chat/channels/<40>/sessions/<80>.uploads/<36>`.

## The hazards

### Names that differ only in case — **the application can produce these**

- **Linux** holds `Plan.md` and `plan.md` side by side.
- **FAT** does not: names are compared without case.
  - `shutil.copytree` onto a vfat mount opens the second name, finds the
    first, and writes over it. There is no error, and one session is gone.
  - This machine's `fat16.zig` also finds names without case (`eqlFold`).
- **The application can produce them.** Session ids keep their case and come
  from the URL, so two topics `Plan` and `plan` in one conversation are two
  sessions on Linux. Channel names are the same.

**This is a hazard after the migration too, not only during it.** On this
machine, creating session `plan` when `Plan` exists replaces it
(`writeFileIn` removes the old entry by name, without case, first). The
same request on Linux makes a second session. The fix belongs in the
application: fold session ids and channel names to one case, or refuse one
that differs from an existing one only in case. Until then, the checker
says whether prod has any.

### Names too long for this machine — **the application could produce these, before `max_name` was 96**

- **Linux** allows 255 bytes. **VFAT** allows 255 UTF-16 characters, so the
  copy succeeds.
- **`fat16.zig` reads and writes names up to `max_name` = 96.** A longer
  name is refused on write, and on read is found only under its 8.3 alias
  (`SESSIO~1.JSO`), so the application cannot open it by name, and a
  listing shows the alias.
- **The application's longest name is 96 characters.**
  `<sid>.reactions.jsonl` is 16 characters longer than the session id, and
  a session id may be 80. A doc slug may be 80 too, making `<slug>.md` 83.
- **It was 64 until QUEUE.md item 8.** Then any session id over 48
  characters, or a doc slug over 61, made a name this machine could not
  hold. Kernels from before item 8 should not serve a migrated volume.
  Nor should kernels from before `d1c7364`, whose reader stopped at 52.

**What to do:** nothing, on a kernel with `max_name` = 96. The checker
still lists any name over 96 in prod's data, which only something other
than the application could have made.

**Paths and depth are fine:**

- `io.zig` opens paths up to 256 bytes; the application's deepest is about
  200.
- `fat16.zig`'s `removeTree` stops at 16 levels; the application's deepest
  tree is about 7.

The checker reports any path past either limit.

### Characters FAT forbids — the application cannot produce these

| what Linux allows | what happens | effect on this machine |
|---|---|---|
| `" * : < > ? \ \|` or a control character | VFAT refuses the name, so the copy fails with `EINVAL` | — |
| a name ending in `.` or a space | vfat drops the trailing dots and spaces, so `notes.` is stored as `notes`, and collides with `notes` if both exist | — |
| a character past ASCII | VFAT can store it (with `iocharset=utf8`) | `fat16.zig` reads it as `?` and cannot find the file by its name |

### Files over 4 GiB — the application cannot produce these

A FAT file's size is 32 bits, so a write past 4 GiB − 1 fails with `EFBIG`.
Caddy caps one upload at 110 MB, and the application caps a user at 1 GiB
in all.

### Timestamps outside 1980–2107 — the application cannot produce these

- **The range.** FAT dates run from 1980-01-01 to 2107-12-31. vfat clamps
  anything outside that, and `fat16.zig` writes "no date" for it. Every file
  the application writes carries a real modification time; a file from
  elsewhere (a `tar` with zero times, say) might not.
- **Two things change for every file**, and matter because chat's "recent"
  is ordered by modification time:
  - **resolution:** FAT keeps times in 2-second steps, so two writes in the
    same 2 seconds sort by name;
  - **time zone:** vfat stores local time. `build_disk` mounts without
    `tz=`, so on a host whose zone is not UTC every time shifts by the
    host's offset. **Mount with `tz=UTC` for the migration.** This machine
    reads FAT times as UTC.

### Symlinks, hard links and special files — the application cannot produce these

| on Linux | on FAT |
|---|---|
| symlink | FAT has none. `shutil.copytree` follows it: a link to a directory copies that tree again, and a dangling one fails the copy. |
| hard link | stored as separate copies, which no longer change together |
| pipe, socket or device | cannot be stored |

The application's `Io` has no call that makes any of these.

### Paths the application does not build — decide whether they move

Nothing is wrong with them on FAT, but something other than the application
wrote them, so they move only if someone decides they should. The checker
reports each such tree once, at its top (`not-the-apps`).

On prod, 2026-10-02, there were two kinds:

- **`data/chat/blog-comments/`**: the retired blog's comments (angry-gopher
  `9f91713c`, `246d82de`). Deleted from prod that day, with the deploy
  directory's old `blog/`, at Steve's direction; a copy is in
  `~/prod-archive/blog-2026-10-02.tgz` on the development box.
- **`data/users/r/` and `data/users/y/`**, one `last-seen` each, written
  2026-06-23 16:01 UTC, 14 seconds apart. That is the chunked-body identity
  bug: a user id read from request memory that the body read had just
  overwritten, fixed 41 minutes later (`e2610edd`). `touchUser` made a
  directory under whatever id it was handed.

**Run the checker on a real copy** (`rsync -a`, without `-H`), not on a
hard-linked view of prod's tree: every file in such a view has two names, and
each is reported as a hard link.

### How many entries a directory holds

- **The size of a name on disk.** An entry is 32 bytes. A name that is not
  upper-case 8.3, which is every name the application makes, takes one entry
  plus one more per 13 characters.
- **The root is a fixed run** of 512 entries (`mkfs.vfat`'s default). It
  holds `data` and `auth`, 4 entries in all.
- **Every other directory may grow to 65,536 entries** (2 MiB). Past that
  `fsck.fat` calls it broken. **`fat16.zig`'s `grow` does not stop there:** it
  would go on extending the directory, and the Linux side would then refuse
  the volume. This is worth a check in `grow`.
- **The application's busiest directories:**
  - **a conversation's `sessions/`:** five names a session, about 4–8 entries
    each, so roughly 4,000 sessions in one conversation before the limit;
  - **a session's `<sid>.uploads/`:** 36-character names, 4 entries each, so
    about 16,000 uploads in one session;
  - **`auth/`:** one directory per account.
- **Speed matters long before the limit.** `fat16.zig` finds a name by
  reading its directory from the start, every time.

The checker reports, per directory, whether it is over its limit.

### Space on the volume

`chat.py` asks for 2 GiB, as large as FAT16 goes, which `mkfs.vfat` formats
with 32 KiB clusters. Every file and directory takes whole clusters:

- 801 files waste at most 801 × 32 KiB ≈ 26 MB;
- with 215 MB of data, that is well inside 2 GiB.

The checker adds it up for the real tree. On prod, 2026-10-02: 835 files and
275 directories take 251 MB on the volume, 12% of it.

### What survives, changed

- **Owners and permissions are lost.** `password` and `api-key` are `0600` on
  Linux; on FAT every file belongs to whoever mounts it. That doesn't matter
  on this machine, which has no users. It does matter for the backup story:
  anyone who can mount the volume can read them.
- **Access and change times are lost**; only the modification time is kept,
  in 2-second steps.

## The copy, step by step

1. **Take a consistent copy of prod's `data/` and `auth/`.** Stop the server
   or snapshot, so that no file changes during the copy.
2. **Check it:**

       droplet/check_volume_tree.py /path/to/copy        # exit 0: nothing found
       droplet/check_volume_tree.py /path/to/copy --json # the same, for a script

   For each finding, rename or remove it in the copy (and in prod, if prod
   is to keep running on Linux meanwhile), or decide to lose it. Then run
   the checker again until it finds nothing.
3. **Build the volume** as `chat.py` builds one (`judge.build_disk(...,
   size=2 << 30)`), but mount with `tz=UTC` added to the options. Then copy
   with `shutil.copytree`, which keeps modification times through `copy2`,
   and unmount.
4. **Check the volume** with `fsck.vfat -n volume.img`, at the partition's
   offset or on a loop device of the partition.
5. **Compare**, without mounting:

       droplet/compare_volume.py /path/to/copy volume.img        # exit 0: identical
       droplet/compare_volume.py /path/to/copy volume.img --json

   It reads the volume through `tools/fat16_read.py`, an independent reader
   written from the FAT spec, so it needs no root. For every file and
   directory in the copy it checks:
   - the name exists, compared exactly, not by case;
   - the size and SHA-256 match;
   - the modification time is within 2 seconds, read as UTC.

   It also reports anything on the volume that is not in the copy, and any
   inconsistency in the volume itself. A volume copied without `tz=UTC`
   shows here as every file's time off by the host's offset.
   `droplet/compare_volume.py --self-test` makes volumes with mkfs.vfat and
   mtools and checks that each kind of mismatch is found.
6. **Let this machine read it.** Boot with the volume attached and request:
   - a conversation;
   - a session with uploads;
   - "recent";
   - a login with a real account.

   The droplet judge's read gates do the same against Linux.
7. **Write the volume onto the DigitalOcean volume once.** From then on, a
   new boot image never touches it.

## Rehearsed, 2026-10-02, on a copy of prod's data (FAT16)

On the development box, nothing on a droplet, angry-gopher `28702571` on both
hosts (the Store's first slice in it):

| step | result |
|---|---|
| 1. the copy | `rsync -a` of prod's `data/` and `auth/`, 2 s: 827 files, 266 directories, 215 MB |
| 2. check it | `check_volume_tree.py`: nothing but `data/users/r` and `data/users/y` (`not-the-apps`), since deleted from prod |
| 3. build the volume | `judge.build_disk(..., size=2 << 30)`, Linux's mount with `tz=UTC`, 3 s |
| 4. check the volume | `fsck.fat -n`: clean, 1,094 files, 7,641 of 65,493 clusters (250 MB); `tools/fat16_read.py check`: ok |
| 5. compare | `compare_volume.py`: "the volume holds the copy exactly" (names, sizes, SHA-256s, times) |
| 6. let this machine read it | booted on the droplet machine with the volume found by its serial; the same copy on Linux. Anonymous pages identical. As uid 1 (a session signed with the copy's own secret), **155 pages: 154 identical**: every conversation, every topic, its `raw` and `reactions`, recent, docs, links, images, code, settings, the admin and game rosters |

**The one difference is FAT's clock.** `/chat/recent` shows 7 sessions one
second earlier on metal: their last change fell on an odd second, and FAT
keeps modification times in 2-second steps ("What survives, changed").
After the cutover metal agrees with itself; only two sessions changed within
one 2-second window could ever trade places there.

**Not rehearsed yet:** the same on FAT32 (QUEUE item 17), the mtools build
(`build_volume.py`, item 19) against the Linux mount's, writes after the
move (a message, an upload, a login) compared with Linux, and step 7, the
real DigitalOcean volume.
