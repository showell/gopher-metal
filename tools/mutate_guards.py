#!/usr/bin/env python3
"""Breaks the machine's guard rails one at a time and reports every break
that `zig build test` does not notice: tools/mutate_tcp.py's idea, for the
rest of what stands between data and the machine.

    tools/mutate_guards.py                 every mutant
    tools/mutate_guards.py NAME...         just these (a file's name, as
                                           fat16, runs all of that file's)
    tools/mutate_guards.py --list          their names

The guards: io.zig's (`.` and `..` refused, nothing written outside the data
folders, the site cache's bounds), fat16.zig's refusals (a boot sector it
cannot trust, a chain that leaves the data, the directory and name bounds,
the 4 GiB file), and the two records a restart trusts from the boot before
(kept_log.zig's header, restart.zig's CMOS record and back-off).

A mutant is **killed** when a test fails or panics, and **survives** when
every test passes: then the guard it broke is one nothing checks. One that
does not compile, or whose text is no longer in its file, is reported
apart. Each is applied to the committed file, built in a cache of its own
(removed after), and the file is put back with `git checkout`; it refuses
to start over uncommitted changes in a file it would touch.

Known equivalent, so not listed: fat16's `sectors_per_fat == 0`, which the
FAT-too-short check after it refuses with the same error.

Not part of gates.sh: a mutant rebuilds the host tests from nothing, fat16's
in ReleaseSafe, a minute or two each. Exit 0 when every mutant is killed.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (file under src/, name, old text, new text). The old text occurs once.
MUTANTS = [
    ('io', 'data dirs matched by case',
     'if (std.ascii.eqlIgnoreCase(dir, first)) return .data;',
     'if (std.mem.eql(u8, dir, first)) return .data;'),
    ('io', 'a write outside the data dirs',
     'if (place == .site and data_dirs.len != 0) {',
     'if (false) {'),
    ('io', 'cached before keepData',
     'return data_dirs.len != 0 and placeOf(path) == .site;',
     'return placeOf(path) == .site;'),
    ('io', 'cache found by case',
     'if (std.ascii.eqlIgnoreCase(self.names[i][0..self.name_lens[i]], path))',
     'if (std.mem.eql(u8, self.names[i][0..self.name_lens[i]], path))'),
    ('io', 'cache keeps a file past largest',
     'if (self.count >= slots or path.len > max_path or bytes.len > largest) return;',
     'if (self.count >= slots or path.len > max_path) return;'),
    ('io', '. and .. routed',
     'if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;',
     '_ = part;'),
    ('io', 'data files cached',
     'return data_dirs.len != 0 and placeOf(path) == .site;',
     '_ = path;\n    return data_dirs.len != 0;'),
    ('io', 'cache past capacity',
     'if (self.used + bytes.len > capacity) return;',
     'if (false) return;'),
    ('fat16', 'TooBig: buf.len < self.fatBytes()',
     'if (buf.len < self.fatBytes()) return Error.TooBig;',
     'if (false and (buf.len < self.fatBytes())) return Error.TooBig;'),
    ('fat16', 'BadBootSector: b[510] != 0x55 or b[511] != 0xAA',
     'if (b[510] != 0x55 or b[511] != 0xAA) return Error.BadBootSector;',
     'if (false and (b[510] != 0x55 or b[511] != 0xAA)) return Error.BadBootSector;'),
    ('fat16', 'NotFat16: bytes_per_sector != sector_size',
     'if (bytes_per_sector != sector_size) return Error.NotFat16;',
     'if (false and (bytes_per_sector != sector_size)) return Error.NotFat16;'),
    ('fat16', 'BadBootSector: sectors_per_cluster == 0 or sectors_per_cluster > 128',
     'if (sectors_per_cluster == 0 or sectors_per_cluster > 128) return Error.BadBootSector;',
     'if (false and (sectors_per_cluster == 0 or sectors_per_cluster > 128)) return Error.BadBootSector;'),
    ('fat16', 'BadBootSector: reserved == 0 or num_fats == 0 or num_fats > 2',
     'if (reserved == 0 or num_fats == 0 or num_fats > 2) return Error.BadBootSector;',
     'if (false and (reserved == 0 or num_fats == 0 or num_fats > 2)) return Error.BadBootSector;'),
    ('fat16', 'VolumeTooLarge: @as(u64, start_lba) + total > 0xFFFF_FFFF',
     'if (@as(u64, start_lba) + total > 0xFFFF_FFFF) return Error.VolumeTooLarge;',
     'if (false and (@as(u64, start_lba) + total > 0xFFFF_FFFF)) return Error.VolumeTooLarge;'),
    ('fat16', 'BadBootSector: total == 0 or data_start >= total',
     'if (total == 0 or data_start >= total) return Error.BadBootSector;',
     'if (false and (total == 0 or data_start >= total)) return Error.BadBootSector;'),
    ('fat16', 'NotFat16: clusters < 4085',
     'if (clusters < 4085) return Error.NotFat16;',
     'if (false and (clusters < 4085)) return Error.NotFat16;'),
    ('fat16', 'TooManyClusters: kind == .fat32 and clusters > 0x0FFF_FFF5',
     'if (kind == .fat32 and clusters > 0x0FFF_FFF5) return Error.TooManyClusters;',
     'if (false and (kind == .fat32 and clusters > 0x0FFF_FFF5)) return Error.TooManyClusters;'),
    ('fat16', 'BadBootSector: root_entries == 0',
     '.fat16 => if (root_entries == 0) return Error.BadBootSector,',
     '.fat16 => if (false and (root_entries == 0)) return Error.BadBootSector,'),
    ('fat16', 'BadBootSector: root_entries != 0 or fat16_sectors != 0',
     'if (root_entries != 0 or fat16_sectors != 0) return Error.BadBootSector;',
     'if (false and (root_entries != 0 or fat16_sectors != 0)) return Error.BadBootSector;'),
    ('fat16', 'NotMirrored: le16(b[40..42]) & 0x80 != 0',
     'if (le16(b[40..42]) & 0x80 != 0) return Error.NotMirrored;',
     'if (false and (le16(b[40..42]) & 0x80 != 0)) return Error.NotMirrored;'),
    ('fat16', 'FatVersion: le16(b[42..44]) != 0',
     'if (le16(b[42..44]) != 0) return Error.FatVersion;',
     'if (false and (le16(b[42..44]) != 0)) return Error.FatVersion;'),
    ('fat16', 'BadRoot: root_cluster < 2 or root_cluster > clusters + 1',
     'if (root_cluster < 2 or root_cluster > clusters + 1) return Error.BadRoot;',
     'if (false and (root_cluster < 2 or root_cluster > clusters + 1)) return Error.BadRoot;'),
    ('fat16', 'BadBootSector: @as(u64, sectors_per_fat) * (sector_size / entry_bytes) < @a',
     'if (@as(u64, sectors_per_fat) * (sector_size / entry_bytes) < @as(u64, clusters) + 2) return Error.BadBootSector;',
     'if (false and (@as(u64, sectors_per_fat) * (sector_size / entry_bytes) < @as(u64, clusters) + 2)) return Error.BadBootSector;'),
    ('fat16', 'BadChain: !self.inData(v)',
     'if (!self.inData(v)) return Error.BadChain;',
     'if (false and (!self.inData(v))) return Error.BadChain;'),
    ('fat16', 'BadChain: cluster == self.seen',
     'if (cluster == self.seen) return Error.BadChain;',
     'if (false and (cluster == self.seen)) return Error.BadChain;'),
    ('fat16', 'BadChain: first != 0 and !vol.inData(first)',
     'if (first != 0 and !vol.inData(first)) return Error.BadChain;',
     'if (false and (first != 0 and !vol.inData(first))) return Error.BadChain;'),
    ('fat16', 'DirectoryFull: (end.clusters + 1) * per_cluster > max_dir_entries',
     'if ((end.clusters + 1) * per_cluster > max_dir_entries) return Error.DirectoryFull;',
     'if (false and ((end.clusters + 1) * per_cluster > max_dir_entries)) return Error.DirectoryFull;'),
    ('fat16', 'BadName: given.len == 0 or given.len > max_name',
     'if (given.len == 0 or given.len > max_name) return Error.BadName;',
     'if (false and (given.len == 0 or given.len > max_name)) return Error.BadName;'),
    ('fat16', 'TooBig: bytes.len > 0xFFFF_FFFF',
     'if (bytes.len > 0xFFFF_FFFF) return Error.TooBig;',
     'if (false and (bytes.len > 0xFFFF_FFFF)) return Error.TooBig;'),
    ('fat16', 'removeTree swallows a failed open',
     "        const entry = self.open(path) catch |e| switch (e) {\n            Error.NotFound => return,\n            else => return e,\n        };",
     "        const entry = self.open(path) catch return;"),
    ('fat16', 'removeTree swallows its last remove',
     "        try self.removeTreeAt(entry.first_cluster, 0);\n        try self.remove(path);",
     "        try self.removeTreeAt(entry.first_cluster, 0);\n        self.remove(path) catch {};"),
    ('fat16', 'append counts clusters from the size',
     "            if (need > end.clusters) {\n                const extra = try self.allocChain(need - end.clusters);",
     "            if (need > have) {\n                const extra = try self.allocChain(need - have);"),
    ('kept_log', 'magic not checked',
     'return h.magic == magic and h.check == h.sum() and h.head < slot_bytes and',
     'return h.check == h.sum() and h.head < slot_bytes and'),
    ('kept_log', 'checksum not checked',
     'return h.magic == magic and h.check == h.sum() and h.head < slot_bytes and',
     'return h.magic == magic and h.head < slot_bytes and'),
    ('kept_log', 'head past the slot',
     'return h.magic == magic and h.check == h.sum() and h.head < slot_bytes and',
     'return h.magic == magic and h.check == h.sum() and'),
    ('kept_log', 'head and total disagree',
     '(h.total >= slot_bytes or h.head == h.total);',
     'true;'),
    ('kept_log', 'the older slot chosen',
     'if (h.boot > headerAt(region, b).boot) best = s;',
     'if (h.boot < headerAt(region, b).boot) best = s;'),
    ('kept_log', 'this boot writes over the last',
     'const slot: u1 = if (best) |b| ~b else 0;',
     'const slot: u1 = if (best) |b| b else 0;'),
    ('restart', 'magic not checked',
     'if (b[0] != magic or b[7] != checksum(b[0..7]) or b[1] == 0) return null;',
     'if (b[7] != checksum(b[0..7]) or b[1] == 0) return null;'),
    ('restart', 'checksum not checked',
     'if (b[0] != magic or b[7] != checksum(b[0..7]) or b[1] == 0) return null;',
     'if (b[0] != magic or b[1] == 0) return null;'),
    ('restart', 'a count of 0 taken',
     'if (b[0] != magic or b[7] != checksum(b[0..7]) or b[1] == 0) return null;',
     'if (b[0] != magic or b[7] != checksum(b[0..7])) return null;'),
    ('restart', 'count never resets after an hour',
     'if (n < then or n - then > count_resets_after_minutes) break :blk 1;',
     'if (n < then) break :blk 1;'),
    ('restart', 'a clock gone back counted in a row',
     'if (n < then or n - then > count_resets_after_minutes) break :blk 1;',
     'if (n - then > count_resets_after_minutes) break :blk 1;'),
    ('restart', 'count wraps to 0',
     'break :blk p.count +| 1;',
     'break :blk p.count +% 1;'),
    ('restart', 'no wait at the 4th',
     '        4 => 60,',
     '        4 => 0,'),
    ('restart', 'a sum that equal bytes pass',
     'var s: u8 = 0x5A;',
     'var s: u8 = 0;'),
]


def path_of(file: str) -> str:
    return f"src/{file}.zig"


def run(mutants) -> int:
    files = sorted({m[0] for m in mutants})
    dirty = subprocess.run(["git", "status", "--porcelain", "--", *map(path_of, files)],
                           cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if dirty:
        print(f"mutate_guards: uncommitted changes in a file it would touch; commit or stash them first:\n{dirty}")
        return 2
    counts = {"killed": 0, "SURVIVED": 0, "did not compile": 0, "STALE": 0}
    try:
        for file, name, old, new in mutants:
            p = os.path.join(ROOT, path_of(file))
            text = open(p).read()
            if text.count(old) != 1:
                verdict = "STALE"
            else:
                open(p, "w").write(text.replace(old, new))
                cache = tempfile.mkdtemp(prefix="mutate-guards-")
                try:
                    r = subprocess.run(["zig", "build", "test", "--cache-dir", cache], cwd=ROOT,
                                       capture_output=True, text=True, timeout=1800)
                finally:
                    subprocess.run(["git", "checkout", "--", path_of(file)], cwd=ROOT, check=True)
                    shutil.rmtree(cache, ignore_errors=True)
                out = r.stdout + r.stderr
                if r.returncode == 0:
                    verdict = "SURVIVED"
                elif "failed:" in out or "failed without output" in out or "terminated with signal" in out or "panic" in out:
                    verdict = "killed"
                else:
                    verdict = "did not compile"
            counts[verdict] += 1
            print(f"{verdict:16} {file}:{name}", flush=True)
    finally:
        subprocess.run(["git", "checkout", "--", *map(path_of, files)], cwd=ROOT)
    print("mutate_guards: " + ", ".join(f"{n} {k}" for k, n in counts.items()))
    return 0 if counts["SURVIVED"] == 0 and counts["STALE"] == 0 else 1


def main(argv) -> int:
    if argv[1:] == ["--list"]:
        for file, name, _, _ in MUTANTS:
            print(f"{file}:{name}")
        return 0
    asked = argv[1:]
    chosen = [m for m in MUTANTS if not asked or m[0] in asked or m[1] in asked or f"{m[0]}:{m[1]}" in asked]
    if asked and not chosen:
        print(f"mutate_guards: no mutant or file named {' '.join(asked)}; --list names them")
        return 2
    return run(chosen)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
