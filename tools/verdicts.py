#!/usr/bin/env python3
"""**WHICH CODE WAS JUDGED, AND WHAT THE JUDGES SAID.** A release is an image
of two repos' code: this one's, and angry-gopher's server as `port.sh` copied
it. A gate that passed on other code than the image carries has proved
nothing about the image, and nothing used to say which code a gate judged.
So:

- `port.sh` writes a **stamp** into the ported tree: angry-gopher's commit,
  and whether its `zig-server/` had uncommitted changes.
- `gates.sh` and `long.sh` call `pair`, which prints the two commits they
  are about to judge and refuses a port that is not angry-gopher's HEAD.
  At the end they call `record`, which keeps their verdict for that pair.
- `droplet/chat.py` calls `require`, which refuses to build an image unless
  both trees are clean and both verdicts are PASS for exactly that pair.

    tools/verdicts.py stamp                  (port.sh)
    tools/verdicts.py pair                   (gates.sh, long.sh: print, or refuse)
    tools/verdicts.py ids                    (the pair, as the run starts)
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
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
PORT = os.environ.get("GOPHER_PORT", os.path.expanduser("~/build/gopher-metal/port"))
STAMP = os.path.join(PORT, "PORTED_FROM")
VERDICT_DIR = os.environ.get("GATES_VERDICT_DIR", os.path.expanduser("~/build/gopher-metal/verdicts"))
TIERS = ("gates", "long")


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()


def commit_of(repo: str, paths: tuple = ()) -> str:
    """HEAD, with `-dirty` when tracked files under `paths` (all, if none)
    differ from it. Untracked files do not count: they are not built."""
    head = git(repo, "rev-parse", "HEAD")
    changed = git(repo, "status", "--porcelain", "--untracked-files=no", "--", *paths)
    return head + ("-dirty" if changed else "")


def stamp() -> int:
    ported = commit_of(GOPHER_ROOT, ("zig-server",))
    with open(STAMP, "w") as f:
        f.write(ported + "\n")
    print(f"ported angry-gopher {ported[:12]}{'-dirty' if ported.endswith('-dirty') else ''}")
    return 0


def ported() -> str:
    try:
        with open(STAMP) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


def current_pair() -> tuple:
    """(this repo's commit, the ported angry-gopher commit), or an error."""
    ours = commit_of(ROOT)
    theirs = ported()
    if not theirs:
        return ours, None, f"no stamp at {STAMP}: run ./port.sh"
    now = commit_of(GOPHER_ROOT, ("zig-server",))
    if theirs != now:
        return ours, theirs, (f"the port is angry-gopher {theirs[:12]}, but angry-gopher is now {now[:12]}"
                              f"{' (with uncommitted changes)' if now.endswith('-dirty') else ''}: run ./port.sh")
    return ours, theirs, None


def short(c: str) -> str:
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
    if ours.endswith("-dirty"):
        why.append("gopher-metal has uncommitted changes")
    if theirs.endswith("-dirty"):
        why.append("angry-gopher's zig-server has uncommitted changes")
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


def main() -> int:
    args = sys.argv[1:]
    if args == ["stamp"]:
        return stamp()
    if args == ["pair"]:
        return pair()
    if args == ["ids"]:
        return ids()
    if len(args) == 3 and args[0] == "record":
        return record(args[1], args[2])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
