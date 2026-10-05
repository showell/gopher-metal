#!/usr/bin/env python3
"""**AN SDK.JSONL, JUDGED** the way Antithesis's triage report would: one
verdict per property (src/antithesis.zig), over every boot whose lines the
file holds. A property is its `id`; its sites are declared (`hit: false`) by
each boot, and a boot reports the first pass and the first failure of each.

    tools/antithesis_report.py <sdk.jsonl>

FAIL is a property the runs broke: an Always or AlwaysOrUnreachable seen
false, an Unreachable reached. MISS is one they never got to: a Sometimes
never true, a Reachable or an Always never reached. Antithesis fails both;
this exits 1 on a FAIL only, because a MISS is a gap in the runs, not a bug.
"""
import json
import sys

# The kinds a false condition breaks (Unreachable records its hit as false).
MUST_HOLD = {"Always", "AlwaysOrUnreachable", "Unreachable"}


def main(path):
    props = {}
    boots = 0
    with open(path) as f:
        for n, line in enumerate(f, 1):
            try:
                event = json.loads(line)
            except json.JSONDecodeError as e:
                sys.exit(f"{path}:{n}: not JSON ({e}): {line[:120]!r}")
            if "antithesis_sdk" in event:
                boots += 1
                continue
            a = event.get("antithesis_assert")
            if a is None:
                continue
            p = props.setdefault(a["id"], {
                "display": a["display_type"], "where": a["location"],
                "true": 0, "false": 0, "first_false": None,
            })
            if not a["hit"]:
                continue
            if a["condition"]:
                p["true"] += 1
            else:
                p["false"] += 1
                if p["first_false"] is None:
                    p["first_false"] = a.get("details")

    broken = 0
    rows = []
    for id_, p in props.items():
        d, t, f = p["display"], p["true"], p["false"]
        ok = {
            "Always": t + f > 0 and f == 0,
            "AlwaysOrUnreachable": f == 0,
            "Unreachable": f == 0,
            "Sometimes": t > 0,
            "Reachable": t > 0,
        }[d]
        missed = not ok and not (d in MUST_HOLD and f > 0)
        if not ok and not missed:
            broken += 1
        rows.append((ok, missed, id_, p))
    rows.sort(key=lambda r: (r[0], r[1], r[2]))

    print(f"{boots} boots, {len(props)} properties")
    for ok, missed, id_, p in rows:
        where = p["where"]
        verdict = "ok  " if ok else "MISS" if missed else "FAIL"
        print(f"{verdict} {p['display']:<19} {id_}  ({where['file']}:{where['begin_line']}; "
              f"{p['true']} boots true, {p['false']} false)")
        if p["first_false"] is not None and not ok:
            print(f"       first failure: {json.dumps(p['first_false'])}")
    return 1 if broken else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
