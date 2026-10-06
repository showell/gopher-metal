# Store census: where angry-gopher reaches the disk

*(metal-vmm QUEUE item 80. angry-gopher `f5d360e`, `zig-server/src`, read only; nothing in angry-gopher was changed. Generated from the source by a script, so each file and line is exact; "what it does" is the function the call is in.)*

angry-gopher already has one seam for its data, its own `store.zig`: twelve operations where gopher-metal's Store (`src/store.zig`) has six. It already keeps FAT's name rules on every host and folds case as FAT does (Steve, 2026-10-02), which gopher-metal's Store does too.

**The count:** 143 calls in application code (84 map to one of the six; 23 to an operation the six lack; 1 reach `std.Io` directly, outside the store; 11 are in developer tools; 24 are the store's own), and 73 in tests.

## Calls that are one of the six

| file:line | in | operation | the Store's | refusals that can reach it |
|---|---|---|---|---|
| `admin_backup.zig:171` | `walk` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `admin_lynrummy.zig:187` | `gatherStats` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `admin_lynrummy.zig:198` | `countSubdirs` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `admin_lynrummy.zig:207` | `dirBytes` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `admin_lynrummy.zig:212` | `dirBytes` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `admin_lynrummy.zig:223` | `countTextLines` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `chat_retire.zig:90` | `rmFile` | `store.remove` | remove | NotFound, IsDirectory, BadName, Damaged, Io |
| `chat_retire.zig:205` | `retireTopic` | `store.remove` | remove | NotFound, IsDirectory, BadName, Damaged, Io |
| `chat_retire.zig:220` | `allMembers` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `chat_retire.zig:254` | `retireDMs` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `chat_retire.zig:287` | `pruneChannels` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `chat_retire.zig:291` | `pruneChannels` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `chat_retire.zig:309` | `pruneChannels` | `store.replace` | replace | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:322` | `sweepReferences` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `chat_retire.zig:335` | `sweepReferences` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `chat_retire.zig:350` | `sweepDir` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `chat_retire.zig:376` | `keptUser` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `chat_retire.zig:454` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:455` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:457` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:461` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:462` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:463` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:464` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:468` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:471` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:473` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:477` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:478` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:482` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:483` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_retire.zig:484` | `stage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_store.zig:147` | `openStream` | `store.readOrEmpty` | read (an absent file reads as empty) | IsDirectory, BadName, TooBig, Damaged, Io (NotFound is answered as empty) |
| `chat_store.zig:173` | `appendMessage` | `store.append` | append | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_store.zig:184` | `appendMessage` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `chat_store.zig:214` | `readReactions` | `store.readOrEmpty` | read (an absent file reads as empty) | IsDirectory, BadName, TooBig, Damaged, Io (NotFound is answered as empty) |
| `chat_store.zig:231` | `appendReaction` | `store.append` | append | BadName, IsDirectory, NoSpace, Damaged, Io |
| `counter.zig:30` | `next` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `counter.zig:39` | `next` | `store.replace` | replace | BadName, IsDirectory, NoSpace, Damaged, Io |
| `counter.zig:49` | `peek` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `downloads.zig:41` | `serve` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `gallery.zig:120` | `serveImage` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `game_limits.zig:273` | `measure` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `game_limits.zig:283` | `sizeOf` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `home.zig:89` | `parseHome` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `player.zig:115` | `setName` | `store.replace` | replace | BadName, IsDirectory, NoSpace, Damaged, Io |
| `player.zig:138` | `list` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `player.zig:182` | `touchImpl` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `player.zig:187` | `readField` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `resume_page.zig:40` | `handle` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `resume_page.zig:55` | `handlePdf` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `roots.zig:79` | `migrateSecret` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `roots.zig:80` | `migrateSecret` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `roots.zig:82` | `migrateSecret` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `roots.zig:85` | `migrateSecret` | `store.remove` | remove | NotFound, IsDirectory, BadName, Damaged, Io |
| `safari_download.zig:33` | `handle` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `storage.zig:121` | `writePuzzleSessionFile` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `storage.zig:147` | `appendTextLine` | `store.append` | append | BadName, IsDirectory, NoSpace, Damaged, Io |
| `storage.zig:174` | `writeSessionFile` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `storage.zig:182` | `readSessionFile` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `storage.zig:214` | `listSessionIDs` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `storage.zig:231` | `countTextLines` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `storage.zig:254` | `appendRawLine` | `store.append` | append | BadName, IsDirectory, NoSpace, Damaged, Io |
| `uid_cookie.zig:124` | `issueMarked` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `uid_cookie.zig:137` | `isMarked` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `uid_cookie.zig:150` | `windowOpen` | `store.readOrEmpty` | read (an absent file reads as empty) | IsDirectory, BadName, TooBig, Damaged, Io (NotFound is answered as empty) |
| `uid_cookie.zig:153` | `windowOpen` | `store.replace` | replace | BadName, IsDirectory, NoSpace, Damaged, Io |
| `users.zig:210` | `listAuthorized` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `users.zig:253` | `touchUserImpl` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `users.zig:268` | `userUploadBytes` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `users.zig:285` | `reserveUploadBytes` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `users.zig:313` | `setUserAPIKey` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |
| `users.zig:321` | `clearUserAPIKey` | `store.remove` | remove | NotFound, IsDirectory, BadName, Damaged, Io |
| `users.zig:345` | `listUserIDs` | `store.list` | list | NotFound, BadName, Damaged, Io |
| `users.zig:366` | `userLastSeen` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `users.zig:378` | `readAuthFile` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `users.zig:402` | `previousSecret` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `users.zig:407` | `previousSecret` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `users.zig:422` | `rotateSecret` | `store.replace` | replace | BadName, IsDirectory, NoSpace, Damaged, Io |
| `users.zig:423` | `rotateSecret` | `store.replace` | replace | BadName, IsDirectory, NoSpace, Damaged, Io |
| `users.zig:428` | `rotateSecret` | `store.replace` | replace | BadName, IsDirectory, NoSpace, Damaged, Io |
| `users.zig:436` | `loadSecret` | `store.read` | read | NotFound, IsDirectory, BadName, TooBig, Damaged, Io |
| `users.zig:535` | `setUserName` | `store.replace` | replace | BadName, IsDirectory, NoSpace, Damaged, Io |
| `users.zig:545` | `setUserPassword` | `store.write` | write | BadName, IsDirectory, NoSpace, Damaged, Io |

## Calls that fit none of the six

Each is a question about the seam, for Steve: grow the six, or rewrite the call in terms of them? Grouped by what the call needs.

### `store.has`: whether a name is there (6)

- `chat_retire.zig:368`, in `convGone`: `return !store.has(io, alloc, dir);`
- `roots.zig:76`, in `migrateSecret`: `if (!store.has(io, alloc, old_path)) continue;`
- `roots.zig:78`, in `migrateSecret`: `if (!store.has(io, alloc, new_path)) {`
- `uid_cookie.zig:136`, in `isMarked`: `if (!store.has(io, alloc, p)) return false;`
- `uid_cookie.zig:166`, in `legacyHonoured`: `if (!store.has(io, alloc, row) and !users.principalExists(io, alloc, id)) return false;`
- `users.zig:372`, in `authFileExists`: `return store.has(io, alloc, path);`

### `store.makeDir`: a directory made on its own, with nothing in it yet (1)

- `users.zig:282`, in `reserveUploadBytes`: `store.makeDir(io, alloc, dir) catch return false;`

### `store.readAt`: part of a file, from an offset (1)

- `admin_backup.zig:189`, in `walk`: `const n = try store.readAt(io, alloc, host_path, at, buf[0..want]);`

### `store.removeTree`: a directory and everything under it removed (8)

- `chat_retire.zig:95`, in `rmTree`: `if (self.apply) store.removeTree(self.io, self.alloc, path) catch {};`
- `chat_retire.zig:208`, in `retireTopic`: `if (pl.apply) store.removeTree(pl.io, alloc, up) catch {};`
- `chat_retire.zig:246`, in `retireUser`: `if (pl.apply) store.removeTree(pl.io, alloc, path) catch {};`
- `chat_retire.zig:261`, in `retireDMs`: `if (pl.apply) store.removeTree(pl.io, alloc, try std.fs.path.join(alloc, &.{ chat_store.chat_root, e.name })) catch {};`
- `player.zig:124`, in `deleteRecord`: `store.removeTree(io, alloc, dir) catch {};`
- `storage.zig:58`, in `deleteUserData`: `store.removeTree(io, alloc, root) catch {};`
- `users.zig:573`, in `deleteUserRecord`: `store.removeTree(io, alloc, p) catch {};`
- `users.zig:576`, in `deleteUserRecord`: `store.removeTree(io, alloc, p) catch {};`

### `store.stat`: a file's size and kind, without its bytes (7)

- `admin_backup.zig:166`, in `walk`: `const st = store.stat(io, alloc, dir) catch return; // a root not there yet`
- `admin_backup.zig:179`, in `walk`: `const fst = store.stat(io, alloc, host_path) catch continue;`
- `gallery.zig:106`, in `imageFile`: `if (store.stat(io, alloc, path)) \|_\| return name else \|_\| {}`
- `game_limits.zig:286`, in `sizeOf`: `.file => total += (store.stat(io, alloc, p) catch continue).size,`
- `storage.zig:127`, in `puzzleSessionExists`: `const st = store.stat(io, alloc, dir) catch return false;`
- `storage.zig:188`, in `sessionExists`: `const st = store.stat(io, alloc, dir) catch return false;`
- `users.zig:183`, in `userExists`: `const st = store.stat(io, alloc, dir) catch return false;`

Where each might go in the six, as a starting point and not an answer:

- `stat` and `has`: `list` of the parent, and the name looked for in it; a cost of one directory walk.
- `readAt`: no rewrite in the six. A picture served in parts (Range requests, `chat_upload`) needs it, so this is the likeliest seventh.
- `makeDir`: a directory the Store makes for the first file under it; a directory with nothing in it yet has no place in the six.
- `removeTree`: `list` and `remove` for each file, but the six never remove a directory, so an emptied one stays. A deleted player is this.

## Calls that reach `std.Io` directly, outside the store

These bypass angry-gopher's own seam, so its name rules do not apply to them.

| file:line | in | call | line |
|---|---|---|---|
| `config.zig:31` | `load` | `readFileAlloc` | `const body = Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch \|e\| {` |

Developer tools, which read chat files on a laptop and never run in the server: `markdown_bench.zig`, `markdown_hostile_probe.zig`, `markdown_regression_test.zig` (11 calls).

## The store's own calls (`store.zig`)

The seam itself, for reference: where each of its operations meets `std.Io`.

| line | in | call |
|---|---|---|
| `133` | `sibling` | `openDir` |
| `138` | `sibling` | `iterate` |
| `181` | `exists` | `access` |
| `197` | `read` | `readFileAlloc` |
| `200` | `read` | `readFileAlloc` |
| `218` | `readAt` | `openFile` |
| `221` | `readAt` | `openFile` |
| `226` | `readAt` | `readPositionalAll` |
| `249` | `stat` | `statFile` |
| `252` | `stat` | `statFile` |
| `273` | `list` | `openDir` |
| `276` | `list` | `openDir` |
| `282` | `list` | `iterate` |
| `304` | `write` | `writeFile` |
| `306` | `write` | `writeFile` |
| `334` | `replace` | `writeFile` |
| `336` | `replace` | `writeFile` |
| `338` | `replace` | `rename` |
| `357` | `append` | `createFile` |
| `360` | `append` | `writePositionalAll` |
| `366` | `makeDir` | `createDirPath` |
| `372` | `remove` | `deleteFile` |
| `375` | `remove` | `deleteFile` |
| `387` | `removeTree` | `deleteTree` |

