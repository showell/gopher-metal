#!/usr/bin/env python3
"""MIGRATION.md step 3, without root: a volume image holding a copy of
prod's data, built with mtools rather than a loop mount (QUEUE.md item 19).

    droplet/build_volume.py <copy> <out.img>                      # FAT16, 2 GiB
    droplet/build_volume.py <copy> <out.img> --fat 32 --gib 16    # FAT32, 16 GiB
    droplet/build_volume.py --self-test

`<copy>` holds `data/` and `auth/`. The image is laid out as new_volume.py
lays one out: a GPT disk with one partition, formatted by mkfs.vfat. FAT16
lets mkfs.vfat choose its clusters; FAT32 uses 32 KiB clusters (FAT32.md).
Then mtools copies the tree in, keeping each file's modification time
(`mcopy -m`), in UTC (`TZ=UTC`), which is how this machine reads FAT times.
It prints the FAT serial, which goes in `droplet/volume-serial`.

**A TREE check_volume_tree.py FINDS ANYTHING IN IS REFUSED**: fix or decide
on those first (MIGRATION.md step 1). Afterwards the image is judged by
three readers that are not mtools: `compare_volume.py` against the copy,
`tools/fat16_read.py check`, and `fsck.fat -n` on the partition.

Needs sgdisk, mkfs.vfat and mtools; no root.
"""
import errno
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import check_volume_tree  # noqa: E402
import compare_volume  # noqa: E402
import fat16_read  # noqa: E402
import judge_gopher  # noqa: E402

PART_FIRST = judge_gopher.PART_FIRST
SECTOR = 512
FAT32_CLUSTER_SECTORS = 64


class Refused(Exception):
    pass


def build(copy: str, out: str, fat: int = 16, size: int = 2 << 30, cluster_sectors: int = None,
          check: bool = True) -> str:
    """Builds `out` from `copy`; answers the serial. Raises Refused for a tree
    the checker finds anything in, or a size the kind cannot have."""
    if check:
        findings, _ = check_volume_tree.check(copy, volume=size, fat=fat)
        if findings:
            raise Refused(f"check_volume_tree.py finds {len(findings)} thing(s) in {copy}, the first "
                          f"{findings[0].rule} at {findings[0].path}: fix or decide on them first")
    if fat == 16 and size > 2 << 30:
        raise Refused("FAT16 goes to 2 GiB")
    with open(out, "wb") as f:
        f.truncate(size)
    subprocess.run(["sgdisk", "-o", "-n", f"1:{PART_FIRST}:0", "-t", "1:0700", "-c", "1:gopher", out],
                   check=True, capture_output=True)
    blocks = (judge_gopher.partition_last(out) - PART_FIRST + 1) // 2
    spc = cluster_sectors or (FAT32_CLUSTER_SECTORS if fat == 32 else None)
    made = subprocess.run(["mkfs.vfat", "-F", str(fat), "-S", str(SECTOR), *(["-s", str(spc)] if spc else []),
                           "-n", "GOPHER", "--offset", str(PART_FIRST), out, str(blocks)],
                          capture_output=True, text=True)
    if made.returncode != 0:
        raise Refused(f"mkfs.vfat would not make FAT{fat} of {size >> 20} MiB: {made.stderr.strip()}")
    # **WHAT mkfs.vfat CALLS FAT32 MAY NOT BE.** It makes a FAT32 layout with
    # too few clusters without complaint (1 GiB at 32 KiB clusters: 32,768).
    # Linux calls that FAT32; the spec, and this machine, count clusters and
    # call it FAT16, and the mount refuses it (REVIEW-restart-fat32.md F2).
    kind = fat16_read.load(out).kind
    if kind != f"FAT{fat}":
        raise Refused(f"mkfs.vfat made a FAT{fat} layout of {size >> 20} MiB that the spec's cluster count calls "
                      f"{kind}, which this machine refuses; FAT32 needs 65,525 clusters (--gib 3 or more at "
                      f"32 KiB clusters)")
    at = f"{out}@@{PART_FIRST * SECTOR}"
    env = dict(os.environ, TZ="UTC", MTOOLS_SKIP_CHECK="1")
    for top in sorted(os.listdir(copy)):
        subprocess.run(["mcopy", "-s", "-m", "-i", at, os.path.join(copy, top), "::/"],
                       check=True, capture_output=True, env=env)
    return judge_gopher.fat_serial(out)


def copy_sparse(image: str, start: int, out: str) -> None:
    """`image` from byte `start` to its end, into `out`, leaving holes where
    it has them or is zero (QUEUE.md item 75). fsck.fat takes no offset, so it
    is handed the partition as a file of its own; written whole, a 16 GiB
    volume would be 16 GiB more in the scratch folder, which may be memory
    (tmpfs). The image's own holes are skipped without reading them
    (SEEK_DATA), and a block of zeros in what is read is left a hole too."""
    chunk = 1 << 20
    with open(image, "rb") as src, open(out, "wb") as dst:
        end = os.fstat(src.fileno()).st_size
        pos = start
        while pos < end:
            try:
                data = os.lseek(src.fileno(), pos, os.SEEK_DATA)
                hole = os.lseek(src.fileno(), data, os.SEEK_HOLE)
            except OSError as e:
                if e.errno == errno.ENXIO:  # nothing but a hole from here to the end
                    break
                data, hole = pos, end  # a filesystem without SEEK_DATA: read it all
            src.seek(data)
            dst.seek(data - start)
            at = data
            while at < hole:
                block = src.read(min(chunk, hole - at))
                if not block:
                    break
                if block.count(0) == len(block):
                    dst.seek(len(block), os.SEEK_CUR)
                else:
                    dst.write(block)
                at += len(block)
            pos = hole
        dst.truncate(end - start)


def judge(copy: str, image: str) -> list:
    """What the three readers that are not mtools say: nothing, for a good
    volume."""
    problems = [f"compare_volume: {k} {p}: {w}" for k, p, w in compare_volume.compare(copy, image)]
    problems += [f"fat16_read: {p}" for p in fat16_read.load(image).check()]
    with tempfile.TemporaryDirectory() as d:
        part = os.path.join(d, "part.img")
        copy_sparse(image, PART_FIRST * SECTOR, part)
        fsck = subprocess.run(["fsck.fat", "-n", part], capture_output=True, text=True)
        if fsck.returncode != 0:
            problems.append("fsck.fat: " + " | ".join(fsck.stdout.splitlines()[1:4]))
    return problems


def main(argv) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    args = argv[1:]
    fat, gib = 16, None
    try:
        for flag in ("--fat", "--gib"):
            if flag in args:
                i = args.index(flag)
                value = int(args[i + 1])
                del args[i:i + 2]
                if flag == "--fat":
                    fat = value
                else:
                    gib = value
    except (IndexError, ValueError):
        args = []
    if len(args) != 2 or not os.path.isdir(args[0]) or fat not in (16, 32) or (fat == 32 and gib is None):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    copy, out = args
    size = (gib << 30) if gib else 2 << 30
    try:
        serial = build(copy, out, fat, size)
    except Refused as e:
        print(f"refused: {e}", file=sys.stderr)
        return 1
    problems = judge(copy, out)
    for p in problems:
        print(p)
    print(f"build_volume.py: {out}, FAT{fat}, {size >> 20} MiB, serial {serial}"
          + ("" if not problems else f"; {len(problems)} problem(s), above"))
    return 1 if problems else 0


# ── the self-test ───────────────────────────────────────────────────────────

# Every name shape the application makes (MIGRATION.md's table), at its
# longest where that matters, and dates near both ends of FAT's range.
SID80 = "A" + "b" * 78 + "9"  # 80 characters, mixed case
SLUG80 = "s" + "-x" * 39 + "z"  # 80 characters, lower case
HEX = "0123456789abcdef" * 2
NOW = 1_790_000_000
SHAPES = {
    f"data/chat/1_2/sessions/{SID80}.md": b"# a topic\n",
    f"data/chat/1_2/sessions/{SID80}.count": b"3\n",
    f"data/chat/1_2/sessions/{SID80}.lastauthor": b"1",
    f"data/chat/1_2/sessions/{SID80}.reactions.jsonl": b"{}\n",  # 96 characters: the longest
    f"data/chat/1_2/sessions/{SID80}.uploads/{HEX}.png": bytes(range(256)) * 300,
    "data/chat/1_2/sessions/Plan-B.md": b"mixed case\n",
    "data/chat/channels/Dev-Talk.channel": b"1\n7\n",
    "data/chat/channels/Dev-Talk/sessions/general.md": b"hi\n",
    f"data/chat/users/7/docs/{SLUG80}.md": b"# a doc\n",
    "data/chat/users/7/code.md": b"",
    "data/chat/users/7/images.md": b"",
    "data/chat/users/7/last-conv": b"1_2",
    "data/chat/users/7/last-sessions/1_2": b"general",
    "data/chat/users/7/pinned-sessions/Dev-Talk": b"general",
    "data/users/7/last-seen": b"1790000000",
    "data/users/7/upload-bytes": b"76800",
    "data/users/1/admin": b"",
    "data/players/p3/name": b"Ada",
    "data/players/p3/last-seen": b"1790000000",
    "data/players/next-id.txt": b"4\n",
    "data/lynrummy/1/puzzle/sessions/1/meta": b"{}",
    "auth/7/password": b"$2a$10$" + b"x" * 53,
    "auth/7/api-key": b"0123456789abcdef",
    "auth/next-id.txt": b"8\n",
    "auth/_session_secret": b"x" * 42,
    "auth/_session_secret.previous": b"y" * 42,
    "auth/_session_secret.previous-until": b"1790086400\n",
}
# FAT keeps 1980-01-01 to 2107-12-31, in even seconds.
OLDEST = 315_532_800 + 2       # 1980-01-01T00:00:02Z
NEWEST = 4_354_819_199 - 1     # 2107-12-31T23:59:58Z


def make_tree(root: str) -> None:
    for k, (rel, data) in enumerate(sorted(SHAPES.items())):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        t = OLDEST if k == 0 else NEWEST if k == 1 else NOW + 2 * k
        os.utime(path, (t, t))


# **A LARGE VOLUME, IN LITTLE MEMORY** (QUEUE.md item 75): the FAT32 rehearsal
# on a 3 GiB volume grew to 7.4 GB and was killed, because the readers held
# the image whole, two at a time. Now they map it (fat16_read.open_image), and
# fsck's copy of the partition is sparse. Measured in a process of its own, so
# its peak is its own: getrusage's RUSAGE_CHILDREN is the largest of the
# children waited for, and their own children (mkfs.vfat, mcopy, fsck.fat).
LARGE_GIB = 16
LARGE_PEAK_MB = 256


def large_volume_memory() -> list:
    import resource
    with tempfile.TemporaryDirectory() as d:
        copy = os.path.join(d, "copy")
        make_tree(copy)
        out = os.path.join(d, "large.img")
        code = (f"import sys; sys.path.insert(0, {HERE!r}); import build_volume as b\n"
                f"b.build({copy!r}, {out!r}, 32, {LARGE_GIB} << 30)\n"
                f"p = b.judge({copy!r}, {out!r})\n"
                f"print(len(p)); sys.exit(1 if p else 0)\n")
        before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
        peak_mb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss >> 10  # KiB, on Linux
        on_disk_mb = (os.stat(out).st_blocks * 512) >> 20 if os.path.exists(out) else 0
    failures = []
    if r.returncode != 0:
        failures.append(f"a {LARGE_GIB} GiB FAT32 volume did not build and judge clean: "
                        f"{(r.stdout + r.stderr).strip()[-300:]}")
    if peak_mb > LARGE_PEAK_MB and peak_mb > before >> 10:
        failures.append(f"building and judging a {LARGE_GIB} GiB volume peaked at {peak_mb} MB, "
                        f"over {LARGE_PEAK_MB} MB")
    if on_disk_mb > 256:
        failures.append(f"the {LARGE_GIB} GiB volume took {on_disk_mb} MB on disk; it should be sparse")
    print(f"  a {LARGE_GIB} GiB FAT32 volume: built and judged, peak {peak_mb} MB, {on_disk_mb} MB on disk")
    return failures


def self_test() -> int:
    missing = [t for t in ("sgdisk", "mkfs.vfat", "mcopy", "fsck.fat") if shutil.which(t) is None]
    if missing:
        print(f"self-test cannot run: {', '.join(missing)} not installed")
        return 2
    failures = []
    with tempfile.TemporaryDirectory() as d:
        copy = os.path.join(d, "copy")
        make_tree(copy)
        found, _ = check_volume_tree.check(copy)
        if found:
            failures.append(f"the self-test's own tree has findings: {[(f.rule, f.path) for f in found]}")
        # The smallest of each kind mkfs.vfat makes here, so the test is quick;
        # a real one is 2 GiB (FAT16) or --gib N with 32 KiB clusters (FAT32).
        for fat, size, spc in ((16, 64 << 20, None), (32, 64 << 20, 1)):
            out = os.path.join(d, f"v{fat}.img")
            try:
                serial = build(copy, out, fat, size, spc)
            except Refused as e:
                failures.append(f"FAT{fat}: refused a good tree: {e}")
                continue
            kind = fat16_read.load(out).kind
            if kind != f"FAT{fat}":
                failures.append(f"FAT{fat}: made {kind}")
            problems = judge(copy, out)
            if problems:
                failures.append(f"FAT{fat}: {problems}")
            if len(serial) != 9 or serial[4] != "-":
                failures.append(f"FAT{fat}: a serial of {serial!r}")
        # A FAT32 layout too small to be FAT32 by its cluster count is refused.
        try:
            build(copy, os.path.join(d, "small32.img"), 32, 1 << 30)
            failures.append("a 1 GiB FAT32 at 32 KiB clusters was built, not refused")
        except Refused as e:
            if "cluster count" not in str(e):
                failures.append(f"a 1 GiB FAT32 was refused for another reason: {e}")
        # A tree the checker finds something in is refused.
        bad = os.path.join(d, "bad")
        make_tree(bad)
        os.makedirs(os.path.join(bad, "data/notes"))
        with open(os.path.join(bad, "data/notes/what?.txt"), "w") as f:
            f.write("x")
        try:
            build(bad, os.path.join(d, "bad.img"), 16, 64 << 20)
            failures.append("a tree with a forbidden character was built, not refused")
        except Refused:
            pass
        # And the judge finds a volume that differs from its copy.
        with open(os.path.join(copy, "data/players/p3/name"), "wb") as f:
            f.write(b"Bea")
        os.utime(os.path.join(copy, "data/players/p3/name"), (NOW, NOW))
        if not any("content" in p for p in judge(copy, os.path.join(d, "v16.img"))):
            failures.append("the judge did not find a file that changed after the build")
    failures += large_volume_memory()
    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: every name shape the application makes, and dates at both ends of "
          "FAT's range, built on FAT16 and FAT32 without root and read back exactly by "
          "compare_volume.py, fat16_read.py and fsck.fat; a tree with findings refused; a 16 GiB "
          "volume built and judged in little memory and little disk")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
