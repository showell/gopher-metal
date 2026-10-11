#!/usr/bin/env python3
"""The judge's site volume, built from an angry-gopher checkout, with no boot.

    tools/site_volume.py OUT.img [GOPHER_ROOT]

Exactly what probe/judge_gopher.py's main builds before its first boot
(stage, build_disk on FAT32 or $FAT, one request a boot), by the judge's own
functions, so the two cannot differ. gates.sh builds it first, so every check
that needs a site volume (metal-vmm's timeouts.sh, long.sh's sweeps) judges
this checkout's site, where they read whatever volume a chat judge had last
left at a default path, which nothing kept fresh.
"""
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "probe"))
import judge_gopher as judge  # noqa: E402


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(__doc__.strip())
        return 2
    out = os.path.abspath(sys.argv[1])
    root = sys.argv[2] if len(sys.argv) == 3 else os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
    work = tempfile.mkdtemp(prefix="site-volume-")
    try:
        content = os.path.join(work, "content")
        mnt = os.path.join(work, "mnt")
        judge.stage(content, root)
        image = os.path.join(work, "pristine.img")
        judge.build_disk(image, content, mnt)
        judge.set_request_limit(image, 1, mnt)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.move(image, out)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"site volume: {out} (FAT{judge.FAT_KIND}, from {root})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
