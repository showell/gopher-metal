# Sessions and the secret: options for Steve

> **Partly built:** changing the secret is `/admin/secret` (QUEUE.md item 66;
> SECRET-LEAK.md and `droplet/rotate_secret.py`), keeping players' cookies for
> 0-90 days. Session lifetimes and revocation are still as described. What
> follows is the note as written: "today" below means then.

QUEUE.md item 58, from REVIEW-admin-backup.md findings 1 and 5. This is a
note for a decision: no code here. Read at angry-gopher `3669ef98`.

## Today

- **`gopher_auth`**, a member's session: `<id>.<issued>.<mac>`, with mac =
  HMAC(secret, id, issued).
  - It is good for **365 days** from `issued` (`session_max_age_secs`).
  - Nothing on the server records it, so **nothing can revoke it**.
    Logging out clears the browser's copy only. A copy taken before
    still works, and so does one taken after a password change.
- **`gopher_uid`**, a player's identity: signed with the same secret since
  item 51, **with no expiry at all**. For a player it is the only thing
  that says who they are: there is no password to fall back on.
- **The secret**, `data/chat/_session_secret`, has never changed.
  - It is in every backup.
  - Whoever has it mints any member's session and any player's cookie,
    offline, for as long as it stays the same.

Since item 57 the backup asks for the password again, so a copied session
no longer reaches the secret. What remains is below.

## Changing the secret

When it would be needed: the secret leaked (a backup lost or copied, a
laptop gone), or as routine.

**How, so that nobody notices:**
1. A new secret is written beside the old one. The old one is kept as
   `_session_secret.previous`, with the date it stops being accepted.
2. New cookies are signed with the new secret.
3. A cookie signed with the old one is still accepted until that date. On
   its first use it is answered with a fresh one, as item 51 re-signs a
   legacy `gopher_uid`. `issued` is already in both cookies' formats,
   and was kept for this.
4. After the date, the old secret is deleted.

**What each person sees:**
- **A member who visits before the date:** nothing.
- **A member who does not:** logged out once. They log in again with
  their password.
- **A player who visits before the date:** nothing.
- **A player who does not: their identity is gone**, as with item 51's
  window. So the date is a trade:
  - a long one (90 days) keeps the players who come back seasonally;
  - a short one (7 days) shuts a leaked secret out sooner.
  After a leak, the honest answer is a short date and the players' loss.

**Cost:** two secrets read instead of one, and a re-sign on first use.
That is about the size of item 51's re-sign, and works the same on both
hosts.

## Shorter or revocable sessions: three shapes

**A. Shorter, renewed on use.** The max age drops to, say, 30 days, and a
request with a session older than a week gets a fresh cookie.
- A member who visits monthly never notices.
- A copied cookie lasts at most 30 days, unless the thief keeps using it,
  since renewal works for them too.
- Revocation: still none.
- Cost: a few lines in users.zig, and a Set-Cookie now and then.

**B. A per-member generation number.** `auth/<id>/session-gen` is a
number, and it goes into the session's MAC.
- Bumping it kills every session of that member at once. It would be
  bumped on a password change and by a new "log out everywhere" button.
- The same works for a player, with `data/players/<id>/gen`, bumped by
  "log out everywhere" on /play. A player cannot then get back in
  without a cookie, so that button would say so.
- Revocation: per person, at once.
- Cost: one more small file read when a session is checked (the account's
  files are read anyway), and existing cookies re-signed once, as in
  "Changing the secret".

**C. Sessions kept on the server.** A random token in the cookie, looked
up in `data/sessions/`.
- Every session can be listed, ended, and shown to its owner ("your
  sessions").
- Cost:
  - a file written per login and per renewal, many small files on FAT;
  - every request reads one;
  - the backup then holds live tokens as well as the secret.
- It is the most code, and it changes what a cookie is.

**CC's recommendation:**
- **A and B together:** 30 days renewed on use, and a generation number
  bumped by a password change and by "log out everywhere".
- **Write down the change of secret** as a procedure for a leak,
  rather than doing it as routine, since each change costs the players
  who do not come back in time.
- **C buys little more** at this site's size: one admin and a few
  members.

## For Steve to decide

1. The session's max age: 365 days as now, or shorter with renewal (A)?
2. Revocation: none as now, per person (B), or kept on the server (C)?
3. After a leak, how long the old secret is still accepted: what that
   means for players who do not come back in time.
