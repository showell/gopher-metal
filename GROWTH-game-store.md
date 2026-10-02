# The game store's disk growth: options for Steve

QUEUE.md item 26, from REVIEW-request-paths.md finding 6. There is no code
in this note. It was measured on angry-gopher at CC's branch `4233a319`.

## What grows, and what each request costs

Anyone can write to the game store without an account. A player is free
to make (`POST /play`), and a cookie alone is that player. Three routes
write:

| Request | Writes | On Linux (measured) | On FAT, 32 KiB clusters |
|---|---|---|---|
| `GET /puzzles` (any page view) | a new puzzle session: a folder and a `meta` holding the whole catalog | 37,776 bytes + a folder | 3 clusters, 96 KiB |
| `POST /play` | a new player: a folder and `name` | a few bytes + a folder | 2 clusters, 64 KiB |
| `POST /game/sessions/<n>/actions` | one line, up to 64 KB, with no count limit | up to 64 KB | up to 64 KB, rounded up to clusters |

There is a fourth route: `POST /game/new-session` (up to 256 KB of meta
each). Its cost per request is like an append's.

## How fast

These rates were measured in CC's container, with a ReleaseFast
zig-server on loopback and 8 connections at once. They are 2,000 of each
request, every one answered:

- `GET /puzzles`: 1,417 a second.
- `POST /play`: 1,190 a second.
- 64 KB appends: 2,116 a second, about 135 MB/s.

A droplet is slower than this container, and an attacker's link is
slower still for the appends. So the rates below are upper bounds, but
the page views and the mints need almost no bandwidth.

| To fill | `GET /puzzles` | `POST /play` | appends, at the measured rate | appends, at 10 MB/s |
|---|---|---|---|---|
| 2 GiB FAT16 (about 65,500 clusters) | about 21,800 requests, **15 s** | about 32,700, **27 s** | about 32,800, 16 s | 3.5 min |
| 16 GiB FAT32 (about 524,000 clusters) | about 175,000, **2 min** | about 262,000, 3.7 min | about 262,000, 2 min | 28 min |
| each GB of an ext4 disk (prod today) | about 24,000, 17 s | about 130,000, 110 s | about 15,600, 7 s | 100 s |

FAT's directory limit (65,536 entries a folder) stops one player's
`sessions/` at about 65,000 sessions. That comes after the 2 GiB volume
is full, and it does not slow an attacker who mints players.

**Where it applies.** At the cutover Lyn Rummy stays on the Linux
droplet, so today this is prod's own disk, shared with everything else
on it. If metal ever serves the game, it is the data volume, and **a
full volume is chat unable to write.**

## Three shapes of limit

1. **Per player.** Cap each player's game store, for example at 1,000
   sessions and 64 MiB, counted as `upload-bytes` is for chat. Refuse a
   write past the cap, and **stop writing on a `GET`**: allocate a puzzle
   session on its first move, not on the page view.
   - **Cost to a real player:** nothing at those numbers, if prod's
     largest player is far below them. The box has prod's copy and can
     say how large the largest is.
   - **Alone, it stops nothing.** Players are free to mint, so an
     attacker makes a new one per cap. It needs one of the other two.
2. **Per address.** Limit player mints and game bytes per client address
   per hour, for example 20 players and 50 MB.
   - **Cost:** everyone behind one address shares it: a school or an
     office, or a mobile carrier's shared address. The address must come
     from Caddy's `X-Forwarded-For`, trusted only from Caddy.
   - **It is state to keep:** a table of addresses, expired hourly, in
     memory.
3. **Global.** Stop game writes when the store passes a total, or when
   the disk's free space falls below a floor (for example a quarter of
   the volume, or 2 GiB on prod). Answer those writes 507 while chat
   carries on.
   - **Cost:** under attack, every player loses saving for a while. Chat,
     accounts and uploads are untouched.
   - **It is cheap:** metal keeps the free count (item 14), and Linux has
     `statvfs`.

**CC's recommendation:**
- **No write on a `GET`.** It removes the cheapest way in, which needs
  no bandwidth at all, and it costs a real player nothing.
- **A global floor**, so the game can never take chat's disk.
- **A per-player byte cap**, so one player cannot have all of the game's
  share.
- **Per-address only if abuse is ever seen.** It is the one shape that
  costs real people something on a normal day.

## Found while measuring: concurrent appends lose lines

2,000 appends of 65,000 bytes, 8 at once to one session, left **1,814
lines** (121 MB of 130 MB). `appendTextLine` stats the file and writes at
the old end. Two appends that stat before either writes land at the same
offset, and one overwrites the other. `storage.zig`'s comment calls this
safe because "a given actions.dsl is only ever appended by the one request
that allocated its session". But the route takes any session id the
cookie's player owns, so the same player in two tabs, or a client
retrying, can lose moves. **The fix:** a mutex per session, or one for
the game store, around the stat and the write, as chat's appends have
`chat_mu`. This is a bug, not a policy question; CC can fix it if wanted.
