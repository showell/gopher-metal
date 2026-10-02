# The cutover: lynrummy.com from Linux to gopher-metal

QUEUE.md item 33. **Steve runs this.** The box Claude helps from the dev
box. Every step ends with a **GO** line: what must be true before the next
step. Anything else is **NO-GO**: stop, and take the way back (the last
section).

What moves: prod's `data/` and `auth/`, all of chat and every app, onto a
FAT32 DigitalOcean volume that gopher-metal serves. lynrummy.com's Caddy
then sends the site to it. Linux keeps the old data, untouched, until the
first day is over.

Placeholders, not real addresses: `<prod>` is the lynrummy.com droplet,
`<metal>` the gopher-metal droplet's private address, `<box>` the dev
box, `N` the volume's size in GiB, and `/dev/sdX` whatever `lsblk` shows.

## Before the day

Each of these is done, and checked, at least a day before.

1. **Everything is on `master` and green.** `gates.sh` passes with both
   gopher judges, the droplet judge, and `FAT=32 probe/run.sh gopher`.
   - GO: `GATES: PASS`.
2. **prod runs the same angry-gopher commit as metal will.** Deploy it to
   prod first, as usual (angry-gopher's `deploy/README.md`). The two hosts
   are then compared page by page, so they must be the same program.
   - GO: `https://lynrummy.com/version` names that commit.
3. **The rehearsal, on FAT32**, on a fresh copy of prod's data (MIGRATION.md
   "Rehearsed", repeated with `--fat 32`). The box runs `compare_hosts.py`
   with `--writes` between metal under QEMU and Linux on the same copy.
   - GO: `0 different`. Write down how long each step took; the day's
     freeze is their sum.
4. **The restart stays off** (RESTART.md) unless the box has measured on a
   real droplet that a guest's reset restarts it. A failure while serving
   then halts the machine, and the first-day watch catches it.
   - GO: the boot image is built without `-Drestart=true` (the default),
     or the measurement is written up.
5. **A new, empty DigitalOcean volume** for prod's data: FAT32, N GiB
   (16 is room for every user's 1 GiB cap many times over), in nyc2, made
   in the DigitalOcean console. It is not the test site's volume, and it is
   not attached to anything yet.
   - GO: it is listed, unattached, at N GiB.
6. **The way back is tried once**, on the rehearsal's volume:
   `droplet/extract_volume.py VOLUME.img OUT/` gives back a tree that
   `compare_volume.py` finds identical.
   - GO: `compare_volume.py finds the tree and the volume the same`.

## The day

The site is down from step 1 to step 12. In the FAT16 rehearsal, steps 2
to 6 took under five minutes; the recovery-console write (step 8) and the
rebuild (step 9) are most of the rest. **Plan on an hour**, and say so on
the site's chat beforehand.

### 1. Freeze prod

On `<prod>`:

    sudo systemctl stop gopher-server

Stopped, not read-only: a page view writes too (a topic page records it as
your last topic, a puzzle page makes a session). The watchdog only reports,
so nothing restarts it, and it will show `server FAIL` until step 12.

- GO: `curl -s -o /dev/null -w '%{http_code}\n' https://lynrummy.com/version`
  prints `502`.

### 2. Copy the data

On `<box>`:

    rsync -a <prod>:AngryGopher/prod/data <prod>:AngryGopher/prod/auth copy/

- GO: rsync exits 0, and `find copy -type f | wc -l` is the same number as
  on `<prod>`.

Then **close the window for unsigned cookies** (QUEUE.md item 51: "until
the cutover or 30 days, whichever is first"). angry-gopher re-signs an
unsigned `gopher_uid` once while `data/players/unsigned-window` holds a
time still to come; this makes that time now, in the copy metal will
serve, and leaves prod's own data alone:

    date +%s > copy/data/players/unsigned-window

- GO: `cat copy/data/players/unsigned-window` is a number no later than
  `date +%s`. A player or guest who has not visited since the signed
  cookie was deployed now gets the name page, as DESIGN-signed-uid.md
  says; their data stays on the volume.

### 3. Check it

    droplet/check_volume_tree.py copy --fat 32 --gib N

- GO: exit 0, nothing found.
- NO-GO: anything listed. Restart prod (`sudo systemctl start
  gopher-server`) and decide about it another day. Nothing is lost.

### 4. Build the volume

    droplet/build_volume.py copy prod-volume.img --fat 32 --gib N

It builds without root, then judges what it built with `compare_volume.py`,
`tools/fat16_read.py` and `fsck.fat`, and prints the FAT serial.

- GO: exit 0. **Write the serial down**, for example `1A2B-3C4D`.

### 5. Compare once more, by hand

    droplet/compare_volume.py copy prod-volume.img

- GO: `the volume holds the copy exactly`.

### 6. Let metal read it, on the box first

Boot gopher on `prod-volume.img` on the droplet-shaped QEMU (the droplet
judge's machine). On `<box>`, serve the same copy with Linux on loopback
only:

    GOPHER_BIND=127.0.0.1 GOPHER_PORT=9101 GOPHER_CONFIG=copy.conf zig-server

Then compare the two:

    droplet/compare_hosts.py copy http://127.0.0.1:9101 http://<the QEMU guest>

- GO: `N pages, N identical, 0 different`.

### 7. Build the boot image

Put the serial from step 4 in `droplet/volume-serial`, and prod's private
address (where its Caddy reaches `<metal>` from) in `droplet/trusted-proxy`.
Without the second, every request through Caddy counts as one address, and
the game store's bound of 5 new players an hour (QUEUE.md item 52) is the
whole site's. Then:

    droplet/chat.py boot.img
    gzip -k boot.img

Serve `boot.img.gz` and `prod-volume.img.gz` (`gzip -k prod-volume.img`)
where `<metal>`'s recovery console can fetch them.

- GO: both files are there, `boot.img`'s `gopher-metal.conf` names the
  serial from step 4, and chat.py's last line says which address's
  X-Forwarded-For it believes, not "believing no X-Forwarded-For".

### 8. Write the volume, from the recovery console

In the DigitalOcean console:
- attach the new volume to the gopher-metal droplet, and **detach the test
  site's volume**;
- boot the droplet into the recovery console.

Then type:

    lsblk

Find the disk that is **N GiB** with nothing on it. That is `/dev/sdX`. It
is not the boot disk, which is smaller.

    curl -s http://<box>/prod-volume.img.gz | gunzip | dd of=/dev/sdX bs=4M conv=fsync status=progress
    blkid /dev/sdX1

- GO: `blkid` shows `TYPE="vfat"` and the serial from step 4 as `UUID`.
- NO-GO: any other serial, or an error from dd. Write it again; nothing
  else has changed.

### 9. Rebuild the droplet from the new image

Import `boot.img.gz` as a custom image, and rebuild the gopher-metal
droplet from it (README, "A deploy", steps 2-3). The volume stays attached
and is not touched.

- GO: the droplet's console shows the boot.

### 10. Watch the boot

On the droplet's console, the lines that matter:

    the volume: FAT32 at LBA 2048, ...
    its serial: 1A2B-3C4D
    disk check, the boot disk: ... 0 leaked, 0 problems
    disk check, the volume: ... 0 leaked, 0 problems
    chat's data: the volume
    listening on port 80

- GO: every one of those lines, with FAT32 and the serial from step 4.
- NO-GO: a problem in the disk check, another serial, or `stopped`.
  Prod's data is untouched: the way back is step 1 of it.

### 11. Compare with prod's own Linux, before anyone sees it

On `<prod>`, serve the frozen data on loopback only, and compare. Copy
`droplet/compare_hosts.py` there first; it is one file with nothing to
install.

    cd /home/steve/angry-gopher
    GOPHER_BIND=127.0.0.1 GOPHER_PORT=9101 GOPHER_CONFIG=/home/steve/AngryGopher/gopher.conf ./zig-server &
    droplet/compare_hosts.py AngryGopher/prod http://127.0.0.1:9101 http://<metal>
    droplet/compare_hosts.py AngryGopher/prod http://127.0.0.1:9101 http://<metal> --writes

`--writes` posts a message, a picture and a reaction to a new topic in
uid 1's own DM on both hosts (no one else sees it), then compares again.
The walk also moves uid 1's last-topic bookmark on both. Stop the loopback
server afterwards.

- GO: both runs end `0 different`.
- NO-GO: any difference. The labels say where (`dm 3, topic 12, raw`)
  without the data's names. Look at it on both; the way back is step 1.

### 12. Switch Caddy

On `<prod>`, point lynrummy.com at `<metal>`. Make the same change the
test name has (`droplet/metal.lynrummy.com.caddy`), for the main site:

    sudoedit /etc/caddy/Caddyfile        # reverse_proxy <metal>:80
    sudo caddy validate --config /etc/caddy/Caddyfile
    sudo systemctl reload caddy

- GO:
  - `https://lynrummy.com/version` names the same commit as step 2;
  - `/admin/host` says `gopher-metal, with no operating system`;
  - you can log in, post a message, and see it.

**The site is up, on metal.**

## The first day

Look at these every hour or two, then every day for a week:
- **`/admin/host`** (as the admin):
  - uptime keeps growing (a restart or a halt resets it);
  - the volume's free space;
  - the disk-check lines in the log section;
  - requests and connections.
- **The site:** chat, a game, an upload. `droplet/race.py` compares
  response times with what the README measured.
- **A backup:** download `/admin/backup` once, as the admin. It is a tar
  of everything; keep it off the droplet.

Prod's Linux server stays stopped, with its data as it was at step 1. **Do
not start it** while metal serves: two hosts writing two copies of the
same data cannot be merged.

## The way back

**Before step 12:** nothing has changed for anyone. Start prod again:

    sudo systemctl start gopher-server

**After step 12, once people have written on metal:**
1. **Freeze metal.** Point Caddy at a maintenance page, or at nothing, so
   no more writes land.
2. **Take the data off it**, either way:
   - `/admin/backup` as the admin (no console needed). Then `tar xf
     gopher-backup.tar -C back/`; tar keeps the modification times.
   - Or the whole volume: from the recovery console, `dd if=/dev/sdX1`
     to a file, fetched to `<box>`. Then:

         droplet/extract_volume.py volume.img back/

     It writes every name in its stored case, every byte and every time,
     and checks the result against the volume.
3. **Put it on prod.** Move prod's `data/` and `auth/` aside (keep them),
   copy `back/data` and `back/auth` in, then `sudo systemctl start
   gopher-server`.
4. **Compare before switching back:**

       droplet/compare_hosts.py back http://127.0.0.1:9001 http://<metal>

   - GO: `0 different`.
5. **Point Caddy back at prod's own server**, and reload it.

- GO: `/admin/host` says `Linux, zig-server`, and the messages written on
  metal are there.
