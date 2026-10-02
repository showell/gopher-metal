#!/usr/bin/env python3
"""The way back (QUEUE.md item 34): a volume gopher-metal wrote, as a Linux
tree again, without root.

    droplet/extract_volume.py VOLUME.img OUT/ [--anyway]
    droplet/extract_volume.py --self-test [ZIG_SERVER_BINARY]

Every file and folder on the volume is written under OUT/ with the name it
is stored under, in its case (long names, and the NT case bits of a short
one), with its modification time. Folders get theirs after their contents
are written. So a cutover that fails after writes on metal can go back to
Linux carrying them: copy OUT/'s `data/` and `auth/` over prod's.

It is read by tools/fat16_read.py, the reader written from the spec, not
by a mount, so no root is needed and no driver's idea of a name gets in
the way.

**A DAMAGED VOLUME IS REFUSED**, unless `--anyway`: a cross-link, a broken
chain or a file whose size and chain disagree is a decision for a person,
not something to copy across quietly. Leaked clusters lose no file, so they
are reported and the extraction goes on. OUT/ must be missing or empty.

Afterwards the result is judged by compare_volume.py, reversed: the tree
just written against the volume it came from, every name, byte and time.
An entry with no date on the volume (one written before the machine's
clock was set) keeps the time of the extraction, with a warning: there is
no time to give it.
Exit 0 when it agrees, 1 when anything differs or the volume is refused, 2
for a usage error.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import compare_volume  # noqa: E402
import fat16_read  # noqa: E402


class Refused(Exception):
    pass


def extract(image: str, out: str, anyway: bool = False) -> tuple:
    """Writes `image`'s tree under `out`. Answers (files, folders, warnings)."""
    if os.path.exists(out) and os.listdir(out):
        raise Refused(f"{out} is not empty")
    v = fat16_read.load(image)
    problems = []
    walked = v.walk(problems)
    if problems and not anyway:
        raise Refused(f"the volume has {len(problems)} problem(s), the first: {problems[0]} "
                      f"(--anyway extracts what reads)")
    # Leaks are found by the whole check, not the walk; they lose nothing.
    warnings = [p for p in v.check() if p not in problems]
    os.makedirs(out, exist_ok=True)
    files = folders = 0
    for full, is_dir, first, size in walked:
        path = os.path.join(out, full.lstrip("/"))
        if is_dir:
            os.makedirs(path, exist_ok=True)
            folders += 1
            continue
        try:
            data = b"" if size == 0 else b"".join(v.cluster(c) for c in v.chain(first))[:size]
        except fat16_read.Problem as p:
            warnings.append(f"{full}: not extracted: {p}")
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        files += 1
        t = v.mtime.get(full)
        if t is not None:
            os.utime(path, (t, t))
    # Folders last, deepest first: writing a file into a folder moves its time.
    for full, is_dir, _, _ in sorted(walked, key=lambda w: -w[0].count("/")):
        t = v.mtime.get(full)
        if is_dir and t is not None:
            p = os.path.join(out, full.lstrip("/"))
            os.utime(p, (t, t))
    return files, folders, warnings


UNDATED = "the volume's entry has no date"


def judged(out: str, image: str) -> tuple:
    """compare_volume's findings for `out` against `image`, as (differences,
    undated): an entry with no date is not a difference, since there is no
    time it could have been given."""
    found = compare_volume.compare(out, image)
    undated = [f for f in found if f[0] == "time" and f[2] == UNDATED]
    return [f for f in found if f not in undated], undated


def main(argv) -> int:
    if argv[1:2] == ["--self-test"]:
        return self_test(argv[2] if len(argv) > 2 else None)
    args = argv[1:]
    anyway = "--anyway" in args
    if anyway:
        args.remove("--anyway")
    if len(args) != 2 or not os.path.isfile(args[0]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    image, out = args
    try:
        files, folders, warnings = extract(image, out, anyway)
    except (Refused, fat16_read.Problem) as e:
        print(f"refused: {e}", file=sys.stderr)
        return 1
    for w in warnings:
        print(f"warning: {w}")
    differences, undated = judged(out, image)
    if undated:
        print(f"warning: {len(undated)} file(s) have no date on the volume and keep the extraction's time")
    for kind, path, what in differences:
        print(f"differs: {kind} {path}: {what}")
    print(f"extract_volume.py: {files} files, {folders} folders from {image} into {out}"
          + (f"; {len(differences)} difference(s) from the volume, above" if differences else
             "; compare_volume.py finds the tree and the volume the same"))
    return 1 if differences else 0


# ── the self-test ───────────────────────────────────────────────────────────

def self_test(binary: str = None) -> int:
    """Volumes made by mtools (build_volume.py's tree of every name shape)
    and by fat16.zig itself, on FAT16 and FAT32: each extracted, then
    compared back name for name, byte for byte and time for time; a damaged
    one refused. With a zig-server binary, the Linux server then serves a
    doc from an extracted tree."""
    import build_volume
    missing = [t for t in ("sgdisk", "mkfs.vfat", "mcopy") if shutil.which(t) is None]
    if missing:
        print(f"self-test cannot run: {', '.join(missing)} not installed")
        return 2
    failures = []
    with tempfile.TemporaryDirectory() as d:
        copy = os.path.join(d, "copy")
        build_volume.make_tree(copy)
        for fat, spc in ((16, None), (32, 1)):
            img = os.path.join(d, f"v{fat}.img")
            build_volume.build(copy, img, fat, 64 << 20, spc)
            out = os.path.join(d, f"out{fat}")
            files, folders, warnings = extract(img, out)
            if warnings:
                failures.append(f"FAT{fat}: warnings on a healthy volume: {warnings}")
            # Back to the copy it was built from, exactly: names, bytes, times.
            for root, _, names in os.walk(copy):
                for n in names:
                    rel = os.path.relpath(os.path.join(root, n), copy)
                    got = os.path.join(out, rel)
                    if not os.path.isfile(got):
                        failures.append(f"FAT{fat}: {rel} is missing (or not in its case)")
                        continue
                    with open(os.path.join(copy, rel), "rb") as a, open(got, "rb") as b:
                        if a.read() != b.read():
                            failures.append(f"FAT{fat}: {rel} differs")
                    if int(os.stat(got).st_mtime) != int(os.stat(os.path.join(copy, rel)).st_mtime):
                        failures.append(f"FAT{fat}: {rel}'s time differs")
            wanted = sum(len(n) for _, _, n in os.walk(copy))
            if files != wanted:
                failures.append(f"FAT{fat}: {files} files extracted, the copy has {wanted}")
            if judged(out, img) != ([], []):
                failures.append(f"FAT{fat}: compare_volume finds differences")
            # A refused one: a cross-link made on purpose.
            if fat == 16:
                bad = os.path.join(d, "bad.img")
                shutil.copy(img, bad)
                with open(bad, "rb") as f:
                    data = bytearray(f.read())
                v = fat16_read.Volume(bytes(data))
                files_on = [w for w in v.walk([]) if not w[1] and w[3] > v.cluster_bytes]
                big, small_one = files_on[0], [w for w in v.walk([]) if not w[1] and 0 < w[3]][-1]
                last = v.chain(small_one[2])[-1]
                at = v.base + v.fat_start * 512 + last * 2
                data[at:at + 2] = big[2].to_bytes(2, "little")  # its chain runs into another file's
                with open(bad, "wb") as f:
                    f.write(data)
                try:
                    extract(bad, os.path.join(d, "out-bad"))
                    failures.append("a cross-linked volume was extracted, not refused")
                except Refused:
                    pass
                # Into a folder that is not empty: refused.
                try:
                    extract(img, out)
                    failures.append("extracted into a folder that was not empty")
                except Refused:
                    pass

        # What fat16.zig itself writes: the host tests' kept images, if a
        # caller made them (tools/check_fat16_images.sh keeps them here).
        kept = os.environ.get("FAT16_IMAGES")
        if kept and os.path.isdir(kept):
            n = 0
            for name in sorted(os.listdir(kept)):
                if not name.endswith(".img") or name.startswith(("damaged-", "limit-", "io-")):
                    continue
                img = os.path.join(kept, name)
                out = os.path.join(d, "kept", name)
                try:
                    extract(img, out)
                except (Refused, fat16_read.Problem) as e:
                    failures.append(f"{name}: {e}")
                    continue
                differ, _ = judged(out, img)  # the host tests set no clock: no dates
                if differ:
                    failures.append(f"{name}: compare_volume finds {differ[:2]}")
                n += 1
            print(f"  {n} volumes fat16.zig wrote extracted and compared")

        if binary:
            sys.path.insert(0, os.path.join(ROOT, "probe"))
            import judge_gopher as G
            import compare_hosts
            out = os.path.join(d, "out16")
            server = G.LinuxServer(binary, out, os.path.join(d, "serve.log"))
            try:
                with open(os.path.join(out, "data/chat/_session_secret"), "rb") as f:
                    secret = f.read()
                cookie = compare_hosts.mint_session(secret, "7", int(time.time()))
                slug = build_volume.SLUG80
                status, body = compare_hosts.ask(f"http://127.0.0.1:{server.port}", f"/chat/docs/{slug}", cookie)
                if status != "200" or b"a doc" not in body:
                    failures.append(f"the Linux server did not serve the extracted doc: {status}")
            finally:
                server.stop()
    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: FAT16 and FAT32 volumes extracted to the tree they were built from, every "
          "name in its case, every byte and every time; a cross-linked volume and a non-empty folder refused"
          + ("; the Linux server serves the extracted data" if binary else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
