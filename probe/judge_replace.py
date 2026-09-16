#!/usr/bin/env python3
"""The outside verdict on probe/replace.zig.

    judge_replace.py <volume image> <read-only mount of it>

Nothing here reads the volume through gopher-metal's code. The expected final
state is computed from the same formulas the probe used (restated below, not
imported); the files are read through the Linux VFAT driver via the mount; and
the COVERAGE — that the sessions directory really is fragmented, and that a
long-name run really does straddle one of its cluster edges — is checked by
parsing the raw image here.

That last part is what keeps the probe honest. Both bugs it exists for only
fire in those shapes. If a change to the allocator ever stopped producing them,
the probe would go on passing while testing nothing, so the judge fails instead.

Exit 0 with nothing printed on success; otherwise one line per failure.
"""
import os
import struct
import sys

FILES = 120
NEW_FILES = 20
ATTR_LFN = 0x0F


def body(i: int, variant: int) -> bytes:
    length = 3000 + (i * 37) % 500 if variant == 0 else 100 + (i * 53) % 4000
    tag = f"v{variant}:{i:03}:"
    return (tag * (length // len(tag) + 1))[:length].encode()


def deleted(i: int) -> bool:
    return i % 3 == 0


def replaced(i: int) -> bool:
    return i % 7 == 0 and not deleted(i)


def expected_sessions() -> dict:
    want = {}
    for i in range(FILES):
        if deleted(i):
            continue
        want[f"{i:03}-session-file-name.dsl"] = body(i, 1 if replaced(i) else 0)
    for j in range(NEW_FILES):
        want[f"{j:02}-new-file-after-deletes.dsl"] = f"new file {j}, written into a tombstone\n".encode()
    return want


class Volume:
    """Just enough FAT16 to follow a directory's chain. Independent of fat16.zig."""

    def __init__(self, path: str):
        with open(path, "rb") as f:
            self.data = f.read()
        bs = self.data[:512]
        self.bps = struct.unpack_from("<H", bs, 11)[0]
        self.spc = bs[13]
        reserved = struct.unpack_from("<H", bs, 14)[0]
        nfats = bs[16]
        self.root_entries = struct.unpack_from("<H", bs, 17)[0]
        spf = struct.unpack_from("<H", bs, 22)[0]
        self.fat = reserved * self.bps
        self.root = (reserved + nfats * spf) * self.bps
        root_sectors = (self.root_entries * 32 + self.bps - 1) // self.bps
        self.data_start = self.root + root_sectors * self.bps
        self.cluster_bytes = self.spc * self.bps

    def next(self, c: int) -> int:
        return struct.unpack_from("<H", self.data, self.fat + 2 * c)[0]

    def chain(self, first: int) -> list:
        out, c = [], first
        while 2 <= c < 0xFFF8:
            if c in out:
                raise ValueError(f"cluster chain loops at {c}")
            out.append(c)
            c = self.next(c)
        return out

    def cluster(self, c: int) -> bytes:
        at = self.data_start + (c - 2) * self.cluster_bytes
        return self.data[at: at + self.cluster_bytes]

    def root_entry(self, long_name: str):
        """The root entry whose VFAT long name is `long_name` (case-insensitive).

        Found by the long name because a lowercase name never reads back as
        itself in 8.3, so it is stored under an alias — SESSIO~1, not SESSIONS.
        The parts are UCS-2 at thirteen fixed offsets, last part first on disk.
        """
        offsets = (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
        parts = []
        for n in range(self.root_entries):
            e = self.data[self.root + n * 32: self.root + (n + 1) * 32]
            if e[0] == 0:
                return None
            if e[0] == 0xE5:
                parts = []
                continue
            if e[11] == ATTR_LFN:
                if e[0] & 0x40:
                    parts = []
                chars = []
                for off in offsets:
                    u = struct.unpack_from("<H", e, off)[0]
                    if u in (0x0000, 0xFFFF):
                        break
                    chars.append(chr(u))
                parts.append("".join(chars))
                continue
            name = "".join(reversed(parts))
            parts = []
            if name.lower() == long_name.lower():
                return e
        return None


def coverage(image: str) -> list:
    problems = []
    vol = Volume(image)
    e = vol.root_entry("sessions")
    if e is None:
        return ["the raw image has no `sessions` directory in its root"], 0, 0, 0
    if not e[11] & 0x10:
        return ["`sessions` in the raw image is not a directory"], 0, 0, 0
    chain = vol.chain(struct.unpack_from("<H", e, 26)[0])
    if len(chain) < 3:
        problems.append(f"sessions/ spans only {len(chain)} cluster(s): the probe no longer grows it")

    gaps = sum(1 for a, b in zip(chain, chain[1:]) if b != a + 1)
    if gaps == 0:
        problems.append(f"sessions/ occupies contiguous clusters {chain}: "
                        "the probe no longer fragments the directory, so it no longer tests the cross-cluster path")

    straddles = 0
    for c in chain[:-1]:
        last = vol.cluster(c)[-32:]
        if last[0] not in (0x00, 0xE5) and last[11] == ATTR_LFN:
            straddles += 1
    if straddles == 0:
        problems.append("no live long-name run straddles a cluster edge of sessions/: "
                        "the probe no longer tests the case writeEntry and removeEntry got wrong")
    return problems, len(chain), gaps, straddles


def contents(mount: str) -> list:
    problems = []
    counter = open(os.path.join(mount, "counter.txt"), "rb").read()
    if counter != b"200\n":
        problems.append(f"counter.txt reads {counter!r}, want b'200\\n'")

    if os.path.exists(os.path.join(mount, "tree")):
        problems.append("tree/ still exists after deleteTree")

    want = expected_sessions()
    have = set(os.listdir(os.path.join(mount, "sessions")))
    missing = sorted(set(want) - have)
    extra = sorted(have - set(want))
    if missing:
        problems.append(f"sessions/ is missing {len(missing)} file(s), e.g. {missing[:3]}")
    if extra:
        problems.append(f"sessions/ has {len(extra)} unexpected file(s), e.g. {extra[:3]}")
    wrong = [n for n in sorted(set(want) & have)
             if open(os.path.join(mount, "sessions", n), "rb").read() != want[n]]
    if wrong:
        problems.append(f"{len(wrong)} file(s) in sessions/ have the wrong bytes, e.g. {wrong[:3]}")
    return problems


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip())
        return 2
    image, mount = sys.argv[1], sys.argv[2]
    cov, clusters, gaps, straddles = coverage(image)
    problems = cov + contents(mount)
    for p in problems:
        print(p)
    if not problems:
        print(f"sessions/ is {clusters} clusters with {gaps} gap(s) and {straddles} straddling run(s); "
              f"all {len(expected_sessions())} files read back byte for byte")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
