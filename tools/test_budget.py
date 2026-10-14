#!/usr/bin/env python3
"""**TIER 0 STAYS FAST, OR FAILS** (metal-vmm QUEUE 198.11, B31's guard;
198.12: on CPU time).

Reads the records tools/cpu_time.py wrote for each test binary that ran
(`zig build test -Dtest-cpu-dir=<dir>`) and fails when one binary's CPU time
passes the per-binary budget, or all of them together pass the total, naming
each. CPU time, not wall time: under `-j` on the box's 2 cores, a binary's
wall time was as much the binaries beside it as its own work, and the same
tests passed here (4 cores) and failed there. CPU time is the test's own on
any number of cores; the total is what a box of N cores waits at least
total/N for. A slow test has a load-bearing reason to be slow, and that
reason is said where its count is cut (long.sh runs the big counts).

    python3 tools/test_budget.py <cpu dir> [per-binary seconds] [total seconds]
                                           (defaults 25 and 75)

Exit 0 within budget, 1 past it, 2 when no binary ran (all cached).
"""
import os
import sys


def records(directory):
    runs = []
    for name in sorted(os.listdir(directory)) if os.path.isdir(directory) else []:
        if not name.endswith(".cpu"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as f:
            first = f.readline().split(maxsplit=2)
        if len(first) == 3:
            runs.append((float(first[0]), float(first[1]), first[2].strip()))
    return runs


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[0])
        return 2
    each = float(argv[2]) if len(argv) > 2 else 25.0
    total_budget = float(argv[3]) if len(argv) > 3 else 75.0
    runs = records(argv[1])
    if not runs:
        print("test budget: NOT checked: no test binary ran (all cached?)")
        return 2
    total = sum(cpu for cpu, _, _ in runs)
    slowest = max(runs)
    print(f"test budget: {len(runs)} test binaries ran, {total:.0f} s of CPU in all (budget {total_budget:.0f}); "
          f"the most {slowest[0]:.1f} s ({slowest[2]}; budget {each:.0f} each)")
    for cpu, wall, name in sorted(runs, reverse=True)[:5]:
        print(f"test budget:   {cpu:6.1f} s CPU  {wall:6.1f} s wall  {name}")
    over = [(cpu, name) for cpu, _, name in runs if cpu > each]
    for cpu, name in sorted(over, reverse=True):
        print(f"test budget: OVER: {name}: {cpu:.1f} s of CPU")
    if total > total_budget:
        print(f"test budget: OVER: all binaries together: {total:.0f} s of CPU")
    return 1 if over or total > total_budget else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
