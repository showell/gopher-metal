#!/usr/bin/env python3
"""**CHAT, ON A DISK A DROPLET CAN BOOT.** The real server (gopher.elf) in
partition 1, and in partition 2 a FAT16 volume holding the judge's own staged
site: the same pages, the same two test accounts (Steve and apoorva, the
judge's test password), the same session secret, plus the home page's
pictures (gallery/). Test data, never prod's.

The volume is built by the judge's own functions (stage, build_disk), so it is
the volume `probe/run.sh gopher` already judges against Linux, and its
gopher-metal.conf says nothing about `requests`: the server serves until the
machine is turned off. It says `card = private`: nothing on the internet can
reach it, only machines on the droplet's private network, prod among them.

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


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    if not os.path.isfile(ELF):
        print(f"no {ELF}: ./port.sh && zig build gopher")
        return 1
    with tempfile.TemporaryDirectory() as work:
        content = os.path.join(work, "content")
        os.makedirs(content)
        judge.stage(content, GOPHER_ROOT)
        # The home page's pictures: prod's deploy copies gallery/ beside
        # pages/, and the server reads them from disk. The judge's site leaves
        # them out (it compares answers, not pictures), so they are added here.
        shutil.copytree(os.path.join(GOPHER_ROOT, "gallery"), os.path.join(content, "gallery"))
        # A connection that makes no progress for ten seconds is let go, as in
        # the judge; no `requests` line, so the machine never stops on its own;
        # and only the private card, where prod's Caddy reaches it.
        with open(os.path.join(content, "gopher-metal.conf"), "w") as f:
            f.write("idle_timeout_ms = 10000\ncard = private\n")
        disk = os.path.join(work, "judge.img")
        judge.build_disk(disk, content, os.path.join(work, "mnt"))
        last = judge.partition_last(disk)
        volume = os.path.join(work, "volume.fat")
        with open(disk, "rb") as f, open(volume, "wb") as v:
            f.seek(judge.PART_FIRST * judge.SECTOR)
            v.write(f.read((last - judge.PART_FIRST + 1) * judge.SECTOR))
        subprocess.run([os.path.join(HERE, "image.sh"), ELF, out, volume], check=True)
    print(f"chat.py: {out}, {os.path.getsize(out) >> 20} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
