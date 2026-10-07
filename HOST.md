# The host: what Linux and metal both promise the application

*2026-10-07. The contract between angry-gopher's route table and the host it
runs on, Linux or metal; beside STORE.md, which is the data's part of it.
Essay: notes/the-other-doors.md. Steve's decisions of 2026-10-07 are marked.*

**The aim is that Linux and metal agree** (Steve: no second tenant is in
view). Every rule here exists so that something which works on a laptop
works the same on the droplet, and something that would fail on the droplet
fails on the laptop first.

## What a host does before the first request

angry-gopher's `router.zig` declares these ("the host contract"), and both
hosts do them: Linux in `server.zig`, metal in `probe/gopher.zig`.

1. `mem_meter.init(base)`: the process-lifetime allocator.
2. `roots.point(base, r)`: the data's two roots.
3. one `Hub`, the registry live streams publish through.
4. `store.backfillAll`: each chat topic's last-message record.
5. after `route` returns: serve the stream the request kept, if any.
6. optionally, `host_status.provide`: the host's own facts for /admin/host.
7. `game_limits.free_space`: how much of the data's disk is free.

## One handler at a time *(Steve, 2026-10-07)*

**A handler runs to its end with no other handler interleaved, on both
hosts.** Metal already works this way: one loop. Linux runs requests on many
tasks at once, and angry-gopher holds 45 locks to make that safe, so today the
two hosts run the same code as different machines, and the judge, which
replays one request at a time, cannot see the difference.

So Linux serializes handlers too: one handler at a time, with connections
still accepted, read and written concurrently around it. A kept stream is
served between handlers, never during one, as metal serves it. The
application's locks then guard nothing and go, and what's left is one
machine, judged the same way on both hosts.

Cost: Linux loses request parallelism. At lynrummy.com's load (a handful of
people, requests answered in milliseconds) that costs nothing measurable,
and a slow handler is a bug on metal already.

## Durability

**No response leaves before the writes ahead of it are durable** (v18). The
application never flushes; the host flushes at the one moment that matters,
before the first byte of a response, and a failed flush is logged and the
response still goes. On Linux the same promise is an `fsync` of what the
request wrote. *(Not yet: Linux relies on the page cache, so the two hosts
differ after a power cut. Owed.)*

## Limits: one source of truth *(Steve, 2026-10-07)*

Today the same limit is written in several places:

| limit | written in | today |
|---|---|---|
| a request's head | Linux `server.zig` (`read_buf`), metal `probe/gopher.zig` (`read_buf`) | 16 KiB each, by copy |
| an ordinary body | Caddy (`request_body`), the app's per-route caps (`http.readLimitedBody`) | 1 MB at Caddy; per route in the app |
| an upload | Caddy, `chat_upload.zig`'s kinds | 110 MB at Caddy; 10 MiB images, 100 MiB video |
| a name, a path, a depth | angry-gopher `store.zig`, metal `fat16.zig` and `io.zig` | 96, 256, 16 (checked: `tools/check_limits.py`) |

**The rule:** each limit is defined once, in angry-gopher, where the
application that depends on it lives (a `limits.zig` the router exports), and
every other place either reads it or is checked against it:

- **Both hosts read it.** `server.zig` and `probe/gopher.zig` size their head
  buffers from it, so the two can't drift.
- **Caddy is checked against it.** A script reads `deploy/Caddyfile` and fails
  if Caddy's caps are below the application's (then a request the app allows
  is refused at the door) or far above them (then Caddy passes what the app
  refuses, which is harmless but means one of them is stale).
- **The store's limits stay where they are**, in `store.zig`, checked against
  metal's by `tools/check_limits.py`, because `fat16` needs them at compile
  time and can't import angry-gopher.

## Live streams

The application describes a stream; the host keeps it (`bus.zig`). The
contract, as `bus.zig` has it and both hosts serve it:

- **Live-only.** A reader whose queue is full misses the event; a reload
  derives it again. Nothing is owed to a reader that wasn't listening.
- **Each key's events in the order they were published.**
- **A stream ends** when its reader goes away, or when the host gives up on
  a reader that has stopped reading (metal: `idle_timeout_ms`).

*(Owed: a simulator driving the Hub with stalling and vanishing readers,
under both serving styles, checking the same frames reach the same readers.)*

## The clock and random bytes

- **Wall time** for what people read (timestamps); **monotonic time** for
  timeouts and throttles. Metal sets wall time from the hardware clock at
  boot and never corrects it; metal-vmm decides it.
- **Random bytes are cryptographic** on both hosts (metal: virtio-rng and
  RDRAND; Linux: the OS). In tests both come from the tape, so the seed
  explorer can steer them.

## Config

A value by name, typed when read. A malformed value stops the boot; **so
does a file that exists but can't be read** (Steve, 2026-10-07: halting is
right; B21). A missing file is the defaults.

## What's owed, in order

1. **One handler at a time on Linux** (`server.zig`), then the application's
   locks deleted. This is the change that makes the two hosts one machine.
2. **`limits.zig`** in angry-gopher, both hosts' head buffers read from it,
   and the Caddyfile check.
3. **Durability on Linux:** an `fsync` before a response that followed a
   write, as metal's flush.
4. **The Bus simulator.**
