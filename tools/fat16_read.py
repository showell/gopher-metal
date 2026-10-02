#!/usr/bin/env python3
"""An independent FAT16 reader, written from Microsoft's FAT specification
and not from src/fat16.zig: the oracle for what this machine writes (QUEUE.md
item 4).

    tools/fat16_read.py list  IMAGE            every file and directory, with sizes
    tools/fat16_read.py cat   IMAGE PATH       a file's bytes, to stdout
    tools/fat16_read.py check IMAGE...         the volume's consistency; exit 1 if not
    tools/fat16_read.py make-foreign DIR       writes the self-test's volumes, for fat16.zig's check
    tools/fat16_read.py --self-test            checks this reader against mkfs.vfat
                                               and mtools, then against damage

IMAGE is a bare FAT16 volume, or a GPT disk whose first partition holds one
(the volume is found through the GPT, as this machine finds it).

`check` reports, each on its own line:

  - a FAT copy that differs from the first;
  - a chain that leaves the data region, runs into a free or bad cluster, or
    loops;
  - a cluster in two chains (cross-linked);
  - a file whose size does not match its chain's length, or a directory with
    a size;
  - a long name whose checksum does not match its short entry, or whose parts
    are out of order;
  - a directory missing its "." or "..", or with them pointing wrong;
  - clusters marked used that nothing reaches (leaked).

Plain Python, standard library only, no mounting.
"""
import calendar
import datetime
import os
import shutil
import struct
import subprocess
import sys
import tempfile

SECTOR = 512
ATTR_READ_ONLY, ATTR_HIDDEN, ATTR_SYSTEM, ATTR_VOLUME, ATTR_DIR, ATTR_ARCHIVE = 1, 2, 4, 8, 0x10, 0x20
ATTR_LONG = 0x0F
EOC = 0xFFF8
BAD = 0xFFF7


class Problem(Exception):
    pass


def find_volume(img):
    """Byte offset of the FAT volume: 0 for a bare one, else the first GPT
    partition's start."""
    if len(img) >= 2 * SECTOR and img[SECTOR:SECTOR + 8] == b"EFI PART":
        entries_lba, count, size = struct.unpack_from("<QII", img, SECTOR + 72)
        for k in range(count):
            e = (entries_lba * SECTOR) + k * size
            first = struct.unpack_from("<Q", img, e + 32)[0]
            if img[e:e + 16] != bytes(16) and first:
                return first * SECTOR
        raise Problem("a GPT with no partition")
    return 0


class Volume:
    def __init__(self, img, base=None):
        self.img = img
        self.base = find_volume(img) if base is None else base
        b = img[self.base:self.base + SECTOR]
        if len(b) < SECTOR or b[510:512] != b"\x55\xaa":
            raise Problem("no boot sector signature (55 AA)")
        (self.bytes_per_sector, self.spc, self.reserved, self.nfats, self.root_entries,
         total16, _media, self.fat_sectors) = struct.unpack_from("<HBHBHHBH", b, 11)
        total32 = struct.unpack_from("<I", b, 32)[0]
        self.total = total16 or total32
        if self.bytes_per_sector != SECTOR:
            raise Problem(f"{self.bytes_per_sector}-byte sectors; this reader takes 512")
        if self.spc == 0 or self.spc & (self.spc - 1):
            raise Problem(f"{self.spc} sectors a cluster is not a power of two")
        if self.fat_sectors == 0:
            raise Problem("no FAT16 FAT size (a FAT32 volume?)")
        self.root_sectors = (self.root_entries * 32 + SECTOR - 1) // SECTOR
        self.fat_start = self.reserved
        self.root_start = self.reserved + self.nfats * self.fat_sectors
        self.data_start = self.root_start + self.root_sectors
        self.clusters = (self.total - self.data_start) // self.spc
        # The spec decides the FAT type by cluster count, and nothing else.
        if self.clusters < 4085:
            raise Problem(f"{self.clusters} clusters: FAT12, not FAT16")
        if self.clusters >= 65525:
            raise Problem(f"{self.clusters} clusters: FAT32, not FAT16")
        if self.fat_sectors * SECTOR // 2 < self.clusters + 2:
            raise Problem(f"a FAT of {self.fat_sectors} sectors cannot hold {self.clusters} clusters")
        self.max_cluster = self.clusters + 1
        self.cluster_bytes = self.spc * SECTOR
        self.fats = [self.sectors(self.fat_start + k * self.fat_sectors, self.fat_sectors) for k in range(self.nfats)]

    def sectors(self, lba, count):
        at = self.base + lba * SECTOR
        data = self.img[at:at + count * SECTOR]
        if len(data) != count * SECTOR:
            raise Problem(f"sectors {lba}..{lba + count} run past the end of the image")
        return data

    def fat(self, cluster):
        return struct.unpack_from("<H", self.fats[0], cluster * 2)[0]

    def cluster(self, n):
        return self.sectors(self.data_start + (n - 2) * self.spc, self.spc)

    def chain(self, first):
        """The clusters of a chain, in order. Raises Problem on a broken one."""
        out, seen = [], set()
        c = first
        while True:
            if c < 2 or c > self.max_cluster:
                raise Problem(f"cluster {c} is outside the data region (2..{self.max_cluster})")
            if c in seen:
                raise Problem(f"the chain loops back to cluster {c}")
            seen.add(c)
            out.append(c)
            nxt = self.fat(c)
            if nxt >= EOC:
                return out
            if nxt == 0:
                raise Problem(f"the chain runs into free cluster after {c}")
            if nxt == BAD:
                raise Problem(f"the chain runs into a bad cluster after {c}")
            c = nxt

    # ── directories ─────────────────────────────────────────────────────────

    def raw_entries(self, first):
        """The 32-byte entries of a directory: the root (first 0) or a chain."""
        data = self.sectors(self.root_start, self.root_sectors) if first == 0 else \
            b"".join(self.cluster(c) for c in self.chain(first))
        for k in range(0, len(data), 32):
            e = data[k:k + 32]
            if e[0] == 0:
                return
            yield e

    def entries(self, first, problems, where):
        """(name, attr, first cluster, size, mtime) for each entry, long names
        joined and checked against their short entries. `mtime` is the
        entry's modification time as Unix seconds, reading the DOS fields as
        UTC (as gopher-metal does); None for a date the fields cannot be."""
        parts, expect, checksum = {}, None, None
        for e in self.raw_entries(first):
            if e[0] == 0xE5:
                parts, expect = {}, None
                continue
            attr = e[11]
            if attr == ATTR_LONG:
                seq = e[0] & 0x1F
                if e[0] & 0x40:
                    parts, expect, checksum = {}, seq, e[13]
                elif expect is None or seq != expect - len(parts) or e[13] != checksum:
                    problems.append(f"{where}: a long-name part out of order or from another name")
                    parts, expect = {}, None
                    continue
                chars = e[1:11] + e[14:26] + e[28:32]
                parts[seq] = chars
                continue
            if attr & ATTR_VOLUME:
                parts, expect = {}, None
                continue
            short = e[0:11]
            name = short_name(short, e[12])
            if parts:
                if len(parts) != expect or set(parts) != set(range(1, expect + 1)):
                    problems.append(f"{where}/{name}: its long name is missing parts")
                elif lfn_checksum(short) != checksum:
                    problems.append(f"{where}/{name}: its long name's checksum is not its short entry's")
                else:
                    units = b"".join(parts[k] for k in range(1, expect + 1))
                    text = units.decode("utf-16-le", "replace")
                    name = text.split("\x00")[0]
            parts, expect = {}, None
            hi, lo = struct.unpack_from("<H", e, 20)[0], struct.unpack_from("<H", e, 26)[0]
            first_cluster = lo  # FAT16: the high half is not a cluster
            if hi:
                problems.append(f"{where}/{name}: a FAT32 high cluster half on FAT16 ({hi})")
            size = struct.unpack_from("<I", e, 28)[0]
            yield name, attr, first_cluster, size, dos_time(struct.unpack_from("<HH", e, 22))

    # ── the walk ────────────────────────────────────────────────────────────

    def walk(self, problems):
        """Every file and directory: (path, is_dir, first cluster, size), with
        every chain checked and recorded in self.owner, and each one's
        modification time in self.mtime (see `entries`)."""
        self.owner = {}
        self.mtime = {}
        out = []

        def own(path, first):
            try:
                chain = self.chain(first)
            except Problem as p:
                problems.append(f"{path}: {p}")
                return None
            for c in chain:
                if c in self.owner:
                    problems.append(f"{path}: cluster {c} is also {self.owner[c]}'s (cross-linked)")
                else:
                    self.owner[c] = path
            return chain

        def visit(first, path, parent, depth):
            if depth > 64:
                problems.append(f"{path}: directories nested deeper than 64; a loop?")
                return
            names = set()
            dot = dotdot = False
            for name, attr, fc, size, mtime in self.entries(first, problems, path or "/"):
                if name == ".":
                    dot = True
                    if fc != first:
                        problems.append(f"{path}/.: points at cluster {fc}, not its own {first}")
                    continue
                if name == "..":
                    dotdot = True
                    if fc != parent:
                        problems.append(f"{path}/..: points at cluster {fc}, not its parent's {parent}")
                    continue
                full = f"{path}/{name}"
                self.mtime[full] = mtime
                if name.casefold() in names:
                    problems.append(f"{full}: a second entry of the same name")
                names.add(name.casefold())
                if attr & ATTR_DIR:
                    if size:
                        problems.append(f"{full}: a directory with a size ({size})")
                    if fc == 0:
                        problems.append(f"{full}: a directory with no cluster")
                        continue
                    if own(full, fc) is None:
                        continue
                    out.append((full, True, fc, 0))
                    visit(fc, full, first, depth + 1)
                else:
                    out.append((full, False, fc, size))
                    if size == 0:
                        if fc:
                            problems.append(f"{full}: empty, but it holds cluster {fc}")
                        continue
                    if fc == 0:
                        problems.append(f"{full}: {size} bytes and no cluster")
                        continue
                    chain = own(full, fc)
                    if chain is not None:
                        want = (size + self.cluster_bytes - 1) // self.cluster_bytes
                        if len(chain) != want:
                            problems.append(f"{full}: {size} bytes needs {want} clusters; its chain has {len(chain)}")
            if first != 0 and not (dot and dotdot):
                problems.append(f"{path}: missing its . or .. entry")

        visit(0, "", 0, 0)
        return out

    def check(self):
        problems = []
        for k in range(1, self.nfats):
            if self.fats[k] != self.fats[0]:
                problems.append(f"FAT copy {k + 1} differs from the first")
        if self.fat(0) & 0xFF != self.img[self.base + 21]:
            problems.append("the FAT's first entry does not carry the media byte")
        self.walk(problems)
        leaked = [c for c in range(2, self.max_cluster + 1)
                  if self.fat(c) not in (0, BAD) and c not in self.owner]
        if leaked:
            problems.append(f"{len(leaked)} clusters marked used that nothing reaches (leaked), "
                            f"first {leaked[:8]}")
        return problems

    def read(self, path):
        problems = []
        for full, is_dir, fc, size in self.walk(problems):
            if full.casefold() == ("/" + path.strip("/")).casefold():
                if is_dir:
                    raise Problem(f"{path} is a directory")
                if size == 0:
                    return b""
                return b"".join(self.cluster(c) for c in self.chain(fc))[:size]
        raise Problem(f"{path}: not found")


def dos_time(fields):
    """A DOS (time, date) pair as Unix seconds, read as UTC: the date's bits
    are years since 1980, month, day; the time's are hours, minutes, and
    seconds in two-second steps. None for fields that are not a date (a zero
    date, as an entry nothing ever dated has)."""
    t, d = fields
    year, month, day = 1980 + (d >> 9), (d >> 5) & 0xF, d & 0x1F
    hour, minute, second = t >> 11, (t >> 5) & 0x3F, (t & 0x1F) * 2
    if not (1 <= month <= 12 and 1 <= day <= 31 and hour < 24 and minute < 60 and second < 60):
        return None
    try:
        datetime.date(year, month, day)  # 30 February, and the like
    except ValueError:
        return None
    return calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0))


def short_name(short, case):
    """An 8.3 entry as text, honouring the NT case bits (0x08 base, 0x10 ext)."""
    base = short[0:8].rstrip(b" ")
    ext = short[8:11].rstrip(b" ")
    if base[:1] == b"\x05":
        base = b"\xe5" + base[1:]
    b = base.decode("latin-1")
    x = ext.decode("latin-1")
    if case & 0x08:
        b = b.lower()
    if case & 0x10:
        x = x.lower()
    return b + ("." + x if x else "")


def lfn_checksum(short):
    s = 0
    for c in short:
        s = (((s & 1) << 7) | (s >> 1)) + c & 0xFF
    return s


# ── the command line ────────────────────────────────────────────────────────

def load(path):
    with open(path, "rb") as f:
        return Volume(f.read())


def main(argv):
    if argv[1:2] == ["--self-test"]:
        return self_test()
    if len(argv) == 3 and argv[1] == "make-foreign":
        return make_foreign(argv[2])
    if len(argv) >= 3 and argv[1] == "list":
        v = load(argv[2])
        problems = []
        for full, is_dir, fc, size in v.walk(problems):
            print(f"{'d' if is_dir else '-'} {size:>10} {full}")
        for p in problems:
            print(f"! {p}", file=sys.stderr)
        return 1 if problems else 0
    if len(argv) == 4 and argv[1] == "cat":
        sys.stdout.buffer.write(load(argv[2]).read(argv[3]))
        return 0
    if len(argv) >= 3 and argv[1] == "check":
        bad = 0
        for path in argv[2:]:
            try:
                problems = load(path).check()
            except Problem as p:
                problems = [f"not a FAT16 volume: {p}"]
            print(f"{'ok  ' if not problems else 'FAIL'} {path}")
            for p in problems:
                print(f"     {p}")
            bad += bool(problems)
        return 1 if bad else 0
    print(__doc__, file=sys.stderr)
    return 2


# ── the self-test ───────────────────────────────────────────────────────────

MTOOLS = ("mkfs.vfat", "mcopy", "mmd")


def foreign_volumes(d):
    """A volume another program made (mkfs.vfat formats it, mtools writes
    it), the files written to it, and the same volume damaged each way
    `check` must catch: (healthy image bytes, files, [(name, what, image
    bytes, the words a problem must hold)]). `d` is a scratch directory."""
    img = os.path.join(d, "v.img")
    with open(img, "wb") as f:
        f.truncate(8 << 20)
    subprocess.run(["mkfs.vfat", "-F", "16", "-S", "512", "-s", "1", "-n", "TEST", img],
                   check=True, capture_output=True)
    files = {
        "data/chat/1_2/sessions/topic.md": b"hello\n" * 300,
        "data/chat/1_2/sessions/a-much-longer-session-name.reactions.jsonl": b"{}\n",
        "auth/1/api-key": b"0123456789abcdef",
        "EMPTY": b"",
        "data/big.bin": bytes(range(256)) * 400,
    }
    for path in files:
        parent = os.path.dirname(path)
        parts = parent.split("/") if parent else []
        for k in range(1, len(parts) + 1):
            subprocess.run(["mmd", "-i", img, "-D", "s", "::/" + "/".join(parts[:k])],
                           capture_output=True)
    for path, data in files.items():
        src = os.path.join(d, "src")
        with open(src, "wb") as f:
            f.write(data)
        subprocess.run(["mcopy", "-i", img, src, "::/" + path], check=True, capture_output=True)

    with open(img, "rb") as f:
        good = bytes(f.read())
    v = Volume(good)

    def fat_set(img2, cluster, value, copies=None):
        for k in (copies if copies is not None else range(v.nfats)):
            at = v.base + (v.fat_start + k * v.fat_sectors) * SECTOR + cluster * 2
            struct.pack_into("<H", img2, at, value)

    def damage(change):
        img2 = bytearray(good)
        change(img2)
        return bytes(img2)

    big = v.chain(next(fc for p, isd, fc, s in v.walk([]) if p == "/data/big.bin"))
    topic = next(fc for p, isd, fc, s in v.walk([]) if p.endswith("topic.md"))
    free = next(c for c in range(2, v.max_cluster + 1) if v.fat(c) == 0)
    damages = [
        ("loop", "a loop", damage(lambda i: fat_set(i, big[3], big[1])), "loops"),
        ("free", "a free cluster in a chain", damage(lambda i: fat_set(i, big[2], 0)), "free cluster"),
        ("crossed", "a cross-link", damage(lambda i: fat_set(i, v.chain(topic)[-1], big[5])), "cross-linked"),
        ("leak", "a leak", damage(lambda i: fat_set(i, free, 0xFFFF)), "leaked"),
        ("short", "a short chain", damage(lambda i: fat_set(i, big[-2], 0xFFFF)), "needs"),
        ("fats", "FAT copies differing", damage(lambda i: fat_set(i, free, 0xFFFF, copies=[1])), "differs"),
    ]
    return good, files, damages


def make_foreign(out):
    """Writes foreign_volumes' images into `out`, for fat16.zig's own check
    to judge: healthy-mtools.img, and damaged-mtools-<kind>.img."""
    missing = [t for t in MTOOLS if shutil.which(t) is None]
    if missing:
        print(f"cannot make them: {', '.join(missing)} not installed "
              "(apt-get install dosfstools mtools)", file=sys.stderr)
        return 2
    os.makedirs(out, exist_ok=True)
    with tempfile.TemporaryDirectory() as d:
        good, _, damages = foreign_volumes(d)
        with open(os.path.join(out, "healthy-mtools.img"), "wb") as f:
            f.write(good)
        for name, _, img, _ in damages:
            with open(os.path.join(out, f"damaged-mtools-{name}.img"), "wb") as f:
                f.write(img)
    return 0


def self_test():
    """Against volumes another program made: mkfs.vfat formats, mtools
    writes. Then the same volume damaged each way `check` must catch."""
    missing = [t for t in MTOOLS if shutil.which(t) is None]
    if missing:
        print(f"self-test cannot run: {', '.join(missing)} not installed "
              "(apt-get install dosfstools mtools)")
        return 2
    failures = []
    with tempfile.TemporaryDirectory() as d:
        good, files, damages = foreign_volumes(d)
        v = Volume(good)
        problems = v.check()
        if problems:
            failures.append(f"a clean mtools volume reads as inconsistent: {problems}")
        for path, data in files.items():
            try:
                if v.read(path) != data:
                    failures.append(f"{path}: the bytes read back differ")
            except Problem as p:
                failures.append(f"{path}: {p}")
        for _, what, img, want in damages:
            try:
                got = Volume(img).check()
            except Problem as p:
                got = [str(p)]
            if not any(want in p for p in got):
                failures.append(f"{what}: wanted a problem with {want!r}, got {got}")

    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: an mtools-written volume reads back exactly and checks clean, "
          "and each kind of damage is found")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
