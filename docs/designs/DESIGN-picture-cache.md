# Design: pictures in the page cache (QUEUE.md item 102, picture lever 1)

**On a branch; it does not merge until after the cutover** (Steve: the picture
levers wait). The box measures the cap under KVM against prod's real picture
sizes and sets it before this merges.

Item 90 left one stall that matters: a big picture read whole on each request,
**30-39 MB/s on v14** against Linux's 280-470. The page cache (`page_cache.zig`,
item 87) already keeps the data's files in memory after their first read — but
it was not helping pictures at all, for two separate reasons. This note is what
I found, what I changed, and the one number the box must measure.

## What I found: pictures were never kept, at any size

Two read paths reach the cache (`io.zig`):

- **`readFileAlloc`** — a whole file into a fresh buffer. On a miss it reads the
  disk and **puts the bytes in the cache** (`if (n == e.size) c.put(...)`). This
  is how transcripts, game state and markdown are read, so these were cached.
- **`readPositionalAll`** — read into a caller's buffer at an offset. It read
  **from** the cache if the file was already there, but **never put anything
  in**.

A stored picture is served by `chat_upload.serveUpload` → `store.readAt` →
`readPositionalAll`. A plain GET (an `<img src>`, how a browser loads a photo)
reads the whole file in one call at offset 0; a `Range:` GET (how a browser
streams a `<video>`) reads one slice. **Neither populated the cache.** So a
picture was read whole from the disk on *every* GET, no matter how small it was
or how large `largest` was. Raising the size cap alone — which is how the item
is framed — would have changed nothing.

So lever 1 is two changes, not one.

## The change

1. **A whole-file positional read brings the file in** (`io.zig`,
   `readPositionalAll`): after the disk read, `if (offset == 0 and n == e.size)
   c.put(path, buffer[0..n])`, exactly as `readFileAlloc` does. A plain GET of a
   picture keeps it; the next GET is served from memory. A `Range:` read keeps
   nothing — it is a seek into a video (offset past the start, or a buffer too
   small to have held the whole file), and a video is past the cap anyway. The
   cache's exact-or-absent invariant is unchanged: every write, rename and
   remove still goes through `io.zig`'s hooks, and an upload is written once
   under a random name and never overwritten, so a kept picture is never stale.

2. **The cap is configurable and its default is raised** (`probe/gopher.zig`):
   `page_cache_largest_kib`, default **4096 (4 MiB)**, up from a hardcoded 2 MiB,
   at most **10240** (chat's 10 MiB image cap — past it, no picture could reach
   the cache). The boot line and `/facts` both report the effective cap, so the
   box can see what a given image serves with.

## The cap: what I can measure, and what the box must

The cap is a trade: a bigger cap keeps bigger pictures in memory, at the cost of
the room those bytes take from the transcripts (and from the other pictures).
Picking it well needs prod's **file-size distribution** — the sizes of the
pictures people actually load — which `fatlayout.py` reports on the box and I
cannot see from here. What I have:

- **Chat's own limits** (`chat_upload.zig`): an image is capped at **10 MiB**, a
  video at 100 MiB. A video is served by `Range:` and so is never cached by the
  change above; only images (and the odd whole-file GET) are. So the cap only
  ever needs to reach the **10 MiB image ceiling**, never the video one.
- **The judge's content:** the largest file the judge stages is a 27 KB PDF; its
  upload story posts a 64 KB picture (and, not QUICK, a 40 MB oversized one that
  is *meant* to be refused). Prod's largest transcript is 362 KB. So everything
  the gate reads today already fits a 4 MiB cap with room to spare — the gate
  does not exercise the interesting part of the cap, and the box's measurement
  does.
- **The budget** the soak watched: heap **59-65 MB of 71, flat, with a 64 MiB
  cache**. The cache's budget is already clamped to a quarter of free memory at
  boot (`gopher.zig`), and `put`/`room` evict by LRU to hold it, so a larger cap
  **cannot** grow the total — it only changes *which* files fill the same
  budget. The real risk is churn: a cap near the budget lets one big picture
  evict almost everything. At 4 MiB against a budget measured in the tens of MB,
  one picture is a small fraction of the cache, so the transcripts survive it.

**What the box measures under KVM, after the cutover:** from prod's picture
sizes (`fatlayout.py`, sizes only), the cap that keeps the pictures people
actually load — likely the 90th–95th percentile picture, not the 10 MiB ceiling
— and confirm with a soak that the heap stays flat at that cap with real traffic
(a gallery browse interleaved with chat reads), and that the hit rate on
pictures is what the stall needs. Set `page_cache_largest_kib` to that, then
merge. If the measurement says the pictures that matter are all under 4 MiB, the
default already stands and only change 1 (keeping them at all) is the lever.

## Tested here

- **`src/io_test.zig`**, a focused test: a picture written (not kept — a write
  never brings a file in), then a plain whole-file read keeps it (a second read
  is a hit, count 1), a `Range:` read of another file keeps nothing, and a
  picture past `largest` is read from the disk every time and never kept.
- **`src/io_test.zig`**, the existing page-cache fuzz (3000 interleaved ops):
  its positional reads now exercise the populate path too, and the cache still
  equals the disk after every op, under evictions and failed writes.
- `zig build test` green; `zig build gopher` builds; `zig fmt` clean. The
  droplet-speed half (the 30-39 MB/s becoming a memory read) is the box's to
  measure under KVM — I have no KVM and cannot boot metal here.
