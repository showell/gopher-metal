# Review: /admin/host, as an adversary

QUEUE.md item 11. This review covers:

- angry-gopher's `host_status.zig` and `admin_host.zig`, and `server.zig`'s
  `linuxFacts`, at `be16d28`;
- gopher-metal's `metalFacts` and `addVolume` in `probe/gopher.zig`, and
  `fat16.Volume.space`, at `7db2603`;
- the judge's check of the page, `host_page_differences` in
  `probe/judge_gopher.py`.

Nothing is fixed here. Each finding names the failure it would cause and how
likely that failure is. Findings are in order of severity.

It is a reading, not a run. Where a claim rests on code outside these files,
the file is named.

## What holds up

- **Only the admin reaches it.** `admin.handle` calls `ui.requireAdmin`
  before it looks at `sub`.
  - With no session the answer is a redirect to `/login/full`; a signed-in
    user who is not the admin gets a 404.
  - `/admin/lynrummy` is matched first in `router.zig`, and `/admin/host`
    is an exact match. So `/admin/HOST`, `/admin/host/` and
    `/admin//host` are 404s after the gate, not before it.
- **Every value is escaped.** `admin_host.row` passes both label and value
  through `html.htmlEscape`. That covers the facts a host hands over, and
  the volume serial and anything else read from a disk.
- **A failing report does not fail the page.**
  - `host_status.facts` turns an error from the host's report into one row
    naming it, and the application's half still renders.
  - The only failures left are allocation failures inside `admin_host`
    itself.
- **Nothing on it is a secret.** It shows:
  - commits, the version, the memory meter, edge counters;
  - uptime, request and connection counts;
  - volume serials and free space, the TSC rate, NMIs.

  On Linux it also shows the pid and the data directory's path. No key,
  hash, cookie, session or file content is on it. The public `/version`
  already serves the meter and the edge counters.
- **It changes nothing.** It is a GET that reads counters and walks the
  FAT. A cross-site request can make an admin's browser fetch it, but not
  read it.
- **It leaks nothing per request.** Both hosts run each request on an
  arena: `server.zig`'s per-connection `ArenaAllocator`, and gopher-metal's
  `RequestHeap`. So returning `facts.items` without `toOwnedSlice`, and the
  formatted strings, cost nothing past the request.
- **Its cost is small on the machine as built.** `addVolume` calls
  `Volume.space()`, one pass over the FAT per volume per page view. On a
  2 GiB volume that is about 65,000 entries.
  - `mountFat` always holds the FAT in memory, so this is a memory scan,
    well under a millisecond.
  - Only the admin can ask for it.
- **Its clock reads cannot panic as the boot stands.**
  - `metalFacts` calls `Io.Clock.now(.real)`, which panics when the wall
    clock is unset (`io.zig`, `real_unset_msg`).
  - `metal.wallclock.start()` sets it before `host_status.provide` is
    called, and a wall-clock failure halts the boot (`gopher.zig`, "the
    clocks would not come up").
  - `Io.ticksToNs` needs `startClock`, which happens first too.
- **The Linux report reads `/proc` carefully.** `readProcFile` reads to
  EOF rather than trusting a size of zero, closes its fd on every path,
  and turns a failed open or read into a row, not an error.

## Findings

### 1. The judge passes a page whose host half failed

**Where:** `host_page_differences` in `probe/judge_gopher.py`.

**The problem:** the judge requires both halves, the same application rows
on both hosts, `gopher-metal, with no operating system`, and `serial `. It
does not look at what the host's rows say.

- **A failed report is caught, but by accident.** It becomes the single row
  `the host's report: <error>`, which replaces every row, so `serial ` and
  the gopher-metal line go missing and the judge fails. It says "does not
  say it is gopher-metal", not that the report failed.
- **It would pass these:**
  - `FAT16, serial 92DE-8831: free space unreadable (ReadFailed)`, which
    still contains `serial `;
  - a free-space figure that is wrong, such as free larger than total, or
    a count that double-counts.

**Failure:** a regression in `metalFacts` or `Volume.space` reaches `master`
behind a green gate. The operator then reads a wrong free-space figure off
the one page meant to warn them the volume is filling.

**How likely:**
- **The report error:** only on a change that breaks it, but no gate would
  see it.
- **"unreadable":** needs a device read failure, which cannot happen with
  the FAT held in memory.
- **A wrong count:** the code is a dozen lines and reads correctly today.

**Fix shape:**
- Fail when the host's half has a row labelled `the host's report`, or a
  value containing `unreadable`.
- Parse each `N MB free of M MB` and require `N ≤ M` and `M > 0`.
- Better, check the page against `tools/fat16_read.py`, as this judge
  already checks files through the Linux VFAT driver. The judge holds the
  image. The oracle's cluster count gives the volume's total exactly, and
  the free figure at the end of the run gives a bound. The page was
  fetched earlier, and the later steps only use space, so the page's free
  must be at least the final free.

### 2. Only `/admin` is tested for refusal, not `/admin/host`

**Where:** `judge_gopher.py`'s cases. `admin, anonymous` and `admin, a bare
uid is not a member` ask for `/admin`. The one `/admin/host` request is made
as the admin.

**The problem:** today `/admin/host` is refused by the same gate, at the top
of `admin.handle`, so it is refused too. But nothing tests that. A change
that serves `/host` before the gate would still pass every gate. For
example: dispatch it from `router.zig` beside `/version`, or give it its own
handler like `/admin/lynrummy`.

**Failure:** the page goes public. Finding 5 says what it would show:
nothing secret, but a map of the machine (commits, volume serials, memory,
counters, the Linux data path).

**How likely:** low: it needs a refactor of the dispatch. It is listed
because the fix is two lines and the gate is the page's only protection.

**Fix shape:** two cases beside the existing ones: `GET /admin/host`
anonymous, and with `P1`. Each must be refused exactly as `/admin` is, and
both are compared metal against Linux like every other case.

### 3. A host that serves without a wall clock would panic on this page

**Where:** `metalFacts`, `Io.Clock.now(.real, io)`.

**The problem:** the call panics if the wall clock was never set. That
cannot happen today: the boot halts first (What holds up). But RESTART.md
(item 7) proposes that a machine keep serving through failures. A later
change that lets the boot carry on without a wall clock, logging "no clock"
instead of halting, would leave this one call as a panic that any admin page
view triggers.

**Failure:**
- **Today:** none.
- **After such a change:** the admin's own status page stops the machine,
  which is the page they would open to find out why the clock is missing.

**How likely:** none now. It becomes certain if the boot ever stops
requiring the clock.

**Fix shape:**
- Read the clock the way `io.zig`'s `realUnixOrNull` does. Show "its clock
  now: never set" and "up for" from `Io.awakeNs()` when it is null.
- Or leave a comment at `wallclock.start()` naming this caller among the
  things that rely on the halt.

### 4. `Volume.space` on a volume whose FAT is not held reads a sector per cluster

**Where:** `fat16.Volume.space`. It calls `fatGet` once per cluster, and
`fatGet` on a volume without `cacheFat` reads the FAT sector holding that
entry, every time.

**The problem:** on a 2 GiB volume without the FAT held, one call is about
65,000 device reads of the same 256 sectors, 256 times each. That is
seconds of a single-threaded server doing nothing else, per volume per page
view.

**Failure:**
- **Today:** none: `gopher.zig`'s `mountFat` always holds the FAT, and it
  is the only caller of `space`.
- **Elsewhere:** the probe kernels mount volumes without the FAT held
  (`replace.elf` against `replace_cached.elf` exists to judge both). Any
  host that showed space on such a volume would stall.

**How likely:** latent. It needs a caller this code does not have yet.

**Fix shape:** walk the FAT a sector at a time, reading each once into a
local sector, as `Volume.check`'s `fatOnDisk` does. Use the held FAT when
there is one.

### 5. What the page tells an admin's attacker, for the record

**Where:** the whole page, if finding 2 ever happens, or for anyone holding
the admin's session.

**What is shown:**
- the exact angry-gopher and gopher-metal commits, which point an
  attacker at the source of the running build;
- the volume serials;
- memory use against the total;
- the edge's refusal counts;
- uptime and the boot time;
- on Linux, the pid and the absolute data path.

None of it grants access. An attacker could use it in three ways:
- the commits, to choose an exploit;
- uptime and memory, to time a resource attack;
- the volume serial, which is what `volume = <serial>` in the machine's
  config names, but only if they could also attach a disk with a forged
  serial, which needs DigitalOcean access already.

**How likely:** informational. It stays behind the admin gate, which
finding 2 asks to be tested.

**Fix shape:** none needed while the gate holds. If the page ever becomes
semi-public, as a status page for others, drop the commits and the Linux
path from what it shows.

## Summary

| # | finding | severity | likelihood |
|---|---|---|---|
| 1 | the judge passes an unreadable or wrong free-space figure, and names a failed report wrongly | medium: a gate that does not look | on a regression |
| 2 | `/admin/host`'s refusal is untested | low | needs a dispatch refactor |
| 3 | `Clock.now(.real)` would panic if the boot stopped requiring a clock | low now | certain after such a change |
| 4 | `space()` without a held FAT is a device read per cluster | low, latent | needs a new caller |
| 5 | what the page shows | informational | — |

The page itself holds up: gated first, escaped throughout, read-only, cheap
as built, and fails soft. Findings 1 and 2 are about the judge, and are the
ones worth doing now.
