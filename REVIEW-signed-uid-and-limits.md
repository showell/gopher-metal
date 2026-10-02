# Review: signed gopher_uid and the game store's limits, as an adversary

QUEUE.md item 53, in REVIEW-interrupts.md's shape. Nothing is fixed here.
CC wrote both items under review (51 and 52), so this is a review of CC's
own work. Findings are in order of severity.

**What was read:** angry-gopher at CC's branch `3d6b37fc` (on master
`4e776903`):
- `uid_cookie.zig`, `game_limits.zig`;
- the callers: `router.route`, `player.current` and `player.handle`,
  `users.currentUserID`'s guest arm, `login.loginAsMember` and
  `handleLogout`/`releaseTarget`, `game.zig`, `puzzles.zig`,
  `storage.ensurePuzzleSession`;
- `server.zig`'s peer, statfs and trusted proxy;
- `deploy/Caddyfile` and `deploy/gopher-server.service`, read only.

From gopher-metal at `3ce698d`: `probe/gopher.zig`'s side of the same.

**What was run:** the re-sign redirect, against a Linux server on the
judge's staged site (finding 2). The rest is a reading: "would" means the
code allows it.

## What holds up

- **The signature.**
  - Its label (`"gopher_uid\n"`) keeps a session's MAC from passing as a
    uid's (tested), and the compare is timing-safe.
  - An id holds no `.`, `/` or `..` (`validId`), and the format is pinned
    by a vector computed in Python.
  - With no secret, nothing is minted: a 500, never an unsigned cookie
    (tested).
- **What an unsigned cookie can do.**
  - Only a GET re-signs it. A POST with it is no one, window or not
    (tested), so the marker cannot be stepped around.
  - A member's id and the agent's are never re-signed (tested). The guest
    upgrade needs a signed cookie (tested).
- **X-Forwarded-For.**
  - It is believed only from `trusted_proxy`, and only its last entry:
    the one Caddy added, whether Caddy replaces the header or appends to
    it.
  - Anything that is not an address's characters is refused (tested).
  - Prod's server binds IPv4 (no `GOPHER_BIND` in its unit), so Caddy's
    `localhost:9001` reaches it from `127.0.0.1`, which is the default it
    trusts.
- **Admission is one step.** `admit` checks and counts under one lock, so
  two writes at once cannot pass a bound together. A refused write writes
  nothing (tested: no session folder, no line).
- **The answer says why.** Both 507 and 429 bodies name the bound.

## Findings

### 1. The open window is a sweep, and now it also locks the owner out (medium)

**Where:** `uid_cookie.legacyHonoured` and `reissue`.

**The problem:** inside the window, anyone can send `gopher_uid=p1`,
`p2`, and so on, one GET each. Players are numbered from 1, and a
guest's id is a small number. Each of those GETs:
- comes back signed;
- marks the id;
- leaves the visitor holding that identity for good, with the release
  that deletes its games.
The owner's own unsigned cookie is refused from then on. Before item 51,
a forger could already act as any of them, but so could the owner. What
is new is that the owner loses. Prod's 19 players and 6 guests could be
taken in 25 requests.

**How likely:** it takes someone who knows the cookie's shape and wants
the games. The window, open until the cutover (CUTOVER.md closes it) or
30 days, is the whole exposure.

**Fix shape:** count re-signs per address, as admitPlayer counts names:
one or two an hour is all an owner needs, and a sweep would then take an
address per id. Shortening the window helps too.

### 2. The re-sign redirect goes wherever the request line says (medium)

**Where:** `router.route` answers the re-sign with `location =
http.target(req)`.

**The problem:** measured on a Linux server, with an unsigned `p1`:
- `GET //evil.example/x` answered `303`, `location: //evil.example/x`,
  which a browser reads as another host;
- the absolute form `GET http://evil.example/y` answered
  `location: http://evil.example/y`.
A browser sends the first for a link like `https://lynrummy.com//evil.example/x`.
So a link sent to a player who has not been back since the deploy takes
them, once, to a page of the sender's choosing, from lynrummy.com's own
redirect.

**How likely:** it needs a legacy cookie not yet re-signed, and a link the
player follows. Not checked: whether Caddy passes a `//` path through
unchanged. Nothing in its Caddyfile rewrites paths.

**Fix shape:** use the redirect target `player.sanitizeNext` already
makes: a path that starts with one `/`, else `/`.

### 3. One lost answer loses an identity (medium)

**Where:** `uid_cookie.issue` writes the marker before the answer leaves.

**The problem:** the unsigned cookie is refused once the marker is
written. If the signed cookie never reaches the browser, the owner has
neither. That happens when:
- the tab is closed mid-load;
- the connection drops;
- the 303 goes to something that keeps no cookies.
A player is a name with no password, so nothing can recover them.

**How likely:** rare per visit. Across 25 owners, each with exactly one
chance, it is not negligible.

**Fix shape:** mark the id when its signed cookie first comes back, which
proves it arrived, rather than when it is sent. Until then the unsigned
spelling still works. That widens the window for a forger by the same
margin, so a short grace period instead (honour it again within ten
minutes of the marker) is the narrower fix.

### 4. With IPv6, an address is not one client (medium, if prod has IPv6)

**Where:** `game_limits.seenSlot` keys on the full address text.

**The problem:** an IPv6 client usually holds a /64, which is 2^64
addresses. Each new one gets its own 5 players and 20 MB an hour, so the
per-address bounds bind nothing for such a client.

**How likely:** only if prod is reachable over IPv6, which was not
checked. A DigitalOcean droplet has it when it was enabled, and Caddy
listens on it when the host does.

**Fix shape:** key an IPv6 address by its first 64 bits.

### 5. Registering bypasses the bound on new players (low)

**Where:** `/login/full`'s register arm, which `admitPlayer` does not see.

**The problem:** a new member gets a game identity at login (the player
store's mirror row), and registering is not counted. So the 5 new players
an hour is 5 by `/play` and as many as wanted by registering. The bytes
an hour still bound what one address writes to the game store. What is
not bounded is the account store, a few small files per account.

**Fix shape:** count a registration in `admitPlayer` too.

### 6. A member's signed gopher_uid is a game login that never ends (low)

**Where:** `loginAsMember` issues it; `player.current` reads it first,
before the session.

**The problem:** the cookie has no expiry and cannot be revoked. A copy
plays as the member, and survives:
- logging out elsewhere;
- a password change;
- the session's own year.
It does not reach chat. Release refuses it (`releaseTarget`: an account's
data goes only with the account's own credential).

**Fix shape:** for an id that is an account, take the games' identity
from the session only, and ignore the uid cookie.

### 7. A sibling site can set these cookies (low)

**Where:** prod's Caddy also serves `roc.lynrummy.com` (its Caddyfile
imports `/etc/caddy/sites/*.caddy`).

**The problem:** a page on a sibling subdomain can set `gopher_uid` or
`gopher_auth` with `Domain=lynrummy.com`, and the browser sends them to
lynrummy.com. With that, a visitor can be made to:
- play as the setter's player;
- be logged in as the setter's account.
It needs control of what the sibling serves, which is Steve's own app
today.

**Fix shape:** `__Host-` names for both cookies. A browser refuses a
`Domain` on those, and needs `Secure` and `Path=/`.

### 8. The usage table can be made to walk folders under its lock (low)

**Where:** `game_limits.slot` measures a player not in the table, under
`mu`.

**The problem:** the table holds 256 players. With more players than
that writing in turn, each write can push one out and measure another,
which is a walk of their folder. A folder at the bounds is 500 sessions
and their files. All game writes wait on that lock. On metal, each walk
is disk reads in the one loop.

**Fix shape:** a bigger table, or a usage file per player that is
updated with each write and read instead of walked.

### 9. The floor goes quiet, and covers the game store only (low)

**Where:** `admit`: `free_space` null, or answering null, means no floor.

**The problem:** a host that cannot read free space has no floor, and
nothing says so:
- statfs failing on Linux;
- `space()` failing on metal.
The floor also stops only game writes, by design. Chat's uploads, up to
1 GiB in each member's lifetime, can still fill the volume. Then chat's
own appends fail, and the floor has protected nothing.

**Fix shape:** log once when free space cannot be read, and show it on
/admin/host. Whether uploads need a floor of their own is Steve's call.

### 10. The window starts late, and starts again if its file goes (low)

**Where:** `uid_cookie.windowOpen`.

**The problem:** the file is written the first time an unsigned cookie
is checked, not when the build deploys. And if the file is ever lost, a
new 30 days begins, for example after a restore of `data/players` from
before it existed.

**Fix shape:** write it at startup when absent: the host contract's step
2, `roots.point`, is the place. And treat a missing file as closed once
a marker exists.

### 11. A count can run high (low, by design)

**Where:** `admit` counts before the write.

**The problem:** a write that then fails stays counted until the next
start. So does a puzzle's first move whose session another request made
first. Either way the count errs toward refusing early, never toward
letting a write past a bound.

### 12. A stale comment (none)

`login.releaseTarget` still says "`gopher_uid` is not signed".
