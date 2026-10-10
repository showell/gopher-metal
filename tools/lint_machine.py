#!/usr/bin/env python3
"""**ONLY `fire` CHANGES A MACHINE'S STATE** (src/machine.zig, metal-vmm QUEUE
item 140). Zig has no private fields, so this is the guard. Run by
`zig build test`.

    tools/lint_machine.py [src]

Outside src/machine.zig it refuses:
- an assignment to `machine_state`, the state's field;
- `startingAt(`, a machine made at a given state, outside a `test` block;
- an assignment to a field whose type is a machine (`fin: FinMachine`),
  outside a `test` block: a whole machine replaced is a state chosen.

A machine is any `const X = machine.Machine(` declaration in src. Exits 0
when clean, 1 with each refusal as file:line.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(HERE), "src")


def zig_files():
    for d, _, names in os.walk(SRC):
        for n in sorted(names):
            if n.endswith(".zig") and n != "machine.zig":
                yield os.path.join(d, n)


def strip_comment(line):
    # Good enough for this code: no "//" inside the strings these rules look at.
    i = line.find("//")
    return line if i < 0 else line[:i]


def test_lines(lines):
    """The 0-based lines inside a `test "..." {` block, by brace depth."""
    inside = set()
    depth = None
    for i, line in enumerate(lines):
        code = strip_comment(line)
        if depth is None and re.match(r'\s*test\s+"', code) and "{" in code:
            depth = 0
        if depth is not None:
            inside.add(i)
            depth += code.count("{") - code.count("}")
            if depth <= 0:
                depth = None
    return inside


def main():
    files = {p: open(p).read().split("\n") for p in zig_files()}
    machines = set()
    for lines in files.values():
        for line in lines:
            m = re.match(r"\s*(?:pub\s+)?const\s+(\w+)\s*=\s*machine\.Machine\(", line)
            if m:
                machines.add(m.group(1))
    fields = set()
    for lines in files.values():
        for line in lines:
            for name in machines:
                m = re.match(r"\s*(\w+)\s*:\s*(?:\w+\.)?" + name + r"\b", line)
                if m:
                    fields.add(m.group(1))

    refusals = []
    for path, lines in files.items():
        tests = test_lines(lines)
        rel = os.path.relpath(path, os.path.dirname(SRC))
        for i, line in enumerate(lines):
            code = strip_comment(line)
            if re.search(r"\bmachine_state\s*=[^=>]", code):
                refusals.append(f"{rel}:{i + 1}: machine_state assigned; only fire changes a machine's state")
            if i in tests:
                continue
            if "startingAt(" in code:
                refusals.append(f"{rel}:{i + 1}: startingAt outside a test; a machine starts at its initial state")
            for f in fields:
                # `c.fin =` or `conns[i].fin =`, not `.{ .fin = .queued }`
                # (a literal's field) or `.fin =>` (a switch prong).
                if re.search(r"[\w\])]\." + f + r"\s*=[^=>]", code):
                    refusals.append(f"{rel}:{i + 1}: the machine field `{f}` replaced; fire an event instead")
    for r in refusals:
        print(r)
    if not machines:
        print("lint_machine: no machine found in src; is the declaration's form one this lint reads?")
        return 1
    return 1 if refusals else 0


if __name__ == "__main__":
    sys.exit(main())
