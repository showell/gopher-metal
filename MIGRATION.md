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
4. Mount read-only and compare every name, size, hash and modification time
   with the source. Then boot this machine on it and let the chat judge's
   read gates look.

The application can produce exactly two of the hazards below: **names that
differ only in case** and **names too long for `fat16.zig`**. The other
hazards would have to come from something other than the application.

## What the application builds

From angry-gopher's own code (`roots.zig`, `chat_store.zig`, `users.zig`,
`player.zig`, `storage.zig`, `docs_store.zig`, `chat_upload.zig`,
`chat_state.zig`):

| part of a path | rule (from the validator) | where it appears |
|---|---|---|
| session id | `[A-Za-z0-9]+(-[A-Za-z0-9]+)*`, 1–80 chars, **either case**, chosen in the URL (`validSessionID`) | `sessions/<sid>.md`, `.count`, `.lastauthor`, `.reactions.jsonl`, `<sid>.uploads/` |
| channel name | a letter, then up to 39 of `[A-Za-z0-9-]`, **either case** (`validChannelName`) | `data/chat/channels/<name>/`, `<name>.channel` |
| doc slug | `[a-z0-9]+(-[a-z0-9]+)*`, 1–80, lower case (`validDocSlug`) | `data/chat/users/<uid>/docs/<slug>.md` |
| upload | 16 random bytes in hex, `.` extension | `<sid>.uploads/<32 hex>.<ext>` |
| user, player, conversation | digits; `p<n>`; `<a>_<b>` | `auth/<id>/`, `data/players/<id>/`, `data/chat/<a>_<b>/` |
| fixed names | `_session_secret`, `next-id.txt`, `last-seen`, `upload-bytes`, `api-key`, `password`, `name`, `code.md`, `images.md`, `last-conv` | |

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

### Names too long for this machine — **the application can produce these**

- **Linux** allows 255 bytes. **VFAT** allows 255 UTF-16 characters, so the
  copy succeeds.
- **`fat16.zig` reads and writes names up to `max_name` = 64.** A longer name
  is refused on write, and on read is found only under its 8.3 alias
  (`SESSIO~1.JSO`), so the application cannot open it by name, and a listing
  shows the alias.
  - Before `d1c7364`, the reader stopped at **52**: a name of 53–64
    characters was written fine and then could not be read back by name.
    Kernels from before that commit should not serve a migrated volume.
- **The application can produce them.** `<sid>.reactions.jsonl` is 16
  characters longer than the session id, so **any session id over 48
  characters** makes a name this machine cannot hold. A doc slug over 61
  does the same. Both are legal at up to 80.

**What to do:** raise `max_name` to 96, which covers the application's
longest name. That costs about 32 bytes of buffer per name in flight. Or cap
session ids and slugs at 48 in the application. The checker lists any name
over 64 in prod's data.

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

The checker adds it up for the real tree.

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
5. **Compare.** Mount read-only with `tz=UTC`, and for every file in the
   copy, check that:
   - the name exists, compared exactly, not by case;
   - the size and SHA-256 match;
   - the modification time is within 2 seconds.

   Also check that nothing on the volume is missing from the copy.
6. **Let this machine read it.** Boot with the volume attached and request:
   - a conversation;
   - a session with uploads;
   - "recent";
   - a login with a real account.

   The droplet judge's read gates do the same against Linux.
7. **Write the volume onto the DigitalOcean volume once.** From then on, a
   new boot image never touches it.
