#!/usr/bin/env python3
"""Reads the ladder kernel's serial log and says, rung by rung, whether each
operation's cost stayed flat.

    judge_ladder.py <serial log>

A rung is FLAT when the last fifth of its run cost no more than CLIMB times
what the second and third tenths cost. The first tenth is left out: it pays
for caches filling, which is the opposite of the growth this looks for. Disk
requests per tenth must not climb either — a rung whose cost is flat only
because each operation did less would be flat for the wrong reason.
Exit 0 when every rung is flat, 1 otherwise."""
import re
import sys

CLIMB = 1.5
RUNG = re.compile(r"^rung (\w+): (\d+) ops; ns per op by tenth:((?: \d+)+); "
                  r"disk requests by tenth:((?: \d+)+)$", re.M)
RUNGS = ["cpu", "alloc", "read_same", "write_same", "write_spread", "append", "replace"]


def parse(log: str) -> dict:
    out = {}
    for m in RUNG.finditer(log):
        out[m.group(1)] = {
            "ops": int(m.group(2)),
            "ns": [int(x) for x in m.group(3).split()],
            "requests": [int(x) for x in m.group(4).split()],
        }
    return out


def verdict(r: dict):
    """(flat, the growth ratio) for one rung."""
    ns = r["ns"]
    early = (ns[1] + ns[2]) / 2
    late = (ns[8] + ns[9]) / 2
    ratio = late / early if early else float("inf")
    req = r["requests"]
    requests_climb = req[8] + req[9] > 1.5 * (req[1] + req[2]) + 2
    return ratio <= CLIMB and not requests_climb, ratio, requests_climb


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip())
        return 2
    log = open(sys.argv[1], "rb").read().decode("latin-1")
    rungs = parse(log)
    failed = 0
    for name in RUNGS:
        r = rungs.get(name)
        if r is None:
            print(f"FAIL {name:12} | the rung never reported")
            failed = 1
            continue
        flat, ratio, requests_climb = verdict(r)
        per_op = r["requests"][9] * 10 / r["ops"]
        line = (f"{name:12} | {r['ops']} ops, {r['ns'][1]:>9} ns -> {r['ns'][9]:>9} ns per op "
                f"(x{ratio:.2f}), {per_op:.2f} disk requests per op")
        if flat:
            print(f"PASS {line}")
        else:
            why = "disk requests climb" if requests_climb else f"cost climbs past x{CLIMB}"
            print(f"FAIL {line}: {why}")
            print(f"       ns by tenth: {' '.join(map(str, r['ns']))}")
            print(f"       requests by tenth: {' '.join(map(str, r['requests']))}")
            failed = 1
    return failed


if __name__ == "__main__":
    raise SystemExit(main())
