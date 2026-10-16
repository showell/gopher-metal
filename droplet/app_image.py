#!/usr/bin/env python3
"""**ANY APPLICATION'S BOOT DISK, FOR A DROPLET** (metal-vmm QUEUE 219). One
kernel, one site folder and one conf in; one disk out, laid out by
droplet/image.sh: the boot loader, the kernel in partition 1, and in
partition 2 a FAT filesystem holding the site folder's entries and the conf
as `zig-metal-unikernel.conf`.

    droplet/app_image.py <kernel.elf> <site-dir> <conf> <out.img>
                         [--disk-mib N] [--fat 16|32] [--label NAME]

- `site-dir`: every entry in it goes into the site filesystem's root, with
  its modification times. It is copied, never changed.
- `--disk-mib`: the disk the site filesystem is made on before it is cut out
  as the image's partition 2. That partition is about 1 MiB smaller than
  the disk: the GPT's own sectors at both ends. 64 by default, as chat's.
- `--fat`: 16 or 32. By default the judge's (FAT=32 in the environment
  unless set), as chat's.
- `--label`: the filesystem's volume label, GOPHER by default.

**ONLY THE LAYOUT IS HERE.** What goes in the conf, which kernel is built
and whether its trees were judged are the application's own build's
(droplet/chat.py for angry-gopher's chat). Builds with mtools, as the judge
does; JUDGE_MOUNT=1 builds through a loop mount instead (sudo -n).
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
import judge_gopher as judge  # noqa: E402

CONF_NAME = "zig-metal-unikernel.conf"


def build(elf: str, site_dir: str, conf: str, out: str, disk_mib: int = 64, fat: str = None, label: str = "GOPHER") -> None:
    """The disk `out`: `elf` in partition 1, and in partition 2 a FAT
    filesystem of `site_dir`'s entries and `conf` (a file) as
    zig-metal-unikernel.conf."""
    if not os.path.isfile(elf):
        raise SystemExit(f"app_image: no kernel {elf}")
    if not os.path.isdir(site_dir):
        raise SystemExit(f"app_image: no site folder {site_dir}")
    if os.path.exists(os.path.join(site_dir, CONF_NAME)):
        raise SystemExit(f"app_image: {site_dir} holds a {CONF_NAME} of its own; the conf is given apart")
    with tempfile.TemporaryDirectory() as work:
        content = os.path.join(work, "content")
        shutil.copytree(site_dir, content)
        shutil.copy2(conf, os.path.join(content, CONF_NAME))
        disk = os.path.join(work, "site.img")
        judge.build_disk(disk, content, os.path.join(work, "mnt"), size=disk_mib << 20, fat=fat, label=label)
        last = judge.partition_last(disk)
        site = os.path.join(work, "site.fat")
        with open(disk, "rb") as f, open(site, "wb") as v:
            f.seek(judge.PART_FIRST * judge.SECTOR)
            v.write(f.read((last - judge.PART_FIRST + 1) * judge.SECTOR))
        subprocess.run([os.path.join(HERE, "image.sh"), elf, out, site], check=True)


def main() -> int:
    p = argparse.ArgumentParser(description="any application's boot disk, for a droplet")
    p.add_argument("elf")
    p.add_argument("site_dir")
    p.add_argument("conf")
    p.add_argument("out")
    p.add_argument("--disk-mib", type=int, default=64)
    p.add_argument("--fat", choices=["16", "32"])
    p.add_argument("--label", default="GOPHER")
    a = p.parse_args()
    build(a.elf, a.site_dir, a.conf, a.out, disk_mib=a.disk_mib, fat=a.fat, label=a.label)
    print(f"app_image: {a.out}, {os.path.getsize(a.out) >> 20} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
