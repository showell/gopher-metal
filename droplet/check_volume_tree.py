#!/usr/bin/env python3
"""Lists everything in a directory tree that would not survive a copy onto
this machine's FAT16 volume. See MIGRATION.md.

    droplet/check_volume_tree.py <root>            # root holds data/ and auth/
    droplet/check_volume_tree.py <root> --json     # the same, one JSON object
    droplet/check_volume_tree.py --self-test       # builds a tree of every
                                                   # hazard and checks each is found

Plain Python, standard library only, no mounting: it reads the tree, and
judges each entry against two sets of limits.

  - **The copy**: Linux's vfat driver, which is what writes the volume
    (judge_gopher.build_disk: mkfs.vfat -F 16, mount, shutil.copytree).
  - **The reader**: this machine's own src/fat16.zig and src/io.zig, which
    are what read it afterwards.

Each finding says whether angry-gopher's own path builders can produce it.
An entry that matches none of them says so too: something other than the
application wrote it.

Exit 0 when nothing is found, 1 when something is, 2 on a usage error.
"""
import json
import os
import re
import stat
import sys
import tempfile
import time

# ── the limits ──────────────────────────────────────────────────────────────

# src/fat16.zig: the longest name it reads or writes (max_name).
MAX_NAME = 96
# The application's longest name: <sid>.reactions.jsonl at a session id of 80.
APP_LONGEST_NAME = 96
# src/io.zig: the longest path a File remembers (max_path).
MAX_PATH = 256
# src/fat16.zig: removeTree's recursion cap (max_tree_depth).
MAX_TREE_DEPTH = 16
# The VFAT long-name limit, in UTF-16 units; Linux refuses longer.
VFAT_MAX_NAME = 255
# A FAT16 file's size field is 32 bits.
MAX_FILE = (1 << 32) - 1
# FAT dates run from 1980-01-01 to 2107-12-31, in local time as Linux writes
# them; this machine reads them as UTC (mount with tz=UTC).
FIRST_DATE = 315532800      # 1980-01-01T00:00:00Z
LAST_DATE = 4354819199      # 2107-12-31T23:59:59Z
# Directory entries are 32 bytes. The root of a FAT16 volume is a fixed run:
# mkfs.vfat's default is 512 entries. Any other directory may grow to 65,536
# entries (2 MiB), past which fsck.fat calls it broken.
ROOT_SLOTS = 512
DIR_SLOTS = 65536
# Characters VFAT refuses in a long name, besides the control characters.
VFAT_FORBIDDEN = set('"*/:<>?\\|')
# The volume: chat.py asks for 2 GiB, as large as FAT16 goes; mkfs.vfat
# chooses 32 KiB clusters for it.
DEFAULT_VOLUME = 2 << 30
DEFAULT_CLUSTER = 32 << 10

# ── what the application builds ─────────────────────────────────────────────
#
# Read from angry-gopher's own code (roots.zig, chat_store.zig, users.zig,
# player.zig, storage.zig, docs_store.zig, chat_upload.zig, chat_state.zig):
#
#   - a session id matches validSessionID: [A-Za-z0-9]+(-[A-Za-z0-9]+)*, up to
#     80 characters, upper AND lower case, chosen in the URL;
#   - a channel name matches validChannelName: a letter, then up to 39 of
#     [A-Za-z0-9-];
#   - a doc slug matches validDocSlug: [a-z0-9]+(-[a-z0-9]+)*, up to 80;
#   - an upload is <16 random bytes in hex>.<ext>;
#   - user, player and conversation ids are digits ("p<n>" for players,
#     "<a>_<b>" for a conversation).
#
# So the application can produce, and only produce, names that differ only
# in case: two sessions "Plan" and "plan" in one conversation, two channels
# "Dev" and "dev". Its longest name, <sid>.reactions.jsonl at a sid of 80, is
# 96 characters, which fat16.zig holds (it held 64 until QUEUE item 8).
# It cannot produce a forbidden or non-ASCII character, a trailing dot or
# space, a symlink, a file over 4 GiB (Caddy caps an upload at 110 MB and a
# user at 1 GiB in all), or a path past MAX_PATH (its deepest is about 200).

SID = r"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*"
CHANNEL = r"[A-Za-z][A-Za-z0-9-]{0,39}"
SLUG = r"[a-z0-9]+(?:-[a-z0-9]+)*"
CONV = r"[0-9]+_[0-9]+"
ID = r"p?[0-9]+"
SESSION_FILE = rf"{SID}\.(?:md|count|lastauthor|reactions\.jsonl)"

APP_PATHS = [
    # (pattern, what it is, the long names it allows, case collisions it allows)
    (rf"data/chat/(?:{CONV}|channels/{CHANNEL})/sessions/{SESSION_FILE}",
     "a chat session's transcript or one of its sidecars", True, True),
    (rf"data/chat/(?:{CONV}|channels/{CHANNEL})/sessions/{SID}\.uploads(?:/[0-9a-f]{{32}}\.[A-Za-z0-9]+)?",
     "a session's uploads", True, True),
    (rf"data/chat/(?:{CONV}|channels/{CHANNEL})(?:/sessions)?", "a conversation", False, True),
    (rf"data/chat/channels/{CHANNEL}\.channel", "a channel's record", False, True),
    (rf"data/chat/users/{ID}/docs/{SLUG}\.md", "a user's doc", True, False),
    (rf"data/chat/users/{ID}(?:/docs|/last-sessions|/pinned-sessions)?", "a user's chat state", False, False),
    (rf"data/chat/users/{ID}/(?:code\.md|images\.md|last-conv)", "a user's chat state", False, False),
    (rf"data/chat/users/{ID}/(?:last|pinned)-sessions/(?:{CONV}|{CHANNEL})", "a user's chat state", False, True),
    (r"data/chat/_session_secret", "the session secret", False, False),
    (rf"data/users/{ID}(?:/last-seen|/upload-bytes)?", "a user's record", False, False),
    (rf"data/players/{ID}(?:/name)?", "a player", False, False),
    (r"data/players/next-id\.txt", "the player counter", False, False),
    (r"data/lynrummy(?:/.*)?", "game and puzzle sessions (storage.zig)", False, False),
    (rf"auth/{ID}(?:/[a-z_-]+)?", "an account", False, False),
    (r"auth/next-id\.txt", "the account counter", False, False),
    (r"(?:data|auth|data/chat|data/chat/channels|data/chat/users|data/users|data/players)",
     "a root the application keeps", False, False),
]
APP_PATTERNS = [(re.compile(p + r"\Z"), what, long_ok, case_ok) for p, what, long_ok, case_ok in APP_PATHS]


def app_kind(rel):
    """What the application uses this path for, or None if nothing it builds."""
    for rx, what, long_ok, case_ok in APP_PATTERNS:
        if rx.match(rel):
            return what, long_ok, case_ok
    return None


# ── the rules ───────────────────────────────────────────────────────────────

def vfat_name(name):
    """The name Linux's vfat driver stores: trailing dots and spaces dropped."""
    return name.rstrip(". ")


def needs_long(name):
    """Whether VFAT stores a long name: anything but an upper-case 8.3 name."""
    return not re.fullmatch(r"[A-Z0-9$%'\-_@~`!(){}^#&]{1,8}(\.[A-Z0-9$%'\-_@~`!(){}^#&]{1,3})?", name)


def slots(name):
    """Directory entries a name takes: the short one, and 13 characters a part."""
    units = len(name.encode("utf-16-le", "surrogatepass")) // 2
    return 1 + ((units + 12) // 13 if needs_long(name) else 0)


class Finding:
    def __init__(self, path, rule, why, app):
        self.path, self.rule, self.why, self.app = path, rule, why, app

    def as_dict(self):
        return {"path": self.path, "rule": self.rule, "why": self.why, "app": self.app}


def app_says(rel, rule):
    """Whether the application can produce this finding, in words."""
    kind = app_kind(rel)
    if kind is None:
        return "no: not a path angry-gopher builds; something else wrote it"
    what, long_ok, case_ok = kind
    # Its longest name is <sid>.reactions.jsonl at a sid of 80: 96, which
    # fat16.zig holds since max_name went from 64 to 96.
    if rule == "long-name" and long_ok and MAX_NAME < APP_LONGEST_NAME:
        return f"yes: {what}; session ids and doc slugs may be 80 characters"
    if rule == "case-collision" and case_ok:
        return f"yes: {what}; session ids and channel names keep their case"
    return f"no: {what}, whose names the application cannot make this way"


def check(root, volume=DEFAULT_VOLUME, cluster=DEFAULT_CLUSTER):
    """Every finding under `root`, and a summary."""
    findings = []
    used = 0
    files = dirs = 0
    root = os.path.abspath(root)

    def add(rel, rule, why):
        findings.append(Finding(rel or ".", rule, why, app_says(rel, rule)))

    for top, subdirs, names in os.walk(root, followlinks=False):
        rel_top = os.path.relpath(top, root)
        rel_top = "" if rel_top == "." else rel_top
        entries = sorted(subdirs + names)
        at_root = rel_top == ""

        # How many directory entries this directory takes on the volume.
        taken = sum(slots(n) for n in entries) + (0 if at_root else 2)
        limit = ROOT_SLOTS if at_root else DIR_SLOTS
        if taken > limit:
            add(rel_top, "directory-full",
                f"{taken} directory entries, more than the {limit} a "
                f"{'FAT16 root' if at_root else 'FAT directory'} holds")
        used += max(1, -(-taken * 32 // cluster)) * cluster if not at_root else 0

        # Names that become one name on FAT: case folded, trailing dots and
        # spaces dropped. shutil.copytree onto vfat writes the second over the
        # first, without an error.
        seen = {}
        for n in entries:
            key = vfat_name(n).casefold()
            if key in seen:
                rel = os.path.join(rel_top, n)
                add(rel, "case-collision",
                    f"the same name on FAT as {os.path.join(rel_top, seen[key])!r}: "
                    "the copy writes one over the other, silently")
            else:
                seen[key] = n

        for n in entries:
            full = os.path.join(top, n)
            rel = os.path.join(rel_top, n)
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                add(rel, "symlink", "FAT has no symlinks; shutil.copytree follows it "
                    "(a link to a directory copies that tree again; a dangling one fails the copy)")
                continue
            if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
                add(rel, "special-file", "not a file or a directory (a pipe, socket or device): FAT cannot hold it")
                continue

            bad = sorted({c for c in n if c in VFAT_FORBIDDEN or ord(c) < 0x20})
            if bad:
                add(rel, "forbidden-character", f"VFAT refuses {''.join(bad)!r} in a name: the copy fails")
            if vfat_name(n) != n:
                add(rel, "trailing-dot-or-space", "vfat drops trailing dots and spaces, so it is stored as "
                    f"{vfat_name(n)!r}")
            if any(ord(c) > 0x7F for c in n):
                add(rel, "non-ascii", "fat16.zig reads a character past ASCII as '?', so the file cannot be found by its name")
            units = len(n.encode("utf-16-le", "surrogatepass")) // 2
            if units > VFAT_MAX_NAME:
                add(rel, "long-name", f"{units} characters; VFAT holds 255, so the copy fails")
            elif len(os.fsencode(n)) > MAX_NAME:
                add(rel, "long-name", f"{len(os.fsencode(n))} bytes; fat16.zig reads and writes names up to {MAX_NAME}, "
                    "so on this machine it is found only under its 8.3 alias")

            if len(os.fsencode(rel)) > MAX_PATH:
                add(rel, "long-path", f"a path of {len(os.fsencode(rel))} bytes; io.zig opens paths up to {MAX_PATH}")
            depth = rel.count(os.sep) + 1
            if depth > MAX_TREE_DEPTH:
                add(rel, "deep", f"{depth} levels down; fat16.zig's removeTree stops at {MAX_TREE_DEPTH}")

            mtime = int(st.st_mtime)
            if mtime < FIRST_DATE or mtime > LAST_DATE:
                add(rel, "date", f"modified {time.strftime('%Y-%m-%d', time.gmtime(max(mtime, 0)))}: "
                    "FAT dates run from 1980 to 2107, so vfat clamps it and chat's 'recent' misplaces it")

            if stat.S_ISREG(st.st_mode):
                files += 1
                if st.st_size > MAX_FILE:
                    add(rel, "too-big", f"{st.st_size} bytes; a FAT16 file holds at most 4 GiB - 1")
                if st.st_nlink > 1:
                    add(rel, "hard-link", f"{st.st_nlink} names for one file: FAT stores each as its own copy")
                used += -(-st.st_size // cluster) * cluster
            else:
                dirs += 1

    # The volume: what every file and directory takes, whole clusters each,
    # against what is left after the FATs and the root (an estimate: two FATs
    # of 2 bytes a cluster, and the 512-entry root).
    clusters = volume // cluster
    usable = volume - 2 * clusters * 2 - ROOT_SLOTS * 32
    if used > usable:
        findings.append(Finding(".", "volume-full",
                                f"{used} bytes in whole {cluster}-byte clusters; the volume holds about {usable}",
                                "-"))
    summary = {"files": files, "directories": dirs, "bytes_on_volume": used,
               "volume_usable": usable, "cluster": cluster}
    return findings, summary


# ── the report ──────────────────────────────────────────────────────────────

def report(findings, summary, out=sys.stdout):
    print(f"{summary['files']} files, {summary['directories']} directories; "
          f"{summary['bytes_on_volume']} bytes on the volume in {summary['cluster']}-byte clusters, "
          f"of about {summary['volume_usable']}", file=out)
    if not findings:
        print("nothing found: every entry survives the copy and reads back on this machine", file=out)
        return
    by_rule = {}
    for f in findings:
        by_rule.setdefault(f.rule, []).append(f)
    for rule in sorted(by_rule):
        group = by_rule[rule]
        print(f"\n{rule}: {len(group)}", file=out)
        for f in group:
            print(f"  {f.path}\n      {f.why}\n      the app can produce this: {f.app}", file=out)


# ── the self-test ───────────────────────────────────────────────────────────

def self_test():
    """A tree with one of every hazard, and a clean tree: each rule must fire
    where it should and nowhere else."""
    with tempfile.TemporaryDirectory() as d:
        def put(rel, data=b"x", mtime=None):
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
            if mtime is not None:
                os.utime(p, (mtime, mtime))
            return p

        sess = "data/chat/1_2/sessions"
        put(f"{sess}/topic.md")                                   # clean
        put(f"{sess}/Plan.md")
        put(f"{sess}/plan.md")                                    # case-collision (app: yes)
        put(f"{sess}/{'a' * 80}.reactions.jsonl")                 # the app's longest: clean
        put(f"{sess}/{'a' * 81}.reactions.jsonl")                 # long-name (app: no)
        put("data/notes/what?.txt")                               # forbidden-character (app: no)
        put("data/notes/trailing.")                               # trailing-dot-or-space
        put("data/notes/café.txt")                           # non-ascii
        put("data/notes/old.txt", mtime=100)                      # date
        os.symlink("topic.md", os.path.join(d, sess, "link.md"))  # symlink
        put("data/notes/one.txt")
        os.link(os.path.join(d, "data/notes/one.txt"), os.path.join(d, "data/notes/two.txt"))  # hard-link x2
        deep = "data/" + "/".join(["d"] * 17) + "/f"
        put(deep)                                                 # deep
        put("data/" + "/".join(["x" * 60] * 5) + "/f")            # long-path
        put("auth/1/api-key")                                     # clean

        findings, _ = check(d)
        got = {}
        for f in findings:
            got.setdefault(f.rule, []).append(f)
        want = {"case-collision": 1, "long-name": 1, "forbidden-character": 1,
                "trailing-dot-or-space": 1, "non-ascii": 1, "date": 1, "symlink": 1,
                "hard-link": 2}
        # A deep or long path is also found at each directory on the way down
        # that is already too deep or too long: at least one, ending at "f".
        at_least = {"deep": deep, "long-path": "data/" + "/".join(["x" * 60] * 5) + "/f"}
        failed = []
        for rule, n in want.items():
            if len(got.get(rule, [])) != n:
                failed.append(f"{rule}: wanted {n}, got {[f.path for f in got.get(rule, [])]}")
        for rule, path in at_least.items():
            if path not in [f.path for f in got.get(rule, [])]:
                failed.append(f"{rule}: wanted {path}, got {[f.path for f in got.get(rule, [])]}")
        for rule in got:
            if rule not in want and rule not in at_least:
                failed.append(f"unexpected {rule}: {[f.path for f in got[rule]]}")
        if "yes" not in got["case-collision"][0].app:
            failed.append("a session case collision should be one the app can produce")
        if not got["long-name"][0].app.startswith("no"):
            failed.append("a name past the application's longest should be one it cannot produce")
        if not got["forbidden-character"][0].app.startswith("no"):
            failed.append("a forbidden character should be one the app cannot produce")

        clean, _ = check(os.path.join(d, "auth"))
        if clean:
            failed.append(f"a clean tree had findings: {[f.rule for f in clean]}")

    if failed:
        print("self-test FAILED:\n  " + "\n  ".join(failed))
        return 1
    print("self-test passed: every rule fires where it should and nowhere else")
    return 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    args = [a for a in argv[1:] if a != "--json"]
    if len(args) != 1 or not os.path.isdir(args[0]):
        print(__doc__, file=sys.stderr)
        return 2
    findings, summary = check(args[0])
    if "--json" in argv:
        json.dump({"summary": summary, "findings": [f.as_dict() for f in findings]}, sys.stdout, indent=2)
        print()
    else:
        report(findings, summary)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
