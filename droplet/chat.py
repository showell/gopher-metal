#!/usr/bin/env python3
"""**CHAT, ON A DROPLET'S TWO DISKS.** Two images:

  - `<out.img>`, the boot disk: the real server (gopher.elf) in partition 1,
    and in partition 2 the site's own files, which come with every image: the
    judge's pages, the home page's pictures (gallery/) and gopher-metal.conf.
  - `<out>-volume.img`, chat's data, for a DigitalOcean volume: a 2 GiB GPT
    disk whose FAT16 partition holds `data/` and `auth/`. It is written onto
    the volume ONCE; a new boot image never touches it.

The data is the judge's own staged site, as `probe/run.sh gopher` judges it
against Linux: the two test accounts (Steve and apoorva, the judge's test
password) and the session secret. Test data, never prod's.

gopher-metal.conf says nothing about `requests`, so the server serves until
the machine is turned off. It says `card = private`: nothing on the internet
can reach it, only machines on the droplet's private network, prod among them.

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
# The volume to ask DigitalOcean for, and the image written onto it: 2 GiB,
# which is as large as FAT16 goes.
VOLUME_BYTES = 2 << 30


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    if not os.path.isfile(ELF):
        print(f"no {ELF}: ./port.sh && zig build gopher")
        return 1
    volume_out = os.path.splitext(out)[0] + "-volume.img"
    with tempfile.TemporaryDirectory() as work:
        content = os.path.join(work, "content")
        os.makedirs(content)
        judge.stage(content, GOPHER_ROOT)
        mnt = os.path.join(work, "mnt")

        # Chat's data, on the volume. As large as FAT16 goes, and as large as
        # the volume DigitalOcean is asked for.
        data = os.path.join(work, "data")
        os.makedirs(data)
        for d in judge.DATA_DIRS:
            shutil.move(os.path.join(content, d), os.path.join(data, d))
        judge.build_disk(volume_out, data, mnt, size=VOLUME_BYTES)

        # The site, on the boot disk. The home page's pictures: prod's deploy
        # copies gallery/ beside pages/, and the server reads them from disk.
        # The judge's site leaves them out (it compares answers, not
        # pictures), so they are added here.
        shutil.copytree(os.path.join(GOPHER_ROOT, "gallery"), os.path.join(content, "gallery"))
        # A connection that makes no progress for ten seconds is let go, as in
        # the judge; no `requests` line, so the machine never stops on its own;
        # and only the private card, where prod's Caddy reaches it.
        with open(os.path.join(content, "gopher-metal.conf"), "w") as f:
            f.write("idle_timeout_ms = 10000\ncard = private\n")
        disk = os.path.join(work, "site.img")
        judge.build_disk(disk, content, mnt)
        last = judge.partition_last(disk)
        site = os.path.join(work, "site.fat")
        with open(disk, "rb") as f, open(site, "wb") as v:
            f.seek(judge.PART_FIRST * judge.SECTOR)
            v.write(f.read((last - judge.PART_FIRST + 1) * judge.SECTOR))
        subprocess.run([os.path.join(HERE, "image.sh"), ELF, out, site], check=True)
    print(f"chat.py: {out}, {os.path.getsize(out) >> 20} MB")
    print(f"chat.py: {volume_out}, {os.path.getsize(volume_out) >> 20} MB, for the volume")
    return 0


if __name__ == "__main__":
    sys.exit(main())
