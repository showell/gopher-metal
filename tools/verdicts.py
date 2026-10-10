#!/usr/bin/env python3
"""**WHICH CODE WAS JUDGED, AND WHAT THE JUDGES SAID.** A release is an image
of two repos' code: this one's, and angry-gopher's server as `port.sh` copied
it. A gate that passed on other code than the image carries has proved
nothing about the image, and nothing used to say which code a gate judged.
So:

- `port.sh` writes a **stamp** into the ported tree: a hash of the content
  of every angry-gopher file an image reads (`served_files`: the server's
  source, the assets its build.zig embeds, pages/ and gallery/), and its
  commit for the reader. A verdict is keyed by that content and by this
  repo's and the SDK's commits (B16), so a README commit in angry-gopher
  leaves a verdict standing and an SDK change does not.
- `gates.sh` and `long.sh` call `pair`, which prints the two commits they
  are about to judge and refuses a port that is not angry-gopher's HEAD.
  At the end they call `record`, which keeps their verdict for that pair.
- `droplet/chat.py` calls `require`, which refuses to build an image unless
  both trees are clean and both verdicts are PASS for exactly that pair.

    tools/verdicts.py stamp                  (port.sh)
    tools/verdicts.py pair                   (gates.sh, long.sh: print, or refuse)
    tools/verdicts.py ids                    (the pair, as the run starts)
    tools/verdicts.py fresh                  (build.zig's check: "fresh", or why not)
    VERDICT_PAIR="<ids>" tools/verdicts.py record gates|long PASS|FAIL

**A VERDICT IS FOR THE CODE THE RUN STARTED ON.** A run takes `ids` first;
`record` keeps nothing if either tree has moved since, because the run then
judged a mixture.

`RELEASE_UNGATED=1` lets `require` pass anyway, for an emergency fix, and
says so loudly; nothing else bypasses it.

Verdicts live in `~/build/gopher-metal/verdicts/` (GATES_VERDICT_DIR), one
file per tier and pair, so a run in another worktree of the same commit
counts.
"""
import hashlib
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
PORT = os.environ.get("GOPHER_PORT", os.path.expanduser("~/build/gopher-metal/port"))
STAMP = os.path.join(PORT, "PORTED_FROM")
VERDICT_DIR = os.environ.get("GATES_VERDICT_DIR", os.path.expanduser("~/build/gopher-metal/verdicts"))
SDK = os.environ.get("COVERAGE_SDK", os.path.join(os.path.dirname(ROOT), "zig-coverage-sdk"))
TIERS = ("gates", "long")

# **WHAT AN IMAGE READS FROM ANGRY-GOPHER** (metal-vmm QUEUE B16): port.sh
# copies zig-server/src; the kernel embeds the assets zig-server/build.zig's
# table names (many generated, so not in git); droplet/chat.py stages pages/
# and gallery/. A verdict is keyed by those files' content, so a commit that
# touches none of them (a README) leaves it standing, and a rebuilt asset
# that git cannot see does not.
SERVED_DIRS = ("zig-server/src", "pages", "gallery")
ASSET_ROW = re.compile(r'\.\{\s*\.name\s*=\s*"([^"]+)"\s*,\s*\.path\s*=\s*"([^"]+)"\s*\}')


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()


def commit_of(repo: str, paths: tuple = ()) -> str:
    """HEAD, with `-dirty` when tracked files under `paths` (all, if none)
    differ from it. Untracked files do not count: they are not built."""
    head = git(repo, "rev-parse", "HEAD")
    changed = git(repo, "status", "--porcelain", "--untracked-files=no", "--", *paths)
    return head + ("-dirty" if changed else "")


def served_files() -> list:
    """Every angry-gopher file an image reads, as paths from its root."""
    files = []
    for d in SERVED_DIRS:
        for dirpath, _, names in os.walk(os.path.join(GOPHER_ROOT, d)):
            for n in names:
                files.append(os.path.relpath(os.path.join(dirpath, n), GOPHER_ROOT))
    build = os.path.join(GOPHER_ROOT, "zig-server", "build.zig")
    files.append("zig-server/build.zig")
    for _, path in ASSET_ROW.findall(open(build).read()):
        files.append(os.path.normpath(os.path.join("zig-server", path)))
    return sorted(set(files))


def content_id() -> str:
    """`content-` and a hash of every served file's path and bytes (a file
    named but not there counts as missing)."""
    h = hashlib.sha256()
    for rel in served_files():
        h.update(rel.encode() + b"\0")
        try:
            with open(os.path.join(GOPHER_ROOT, rel), "rb") as f:
                h.update(hashlib.sha256(f.read()).digest())
        except FileNotFoundError:
            h.update(b"missing")
    return "content-" + h.hexdigest()[:16]


def ours_id() -> str:
    """This repo's commit, and the SDK's it builds against (by path)."""
    return commit_of(ROOT) + ".sdk-" + commit_of(SDK)


def stamp() -> int:
    theirs = content_id()
    commit = commit_of(GOPHER_ROOT)
    with open(STAMP, "w") as f:
        f.write(theirs + "\n" + commit + "\n")
    print(f"ported angry-gopher {short(commit)} ({theirs})")
    return 0


def ported() -> str:
    """The stamp's content id; empty if there is no stamp, or an old one."""
    try:
        with open(STAMP) as f:
            first = f.readline().strip()
    except FileNotFoundError:
        return ""
    return first if first.startswith("content-") else ""


def current_pair() -> tuple:
    """(this repo's and the SDK's commits, the ported angry-gopher content),
    or an error."""
    ours = ours_id()
    theirs = ported()
    if not theirs:
        return ours, None, f"no stamp (or one from before B16) at {STAMP}: run ./port.sh"
    now = content_id()
    if theirs != now:
        return ours, theirs, f"the port is angry-gopher {theirs}, but what it serves is now {now}: run ./port.sh"
    return ours, theirs, None


def short(c: str) -> str:
    if ".sdk-" in c:
        a, b = c.split(".sdk-", 1)
        return short(a) + " with the SDK at " + short(b)
    if c.startswith("content-"):
        return c
    return c[:12] + ("-dirty" if c.endswith("-dirty") else "")


def pair() -> int:
    ours, theirs, problem = current_pair()
    if problem:
        print(f"REFUSING: {problem}")
        return 2
    print(f"judging gopher-metal {short(ours)} with angry-gopher {short(theirs)}")
    return 0


def verdict_path(tier: str, ours: str, theirs: str) -> str:
    return os.path.join(VERDICT_DIR, f"{tier}-{ours}-{theirs}")


def ids() -> int:
    ours, theirs, problem = current_pair()
    if problem:
        print(f"REFUSING: {problem}", file=sys.stderr)
        return 2
    print(f"{ours} {theirs}")
    return 0


def record(tier: str, outcome: str) -> int:
    if tier not in TIERS or outcome not in ("PASS", "FAIL"):
        print(f"usage: verdicts.py record {'|'.join(TIERS)} PASS|FAIL")
        return 2
    ours, theirs, problem = current_pair()
    if problem:
        print(f"no verdict kept: {problem}")
        return 2
    started = os.environ.get("VERDICT_PAIR", "")
    if started != f"{ours} {theirs}":
        print(f"no verdict kept: the code is not what the run started on ({started or 'no VERDICT_PAIR'})")
        return 2
    os.makedirs(VERDICT_DIR, exist_ok=True)
    with open(verdict_path(tier, ours, theirs), "w") as f:
        f.write(f"{outcome} {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
    print(f"verdict kept: {tier} {outcome} for gopher-metal {short(ours)} with angry-gopher {short(theirs)}")
    return 0


def require() -> list:
    """Why this tree may not become an image; empty when it may."""
    ours, theirs, problem = current_pair()
    if problem:
        return [problem]
    why = []
    here, sdk = ours.split(".sdk-", 1)
    if here.endswith("-dirty"):
        why.append("gopher-metal has uncommitted changes")
    if sdk.endswith("-dirty"):
        why.append("zig-coverage-sdk has uncommitted changes")
    # An image is built from committed code: what it serves from angry-gopher
    # (the content id says which bytes; this says they are committed ones).
    # Generated assets are not in git, and are not asked to be.
    if git(GOPHER_ROOT, "status", "--porcelain", "--untracked-files=no", "--", *SERVED_DIRS, "zig-server/build.zig"):
        why.append("angry-gopher's served files have uncommitted changes")
    for tier in TIERS:
        try:
            with open(verdict_path(tier, ours, theirs)) as f:
                said = f.read().split()
        except FileNotFoundError:
            said = []
        if not said:
            why.append(f"no {tier} verdict for this pair: run ./{tier}.sh")
        elif said[0] != "PASS":
            why.append(f"{tier}.sh said {said[0]} for this pair ({said[1] if len(said) > 1 else '?'})")
    return why


def fresh() -> int:
    """**IS THE PORT ANGRY-GOPHER AS IT IS NOW?** (metal-vmm 146(a)): build.zig
    type-checks gopher.elf against the port only then. The port's asset list
    is port.sh's gen/assets.zig, but the files are read from the live
    checkout, so a port older than the checkout fails gopher-metal's tests
    for no fault of gopher-metal's. Prints `fresh`, or why not; exits 0
    either way, so build.zig reads the answer from the output."""
    print(freshness())
    return 0


def freshness() -> str:
    """`fresh`, or why not. Only the port and the checkout: not this repo's
    or the SDK's commits, which `pair` adds and a check of the port needs
    no more than it needs a reason to fail on them."""
    if not os.path.isdir(os.path.join(GOPHER_ROOT, "zig-server")):
        return f"no angry-gopher checkout at {GOPHER_ROOT}"
    theirs = ported()
    if not theirs:
        return f"no stamp (or one from before B16) at {STAMP}: run ./port.sh"
    now = content_id()
    if theirs != now:
        return f"the port is angry-gopher {theirs}, but what it serves is now {now}: run ./port.sh"
    # **AND THIS TREE'S ASSET LIST IS THAT CHECKOUT'S** (146(a)'s review):
    # port.sh writes gen/assets.zig in whichever tree it ran from, and the
    # stamp sits in the shared port, so another worktree, or a branch whose
    # committed list predates an asset's rename, can hold a list the
    # checkout no longer matches.
    try:
        with open(os.path.join(GOPHER_ROOT, "zig-server", "build.zig")) as f:
            table = ASSET_ROW.findall(f.read())
        with open(os.path.join(ROOT, "gen", "assets.zig")) as f:
            listed = ASSET_ROW.findall(f.read())
    except FileNotFoundError as e:
        return f"cannot compare the asset lists: {e.filename} is missing"
    if table != listed:
        return "this tree's gen/assets.zig is not the checkout's asset table: run ./port.sh here"
    return "fresh"


def main() -> int:
    args = sys.argv[1:]
    if args == ["stamp"]:
        return stamp()
    if args == ["pair"]:
        return pair()
    if args == ["ids"]:
        return ids()
    if args == ["fresh"]:
        return fresh()
    if len(args) == 3 and args[0] == "record":
        return record(args[1], args[2])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
