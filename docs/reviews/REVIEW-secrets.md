# Review: secrets, every way out

QUEUE.md item 92, Steve's biggest risk (leaking a password). This traces each
secret from where it is stored to every way it could leave the machine, on
metal (gopher-metal) and on Linux (angry-gopher, the same application code).
Nothing is fixed in this review; one regression test was added where a gate
had no member-case probe (noted below), and one Low has a fix shape.

It is a reading, not a run, except where a test or probe is named.

## The secrets, and where each lives

| secret | at rest | how it authenticates |
|---|---|---|
| password hashes (bcrypt) | `{auth}/<id>/password`, mode 0o600 on Linux (FAT has no mode) | `/login/full` POST body, `/admin/{backup,secret}` POST body |
| the session secret | `{data}/chat/_session_secret` | signs/verifies `gopher_auth`; never sent |
| a member's API key | `{auth}/<id>/api-key` | `Authorization: Bearer <id>-<secret>` header |
| the session cookie | the client's `gopher_auth` | the Cookie header |

All four of the stored ones live under `auth_root` or `{data}/chat` — not under
the site's served trees (`pages/`, `gallery/`, `downloads/`, and the chat
uploads), which on metal are even on a different disk (the boot disk) from the
data volume.

## What holds up

Checked against the item's list of ways out, and found closed:

- **The file/upload serving cannot reach `auth/` or `_session_secret`.**
  - `downloads`, `gallery`, `images` validate the name to `[A-Za-z0-9._-]`
    with no `/` (`isSafeName`), so no segment and no traversal — a name can
    only pick a file *within* that served directory, which holds none of the
    secrets. A FAT 8.3 alias, a case fold or a trailing dot can at most name a
    sibling in the *same* served directory; it cannot cross into `auth/` or
    `chat/`, because crossing needs a `/`.
  - `chat_upload.serveUpload` builds `conv_dir/sessions/<sid>.uploads/<file>`
    and gates `file` through `uploadContentType` **before** the read: exactly
    32 hex characters, a `.`, and a known extension (`if (dot != 32) return
    null;` then a hex check). So `file` can be neither `_session_secret` nor
    `../…`. The `Range:` path reads positionally, clamped to the file size and
    one `range_window`, so it cannot read past the file either.
  - `..`, `%2e`, long names and FAT's 8.3 aliases in a *uid* taken from a form
    were the subject of REVIEW-request-paths.md (findings 4, 5); `apiKeyTarget`
    now gates on `validUid` + `principalExists` + `principalAuthorized`, so an
    id is a uid before it is a path.

- **`/admin/*` refuses everyone but uid 1, members included.** Every
  `/admin/*` route enters `admin.handle`, whose first line is `if (!try
  ui.requireAdmin(...)) return;`. `requireAdmin` resolves the authenticated
  principal (session or Bearer key) and `404`s any uid that is not `"1"` (a
  guest `gopher_uid` is never authorized, so never uid 1). `/admin/backup`
  (every hash + the secret) and `/admin/secret` additionally require uid 1's
  **password** in the body, not just a session. **The existing test covered
  only the anonymous and guest cases; this review adds the member case** —
  a real authorized uid-2 session is refused `/admin`, `/admin/backup`,
  `/admin/secret`, `/admin/apikey`, `/admin/host`, `/admin/lynrummy`, with no
  `200`, no `$2…` hash and no session secret in the body (router.zig,
  "ADMIN\_ONLY — a logged-in non-admin member is refused the secret-bearing
  screens"). 715/715 server tests pass with it.

- **Error pages echo nothing.** `http.notFound` / `methodNotAllowed` respond
  with fixed strings (`"not found\n"`, `"method not allowed\n"`); no handler
  echoes `req.head.target`, a header or a cookie into a body. `http.zig` is
  the one place allowed to touch `req.head.target`, and `target()` dupes it
  for routing — it is not reflected.

- **No leftover memory in a response.** Every `respond(...)` is given the
  exact slice to send — an `ArrayList`'s `.items`, or `data[0..n]` after a
  read that returns `n` — so `Content-Length` equals the bytes written; a
  short read serves `data[0..n]`, never the allocated tail. On metal each
  request runs on its own heap, reset after the response, and the shared
  `write_buf` is only ever sent `[0..written]`. There is no path that declares
  a length larger than what was put in the buffer.

- **The API key and the secret are never shown except on purpose.**
  `/admin/apikey` shows a freshly minted key once, to the admin, in a dynamic
  page (not a cached file); `/admin/secret` changes the session secret behind
  uid 1's password and never prints it. Caddy is a plain `reverse_proxy` (no
  cache), so neither is stored by a shared cache.

- **What is written down holds no cookie, body or header.** Metal's
  `logRequest` writes `METHOD target` and an outcome (`@errorName(e)` or
  `"ok"`) — never a header (so never the Cookie or `Authorization: Bearer`
  key) and never a body (so never a password). `/version` is static counters;
  `/admin/host` reports the host's own facts (version, pid, uptime, memory,
  data dir) and its log, no request data of its own. See finding 1 for the
  one thing `logRequest` does write that the item's rule would keep out.

## Findings

### 1. Metal writes the request query into the log it keeps and serves (Low)

**Where:** `probe/gopher.zig`, `serveOne` builds
`what = "{METHOD} {target[0..256]}"` and `logRequest` writes it into
`serial`, which feeds the 64 KiB `log_ring` that `/admin/host` serves and the
`kept_log` that survives a restart. `target` is `/path?query`.

**The problem:** the item's rule is that no cookie, query or body may be in
what is written down. Cookies, bodies and headers are kept out (above), but
the **query** is not: a `GET /x?… ` is logged whole, to a place an admin reads
and a restart preserves. Linux (`server.zig`) logs no request target at all,
so this is also a metal/Linux divergence.

**The failure it causes, and how likely:** none today. No secret rides a query
in this application — login, secret rotation and key issue are POST bodies,
the session is a cookie, and the API key is an `Authorization` header. So the
log holds no secret now. It is Low, not nil, because the safety is a property
of every current caller, not of the log: a future query-borne token (a share
link, a one-time link, an SSE `?token=` for a client that can't set a header)
would land in an admin-visible, restart-surviving log with nothing to stop it,
and in any backup of that log.

**Fix shape:** log the path, not the query — truncate `target` at `?` when
building `what` (one line in `serveOne`), so the log keeps the route without
the query. A test: a request with a query, then assert the drained
`serial`/ring holds the path and not the text after `?`. Not applied here: it
touches the serving binary the day before the cutover to close a gap nothing
currently reaches; the one line is cheap to take afterward, and Steve may
prefer to keep the full target for debugging and instead hold the rule by
never putting a secret in a query (which is the state today).

## Probes, so the gates keep it closed

- **Added:** router.zig's member-refused test above — the gate on the
  secret-bearing admin screens, which had only an anonymous/guest probe.
- **Already in place, confirming the rest:** `uploadContentType`'s own tests
  (the 32-hex gate), REVIEW-request-paths.md's traversal tests (`validUid`,
  `principalAuthorized`), and the chat judge's `/admin/host` comparison. The
  one thing worth a judge story if finding 1's fix is taken: a request whose
  query would be secret-shaped, asserting it is absent from `/admin/host`'s
  log section.

## Summary

The secret surface is closed on both hosts: file and upload serving cannot
reach `auth/` or `_session_secret` (no-slash charset, 32-hex gate, separate
roots — a separate disk on metal), `/admin/*` refuses members and not just
anonymous visitors (now with a test), the backup and secret-rotation screens
need uid 1's password, error pages echo nothing, responses carry no leftover
memory, and the cookie, body and `Authorization` header are never written
down. The one Low is that metal logs the request *query* into a kept,
admin-visible log; it leaks nothing today because no secret travels in a
query, and finding 1 gives the one-line fix if Steve wants the rule enforced
rather than relied on.
