# Review: /admin/backup, as an adversary

QUEUE.md item 47, in REVIEW-interrupts.md's shape. Nothing is fixed here.
Each finding names the failure it would cause and how likely it is. They are
in order of severity.

**What was read:**
- angry-gopher at CC's branch `3d6b37fc` (on master `30350218`):
  `admin_backup.zig`, `admin.zig`'s dispatch, `admin_ui.requireAdmin`,
  `users.currentUserID` and the session and API-key paths, `login.zig`'s
  cookies, `server.zig`, and `deploy/Caddyfile` (read only);
- gopher-metal at `a748b2c` (on master `98ec89e`): `probe/gopher.zig`'s
  loop and `serveOne`, `src/stream.zig`'s waits.

**What was run:** a tar cut at a member boundary, read by GNU tar and
Python's tarfile (finding 2). Nothing else; "would" means the code allows it.

## What holds up

- **Who can reach it.** `admin.handle` asks `requireAdmin` before any
  sub-route, and that answers yes only for uid 1:
  - anonymous: a redirect to `/login/full`;
  - anyone else: a 404, which does not confirm the page exists;
  - a guest's `gopher_uid` can never be uid 1: the guest arm refuses an
    authorized id, and since item 51 it needs a signed cookie anyway.
  So the ways in are uid 1's session cookie and an API key for uid 1
  (finding 5).
- **A request from another site.** The route is a GET.
  - The session cookie is `SameSite=Lax`, so a cross-site `<img>`, `fetch`
    or form POST does not carry it.
  - A cross-site link the admin follows would carry it, and the tar would
    download to the admin's own machine. Nothing is sent to the other site:
    there are no CORS headers, so it cannot read the answer.
- **The cookie over plain HTTP.** The cookie has no `Secure` flag. But
  prod's Caddyfile sends `Strict-Transport-Security` with a year's max-age,
  so after one visit the browser never asks over HTTP. That leaves the
  first visit from a browser that has never been there.
- **Caching and logging.** Nothing keeps the archive along the way:
  - the answer says `cache-control: no-store`;
  - prod's Caddyfile has no `log` directive, so Caddy writes no access log
    for lynrummy.com (this matters to item 48, which assumes one);
  - the Linux server logs no requests;
  - metal logs the request line, not the body, into a ring whose secrets
    are redacted as they are written.
  Not checked: whether Caddy's `encode gzip` touches `application/x-tar`.
  Compression would not keep a copy either way.
- **Memory.** The archive is streamed in 64 KiB pieces. What does grow with
  the data is the per-entry names kept in the request's arena until the
  end; item 50 measures listings.

## Findings

### 1. A stolen admin session is every account, for good (high)

**Where:** what the archive holds, and how long a session lasts.

**The problem:** the archive holds `data/chat/_session_secret`, so whoever
downloads it can mint sessions offline:
- a `gopher_auth` for any member, the admin included;
- since item 51, a `gopher_uid` for any player.
Getting the archive takes only uid 1's session, and that session is:
- good for 365 days (`session_max_age_secs`);
- stateless, so nothing on the server can revoke it, and logging out only
  clears the browser's copy;
- enough on its own: no password is asked again for the download.
So a session cookie copied once is a year of access. One GET then turns it
into a secret that outlives the session: until the secret is changed, and
nothing changes it today.

**How likely:** it takes a stolen cookie: a shared or lost laptop, malware,
a browser extension. The cost when it happens is the whole site, with no way
to shut the attacker out short of a new secret by hand.

**Fix shape:**
- Ask for the password again on this route. A POST with the password is a
  small change, and it is the one that matters.
- Write down how to rotate the secret, and what that costs: every member
  logs in again, and every player loses their identity unless the old
  secret is also accepted for a while (uid_cookie.zig's `issued` was kept
  for that).

### 2. A cut-off archive reads as complete (medium)

**Where:** `admin_backup.zig`'s header says "a truncated tar is what the
admin gets. A tar reader says so."

**The problem:** it does not say so. Measured:
- a ustar archive of `d/`, `d/b`, `d/a`, cut just before `d/a`'s header;
- `tar -tvf` lists `d/` and `d/b` and exits 0;
- Python's tarfile lists the same and raises nothing.
An archive that ends between members, as this one does whenever a write
fails (each member is written whole or the walk stops), looks like a
backup of fewer files.

What would show the cut:
- **The transfer itself.** The answer is chunked, and a stop leaves out
  the last chunk. curl reports that, and so does a browser's download.
  Not checked: whether Caddy, between them and the server, passes the cut
  on, or ends its own chunked answer cleanly.
- **Not metal's log.** `render` swallows the error and returns normally, so
  `serveOne` logs the request as `ok`.

Ways it is cut:
- on Linux, a file that shrinks between `stat` and its read, which gives
  `error.FileShrank`. Small files are rewritten while the walk goes on: a
  session's message-count record (`store.replace`), a player's last-seen
  time (`store.write`, which truncates first);
- a download that stalls for 10 s on metal: `sendAll` gives up after
  `idle_ns` with no progress. A laptop going to sleep does it;
- any read error.

**How likely:** the shrink takes a chat write to the file being read at
that moment, which is rare. The stall is likely over a home connection.
Either way, the admin keeps a short backup, and finds out on the day it is
needed.

**Fix shape:** end the archive with a member written only after
everything else, such as `backup-complete.txt` with the counts of files
and bytes. Make its absence what "cut off" means, and have the restore
step check for it. A first walk for a `content-length` would also do it,
but it costs a second pass over the disk.

### 3. On metal, a backup stops the site for as long as it downloads (medium)

**Where:** `serveOne` and `stream.sendAll`.

**The problem:** metal serves one request at a time. While the handler
writes the archive, the loop does not turn, so no other request is
answered:
- `sendAll` runs network turns while it waits for room, so TCP is
  serviced and held chat streams still get their frames
  (`after_arrivals`);
- new connections are accepted into the table, but their requests wait;
- once the table's 256 slots are full, new connections are refused, and
  Caddy answers 502.
The archive goes at the admin's download speed, because Caddy streams it
through rather than holding it. So a 250 MB backup at 2 MB/s is two
minutes in which the site answers nothing.

**How likely:** every backup taken through Caddy from a home connection.
Linux is not affected: it serves each connection on its own task.

**Fix shape:** the cheapest is to take metal's backups from inside the
private network (from prod, at network speed), and to say so where the
route is documented. Making the handler yield to the loop between pieces
would be a change to how metal serves, which is too much for this.

### 4. Not one moment's data on Linux (low)

**Where:** the walk reads file after file while other requests write.

**The problem:** a transcript and its records can come from different
moments, and so can a counter and the folder it counts. A restore from
it is like what a crash at a random moment would leave. The message
count carries the transcript size it was taken at, so a stale one is
counted again. Whether every pair of records is checked that way was not
read. Metal's
archive is consistent, because nothing else runs while it is made: that
is finding 3, seen from the other side.

**Fix shape:** none needed beyond saying it in the module header.

### 5. A key for uid 1 reaches it, never expires, and is in every backup (low)

**Where:** `admin.handleAPIKey` accepts any authorized id, uid 1 included.
`currentUserID` takes a bearer key as readily as a session.

**The problem:** an API key minted for uid 1 is a password-free credential
for this route. It does not expire, and it is stored in plain text
(`auth/1/api-key`), so it is also inside every archive it can download.

**How likely:** only if one was minted for uid 1. The agent (uid 3) is the
expected key holder, and uid 3 is not the admin.

**Fix shape:** take only a session on `/admin/backup` (and finding 1's
password), never a bearer key.

### 6. The archive at rest (low)

**Where:** it lands in the admin's Downloads folder.

**The problem:** it is the session secret, every password hash, and
plain-text API keys, unencrypted. A folder that syncs to a cloud account
carries them along.

**Fix shape:** encrypt it with a passphrase (`age` from the command line).
Or offer an archive without the secret for routine copies, and say on the
page which kind it is.

### 7. A HEAD request reads everything (low)

**Where:** `render` does not look at the method.

**The problem:** `respondStreaming` leaves the body out for a HEAD, but
the walk still reads every file to write it into nothing. On metal that
is finding 3's stall without even a download.

**Fix shape:** answer a HEAD with the headers and return.

## Whether the secret should be in it at all

It should, for a restore, and since item 51 more than before:
- a restore without the old secret logs every member out;
- worse, it orphans every player, whose signed `gopher_uid` is their only
  identity.
So the answer is findings 1 and 6: guard the download harder, and keep the
file encrypted.
