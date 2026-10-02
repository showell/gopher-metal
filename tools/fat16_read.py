#!/usr/bin/env python3
"""An independent FAT16 and FAT32 reader, written from Microsoft's FAT
specification and not from src/fat16.zig: the oracle for what this machine
writes (QUEUE.md items 4 and 17). Which FAT a volume is, it decides as the
spec does: by its count of clusters (65,525 and up is FAT32).

    tools/fat16_read.py list  IMAGE            every file and directory, with sizes
    tools/fat16_read.py cat   IMAGE PATH       a file's bytes, to stdout
    tools/fat16_read.py check IMAGE...         the volume's consistency; exit 1 if not
    tools/fat16_read.py make-foreign DIR       writes the self-test's volumes, for fat16.zig's check
    tools/fat16_read.py --self-test            checks this reader against mkfs.vfat
                                               and mtools, then against damage

IMAGE is a bare FAT16 or FAT32 volume, or a GPT disk whose first partition holds one
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
  - clusters marked used that nothing reaches (leaked);
  - on FAT32, also:
    - a version other than 0, or FAT mirroring turned off. fsck.fat accepts
      both, and this machine refuses both at mount (FAT32.md §3), so for this
      oracle they are problems;
    - a root cluster outside the data region;
    - an FSInfo whose signatures are wrong, whose free count is set and wrong
      (fsck.fat reports that), or whose next-free hint is out of range.

    A FAT32 entry's top four bits are reserved, and are not part of its
    value: set, they change nothing.

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
# Per kind (Volume.eoc, Volume.bad): FAT16's, and FAT32's 28-bit values.
EOC16, BAD16 = 0xFFF8, 0xFFF7
EOC32, BAD32 = 0x0FFFFFF8, 0x0FFFFFF7
EOC, BAD = EOC16, BAD16  # what callers outside this file have always used for FAT16


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
        # FAT32's own fields; on FAT16 these bytes are the extended boot
        # record, and they are read only once the cluster count says FAT32.
        fat32_sectors, self.ext_flags, self.fs_ver, self.root_cluster, self.fsinfo_sector, \
            self.backup_boot = struct.unpack_from("<IHHIHH", b, 36)
        if self.fat_sectors == 0:
            self.fat_sectors = fat32_sectors
        if self.fat_sectors == 0:
            raise Problem("the boot sector gives no FAT size")
        self.root_sectors = (self.root_entries * 32 + SECTOR - 1) // SECTOR
        self.fat_start = self.reserved
        self.root_start = self.reserved + self.nfats * self.fat_sectors
        self.data_start = self.root_start + self.root_sectors
        self.clusters = (self.total - self.data_start) // self.spc
        # The spec decides the FAT type by cluster count, and nothing else.
        if self.clusters < 4085:
            raise Problem(f"{self.clusters} clusters: FAT12, which this reader does not take")
        self.kind = "FAT32" if self.clusters >= 65525 else "FAT16"
        self.entry_bytes = 4 if self.kind == "FAT32" else 2
        self.eoc, self.bad = (EOC32, BAD32) if self.kind == "FAT32" else (EOC16, BAD16)
        if self.kind == "FAT32":
            if self.root_entries != 0 or struct.unpack_from("<H", b, 22)[0] != 0:
                raise Problem("FAT32 by its cluster count, with a FAT16 root or FAT size")
        else:
            self.root_cluster = 0
        if self.fat_sectors * SECTOR // self.entry_bytes < self.clusters + 2:
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

    def fat(self, cluster, copy=0):
        """A FAT entry: 16 bits, or FAT32's low 28 (the top four are reserved,
        and are not part of the value)."""
        if self.kind == "FAT32":
            return struct.unpack_from("<I", self.fats[copy], cluster * 4)[0] & 0x0FFFFFFF
        return struct.unpack_from("<H", self.fats[copy], cluster * 2)[0]

    def free_clusters(self):
        return sum(1 for c in range(2, self.max_cluster + 1) if self.fat(c) == 0)

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
            if nxt >= self.eoc:
                return out
            if nxt == 0:
                raise Problem(f"the chain runs into free cluster after {c}")
            if nxt == self.bad:
                raise Problem(f"the chain runs into a bad cluster after {c}")
            c = nxt

    # ── directories ─────────────────────────────────────────────────────────

    def raw_entries(self, first):
        """The 32-byte entries of a directory: the root (first 0) or a chain.
        FAT32's root is a chain too, from the boot sector's root cluster."""
        if first == 0 and self.kind == "FAT32":
            first = self.root_cluster
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
            if self.kind == "FAT32":
                first_cluster = (hi << 16) | lo
            else:
                first_cluster = lo  # FAT16: bytes 20-21 are not a cluster
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

        if self.kind == "FAT32":
            # The root is a chain on FAT32, and its clusters are held by it.
            if own("/", self.root_cluster) is None:
                return out
        visit(0, "", 0, 0)
        return out

    def check(self):
        problems = []
        for k in range(1, self.nfats):
            if self.fats[k] != self.fats[0]:
                problems.append(f"FAT copy {k + 1} differs from the first")
        if self.fat(0) & 0xFF != self.img[self.base + 21]:
            problems.append("the FAT's first entry does not carry the media byte")
        if self.kind == "FAT32":
            problems += self.fat32_problems()
        self.walk(problems)
        leaked = [c for c in range(2, self.max_cluster + 1)
                  if self.fat(c) not in (0, self.bad) and c not in self.owner]
        if leaked:
            problems.append(f"{len(leaked)} clusters marked used that nothing reaches (leaked), "
                            f"first {leaked[:8]}")
        return problems

    def fat32_problems(self):
        """What is wrong with a FAT32 volume's own fields: the version, FAT
        mirroring, the root cluster, and FSInfo, whose free count may be
        unknown (0xFFFFFFFF) but not set and wrong, which fsck.fat reports."""
        out = []
        if self.fs_ver != 0:
            out.append(f"FAT32 version {self.fs_ver:#x}, not 0")
        if self.ext_flags & 0x80:
            out.append("FAT mirroring is off (ExtFlags bit 7): one FAT is live and the others stale")
        if not 2 <= self.root_cluster <= self.max_cluster:
            out.append(f"the root cluster {self.root_cluster} is outside the data region")
        fs = self.sectors(self.fsinfo_sector, 1)
        lead, struc, trail = (struct.unpack_from("<I", fs, o)[0] for o in (0, 484, 508))
        if (lead, struc, trail) != (0x41615252, 0x61417272, 0xAA550000):
            out.append("the FSInfo sector's signatures are wrong")
        else:
            count, hint = struct.unpack_from("<II", fs, 488)
            if count != 0xFFFFFFFF and count != self.free_clusters():
                out.append(f"FSInfo says {count} clusters are free; {self.free_clusters()} are")
            if hint != 0xFFFFFFFF and not 2 <= hint <= self.max_cluster:
                out.append(f"FSInfo's next-free hint {hint} is outside the data region")
        return out

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


def foreign_volumes(d, kind="FAT16"):
    """A volume another program made (mkfs.vfat formats it, mtools writes
    it), the files written to it, and the same volume damaged each way
    `check` must catch: (healthy image bytes, files, [(name, what, image
    bytes, the words a problem must hold, or None for a change that must
    still check clean)]). `d` is a scratch directory.

    A FAT32 volume (`kind`) is the smallest mkfs.vfat makes, with 512-byte
    clusters, and its first file is 33 MiB, so that the files after it start
    past cluster 65,535: the cluster's high half in each entry is then what
    finds them."""
    img = os.path.join(d, f"v{kind}.img")
    fat32 = kind == "FAT32"
    with open(img, "wb") as f:
        f.truncate((48 if fat32 else 8) << 20)
    subprocess.run(["mkfs.vfat", "-F", "32" if fat32 else "16", "-S", "512", "-s", "1", "-n", "TEST", img],
                   check=True, capture_output=True)
    files = {}
    if fat32:
        files["data/huge.bin"] = bytes(range(251)) * (33 * 4096 + 7)
    files.update({
        "data/chat/1_2/sessions/topic.md": b"hello\n" * 300,
        "data/chat/1_2/sessions/a-much-longer-session-name.reactions.jsonl": b"{}\n",
        "auth/1/api-key": b"0123456789abcdef",
        "EMPTY": b"",
        "data/big.bin": bytes(range(256)) * 400,
    })
    if fat32:
        # A root that outgrows its first cluster: FAT16's root cannot grow.
        for k in range(40):
            files[f"root-file-number-{k:03d}.txt"] = b"r%d" % k
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
    if v.kind != kind:
        raise Problem(f"mkfs.vfat made {v.kind}, not {kind}")

    def fat_set(img2, cluster, value, copies=None):
        for k in (copies if copies is not None else range(v.nfats)):
            at = v.base + (v.fat_start + k * v.fat_sectors) * SECTOR + cluster * v.entry_bytes
            struct.pack_into("<I" if fat32 else "<H", img2, at, value)

    def boot_set(img2, offset, fmt, value):
        struct.pack_into(fmt, img2, v.base + offset, value)

    def damage(change):
        img2 = bytearray(good)
        change(img2)
        return bytes(img2)

    end = 0x0FFFFFFF if fat32 else 0xFFFF
    big = v.chain(next(fc for p, isd, fc, s in v.walk([]) if p == "/data/big.bin"))
    topic = next(fc for p, isd, fc, s in v.walk([]) if p.endswith("topic.md"))
    free = next(c for c in range(2, v.max_cluster + 1) if v.fat(c) == 0)
    damages = [
        ("loop", "a loop", damage(lambda i: fat_set(i, big[3], big[1])), "loops"),
        ("free", "a free cluster in a chain", damage(lambda i: fat_set(i, big[2], 0)), "free cluster"),
        ("crossed", "a cross-link", damage(lambda i: fat_set(i, v.chain(topic)[-1], big[5])), "cross-linked"),
        ("leak", "a leak", damage(lambda i: fat_set(i, free, end)), "leaked"),
        ("short", "a short chain", damage(lambda i: fat_set(i, big[-2], end)), "needs"),
        ("fats", "FAT copies differing", damage(lambda i: fat_set(i, free, end, copies=[1])), "differs"),
    ]
    if fat32:
        fsinfo = v.fsinfo_sector * SECTOR
        damages += [
            ("fsinfo", "FSInfo's free count set and wrong",
             damage(lambda i: boot_set(i, fsinfo + 488, "<I", v.free_clusters() + 5)), "FSInfo says"),
            ("mirror", "FAT mirroring off", damage(lambda i: boot_set(i, 40, "<H", 0x80)), "mirroring"),
            ("version", "a FAT32 version not 0", damage(lambda i: boot_set(i, 42, "<H", 1)), "version"),
            ("rootclus", "a root cluster past the volume",
             damage(lambda i: boot_set(i, 44, "<I", v.max_cluster + 1)), "root cluster"),
            # The top four bits of an entry are reserved: set on a chain, they
            # change nothing, and the volume must still check clean.
            ("reserved", "the reserved top bits set on a chain",
             damage(lambda i: fat_set(i, big[1], big[2] | 0xF0000000)), None),
        ]
    return good, files, damages


def make_foreign(out):
    """Writes foreign_volumes' images into `out`, for fat16.zig's own check
    to judge: for FAT16 and for FAT32, healthy-mtools<kind>.img and
    damaged-mtools<kind>-<damage>.img. A change that must still check clean
    (FAT32's reserved bits) is named healthy- too."""
    missing = [t for t in MTOOLS if shutil.which(t) is None]
    if missing:
        print(f"cannot make them: {', '.join(missing)} not installed "
              "(apt-get install dosfstools mtools)", file=sys.stderr)
        return 2
    os.makedirs(out, exist_ok=True)
    with tempfile.TemporaryDirectory() as d:
        for kind, tag in (("FAT16", ""), ("FAT32", "32")):
            good, _, damages = foreign_volumes(d, kind)
            with open(os.path.join(out, f"healthy-mtools{tag}.img"), "wb") as f:
                f.write(good)
            for name, _, img, want in damages:
                state = "healthy" if want is None else "damaged"
                with open(os.path.join(out, f"{state}-mtools{tag}-{name}.img"), "wb") as f:
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
        for kind in ("FAT16", "FAT32"):
            good, files, damages = foreign_volumes(d, kind)
            v = Volume(good)
            problems = v.check()
            if problems:
                failures.append(f"{kind}: a clean mtools volume reads as inconsistent: {problems}")
            for path, data in files.items():
                try:
                    if v.read(path) != data:
                        failures.append(f"{kind} {path}: the bytes read back differ")
                except Problem as p:
                    failures.append(f"{kind} {path}: {p}")
            if kind == "FAT32":
                high = [p for p, isd, fc, s in v.walk([]) if fc > 0xFFFF]
                if not high:
                    failures.append("FAT32: no file starts past cluster 65,535, so the high half went untested")
                if len(v.chain(v.root_cluster)) < 2:
                    failures.append("FAT32: the root never outgrew its first cluster")
            for _, what, img, want in damages:
                try:
                    got = Volume(img).check()
                except Problem as p:
                    got = [str(p)]
                if want is None:
                    if got:
                        failures.append(f"{kind} {what}: must check clean, got {got}")
                elif not any(want in p for p in got):
                    failures.append(f"{kind} {what}: wanted a problem with {want!r}, got {got}")

    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: an mtools-written FAT16 and FAT32 volume each read back exactly and "
          "check clean, and each kind of damage is found (FAT32: files past cluster 65,535, a root "
          "of several clusters, and its own fields)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
