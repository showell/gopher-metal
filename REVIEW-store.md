# Review: angry-gopher's `store.zig`, as an adversary

QUEUE.md item 31, in REVIEW-interrupts.md's shape. Nothing is fixed here.

**What was read:** `zig-server/src/store.zig` at CC's angry-gopher branch
`60b3d812`. That is the box's Store (`c0eec69a` … `cd15276d`) plus CC's
`replace` and path limits (items 24-25), and every caller as items 21-22
left them. On the gopher-metal side, `io.zig` and `fat16.zig` as of this
branch.

**What was run:** one throwaway host test, for finding 3. Everything else
was found by reading.

## What holds up

- **One seam.** Outside tests, benches and `config.zig`, nothing in the
  application calls `Io.Dir.cwd()` any more. So the rules below hold for
  every file the application keeps, and a rule changed here changes
  everywhere.
- **Names FAT cannot hold are refused before anything is made.** Writes
  check the last name; folder creation checks every new name.
  `removeTree` refuses a blank or bad last name, which is what stopped an
  empty id from naming a whole root.
- **An error is not an empty file.** `readOrEmpty` answers "" only for
  `FileNotFound`, and its test pins that a directory in a file's place is
  an error. The callers that rewrite what they read (docs append, pins)
  now all go through it.
- **The case rule costs nothing on a hit.** A name that exists as given
  is used without a listing. Only a miss looks for another case.
- **Behaviour moved with the files.** Each move in items 21-24 says in its
  commit where behaviour differs. Finding 6 collects them.

## Findings

### 1. A miss costs a full directory listing, and on gopher-metal two (medium)

**Where:** `sibling`, called through `retry` and `resolve` by every
`read`, `readOrEmpty`, `stat`, `has`, `list`, `remove` and `readAt` whose
exact path is missing.

**The problem:**
- **A miss is not rare.** It happens for every file that does not exist
  yet: a topic with no reactions (its `reactions` page), a conversation
  with no pins, a session's transcript before its first message
  (`appendMessage` reads it), a user's `upload-bytes` before their first
  upload, and the reading list before its first save.
- **Each miss lists the whole folder.** A topic's sidecars live four to a
  topic in `sessions/`, so a DM with 500 topics has a 2,000-entry folder.
  Every miss in it reads all 2,000 names, and a missing parent adds a
  listing per level.
- **On gopher-metal the listing is pure waste.** `fat16.find` already
  matches without case, so a miss there is a true miss. The Store then
  opens and walks the folder again (`openDir` + `iterate` lists it in full
  through io.zig) to find what FAT already said is not there. That is two
  directory walks per miss, each one sector-by-sector off the disk.

**Failure:** pages that ask for something not there yet slow down as
conversations grow, on metal twice over. Nothing breaks.

**How likely:** certain, in proportion to folder size. It is cheap today:
prod's largest folders are small (MIGRATION.md's survey: 835 files in
total).

**Fix shape:**
- On a host whose filesystem already folds case (metal), skip `sibling`
  entirely: a constant, or a question to io.
- On Linux, either keep a per-folder name index (invalidated on create
  and remove), or accept the listing and note it.

### 2. Two writers can make two names that differ only in case, on Linux only (medium-low)

**Where:** `forWrite` → `resolve`, then the create, with nothing held
between them.

**The problem:** with neither existing, two requests at once write
`Plan.md` and `plan.md` in one folder. Each `resolve` finds no other case,
so each creates its own name. Linux now holds both. Afterwards each case
reads its own file, because an exact hit is used without a listing, so the
Store never notices that it broke its own rule. On metal the same two
writes give one file: `fat16`'s lookup folds case, and the second write
replaces the first, keeping the first's name.

**Failure:**
- **The hosts disagree** about what was written.
- **The Linux tree cannot migrate** without a decision: `check_volume_tree`
  reports the collision, and MIGRATION.md step 1 stops on it.
- In chat, two topics that should be one, each with half the messages.

**How likely:** low: two people creating the same topic within the same
few milliseconds, in different case. Retries and double-clicks usually
repeat the same case.

**Fix shape:** a lock around resolve-and-create. One process-wide mutex
for creates is enough at this site's load, and reads need none. Or, on a
create, list after creating and fold a duplicate into the first.

### 3. On gopher-metal, a file written over a directory's name deletes the directory (medium, metal only; outside store.zig)

**Where:** gopher-metal `io.zig`'s `Dir.writeFile` → `fat16.writeFile` →
`writeFileIn`, which calls `removeEntry` on whatever entry has the name.

**The problem:** neither io.zig nor `writeFileIn` checks whether the name
is a directory. `writeFileIn` removes the entry, a directory's included,
freeing only the directory's own clusters, then writes the file. Linux
refuses the same write (`IsDir`). The Store passes it through: `forWrite`
resolves to the directory and `write` writes to it.

**Failure, run here** (a throwaway host test, not committed): write
`data/plan/inside.md`, then `writeFile("data/Plan", "a file")`:
- the write **succeeds**;
- `data/plan/inside.md` is then `NotFound`;
- the check reports **1 problem, 1 leaked cluster** (the orphaned
  contents).

**How likely:** low today. The application's file names and folder names
do not meet: topics are letters, digits and hyphens with suffixes, and
ids are digits. But it is silent data loss with no guard, on one host
only.

**Fix shape:** `writeFileIn` refuses with an error when the entry it
would replace is a directory, as `createFile` already checks. A host
test, and the oracle on its image.

### 4. `..` in the middle of a path passes the Store, and the hosts then differ (medium-low)

**Where:** `forWrite` checks only the last name. `forMakeDir` checks only
the names past the part that exists, and `..` always exists.

**The problem:** the module says a call is refused unless its names are
ones FAT holds. That is true of the names it creates, not of the path.
`write("data/users/../../x/f")` passes on Linux and writes outside the
data root, and `metalShape` measures it as under `data/`. On metal,
io.zig refuses any path with `.` or `..` (`placeOf`). Callers are meant to
validate ids, and items 20 and 22 found and fixed callers that did not.

**Failure:** the Store is no defence in depth against a caller that
forgets. A mistake that writes outside the data on Linux is refused on
metal, so a judge run on metal alone would not see it.

**How likely:** only through a caller bug. There were three
(REVIEW-request-paths 3-5), now fixed.

**Fix shape:** refuse any component that is `.` or `..`, or empty
between slashes, in every call's path, not only the names it creates.
That makes the Store refuse what metal's io refuses.

### 5. "Not found" covers more than not found (low)

**Where:**
- `exists`, which catches every `access` error as "absent";
- `has`, which catches every `stat` error as false;
- callers' `list(...) catch &.{}` and `read(...) catch return null`.

**The problem:** a permission error, or an I/O error on metal, reads as
"absent" in these places:
- `writeUserDoc` answers `DocDoesNotExist` for a doc that will not stat;
- `userExists` and `principalExists` answer false for an account folder
  that will not stat, so login says "no account named …";
- `resolve` goes on to list the parent looking for another case.

None of these then writes over the file. This is not the "an error is not
an empty file" hole, which `readOrEmpty` closes for the read-then-rewrite
callers.

**Failure:** misleading answers while a disk is failing, and a disk
failure that looks like missing data. No loss.

**How likely:** only on a failing disk or a permission mistake.

**Fix shape:** `has` returns `!bool`, with false only for `FileNotFound`.
Keep `exists` for resolution, where "try another case" is harmless.

### 6. Behaviour that changed when callers moved (information)

These are collected from the commits of items 21-24, for whoever reads the
gate. None is a regression known to matter.
- **Case:**
  - A `gopher_uid` of `P3` reaches player `p3`, which `p3` already could.
  - A channel's per-user state follows the channel in any case.
  - Gallery and download names are found in any case, as metal already
    found them.
- **`write` makes the folders above it.** Before the move, `chat_store`
  wrote `.count` and `.lastauthor` without making `sessions/`. Now a
  sidecar written after its folder was removed recreates the folder (with
  a sidecar and no transcript). Nothing removes a topic today.
- **`admin_lynrummy`:** a folder whose listing failed partway now counts
  0, not what it had read.
- **`chat_upload`'s serve path** opens the file twice (stat, then read).
  Uploads are never rewritten.
- **`replace` leaves `~<hash>.tmp`** after a stop before its rename. The
  folders it is used in are not listed by anything that would show it.
- **Two different names in one folder share a temp name** when their
  32-bit hashes collide. Two replaces at once then race on one temp file.
  The chance is about one in four billion per pair of names, and only
  matters when both are replaced in the same instant. A full-length hash
  or the name itself would remove it.

## Summary

1. **The Store's rules are right, and it is the one seam.** What follows
   are edges, not holes.
2. **Fix first: finding 3**, in gopher-metal: silent data loss on one
   host, a one-line refusal plus a test.
3. **Then finding 4** (refuse `.` and `..` anywhere in a path), which
   makes the Store refuse what metal does, and **finding 2** (one mutex
   for creates).
4. **Finding 1 is cost, not correctness.** Skipping `sibling` on metal is
   cheap and halves its misses.
5. **Finding 5 and the rest** can wait.
