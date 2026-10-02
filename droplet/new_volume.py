#!/usr/bin/env python3
"""**A NEW VOLUME FOR CHAT'S DATA**, as an image to write onto a DigitalOcean
volume once: a 2 GiB GPT disk whose FAT16 partition holds `data/` and `auth/`.
Prints the FAT serial mkfs gave it, which goes in `droplet/volume-serial` once
the image is written and attached, so the boot image names it.

The data is the judge's own staged site, as `probe/run.sh gopher` judges it
against Linux: the two test accounts (Steve and apoorva, the judge's test
password) and the session secret. Test data, never prod's.

Writing it replaces everything on the volume. From the droplet's recovery
console, with the volume found by `lsblk` (2G, no partitions):

    curl -s <url of out.img.gz> | gunzip | dd of=/dev/sda bs=4M conv=fsync status=progress

    droplet/new_volume.py <out.img>

Needs `sudo -n` for the loop mount, as the judge does.
"""
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
import judge_gopher as judge  # noqa: E402

GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
# The volume to ask DigitalOcean for, and the image written onto it: 2 GiB,
# which is as large as FAT16 goes.
VOLUME_BYTES = 2 << 30


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    with tempfile.TemporaryDirectory() as work:
        content = os.path.join(work, "content")
        os.makedirs(content)
        judge.stage(content, GOPHER_ROOT)
        data = os.path.join(work, "data")
        os.makedirs(data)
        for d in judge.DATA_DIRS:
            shutil.move(os.path.join(content, d), os.path.join(data, d))
        judge.build_disk(out, data, os.path.join(work, "mnt"), size=VOLUME_BYTES)
    print(f"new_volume.py: {out}, {os.path.getsize(out) >> 20} MB, serial {judge.fat_serial(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
