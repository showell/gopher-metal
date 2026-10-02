# If the session secret leaks

QUEUE.md item 66. One page, for the day it is needed. The options behind it
are in DESIGN-sessions.md; this is the procedure, whatever Steve decides
about session lifetimes.

## What the secret is, and what a leak gives away

`data/chat/_session_secret` signs both cookies the site sets:
- **every member's session** (`gopher_auth`);
- **every player's identity** (`gopher_uid`).
Whoever has it can make either for anyone, offline, for as long as it
stays the same.

**It has leaked if any of these happened:**
- a backup (`/admin/backup`) was lost, copied, or stored somewhere
  shared;
- a machine holding a backup or a copy of `data/` was lost;
- the file itself was seen.

## The procedure

**1. Decide the days.** Players have no password: after a change, a
player's cookie still works, and is renewed, only for the days you give.
So:
- **the leak is being used** (strange logins, players' games changed):
  **0 days**. Every player not yet signed with the new secret is gone;
  their data stays on the volume;
- **it only may have leaked:** **7 to 30 days**. Players who come back
  in that time notice nothing. Until then, whoever has the old secret can
  still make players' cookies, but not members' sessions.

**2. Change it,** on prod, against the host serving the site: metal's
private address after the cutover, `http://127.0.0.1:9001` before. Never
through Caddy from a home connection.

    droplet/rotate_secret.py http://<host> --days N

It asks for the admin's password, then prints three lines, each of which
must say GO:
- `GO    change the secret`;
- `GO    the old session: ended`;
- `GO    log in again`.

There is a form for the same thing at `/admin/secret`, for when the
script cannot be run.

**3. Then, because the same leak gave away more than the secret:**
- **API keys:** a backup holds them in plain text. At `/admin`, revoke
  each one and make a new one for whoever uses it.
- **Passwords:** a backup holds their hashes. These are slow to break,
  but ask each member to choose a new password.
- **Backups:**
  - take a new one;
  - delete every older one you can reach: they hold the old secret, and
    the old hashes and keys;
  - keep the new one encrypted (REVIEW-admin-backup.md, finding 6).

**4. Tell the members** they will have to log in again, and why.

## What not to do

- **Do not change the secret twice within the days.** The second change
  replaces the "previous" secret, so players still carried over by the
  first are dropped.
- **There is no undo.** The old secret stays readable as
  `_session_secret.previous` until its date, and is no longer used after
  that.

## How this was tested

`droplet/rotate_secret.py --self-test` runs the procedure on the judge's
staged site, on a Linux server and on metal booted under QEMU. On each:
- the secret changed;
- the old session ended;
- the password logged in again;
- a player's cookie signed before the change was renewed with the new
  secret, and named the player.
angry-gopher's router tests also check that a wrong password, or days
that are not 0 to 90, change nothing, and that an old player cookie
names no one once its date has passed.
