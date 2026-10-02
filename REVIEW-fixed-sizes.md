# Review: metal's fixed sizes against data that grows

QUEUE.md item 65, in REVIEW-interrupts.md's shape. **The question:** for
every fixed array, table or bound in metal, can the application's data
outgrow it, and what happens then? The worst answer is the one item 50
found: the directory iterator's 256 slots met a folder that grows with
use, and the machine stopped.

**What was read:**
- gopher-metal at `b708bd1`: `src/io.zig`, `src/fat16.zig`, `src/tcp.zig`,
  `src/stream.zig`, `src/request_heap.zig`, `src/kept_log.zig`,
  `probe/gopher.zig`'s constants, and every `serial.fail` and `@panic` in
  them;
- angry-gopher at `b4b0142d`: where the application meets each bound
  (store.zig's path limit, markdown's depth cap, chat_upload's ranges,
  the Hub, game_limits).

**What was run:** the item 50 tests (a folder of 600 entries on FAT16 and
FAT32), and the whole judge here, both hosts.

## The machine stops only for its own faults now

Every `serial.fail` and `@panic` in metal was read.
- **Most are at boot**, before serving: no memory, no disk, no network, no
  clock, a bad `gopher-metal.conf`, or the wrong volume. Each is a
  refusal, and a deploy that meets one never serves.
- **The rest guard this code's own invariants**: a page freed twice, a
  mutex taken twice, a wait before the clock started. Data cannot reach
  them.
- **Data could reach three:**
  - the iterator, item 50: fixed;
  - the stack guard on a directory walk: below, it holds;
  - the integer casts of a ReleaseSafe build: below, they hold where read.

## Every bound, beside what could reach it

| Bound | Where | Data that grows toward it | Past it | Prod today |
|---|---|---|---|---|
| A directory's entries | `io.Iterator` | sessions in a folder (500 per player, item 52); players (no bound); uploads in a topic | **was: the machine stopped at 257.** Now a cursor: no ceiling | largest folder 70 (QUEUE.md item 50) |
| A FAT directory's size | the FAT spec: 65,536 entries | as above. A long name takes 2-4 entries, so about 16,000 files | **refused** (`DirectoryFull`, then `NoSpaceLeft`): fat16.zig stops at the spec, and has a test (finding 1, withdrawn) | 70 at most |
| A path's length and depth | `io.max_path` 256, `store.max_path` | topic names, upload names | **refused on both hosts** by store.zig (PathTooLong), before metal sees it | ask: the longest |
| A name's length | `fat16.max_name` 96 | topic and doc slugs | refused the same way | ask: the longest |
| Directory depth | the stack guard, checked at every walk | none: the application's paths are a fixed shape, and the Store refuses depth | serial.fail: a stop | fixed by the code, not the data |
| Markdown nesting | `markdown.max_block_depth` | a hostile message | the block is refused (the judge sends one) | — |
| The FAT, held whole | `fat_budget_bytes` | the volume's size, chosen at the cutover | refused at boot, saying so | chosen in CUTOVER.md step 4 |
| A file's size | FAT's u32 | a transcript; an upload (100 MiB cap) | writeInto answers TooBig (item 43) | ask: the largest transcript |
| A read's offset | `io.zig` casts u64 to u32 | a `Range:` header on an upload | **holds:** `chat_upload.parseRange` refuses a start past the file, and a FAT file is under 4 GiB | — |
| A request's memory | the request heap: 32 MiB kept, grows from pages | a topic page reads its whole transcript; an upload is held whole; /admin/lynrummy walks every player | grows into RAM; past RAM, the request fails (500) and the heap shrinks back | ask: the largest transcript, and the player count |
| The process's memory | pages, shared | the Hub (one entry per open stream, removed on close), game_limits' fixed tables, the site cache (4 MiB) | none grows with stored data | — |
| Connections | 256 (64 kept for requests) | open tabs, each holding streams | streams past the budget end the oldest; past 256, a new connection is refused | a few users |
| A connection's buffers | 16 KiB in, 64 KiB out; a 16 KiB request head | cookies, a long URL | a head past 16 KiB is a 431, as Linux answers | — |
| The log | a 64 KiB ring; the kept log, two 64 KiB slots | requests over time | the oldest lines go | — |
| The game store | game_limits: 256 players, 1,024 addresses | players and addresses writing at once | measured afresh, or an address's hour starts early (REVIEW-signed-uid-and-limits.md, finding 8) | — |
| The site cache | 4 MiB, 64 files, 512 KiB each | the site's own files (pages, gallery) | read from the disk, as before | ask: the gallery's sizes |

## Findings

### 1. A FAT directory past 65,536 entries (withdrawn: it already holds)

**This finding was wrong.** It said fat16.zig would grow a directory past
the FAT spec's 65,536 entries. It does not:
- `Volume.grow` refuses at `max_dir_entries`, and the write that needed
  the room fails as `DirectoryFull`, which io.zig answers as
  `NoSpaceLeft`;
- fat16_test.zig's "a directory grows to FAT's limit of 65,536 entries,
  and no further" proves it on every disk shape.
The review read `grow`'s caller and not `grow` (QUEUE.md item 68, found
when starting to fix it).

What remained is said in angry-gopher's Store header (`d2aefc5e`):
- Linux has no such limit, so at that bound the two hosts would differ;
- what each of the application's folders can reach. The players folder,
  about 32,000 players, is the one with nothing but the per-address rate
  bounding it.

### 2. A request holds what it reads whole (low, and the same on Linux)

**Where:** a topic page reads its whole transcript into the request's
heap. So does `/admin/lynrummy`, every player's tree.

**The problem:** these grow without a bound as people talk and play.
Past the machine's RAM, the request fails, the heap shrinks back, and
the machine serves on. Linux behaves the same, with its own RAM. It is a
page that gets slow, then fails, not a machine that stops.

**Fix shape:** none needed now. The prod numbers below say how far off
it is.

### 3. Casts that data reaches (low; audited where read)

**Where:** ReleaseSafe turns a cast that does not fit into a panic, and
that stops the machine (or restarts it, with `-Drestart`). fat16.zig has
31 casts, tcp.zig 11, probe/gopher.zig 8, io.zig 5.

**The problem:** the ones on the data path that were read hold:
- io.zig's read and write offsets: below 4 GiB, as shown in the table;
- the site cache's name lengths: at most `max_path`;
- fat16's slot offsets: within a sector.
fat16.zig's and tcp.zig's casts were not each traced to their inputs.

**Fix shape:** a host test per cast on an input from the disk or the
wire, or fuzzing fat16's mount and directory walk with damaged images
(the `damaged-` images are a start).

## For the box: prod's counts, from the rehearsal copy

These say how far prod is from each bound in the table above:
1. The largest folder (item 50 says 70), and the folder count in
   `data/players` and `data/lynrummy`.
2. The longest path, as metal spells it (`data/...`), and the longest
   single name.
3. The largest file, and the largest chat transcript (`*.md` under
   `data/chat`).
4. The gallery's total size, and its largest picture.

**Nothing here stops the machine today,** so there is no fix-now item.
Finding 3 is worth doing before the volume gets large. Finding 1 was
withdrawn: it already holds.
