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

**A small body arrives before the turn, on both hosts** (2026-10-07):
gopher-metal starts a handler only once a small body (one that fits the
connection's 16 KiB buffer) has arrived (`ready.zig`), and Linux's
`server.zig` reads such a body before taking the turn. A large, chunked or
`Expect: 100-continue` body is read by the handler as it arrives on both
hosts, holding the turn while it does. Checked live on Linux: a client that
stalled 3 s before its body held another client's request for 2.51 s before,
and not at all after.

Cost: Linux loses request parallelism. At lynrummy.com's load (a handful of
people, requests answered in milliseconds) that costs nothing measurable,
and a slow handler is a bug on metal already.

## Durability

**No response leaves before the writes ahead of it are durable** (v18). The
application never flushes; the host flushes at the one moment that matters,
before the first byte of a response, and a failed flush is logged and the
response still goes. On Linux the same promise is an `fsync` of what the
request wrote.

## Limits: one source of truth *(Steve, 2026-10-07)*

**Each limit is defined once, in angry-gopher**, where the application that
depends on it lives (`zig-server/src/limits.zig`, which the router exports),
and every other place either reads it or is checked against it:

| limit | defined | read or checked by |
|---|---|---|
| a request's head (16 KiB) | `limits.zig` | both hosts size their head buffers from it (`router.request_limits.head_bytes`); metal asserts at compile time that a connection's receive buffer holds one |
| an ordinary body, per route | `limits.zig` | every route's `http.readLimitedBody`; Caddy's `request_body`, held to it by `tools/check_caddy_limits.py` in `ops/check_zig` |
| an upload (10 MiB images, 100 MiB video) | `chat_upload.zig`'s kinds | Caddy, by the same script |
| a name, a path, a depth (96, 256, 16) | angry-gopher `store.zig` | metal's `disk_fat.zig` and `io.zig`, by `tools/check_limits.py` (the FAT driver needs them at compile time and can't import angry-gopher) |

The Caddy check fails if Caddy's caps are below the application's (a request
the app allows would be refused at the door) or far above them (harmless,
but one of the two is stale).

## Live streams

The application describes a stream; the host keeps it (`bus.zig`). The
contract, as `bus.zig` has it and both hosts serve it:

- **Live-only.** A reader whose queue is full misses the event; a reload
  derives it again. Nothing is owed to a reader that wasn't listening.
- **Each key's events in the order they were published.**
- **A stream ends** when its reader goes away, or when the host gives up on
  a reader that has stopped reading (metal: `idle_timeout_ms`).

**Simulated** (angry-gopher `bus.zig`, "the mailbox contract over seeded
runs", 300 runs, slow readers included so the overflow is met): a reader
sees exactly its key's events since it opened, in order, nothing skipped,
and ends with `EventsMissed` if and only if its mailbox was full when an
event arrived. On both hosts an overflow ends the stream, and the browser
resumes.

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

## Idle time *(Steve, 2026-10-10; metal only, for now)*

**Work that is not time-critical runs when the machine is quiet**, a step at
a time, under a request's rules: a step is bounded (200 ms), and a request
that arrives meanwhile waits for at most one step. Metal's loop gives the
next task a step when it would otherwise rest and nothing has arrived for
200 ms (`src/idle.zig`); `/admin/host` says the steps, the overruns, and each
task's state.

- **Today it is the host's alone:** the one task is each volume's check,
  asked again while the machine serves (`src/idle_check.zig`), reading and
  writing nothing else. A write under a check starts it again.
- **Not yet in the contract:** the application cannot queue a task, and
  Linux runs none. When the application has one (search's index, built
  lazily), the router declares it as it declares a kept stream, and Linux
  runs it under the same turn when no request waits.
- **A task that writes** would need the fault testing a request gets; the
  first tasks only read.
