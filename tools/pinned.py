#!/usr/bin/env python3
"""**THE PINNED COPIES, AGAINST THEIR SOURCE** (metal-vmm QUEUE 197).

src/pinned/ holds files of zig-webbox that the unit tests need, byte for
byte, so tier 0 needs no zig-webbox checkout. This is tier 3's check that
each is still the same as the checkout's (`zig build pinned`, tier3.sh).

    python3 tools/pinned.py <zig-webbox>/src

Exit 0 when every copy is the same; 1, naming each that differs and the
command that brings it up to date; 2 when the checkout is not there.
"""
import os
import sys

# The copy here, and its source under zig-webbox's src/.
PINNED = {
    "src/pinned/webbox_body.zig": "body.zig",
    "src/pinned/webbox_wake.zig": "wake.zig",
}


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0])
        return 2
    src = argv[1]
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if not os.path.isdir(src):
        print(f"pinned: NOT checked: no zig-webbox sources at {src}")
        return 2
    differ = []
    for copy, source in PINNED.items():
        with open(os.path.join(here, copy), "rb") as f:
            mine = f.read()
        try:
            with open(os.path.join(src, source), "rb") as f:
                theirs = f.read()
        except FileNotFoundError:
            print(f"pinned: {copy}: its source {source} is gone from {src}")
            differ.append(copy)
            continue
        if mine != theirs:
            print(f"pinned: {copy} differs from {os.path.join(src, source)}: cp {os.path.join(src, source)} {copy}")
            differ.append(copy)
    if differ:
        return 1
    print(f"pinned: {len(PINNED)} file(s) the same as zig-webbox's")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
