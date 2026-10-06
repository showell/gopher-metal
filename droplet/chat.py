#!/usr/bin/env python3
"""**CHAT'S BOOT DISK, FOR A DROPLET.** The real server (gopher.elf) in
partition 1, and in partition 2 the site's own files, which come with every
image: the judge's pages, the home page's pictures (gallery/) and
gopher-metal.conf. Chat's data is not here: it is on a DigitalOcean volume,
built once by `droplet/new_volume.py` and never touched by a new boot image.

gopher-metal.conf says nothing about `requests`, so the server serves until
the machine is turned off. It says `card = private`: nothing on the internet
can reach it, only machines on the droplet's private network, prod among them.
And it says `volume = <serial>`, from `droplet/volume-serial`: the volume the
data is on, which must be attached or the machine stops rather than serving an
empty site. And `trusted_proxy = <address>`, from `droplet/trusted-proxy` when
that file is there: prod's private address, whose X-Forwarded-For names the
client. Without it, every request through Caddy counts as Caddy's address, and
the game store's per-address bounds (QUEUE.md item 52: 5 new players and 20 MB
of game writes an hour) apply to the whole site at once; this says so.

    droplet/chat.py <out.img>
    droplet/chat.py <out.img> --reset-admin-password NAME

**THE ADMIN'S LOST PASSWORD** (QUEUE.md item 89, ADMIN-PASSWORD-LOST.md):
with `--reset-admin-password NAME` this asks for a new password twice,
hashes it here with angry-gopher's `hash-password` (the server's own bcrypt),
and puts `admin_password_reset = NAME <hash>` in this image's
gopher-metal.conf. The machine applies it at its next boot, once, and only if
uid 1 on the volume is NAME. Only the hash is in the image, and nothing goes
in the repository; the next deploy without the flag leaves the line out.
Off a terminal, the password is the first line of stdin.

Builds its disks with mtools, as the judge does (no root); JUDGE_MOUNT=1 in the
environment builds them through a loop mount instead, which needs `sudo -n`.
"""
import getpass
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
import judge_gopher as judge  # noqa: E402
sys.path.insert(0, os.path.join(ROOT, "tools"))
import verdicts  # noqa: E402

GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
ELF = os.path.join(ROOT, "probe", "gopher.elf")
# **THE VOLUME THE DEPLOYED MACHINE SERVES**, by its FAT serial (as `blkid`
# shows it). new_volume.py prints a new volume's serial; it goes here once
# that volume is written and attached.
SERIAL_FILE = os.path.join(HERE, "volume-serial")
# **WHOSE X-Forwarded-For IS BELIEVED**: prod's private address, where its
# Caddy reaches this machine from. Optional, and loudly missing.
PROXY_FILE = os.path.join(HERE, "trusted-proxy")


def admin_reset_line(name: str) -> str:
    """`admin_password_reset = NAME <hash>`, the password asked for here and
    hashed by angry-gopher's hash-password; only the hash leaves this
    function."""
    zig_server = os.path.join(GOPHER_ROOT, "zig-server")
    subprocess.run(["zig", "build", "hash-password"], cwd=zig_server, check=True)
    if sys.stdin.isatty():
        password = getpass.getpass(f"New password for {name}: ")
        if password != getpass.getpass("Again: "):
            raise SystemExit("chat.py: the two passwords differ; no image made")
    else:
        password = sys.stdin.readline().rstrip("\r\n")
    made = subprocess.run([os.path.join(zig_server, "zig-out", "bin", "hash-password")],
                          input=password, capture_output=True, text=True)
    if made.returncode != 0:
        raise SystemExit("chat.py: " + made.stderr.strip())
    return f"admin_password_reset = {name} {made.stdout.strip()}\n"


def main() -> int:
    args = sys.argv[1:]
    reset = None
    if len(args) == 3 and args[1] == "--reset-admin-password" and args[2].strip():
        reset = args[2].strip()
        args = args[:1]
    if len(args) != 1:
        print(__doc__)
        return 2
    out = args[0]
    # **ONLY JUDGED CODE BECOMES AN IMAGE** (tools/verdicts.py): both trees
    # clean, and gates.sh and long.sh both PASS for exactly this pair.
    refused = verdicts.require()
    if refused and os.environ.get("RELEASE_UNGATED") == "1":
        print("chat.py: RELEASE_UNGATED=1: building an image the gates have not passed, because:", file=sys.stderr)
        for why in refused:
            print(f"  - {why}", file=sys.stderr)
    elif refused:
        print("chat.py: REFUSING to build an image:")
        for why in refused:
            print(f"  - {why}")
        print("(RELEASE_UNGATED=1 builds it anyway, for an emergency fix, and says so.)")
        return 1
    # **THE KERNEL IS BUILT HERE, FROM THIS TREE**, never taken from disk: a
    # gopher.elf left by another build (long.sh's -Dcoverage one, say) is not
    # what the verdicts judged.
    built = subprocess.run(["zig", "build", "gopher"], cwd=ROOT)
    if built.returncode != 0:
        print("chat.py: gopher.elf does not build")
        return 1
    serial = open(SERIAL_FILE).read().strip()
    proxy = open(PROXY_FILE).read().strip() if os.path.isfile(PROXY_FILE) else None
    if proxy is None:
        print(f"chat.py: WARNING: no {PROXY_FILE}, so no trusted_proxy: every request through Caddy "
              "will count as one address, and 5 new players an hour is then the whole site's", file=sys.stderr)
    with tempfile.TemporaryDirectory() as work:
        content = os.path.join(work, "content")
        os.makedirs(content)
        judge.stage(content, GOPHER_ROOT)
        for d in judge.DATA_DIRS:
            shutil.rmtree(os.path.join(content, d))
        # The home page's pictures: prod's deploy copies gallery/ beside
        # pages/, and the server reads them from disk. The judge's site leaves
        # them out (it compares answers, not pictures), so they are added here.
        shutil.copytree(os.path.join(GOPHER_ROOT, "gallery"), os.path.join(content, "gallery"))
        # A connection that makes no progress for ten seconds is let go, as in
        # the judge; no `requests` line, so the machine never stops on its own;
        # only the private card, where prod's Caddy reaches it; and the volume.
        with open(os.path.join(content, "gopher-metal.conf"), "w") as f:
            f.write(f"idle_timeout_ms = 10000\ncard = private\nvolume = {serial}\n"
                    + (f"trusted_proxy = {proxy}\n" if proxy else "")
                    + (admin_reset_line(reset) if reset else ""))
        disk = os.path.join(work, "site.img")
        judge.build_disk(disk, content, os.path.join(work, "mnt"))
        last = judge.partition_last(disk)
        site = os.path.join(work, "site.fat")
        with open(disk, "rb") as f, open(site, "wb") as v:
            f.seek(judge.PART_FIRST * judge.SECTOR)
            v.write(f.read((last - judge.PART_FIRST + 1) * judge.SECTOR))
        subprocess.run([os.path.join(HERE, "image.sh"), ELF, out, site], check=True)
    print(f"chat.py: {out}, {os.path.getsize(out) >> 20} MB, serving volume {serial}"
          + (f", believing X-Forwarded-For from {proxy}" if proxy else ", believing no X-Forwarded-For")
          + (f"; it resets the password of uid 1 if uid 1 is {reset!r}, at its first boot: "
             "deploy it, log in, then deploy without the flag" if reset else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
