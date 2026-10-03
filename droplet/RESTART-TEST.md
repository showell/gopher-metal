# Does a reset restart a droplet? A test for Steve, at the console

RESTART.md's open question, and QUEUE.md item 16's condition. gopher-metal
can restart itself after a crash (`-Drestart=true`), but only if resetting
a DigitalOcean droplet's machine starts it again. If a reset **powers the
droplet off** instead, a restart is worse than halting with the log on the
screen. QEMU here cannot answer it: DigitalOcean's own settings decide.
This page is the test. It takes about fifteen minutes, and the test site
is down meanwhile. It is not part of the cutover (CUTOVER.md keeps the
restart off), and is best done on a day when nothing else is changing.

**The box prepares** (Steve need not):

    zig build kernels
    droplet/image.sh probe/restart.elf restart.img
    gzip -k restart.img

It then serves `restart.img.gz` at a short address `<box>` that the droplet
can reach. The commands below are short because the console cannot paste.

## 1. Put the probe on the droplet's disk

In DigitalOcean's control panel, for the gopher-metal droplet:
1. **Recovery**: choose "Boot from Recovery ISO".
2. **Power cycle** (DigitalOcean's panel has no separate power-off for this;
   setting Recovery and restarting is the way in).
3. Open the **Recovery Console**.

Then type:

    lsblk

The boot disk is `vda`. A volume, if one is attached, is `sda`: leave it
alone. Then:

    curl -s <box>/restart.img.gz | gunzip | dd of=/dev/vda bs=4M conv=fsync

- **GO:** `dd` reports records in and out, and no error.

## 2. Boot it, and watch

In the control panel:
1. **Recovery**: choose "Boot from Hard Drive".
2. **Power cycle**.
3. Open the **Recovery Console** again (it shows the droplet's screen).

The probe tries three ways of resetting the machine in turn. A way that
works restarts the droplet, and the next boot says so. It is over in
under a minute.

## 3. What the screen means

**Reset restarts (what we hope).** The last screen reads:

    gopher-metal restart probe: boot 4, kernel ends at 0x..., carry at 0x04000000
      .bss on arrival: zero
      restarted by a triple fault: CMOS kept (stage 3); RAM past the kernel kept
      every method has been tried
    PASS

The boot number is 1 plus the number of ways that restarted it: `boot 4`
means all three did. A way that did not shows a line such as

      the keyboard controller (0xFE to 0x64) did NOT restart this machine

which is fine, as long as one way did. **Write down the boot number and any
"did NOT" lines.**

**Reset powers off (the bad case).** Watch for either sign:
- the console goes dark, and the control panel shows the droplet **Off**;
- after you power it on, the screen says
  `first boot: CMOS stage byte ...`. A powered-off machine forgets its
  CMOS; one that restarted keeps it.

**Write down which happened.**

**Nothing on the screen.** Then the probe did not boot. Repeat step 1: the
`dd` may have gone to the wrong disk, and nothing else has changed.

## 4. Put the site back

Rebuild the droplet from the gopher-metal image it had (README, "A deploy",
steps 2-3), or ask the box for the image again. The volume was not
touched.

## What flipping `-Drestart=true` by default would then take

- **If a reset restarts:**
  1. Steve's note of the boot number goes into RESTART.md, in place of
     "Not measured here".
  2. The box builds with `-Drestart=true`.
  3. `probe/run.sh restart` and `probe/run.sh backoff` pass as they do
     now, and the full judge passes on that build.
  4. The default in `build.zig` flips. Its one line is
     `b.option(bool, "restart", ...) orelse false`.
  5. One deploy is watched for the back-off line,
     `restarted after ... (restart N in a row)`, which only appears after
     a real failure.
- **If a reset powers off:** the default stays off, and a crash halts with
  its log on the screen. A restart could still come from outside: item
  56's watchdog, on prod, could power the droplet on through
  DigitalOcean's API when metal stops answering. That would be a new
  item.
