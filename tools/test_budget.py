#!/usr/bin/env python3
"""**TIER 0 STAYS FAST, OR FAILS** (metal-vmm QUEUE 198.11, B31's guard).

Reads `zig build test --summary all` and fails when any test binary's RUN
(not its compile, which a cold cache makes minutes) took longer than the
budget, naming each. A slow test has a load-bearing reason to be slow, and
that reason is said where its count is cut (long.sh runs the big counts).

    python3 tools/test_budget.py <summary file> [seconds]   (default 45)

Exit 0 within budget, 1 past it, 2 when the summary has no run lines.
"""
import re
import sys


def seconds(text):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(ns|us|ms|s|m|h)", text)
    if not m:
        return None
    n, unit = float(m.group(1)), m.group(2)
    # zig's summary rounds down to its unit: "1m" is at least a minute.
    return n * {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600}[unit]


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[0])
        return 2
    budget = float(argv[2]) if len(argv) > 2 else 45.0
    runs = []
    for line in open(argv[1], encoding="utf-8", errors="replace"):
        line = re.sub(r"^[|+\- ]*", "", line.rstrip())
        if not line.startswith("run test"):
            continue
        tokens = line.split()
        # The time is the token before MaxRSS; a cached run has none.
        for i, tok in enumerate(tokens):
            if tok.startswith("MaxRSS") and i > 0:
                t = seconds(tokens[i - 1])
                if t is not None:
                    runs.append((t, line[: line.find(tokens[i - 1])].strip()))
                break
    if not runs:
        print("test budget: NOT checked: no run times in the summary (all cached?)")
        return 2
    over = [(t, name) for t, name in runs if t > budget]
    slowest = max(runs)
    print(f"test budget: {len(runs)} test binaries run, the slowest {slowest[0]:.0f} s ({slowest[1]}); budget {budget:.0f} s each")
    for t, name in sorted(over, reverse=True):
        print(f"test budget: OVER: {name}: {t:.0f} s")
    return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
