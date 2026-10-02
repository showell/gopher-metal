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

Needs `sudo -n` for the loop mount, as the judge does.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
import judge_gopher as judge  # noqa: E402

GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
ELF = os.path.join(ROOT, "probe", "gopher.elf")
# **THE VOLUME THE DEPLOYED MACHINE SERVES**, by its FAT serial (as `blkid`
# shows it). new_volume.py prints a new volume's serial; it goes here once
# that volume is written and attached.
SERIAL_FILE = os.path.join(HERE, "volume-serial")
# **WHOSE X-Forwarded-For IS BELIEVED**: prod's private address, where its
# Caddy reaches this machine from. Optional, and loudly missing.
PROXY_FILE = os.path.join(HERE, "trusted-proxy")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    if not os.path.isfile(ELF):
        print(f"no {ELF}: ./port.sh && zig build gopher")
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
                    + (f"trusted_proxy = {proxy}\n" if proxy else ""))
        disk = os.path.join(work, "site.img")
        judge.build_disk(disk, content, os.path.join(work, "mnt"))
        last = judge.partition_last(disk)
        site = os.path.join(work, "site.fat")
        with open(disk, "rb") as f, open(site, "wb") as v:
            f.seek(judge.PART_FIRST * judge.SECTOR)
            v.write(f.read((last - judge.PART_FIRST + 1) * judge.SECTOR))
        subprocess.run([os.path.join(HERE, "image.sh"), ELF, out, site], check=True)
    print(f"chat.py: {out}, {os.path.getsize(out) >> 20} MB, serving volume {serial}"
          + (f", believing X-Forwarded-For from {proxy}" if proxy else ", believing no X-Forwarded-For"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
