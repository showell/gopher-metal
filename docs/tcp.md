# The network: one loop over state machines

The TCP table (`src/tcp.zig`), the loop that serves it (`probe/gopher.zig`,
`src/stream.zig`, `src/ready.zig`), chat's live streams, and how each is
judged. The plan for finding the table's bugs systematically is
[`TCP_TESTING.md`](../TCP_TESTING.md); its properties and simulator are in
[`COVERAGE.md`](../COVERAGE.md).

## Every wait is a measured duration

A client that connects and then says nothing is a server's worst case. Every
wait in `src/stream.zig` is a duration of the calibrated timestamp counter,
not a spin count, and the one that matters is host configuration in
`gopher-metal.conf` on the boot disk:

    requests = N            serve N and stop; absent, serve until stopped
    idle_timeout_ms = N     how long a connection may make no progress
    streams = N             how many live streams may be held at once
    lose_one_sent_in = N    lose every Nth TCP frame sent (a test switch)

(The kernel knows a few more: `card`, `volume`, `keepalive_ms`,
`page_cache_mib`, `page_cache_largest_kib`, `trusted_proxy`,
`admin_password_reset`.)

"No progress" is the same measure in every direction: a read that gets no
bytes, a write whose peer acknowledges nothing, a close whose FIN is not
acknowledged. An unknown key stops the machine, because a timeout that was
silently not applied is exactly how a server ends up held open by one client.
And `std.Io.Reader` reports both a dead NIC and a quiet client as
`ReadFailed`, leaving the detail to the implementation — so the stream keeps
it, and the log can say which:

```
  request 1: (no request) -> the client stopped sending, and was let go
  request 2: GET / -> ok (base: 93 live bytes, ...)
```

**"It recovered" is not the claim.** The claim is that the configured number
is what governs, and the only way to show that is to change it and watch the
answer move. So the judge boots twice, with two values, and times both.

## Many connections, one request at a time

Chat holds connections open: every conversation tab keeps three streams for
as long as it is open. The design decision (Steve, after
[the SSE essay](http://143.244.172.148:9100/notes/chat-over-http-and-sse.md))
is **state machines, and one loop over them**: talk to the devices, move every
connection along, and serve whatever is ready. No threads, no fibers.

`src/tcp.zig` is a **table of connections** — 256 of them, room for about
sixty tabs — each with its own state, its own receive buffer and its own send
queue, about 20 MB in all. A SYN takes a free slot; a full table drops it, as
Linux does when its accept queue is full, and counts it. The buffer is
consumed as the request is read, and the window advertises the room actually
left, so a body bigger than the buffer arrives in pieces instead of being cut
short. A slot the host is serving is never handed to a new connection until
the host lets it go — otherwise a reader part-way through a request could
find a stranger's bytes.

The state machine is **pure**: frames go out through whatever "wire" the
caller supplies, and the initial sequence number and the time are passed in.
So it is tested on the host (`src/tcp_test.zig`) with a recording wire and a
fake peer that checks sequence numbers as a real client would. Mutations of
it — finding a connection by port alone, handing out a held slot, a constant
window, acknowledging more than was taken, never compacting, throwing away
what arrived with a FIN, accepting out-of-order data, a repeated SYN as a new
connection, not counting a full table — each fail a test, and
`tools/mutate_tcp.py` breaks it one way at a time and reports any break
`zig build test` does not notice.

**The host serves a connection only once the whole request has arrived**
(`src/ready.zig`, which asks `std.http.HeadParser` — the parser `receiveHead`
itself runs — so "ready" and "a whole head" cannot disagree, and then reads
the head for how long the body is). The oldest ready connection is served
start to finish; one that has been quiet for `idle_timeout_ms` is let go;
otherwise the network is polled, which moves every connection at once.

**Three kinds of body cannot be waited for**, and are started at the head
with the handler reading the rest as it comes: one whose client sent
`Expect: 100-continue` (it is waiting to be told to send, and
`std.http.Server` tells it from inside the handler — waiting here would be
both sides waiting); a chunked one, whose length nobody knows until it ends;
and one too big for the connection's receive buffer, since nothing drains
that buffer until the handler runs.

```
ok    8 clients connected at once, each answered as Linux answered; the kernel
      held 8 at once and turned none away
ok    a silent client holds nobody up and is still let go when the volume says:
      closed after 2.1s at 2000 ms and 6.1s at 6000 ms, with the caller beside
      it answered first both times
```

## The machine keeps chat's live streams

A chat tab holds its conversation's stream open, and every message sent in
that conversation has to appear on it. angry-gopher's streams are
**described by the application and kept by the host** (angry-gopher
`950b7e34`): a stream handler writes its head and backlog, then hands the
host a `Kept` — its bus subscriber, and how to render an event for this
viewer — and returns. Linux serves that on the connection's own task.

This machine keeps a **table of held streams**, indexed by the connection each
one lives on. A request that kept a stream leaves its connection open and
claimed. Every turn of the loop drains each held stream's mailbox and writes
the frames; one quiet for the application's keepalive gets a ping; one whose
client has gone — its FIN or reset seen by the connection table — is ended:
subscriber dropped, connection closed, slot released.

The judge holds a stream open on both hosts and requires the same story from
each:

```
ok    live stream on Linux: a stream held open got its backlog first, then the
      message sent on another connection, numbered 1
ok    live stream on the machine: (the same)
```

and on the machine, that the stream was ended because its client went away,
with one held and one ended by the end of the boot. Three mutants of the
table fail it: never draining, never noticing a client that left, and closing
a kept stream's connection anyway.

**A tab, as a browser holds it.** The judge opens one user's three streams at
once — her conversation, her notifications, her sidebar — and has another
user send on the conversation and then start a new topic. Each stream must
get its own event (the message marked as not hers, "Steve sent you a
message", the topic added), and after 27 quiet seconds each must be pinged:
once, not in a flood. A host that pinged on every turn would have delivered a
ping too — the mutant sent 15,339 in 28 seconds — so the gate also requires
that none came before the 25-second keepalive was due.

**Streams cannot starve requests.** A held stream occupies a connection slot
for as long as its tab is open, so `gopher-metal.conf` has a key for it,
`streams = N` (by default all but 64 of the 256 slots). When the budget is
full, a new stream ends the OLDEST: its browser reconnects, and a
conversation stream resumes from its last event. With a budget of two, the
judge opens three, checks the first was closed and the other two still
receive.

**Nothing is kept per stream.** 5 streams and then 25, opened and closed one
after another — half by a polite FIN, half by a reset — must each be ended
because their client went away, leave nobody subscribed, and end two boots
holding the same number of live bytes. (That gate once found the kernel
keeping its own config file's text in the long-lived heap: `requests = 8` is
one byte shorter than `requests = 28`.)

**Streams turn with the network.** Held streams are serviced on every turn of
the network loop (`stream.after_arrivals`), including the turns taken inside a
request's reads and writes — not only between requests. Serviced only between
requests, a stream would move at most one send queue (64 KB) per request, and
a reader sent 60 KB messages back to back would fall behind until its mailbox,
which holds sixteen events, dropped some. A mailbox that does overflow ends
its stream (angry-gopher's `missed` flag) rather than leaving a gap, and
ending a stream never waits: its FIN is queued and the table finishes the
close.

**A tab that stops reading loses its stream, not the site.** The loop never
waits on a stream. It takes the next event from a stream's mailbox only when
it has somewhere to put it (angry-gopher's `nextFrame`), queues as much of the
frame as the connection's send queue takes, and carries the rest to the next
turn; the events behind it wait in the mailbox, as they do on Linux while a
write blocks. A stream whose carry has not moved for the idle time is reset.
A frame still in flight is not a lagging tab: only a carry that does not move
ends a stream.

```
ok    a lagging stream: of two streams sent 60 60 KB messages back to back,
      the one nobody read was ended as not keeping up, and the one being read
      got all 60
```

## The send side

Every connection has a **send queue**, and `Table.transmit` — called on every
turn of the loop — is a state machine like the receive side:

- **The window.** Nothing goes past what the peer last said it has room for.
  A shut window is probed with one byte when the timer runs out.
- **The segment size.** The SYN-ACK says ours (1460); a peer's SYN says its,
  and a peer that says nothing is sent 536-byte segments.
- **Retransmission.** Bytes leave the queue only when acknowledged. What is
  not acknowledged in time is sent again with everything after it, and the
  wait doubles, up to 5 s. The wait is measured (RFC 6298's `srtt + 4 *
  rttvar`, the handshake the first sample), with Linux's 200 ms as its floor
  and first value, so a peer's delayed acknowledgement is not taken for a
  loss. Three duplicate acknowledgements resend at once (RFC 5681).
- **Giving up.** Six timeouts with no progress — about 16 s from a 200 ms
  clock, 35 s at most — and the connection is reset. That is how a peer that
  vanished without a FIN is noticed.
- **Every waiting frame before any timer.** A busy loop finds
  acknowledgements queued in the NIC's ring, and looking at the timers first
  calls those segments lost. It once sent a second SYN-ACK for a connection
  whose ACK was already waiting, and slirp sent nothing more on it until the
  request timed out — one POST in about thirty, seen only once a Debug kernel
  made the loop slow enough, and found with a packet capture
  (`JUDGE_CAPTURE=1` writes one per boot).
- **The FIN goes last**, and only its own acknowledgement closes the
  connection; the host's close waits for as long as the peer keeps
  acknowledging, not a fixed two seconds.
- **An abandoned connection is reset**, so a client still waiting for the
  rest of an answer is told.

The state machine is tested on the host with a peer that sends windows and
acknowledgements. On QEMU, two gates exercise what the others never could:

```
ok    bulk: 8 messages of 40 KB in, a 317376-byte transcript and a 4895-byte
      page out, all answered as Linux answered
ok    bulk, losing one frame sent in seven: (the same), 122 frames lost,
      19 timeouts resent
```

Slow and stalled readers are metal-vmm's `timeouts.sh`, in the machine's
time: a reader that pauses just under the idle setting gets the whole page
with its window probed, and one that pauses just over it is let go.

**The loss switch loses only what this machine sends**
(`lose_one_sent_in`). Losing what arrives as well made each 40 KB request
take 20 s and two of them time out — not the send side's doing: this TCP
takes received segments in order only, so one lost segment throws away every
one behind it, and the peer recovers each hole on its own timer.

**The slow-reader gate needs a 4 MB answer.** A loopback client with a 2 KB
receive buffer still lets its sender queue 1.36 MB, and slirp holds more;
with the 317 KB transcript the machine's window never shut, and the gate —
which requires window probes — would fail rather than pass on nothing.

## The ladder: where does a slowdown live?

`probe/ladder.zig` looks for a cost that grows one layer at a time: each rung
repeats ONE operation and prints the cost per operation of each tenth of the
run, and `judge_ladder.py` fails a rung whose last fifth costs more than 1.5×
its second and third tenths, or whose disk requests climb. `scale=N` on the
kernel's command line (`LADDER_SCALE`) multiplies every count, so a rung is
asked briefly first and at length once it has been flat.

```
PASS cpu          | 5000 ops,    122254 ns ->     90925 ns per op (x0.66)
PASS alloc        | 200000 ops,   31615 ns ->     21737 ns per op (x0.83)
PASS read_same    | 20000 ops,    38217 ns ->     38409 ns per op (x0.80), 1.00 disk requests per op
PASS write_same   | 20000 ops,   183371 ns ->    215008 ns per op (x1.06), 1.00 disk requests per op
PASS write_spread | 20000 ops,   230578 ns ->    235352 ns per op (x1.10), 1.00 disk requests per op
PASS append       | 10000 ops,   770548 ns ->    920819 ns per op (x1.09), 7.00 disk requests per op
PASS replace      | 10000 ops,  2137145 ns ->   2216114 ns per op (x0.99), 15.00 disk requests per op
```

At scale 10 (43 s, emulated CPU), everything below the network is flat: the
processor and the clock, std's allocator on this machine's pages, a sector
read and written in place, a sector written where the host's image file has
to grow, a 5 MB file appended 512 bytes at a time, and a small file rewritten
ten thousand times. Rewriting a file of a dozen bytes takes 15 device
requests, and one append takes 7.

**The one rung that climbed was ours** (`tcp_conn`). A connection whose FIN
has been acknowledged is not finished: forgetting it before the peer's own FIN
arrives leaves the peer in LAST-ACK, and a peer that walks its connection list
per frame — slirp does — gets slower at everything for as long as the machine
is up. The rung is flat at 2,000 connections now.

## The TCP table, on Linux, against Linux's TCP

`src/tcp.zig` touches no device, so it runs as an ordinary Linux program too —
`native/serve.zig`, built Debug in seconds — with a TAP device instead of
virtio-net and **Linux's own TCP as the peer**. No emulator, no slirp, no
kernel image. `native/judge_native.py` (`probe/run.sh native`) creates the
device, starts it at 10.77.0.2, and asks in about a minute:

```
ok    connections: 5000 one after another, 89 -> 90 us each (x1.07); 0 left
      half-closed on Linux's side
ok    lazy close: 30 clients that close 100 ms after the answer: 0 left in
      LAST-ACK on Linux's side, 0 in the table
ok    concurrent: 48 clients x 20: every answer right
ok    bytes: 5 MB read fast and read with a 2 s pause: exact
ok    half-close / reset / keepalive
ok    loss: 5% lost toward the table and 1 in 13 from it: recovered
```

**Why it exists.** The send side was debugged one 40-second QEMU boot at a
time, and the bugs it found were ones a reading of RFC 9293 would have named
in minutes. A cold review against the RFC found eight more, each now a pure
test with a fake clock; the table's host tests (`tcp_test.zig`,
`tcp_check.zig`) run in about a second, timers and all. What is left for a
real peer is the handful of facts an implementation cannot know about itself,
and those are what this harness asks. Its lazy-close client is the one that
caught the LAST-ACK leak above: Linux usually sends its FIN with the
acknowledgement, so an ordinary client could not see it, and the lazy one
fails 30 of 30 without the fix.

A boot that loses nothing on purpose must have no request waiting a second
for its turn (a second is a retransmission timer, not work).

## What the TCP does not do

No congestion control, no selective acknowledgement, no window scaling, no
out-of-order reassembly, no keep-alive. (It does measure round trips: the
retransmission clock is RFC 6298's, from the path.) `zig-server`'s own comment
says keep-alive is deliberately off. The rest are allowed because this
machine sits behind Caddy on a private network, and one of them is a measured
cost:

- **In-order only.** A segment whose sequence is not exactly what we expect is
  dropped and re-acknowledged, which asks the peer to send it again — and
  under loss, that makes the peer resend everything after the hole. (Its
  acknowledgement number is still taken: it is cumulative, so a newer one
  cannot be wrong, and a peer repeating its FIN with ours acknowledged must
  not be made to wait on a timer.)
- **No TIME-WAIT.** A connection is forgotten as soon as both sides have
  finished, and anything that arrives afterwards is answered with a reset.
