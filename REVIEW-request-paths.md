# Review: every path angry-gopher builds from a request, as an adversary

QUEUE.md item 20. This review covers `angry-gopher/zig-server/src` at
`be16d28`. That is GitHub's `master` on 2026-10-02, which does **not** yet
have the box's `e2610edd` (the body-read fix) or `496bdca3` (`touchUser` and
`reserveUploadBytes` refuse a non-digit id). Nothing is fixed here.

**The scope:** every filesystem call whose path is built, even in part, from
a value a request carries. That means:
- URL segments, query values and form fields;
- headers;
- the `gopher_uid` and `gopher_auth` cookies;
- values read back from disk that a request once wrote.

**The method:** an inventory of every `Io.Dir.cwd()` call and the joins
feeding it, then a trace of each value from where the request supplies it to
the join. The findings below were each re-read at the lines cited.

**Two hosts read this differently.** On Linux, `std.fs.path.join` does not
resolve `.` or `..`, so a component of `..` reaches the kernel's
filesystem. On gopher-metal, `io.zig`'s `placeOf` refuses any path holding
`.` or `..` (a write fails, a read is not found). So a finding that needs
`..` is a Linux finding; one that needs only a value the application
accepts is a finding on both.

## What holds up

- **The router never percent-decodes**, and a segment cannot hold `/`.
  - `router.zig:94` takes the raw target. `stripQuery` (`:202`) only cuts
    at `?`. `http.queryValue` (`http.zig:79`) does not decode either.
  - Chat's segments come from `SegIter` (`chat.zig:583`), which splits on
    `/`.
  - So no URL can smuggle a `/` into a component, and `%2e%2e` stays a
    literal name.
- **The shapes that name chat's files are checked before the join, and
  checked tightly:**
  - a session id (`validSessionID`, `chat_store.zig:900`);
  - a channel name (`validChannelName`, `:937`, plus the channel's
    membership file);
  - a doc slug (`validDocSlug`, `docs_store.zig:40`, which `docPath`
    re-runs itself);
  - an upload's name (`uploadContentType`, `chat_upload.zig:173`: 32 hex
    digits and a whitelisted extension).
- **Upload names are minted by the server** (`chat_upload.zig:70`); the
  client's file name is only echoed back.
- **Numeric ids are parsed and re-formatted** (`game.zig:72`,
  `puzzles.zig:86`, `:99`). So `+5` or `1_0` becomes a canonical `5` on
  disk, never the text sent.
- **The deletes refuse an empty id** (`storage.zig:44`, `users.zig:520`),
  which `path.join` would otherwise collapse to the parent directory.
- **`touchUser` and `reserveUploadBytes`** are reached only with an
  authorized principal (`chat.zig:114-121` gates every chat route), even
  without the box's `496bdca3`. That fix is defence in depth, not a
  closed hole.
- **NUL bytes** a form value decodes to (`%00`) make the path an error
  (BadPathName on Linux), not a truncation.

## Findings

### 1. Anyone can delete any player's game data and record, members' included, through `/logout`

**Where:** `login.zig:202-216`, `handleLogout`.
- **The identity:** `users.currentUser`, else `player.current`, both from
  the `gopher_uid` cookie.
- **The release:** with `release=yes`, it calls
  `storage.deleteUserData(id)`, a `deleteTree` of `{data_root}/<id>`, which
  is `data/lynrummy/<id>`. Then `player.deleteRecord(id)` removes
  `{player_root}/<id>`.

**The problem:** `gopher_uid` is not signed. For a member's id, say `1`:
- `currentUser`'s guest arm refuses it, because the member is authorized
  (`users.zig:63-66`), so `user.id` is empty;
- the code then falls to `player.current`, which accepts any `isSafeID`
  value whose `players/<id>/name` exists, and members are mirrored there
  (`login.zig:189`).

So a POST of `release=yes` with `Cookie: gopher_uid=1`, and no session at
all, deletes member 1's game data and player row. Player ids (`p<n>`) are
sequential.

**Failure:** any client erases any member's or player's Lyn Rummy history
and name. It does not reach chat's data: `deleteUserData` is the game
store, and a member's own chat record would need a real session.

**How likely:** trivial for anyone who reads the code or guesses the
cookie. No authentication, no CSRF needed, since the attacker sends the
cookie from their own client.

**Fix shape:**
- A release must be authenticated as strongly as the account it destroys:
  a member's needs the member's session.
- A cookie-only player is an honour system (`player.zig:29-35`), so either
  sign `gopher_uid` with the session secret, or let a release delete only
  a player that has no member behind it. Refusing it for any id that
  `principalExists` closes the member case at once.

### 2. Anyone can take over a guest account by naming it in the cookie

**Where:** `login.zig:103-137`, the `.upgrade` mode of `POST /login/full`,
and `registerMember` (`login.zig:169-173`).

**The problem:** a guest is an id with an `auth/<id>` directory that is not
authorized. `currentUser` takes it from the unsigned `gopher_uid` cookie
(`users.zig:63-66`). The upgrade path then writes a new name and password
into `auth/<id>/` and logs the caller in as that id.

**Failure:** anyone who sends `gopher_uid=<a guest's id>` with a password
becomes that guest, with everything the guest owned. The same cookie also
reaches finding 1's `deleteUserRecord` (`users.zig:522-525`), which deletes
the guest's `auth/<id>` and `users/<id>`.

**How likely:** as likely as guests are. Ids are small integers, so
guessing is easy. How many guest accounts prod holds was not read here;
the box can count `auth/` directories without a `password`.

**Fix shape:** the same as finding 1. An identity that can be upgraded or
deleted must not be an unsigned number; sign the guest cookie, or require
the upgrade to come from the session that minted the guest.

### 3. A DM's other half is never checked: fake conversations on both hosts, and writes one level up on Linux

**Where:** `chat_store.zig:872-881` (`chatKeyParticipant`), and its use at
`chat.zig:242-253`.

**The problem:** a DM key is accepted when it has one `_`, both halves are
non-empty, it is in canonical order by `atoiOr0` (a non-number counts as
0), and the caller is one half. The other half is any text without `/` or
`_`. It becomes:
- the conversation directory, `{chat_root}/<key>`;
- a member of the conversation (`members[1]`, `chat.zig:252`), for whom the
  fan-out (`chat_store.zig:327-387`) appends to
  `{chat_root}/users/<member>/images.md` and `code.md`, and whose name is
  read from `{auth_root}/<member>/name` (`chat.zig:574-581`).

**Failure, by host:**
- **Both hosts:**
  - **Fake directories.** Any member makes conversation directories with
    keys like `abc_5`, `05_5` or `5_05`, and directories named after them
    under `users/`. They are listed at boot (`listConvDirs`, `backfillAll`).
  - **Uploads into them.** A member can store uploads there up to their
    1 GiB cap.
  - **A lost record.** `05_5` and `5_05` are both canonical, since
    `atoiOr0` makes both 5, so one person's DM can be split.
- **Linux only:**
  - **Writes one level up.** With the other half `..`, as in
    `/chat/c/.._5/<sid>/send` (canonical, since `atoiOr0("..")` is 0), the
    server appends the message's image tags and code blocks to
    `{chat_root}/images.md` and `{chat_root}/code.md`. With `.`, it
    appends to `{chat_root}/users/images.md` and `.../code.md`.
  - **A read one level up.** The page title shows `{auth_root}/../name` or
    `{auth_root}/name`, if such a file exists.
  - **On gopher-metal** these paths are refused (`io.zig`), the fan-out's
    `catch continue` swallows the refusal, and only the fake directories
    happen.

**How likely:** any logged-in member, with one URL. The writes are bounded:
two fixed file names, one level up, holding what the member typed. What
does real damage is the clutter, and a `..` member reaching places nothing
expects.

**Fix shape:** in `chatKeyParticipant`, require both halves to be
all-digits with no leading zero, and the other half a principal that
exists (`principalExists`). Then a DM is between two real accounts, and
both halves are canonical.

### 4. An API key's id prefix reaches paths before anything checks it

**Where:** `users.zig:157-167`, `checkAPIKey`, reached from every request
through `currentUserID` and `bearerToken`.

**The problem:** the id is the text before the first `-` of the
`Authorization` header, unvalidated apart from being non-empty. It goes
through `userIsAuthorized` to stat `{auth_root}/<id>/password`. That stat
accepts any kind, so a directory counts. On a match it reads
`{auth_root}/<id>/api-key`. The header is raw, so `<id>` may hold `/` and
`..`.

**Failure:** an unauthenticated client makes the server stat and read
files of those two names anywhere a relative path reaches. Nothing read is
returned; at most this is a timing oracle for what exists. Becoming a
non-canonical id would need a stored `api-key` equal to the whole
presented string, which only finding 5's admin write could make.

**How likely:** reachable by anyone, with little to gain.

**Fix shape:** `allDigits` on the prefix before any path, as the guest arm
already does.

### 5. Admin-only ids are not checked for their shape

**Where:**
- `admin.zig:44-53`, `/admin/apikey`: the decoded form field `user`. It
  goes to `setUserAPIKey` and `clearUserAPIKey` behind `principalExists`
  and `principalAuthorized`, neither of which looks at the characters.
- `admin.zig:63-64`, `?keyrevoked=<k>`: raw, so it may hold `/`. It feeds
  `getUserName(k)`, which reads `{auth_root}/<k>/name`.

**Failure:**
- **A write:** the admin can write or delete an `api-key` file in any
  directory holding something named `password`, such as `1/.` or
  `1/../2`.
- **A rogue identity:** the key written, `1/.-<hex>`, then authenticates
  as the non-canonical uid `1/.` (finding 4).
- **A read:** the query reads `name` files along any relative path, shown
  escaped, to the admin.

**How likely:** admin only. It matters as a sharp edge: a mistyped id on
the admin form writes somewhere strange, and a `GET` the admin is lured
into reads a file.

**Fix shape:** `allDigits` on both, before `principalExists`.

### 6. Unauthenticated clients can grow the disk without limit

**Where:**
- `GET /puzzles` allocates and writes a new puzzle session on every hit
  (`puzzles.zig:120-133`), with a meta file holding the whole catalog.
- `POST /play` mints a new player directory each time (`player.zig:219`).
- `/game/...` appends 64 KB lines with no count limit. All of it is under
  any player id the cookie names (finding 1's cookie).

**Failure:** a loop of requests fills the volume. On a fixed-size FAT
volume (2 GiB today) that is how chat stops being able to write. Chat's
own quota (1 GiB a user, `reserveUploadBytes`) does not cover any of
this.

**How likely:** easy and unauthenticated. Its only cost to an attacker is
bandwidth, which Caddy's request size limit bounds per request, not in
total. On gopher-metal, Lyn Rummy stays on the Linux droplet, so this is
Linux's exposure today.

**Fix shape:**
- Do not write on a `GET`: allocate a puzzle session on the first move.
- Cap sessions and appends per player, and the players minted per client
  and per hour.
- Count the game store against the same per-user total as uploads.

### 7. Small sharp edges

- **`gallery.zig:132` and `downloads.zig:50` (`isSafeName`)** allow `.`,
  `..` and dot-files.
  - `..` reads a directory and gives a 404, so nothing escapes.
  - A dot-file placed in `downloads/` or the gallery is served to anyone.
  - Low.
- **`chat.urlDecode`'s trailing `%XX` (`chat.zig:632`)**: `i + 2 < s.len`
  leaves a final escape undecoded. That is wrong, not unsafe.
- **Case on FAT** (MIGRATION.md; Steve's decision of 2026-10-02): `P1` and
  `p1` are one player directory on gopher-metal and two on Linux, and so
  are the topics `Foo` and `foo`. The decided fix is case-insensitive
  identity, case preserved, and it is the box's in angry-gopher.

## Summary

| # | finding | who can | what it costs | hosts |
|---|---|---|---|---|
| 1 | `/logout` deletes any player's game data and record, members' too | anyone | a member's or player's whole Lyn Rummy history | both |
| 2 | a guest account is taken over by naming it in the cookie | anyone | the guest's account | both |
| 3 | a DM's other half is unchecked | any member | fake conversations everywhere; on Linux, appends to `chat_root/images.md` and `code.md` and a read of `auth_root/../name` | both, worse on Linux |
| 4 | an API key's id reaches paths unchecked | anyone | stats and reads of two names anywhere, nothing returned | both |
| 5 | admin ids unchecked | the admin | writes and reads at odd paths | both |
| 6 | unbounded disk growth from the game store | anyone | a full volume | Linux today |
| 7 | dot-files, a decode slip, case | various | small | — |

**Order of fixing:**
1. **Findings 1 and 2** share one root: an unsigned cookie is treated as
   an identity that can be deleted or upgraded. Signing `gopher_uid`, or
   refusing release and upgrade without a session, closes both.
2. **Finding 3:** two lines in `chatKeyParticipant`.
3. **Findings 4 and 5:** `allDigits` where an id enters.
4. **Finding 6:** a policy question for Steve.
