#!/usr/bin/env python3
"""MIGRATION.md step 5, without a mount: is every file of the copy on the
volume, as it was?

    droplet/compare_volume.py <copy> <volume.img>          # copy holds data/ and auth/
    droplet/compare_volume.py <copy> <volume.img> --json   # the same, one JSON object
    droplet/compare_volume.py --self-test                  # volumes mkfs.vfat and mtools
                                                           # make, each mismatch made on purpose

The volume is read through tools/fat16_read.py, an independent FAT16 reader
written from the spec, not through Linux's vfat driver and not through this
machine's disk_fat.zig. So it needs no root and no loop device. The image may be
a bare volume or a GPT disk whose first partition holds one.

Each finding is one of:

  missing        a file or directory in the copy is not on the volume
  case           it is, but its name differs in case (FAT finds it either
                 way; the application would not, on Linux, after a copy back)
  size           the sizes differ
  content        the sizes match and the SHA-256s do not
  time           the modification times are more than 2 seconds apart (FAT
                 keeps even seconds; times are read as UTC, as gopher-metal
                 reads them, so a volume written without `tz=UTC` shows here)
  extra          something on the volume is not in the copy
  check          the volume itself is inconsistent (fat16_read.py check)

Exit 0 when nothing is found, 1 when something is, 2 on a usage error.
"""
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tools"))
import fat16_read  # noqa: E402

# The resolution FAT keeps a modification time at, and so the most two
# honest times may differ by.
TIME_SLACK = 2


def compare(copy: str, image: str) -> list:
    """Every finding, as (kind, path, why), paths from the copy's root."""
    v = fat16_read.load(image)
    findings = [("check", "", p) for p in v.check()]

    # One walk, and each file read from the chain it found: v.read(path)
    # walks the whole volume again on every call, which on a folder of
    # 65,000 files is 65,000 walks of 65,000 entries.
    on_volume = {}
    for full, is_dir, first, size in v.walk([]):
        on_volume[full] = (is_dir, size, first)
    by_fold = {}
    for full in on_volume:
        by_fold.setdefault(full.casefold(), []).append(full)

    seen = set()
    for dirpath, dirnames, filenames in os.walk(copy):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, copy)
        for name in sorted(dirnames) + sorted(filenames):
            src = os.path.join(dirpath, name)
            rel = "/" + (name if rel_dir == "." else f"{rel_dir}/{name}").replace(os.sep, "/")
            is_dir = os.path.isdir(src)
            if rel not in on_volume:
                near = by_fold.get(rel.casefold(), [])
                if near:
                    findings.append(("case", rel, f"the volume has it as {near[0]}"))
                    seen.update(near)
                else:
                    findings.append(("missing", rel, "not on the volume"))
                continue
            seen.add(rel)
            v_dir, v_size, v_first = on_volume[rel]
            if v_dir != is_dir:
                findings.append(("missing", rel, "a directory on one side and a file on the other"))
                continue
            if is_dir:
                continue
            st = os.stat(src)
            if v_size != st.st_size:
                findings.append(("size", rel, f"{st.st_size} bytes in the copy, {v_size} on the volume"))
                continue
            # Both sides a block at a time: neither file is held whole.
            h = hashlib.sha256()
            with open(src, "rb") as f:
                for block in iter(lambda: f.read(1 << 20), b""):
                    h.update(block)
            want = h.hexdigest()
            h = hashlib.sha256()
            try:
                left = v_size
                for c in (v.chain(v_first) if v_size else ()):
                    if left <= 0:
                        break
                    block = v.cluster(c)[:left]
                    h.update(block)
                    left -= len(block)
            except fat16_read.Problem as p:
                findings.append(("content", rel, f"its chain will not read: {p}"))
                continue
            got = h.hexdigest()
            if want != got:
                findings.append(("content", rel, f"SHA-256 {want[:16]}... in the copy, {got[:16]}... on the volume"))
            vt = v.mtime.get(rel)
            if vt is None:
                findings.append(("time", rel, "the volume's entry has no date"))
            elif abs(vt - st.st_mtime) > TIME_SLACK:
                findings.append(("time", rel, f"modified {st.st_mtime:.0f} in the copy, {vt} on the volume "
                                              f"({vt - st.st_mtime:+.0f} s)"))
    for full in sorted(on_volume):
        if full not in seen:
            findings.append(("extra", full, "on the volume, not in the copy"))
    return findings


def main(argv) -> int:
    if argv[1:] == ["--self-test"]:
        return self_test()
    args = [a for a in argv[1:] if a != "--json"]
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    findings = compare(*args)
    if "--json" in argv:
        print(json.dumps({"findings": [{"kind": k, "path": p, "why": w} for k, p, w in findings]}, indent=1))
    else:
        for k, p, w in findings:
            print(f"{k:8} {p or '(the volume)'}: {w}")
        print(f"{len(findings)} finding(s)" if findings else "the volume holds the copy exactly")
    return 1 if findings else 0


# ── the self-test ───────────────────────────────────────────────────────────

# A small copy of prod's shape: data/ and auth/, long names, an empty file,
# a file of several clusters, times in 2-second steps and not.
TREE = {
    "data/chat/1_2/sessions/plan.md": (b"hello\n" * 300, 1_790_000_000),
    "data/chat/1_2/sessions/a-much-longer-session-name.reactions.jsonl": (b"{}\n", 1_790_000_101),
    "data/players/1/name": (b"Steve", 1_789_000_000),
    "auth/1/password": (b"$2a$10$" + b"x" * 53, 1_788_000_000),
    "auth/next-id.txt": (b"3\n", 1_788_000_003),
    "data/empty": (b"", 1_790_000_002),
}


def make_copy(root: str, tree: dict) -> None:
    for rel, (data, mtime) in tree.items():
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        os.utime(path, (mtime, mtime))


def make_volume(image: str, copy: str) -> None:
    """mkfs.vfat, then mtools copying `copy` in with its times (-m), in UTC."""
    with open(image, "wb") as f:
        f.truncate(16 << 20)
    subprocess.run(["mkfs.vfat", "-F", "16", "-S", "512", "-s", "1", image], check=True, capture_output=True)
    env = dict(os.environ, TZ="UTC", MTOOLS_SKIP_CHECK="1")
    for top in sorted(os.listdir(copy)):
        subprocess.run(["mcopy", "-s", "-m", "-i", image, os.path.join(copy, top), "::/"],
                       check=True, capture_output=True, env=env)


def self_test() -> int:
    missing = [t for t in ("mkfs.vfat", "mcopy") if shutil.which(t) is None]
    if missing:
        print(f"self-test cannot run: {', '.join(missing)} not installed (apt-get install dosfstools mtools)")
        return 2
    failures = []
    with tempfile.TemporaryDirectory() as d:
        def fresh(name, tree=TREE):
            root = os.path.join(d, name)
            make_copy(root, tree)
            return root

        def expect(what, copy, image, kinds):
            got = compare(copy, image)
            if sorted(k for k, _, _ in got) != sorted(kinds):
                failures.append(f"{what}: wanted {kinds}, got {got}")

        copy = fresh("copy")
        image = os.path.join(d, "v.img")
        make_volume(image, copy)
        expect("the copy, on the volume made from it", copy, image, [])

        # In the copy, each changed one way after the volume was made.
        def changed(what, change, kinds):
            c = fresh(what.replace(" ", "-"))
            change(c)
            expect(what, c, image, kinds)

        def write(c, rel, data, mtime=None):
            path = os.path.join(c, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            st = os.stat(path) if os.path.exists(path) else None
            with open(path, "wb") as f:
                f.write(data)
            t = mtime if mtime is not None else (st.st_mtime if st else 1_790_000_000)
            os.utime(path, (t, t))

        changed("a file the volume lacks", lambda c: write(c, "data/new.md", b"x"), ["missing"])
        changed("a file one byte longer", lambda c: write(c, "data/players/1/name", b"Steve!"), ["size"])
        changed("the same size, other bytes", lambda c: write(c, "data/players/1/name", b"Sieve"), ["content"])
        changed("a time 10 s later", lambda c: os.utime(os.path.join(c, "auth/next-id.txt"),
                                                         (1_788_000_013, 1_788_000_013)), ["time"])
        changed("a time 1 s off, within FAT's resolution",
                lambda c: os.utime(os.path.join(c, "auth/next-id.txt"), (1_788_000_004, 1_788_000_004)), [])
        changed("a file the copy lacks", lambda c: os.remove(os.path.join(c, "data/empty")), ["extra"])

        def recase(c):
            os.rename(os.path.join(c, "data/chat/1_2/sessions/plan.md"),
                      os.path.join(c, "data/chat/1_2/sessions/Plan.md"))
        changed("a name in another case", recase, ["case"])

        # The volume damaged: a leaked cluster.
        damaged = os.path.join(d, "damaged.img")
        shutil.copy(image, damaged)
        with open(damaged, "rb") as f:
            data = bytearray(f.read())
        vol = fat16_read.Volume(bytes(data))
        free = max(c for c in range(2, vol.max_cluster + 1) if vol.fat(c) == 0)
        for k in range(vol.nfats):
            struct.pack_into("<H", data, vol.base + (vol.fat_start + k * vol.fat_sectors) * fat16_read.SECTOR
                             + free * 2, 0xFFFF)
        with open(damaged, "wb") as f:
            f.write(data)
        expect("a leaked cluster on the volume", copy, damaged, ["check"])

        # A volume written in another time zone: every time moves.
        shifted = os.path.join(d, "shifted.img")
        with open(shifted, "wb") as f:
            f.truncate(16 << 20)
        subprocess.run(["mkfs.vfat", "-F", "16", "-S", "512", "-s", "1", shifted], check=True, capture_output=True)
        for top in sorted(os.listdir(copy)):
            subprocess.run(["mcopy", "-s", "-m", "-i", shifted, os.path.join(copy, top), "::/"], check=True,
                           capture_output=True, env=dict(os.environ, TZ="America/New_York", MTOOLS_SKIP_CHECK="1"))
        dated = [k for k in TREE if TREE[k][1]]
        expect("a volume written in New York's time", copy, shifted, ["time"] * len(dated))

    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: a volume made from the copy matches it exactly, and each kind of "
          "mismatch is found, alone")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
