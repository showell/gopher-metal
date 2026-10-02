#!/usr/bin/env python3
"""**A NEW VOLUME FOR CHAT'S DATA**, as an image to write onto a DigitalOcean
volume once: a GPT disk whose FAT16 partition (2 GiB) or FAT32 partition
(`--fat 32 --gib N`, N of 3 or more, 32 KiB clusters as FAT32.md says) holds
`data/` and `auth/`.
Prints the FAT serial mkfs gave it, which goes in `droplet/volume-serial` once
the image is written and attached, so the boot image names it.

The data is the judge's own staged site, as `probe/run.sh gopher` judges it
against Linux: the two test accounts (Steve and apoorva, the judge's test
password) and the session secret. Test data, never prod's.

Writing it replaces everything on the volume. From the droplet's recovery
console, with the volume found by `lsblk` (2G, no partitions):

    curl -s <url of out.img.gz> | gunzip | dd of=/dev/sda bs=4M conv=fsync status=progress

    droplet/new_volume.py <out.img>                      # FAT16, 2 GiB
    droplet/new_volume.py <out.img> --fat 32 --gib 16    # FAT32, 16 GiB

No root: the judge's build_disk, which uses mtools (JUDGE_MOUNT=1: a loop
mount, and `sudo -n`).
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
# The volume to ask DigitalOcean for, and the image written onto it: 2 GiB on
# FAT16, which is as large as it goes. FAT32 takes a size, and 32 KiB clusters
# (64 sectors): its FAT is then 4 bytes for each 32 KiB, 512 KiB a GiB, which
# this machine holds in memory up to its budget (gopher.zig's
# fat_budget_bytes, 32 MiB: 64 GiB at this cluster size). FAT32 needs 65,525
# clusters, so at 32 KiB at least 3 GiB.
VOLUME_BYTES = 2 << 30
FAT32_CLUSTER_SECTORS = 64


def main() -> int:
    args = sys.argv[1:]
    fat, gib = "16", None
    try:
        for flag in ("--fat", "--gib"):
            if flag in args:
                i = args.index(flag)
                value = args[i + 1]
                del args[i:i + 2]
                if flag == "--fat":
                    fat = value
                else:
                    gib = int(value)
    except (IndexError, ValueError):
        args = []
    if len(args) != 1 or fat not in ("16", "32") or (fat == "16" and gib not in (None, 2)) \
            or (fat == "32" and (gib is None or gib < 3)):
        print(__doc__)
        return 2
    out = args[0]
    size = VOLUME_BYTES if fat == "16" else gib << 30
    with tempfile.TemporaryDirectory() as work:
        content = os.path.join(work, "content")
        os.makedirs(content)
        judge.stage(content, GOPHER_ROOT)
        data = os.path.join(work, "data")
        os.makedirs(data)
        for d in judge.DATA_DIRS:
            shutil.move(os.path.join(content, d), os.path.join(data, d))
        judge.build_disk(out, data, os.path.join(work, "mnt"), size=size, fat=fat,
                         cluster_sectors=FAT32_CLUSTER_SECTORS if fat == "32" else None)
    print(f"new_volume.py: {out}, FAT{fat}, {os.path.getsize(out) >> 20} MB, serial {judge.fat_serial(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
