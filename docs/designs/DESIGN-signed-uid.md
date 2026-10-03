# Design: signing `gopher_uid`

> **Built** (QUEUE.md item 51, angry-gopher `uid_cookie.zig`), with the
> re-sign grace and per-address count of item 63. What follows is the design
> as it was written, before the code: "today" below means then.

QUEUE.md item 23. This note is the root fix for REVIEW-request-paths.md
findings 1 and 2. It is a design for Steve to decide on; no code is in it.
It was read on angry-gopher at CC's branch `fa28574a`, which sits on
`master` `28702571`.

## What the cookie carries today

`gopher_uid` is set in the clear, for a year, and three kinds of identity
share it:

| Who | Id | Set by | Resolved by |
|---|---|---|---|
| a member | digits | `loginAsMember`, next to the signed `gopher_auth` | `player.current` (games); chat uses `gopher_auth` |
| a legacy guest (prod: 6) | digits, an account with no password | no longer minted: `registerMember` makes members only | `users.currentUserID`'s guest arm, and `player.current` |
| a player (prod: 19) | `p<n>` | `player.handle`, the name page | `player.current` |

Because nothing is signed, whoever sets the cookie by hand **is** that
identity, wherever the cookie is believed:

- **A player's game list.** `gopher_uid=p3` plays as p3, files games under
  p3, and could release p3 (`releaseTarget` allows a cookie-only player to
  release itself).
- **A member's game list.** Every member is mirrored into the player store
  under the same id, so `gopher_uid=1` with no session reaches uid 1's
  games through `player.current`. The box's `releaseTarget` now stops the
  *deletion* (finding 1), but reading and playing as them remain.
- **A guest's account, for good (finding 2).** `gopher_uid=<a guest's id>`
  puts `/login/full` in `.upgrade` mode with the guest's name locked, and
  any password then makes the forger that member.

Chat, settings, admin and uploads are not reached this way: they need
`gopher_auth` or an API key, and the guest arm refuses an id that is
authorized.

## The proposal

**Sign the value with the session secret, under its own label.**

```
gopher_uid = <id>.<issued>.<mac>
mac        = base64url(HMAC-SHA256(secret, "gopher_uid\n" + id + "\n" + issued))
```

- **The same secret** as `gopher_auth` (`_session_secret`), so there is
  nothing new to deploy. On metal it is already on the volume.
- **A label of its own** (`"gopher_uid\n"`) so a session's MAC can never
  pass as a uid's, or a uid's as a session's. `sessionMAC` today hashes
  `id + "\n" + issued` with no label. That is fine on its own, but the two
  must not share a construction.
- **Ids hold no `.`** (digits, or `p` then digits), so the value splits
  without base64, unlike `gopher_auth`, which encodes its id.
- **No server-side expiry.** For a player, the cookie is the only
  identity, and expiring it loses their games. `issued` is there so a
  secret rotation can be added later (accept the previous secret for a
  while), not to time anything out.
- **One place verifies it.** A small module, with the crypto pure and
  parameterized by the secret as `verifySessionWithSecret` is, and a
  frozen-vector test. Both `player.current` and the guest arm call it.
  `player.zig`'s header is right that the player store should not carry
  the account store across. The secret is not the account store, though,
  so it moves into the small module, and `users.zig` reads it from there
  too.
- **Every place that sets the cookie signs it:** `login.uidCookie`
  (members) and `player.cookie` (players). With the secret missing, the
  server refuses to mint, as `loginAsMember` already does, rather than
  issue an unsigned cookie.
- **The guest upgrade** (`.upgrade`) needs a verified cookie. That closes
  finding 2 at its root.

## Cookies already in browsers

Prod has 19 players and 6 guests, and some members' browsers hold an
unsigned `gopher_uid` beside their session. There are three choices for
an unsigned cookie after the change:

1. **Let go.** It is ignored. The players re-enter a name, get a new
   `p<n>`, and lose sight of their old games until an admin merges them by
   name. The guests can no longer upgrade. It is simple, and it is a
   visible loss for up to 25 people.
2. **Read-only.** It shows the name and the games, but cannot play,
   release or upgrade. There is no way to prove ownership later (players
   have no password), so this is option 1 with a view.
3. **Re-identify once (recommended).** For a window (proposed: until the
   cutover to metal, or 30 days, whichever is first), an unsigned cookie
   is accepted **once** for an id that existed on the day the change
   deployed. The response re-issues it signed, and the server then marks
   the id as signed (`{player_root}/<id>/signed`, an empty file). From
   then on, an unsigned cookie for that id is refused, window or not.
   - **The owner usually wins the race.** Whoever visits first after the
     deploy gets the id, and that is nearly always the person who has
     played there for months. A forger has the same chance as today, for
     one visit, and only before the owner returns.
   - **Members are never re-identified this way.** An id with a password
     is refused unsigned, as the guest arm already refuses one. A request
     with a valid `gopher_auth` and an unsigned or missing `gopher_uid` is
     simply given a signed one.
   - **After the window,** what is left is option 1 for whoever did not
     come back. Their ids and data stay on disk, and the admin page lists
     them.
   - **The cost:** one marker file per player, a frozen list of the ids
     that may be re-identified (or "every id whose `name` is older than
     the deploy"), and a date in the code to delete later.

**For the 6 guests,** the same once-only rule applies, and `.upgrade`
needs the signed cookie. A guest who comes back signs on their first
visit and can then upgrade as today. A forger who gets there first has
an account with the guest's name. That is what the hole allows today,
narrowed to one visit before the guest's own.

## How it would be proved

**Unit tests**, in angry-gopher:
- sign then verify gives the id back; a frozen vector pins the format;
- a changed id, `issued` or mac is refused, and so is a value with a
  missing part or an extra one;
- a `gopher_auth` value is refused as a `gopher_uid`, and the reverse;
- an unsigned cookie is accepted once inside the window, and then
  refused, with the marker written;
- an unsigned member id is refused, inside the window or not;
- once the window has closed, an unsigned id is refused;
- with the secret missing, nothing is minted;
- the `.upgrade` mode needs a verified cookie.

**Judge cases**, compared on both hosts, with the judge's staged secret:
- a player names themselves, gets a signed cookie, and plays;
- a hand-set `gopher_uid=p1` (unsigned, the window closed) gets the name
  page, not p1's games;
- a release with that forged cookie deletes nothing (the tree compares
  equal);
- a guest upgrade with a forged cookie gets the stranger page;
- a legacy unsigned cookie inside the window is re-signed, and the same
  unsigned cookie on the next request is refused.
- **One snag:** `issued` is wall-clock seconds, so the two hosts' cookies
  differ. The judge already normalizes times inside each host's window; a
  `gopher_uid` Set-Cookie would need the same normalization, or `issued`
  could be in days.

## For Steve to decide

1. Which of the three choices for existing cookies (CC recommends 3).
2. The window: until the cutover, 30 days, or another length.
3. Whether the once-only marker is worth one file per player. Without it,
   option 3 lets anyone keep using the hole until the window closes.
4. Whether the six guests should instead be turned into players (they
   cannot chat as guests anyway), which would remove the guest arm and
   `.upgrade` altogether.
