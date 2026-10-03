# If the admin password is lost

QUEUE.md item 89, found by fire drill 1. One page, for the day it is
needed. CUTOVER.md is where the cutover's papers start.

## What is locked

The admin is uid 1. Without the admin password there is:
- no backup (`/admin/backup` asks for it);
- no change of the session secret (`/admin/secret` and
  `droplet/rotate_secret.py` ask for it);
- no way to sign in as the admin from a new browser.

The password is stored only as a bcrypt hash, so it cannot be read back.
Metal has no shell to log in to. **A browser still signed in as the admin
is not a way back:** the pages above ask for the password again.

**Neither way back can be started by a request to the site.** Each needs
ssh to prod, or a new boot image for metal.

## Before the cutover: lynrummy.com on prod's Linux

From a machine with ssh to prod and an angry-gopher checkout:

    ops/reset_admin_password

It does four things:
- shows uid 1's name, and asks before changing anything;
- asks for the new password twice;
- hashes the password on your machine, so only the hash goes to prod;
- stops the server, puts the new hash in place, and starts it again.

The site is down for a few seconds. The old hash is kept as
`auth/1/password.before-reset`.

## After the cutover: metal

Metal reads the reset from its boot disk, so it takes a deploy. From the
machine that builds images, with angry-gopher beside this checkout:

**1. Build the image with the reset in it:**

    droplet/chat.py chat.img --reset-admin-password Steve

It asks for the new password twice, and hashes it here. The image then
carries `admin_password_reset = Steve <hash>` in its gopher-metal.conf.
Only the hash is in the image, and nothing goes into the repository.

**2. Deploy it** as any image (README.md, "A deploy").

**3. Watch the boot.** It must say:

    admin password reset for Steve: applied; the old hash is auth/1/password.before-reset

Any other line means nothing changed:
- `applied by an earlier boot`: this same hash was applied before. A
  password changed since then is kept;
- `REFUSED: uid 1 is not named so`: the name on the command line is not
  uid 1's name on this volume (it is matched exactly, case included);
- `REFUSED: uid 1 has no password`: there is no admin on this volume;
- `FAILED`: the volume would not read or write. The next boot tries
  again.

**4. Log in** with the new password.

**5. Deploy once more without the flag**, so the next image no longer
carries the hash. Leaving it in changes nothing, because the reset is
applied once, but nothing needs to carry it.

## Undoing it

The hash replaced is kept beside the new one, as
`auth/1/password.before-reset`.
- **On prod:** copy it back over `auth/1/password`, with the server
  stopped.
- **On metal:** from a backup, or the volume on the box, as any file of
  the data.

## Tested

- **angry-gopher:** `ops/test_reset_admin_password`, against a real
  server.
- **gopher-metal:**
  - `src/io_test.zig`: once; another name; no admin; a reset stopped
    part-way and finished by the next boot;
  - the judge's `admin-reset` gate, on both hosts
    (`probe/run.sh gopher admin-reset`).
