#!/usr/bin/env python3
"""**ONLY `fire` CHANGES A MACHINE'S STATE** (src/machine.zig, metal-vmm QUEUE
item 140). Zig has no private fields, so this is the guard. Run by
`zig build test`.

    tools/lint_machine.py [repo]

In src/, probe/ and native/, outside src/machine.zig, it refuses:
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
ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(HERE)
DIRS = ["src", "probe", "native"]


def zig_files():
    for top in DIRS:
        for d, _, names in os.walk(os.path.join(ROOT, top)):
            for n in sorted(names):
                path = os.path.join(d, n)
                if n.endswith(".zig") and os.path.relpath(path, ROOT) != os.path.join("src", "machine.zig"):
                    yield path


STRING = re.compile(r'"(?:[^"\\]|\\.)*"' + r"|'(?:[^'\\]|\\.)*'")


def strip_comment(line):
    """The line's code: string and character literals blanked (a `{` or a
    `//` in a test's name is not code), then the comment cut."""
    line = STRING.sub('""', line)
    i = line.find("//")
    return line if i < 0 else line[:i]


def test_lines(lines):
    """The 0-based lines inside a `test "..." {` or `test {` block, by brace
    depth, braces in strings not counted (`strip_comment`)."""
    inside = set()
    depth = None
    for i, line in enumerate(lines):
        code = strip_comment(line)
        if depth is None and re.match(r'\s*test\s*("|\{)', code) and "{" in code:
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
    pointers = set()
    for lines in files.values():
        for line in lines:
            for name in machines:
                # A field or a variable of the machine's type, however
                # wrapped: `fin: FinMachine`, `x: ?tcp.FinMachine`,
                # `all: [4]FinMachine`. A pointer to one is a pointer: a
                # write through it (`p.* =`) chooses a state too.
                for m in re.finditer(r"\b(\w+)\s*:\s*([^=;,(){}]*?)\b(?:\w+\.)?" + name + r"\b", strip_comment(line)):
                    (pointers if "*" in m.group(2) else fields).add(m.group(1))
    # A pointer taken with no type written: `var x = &c.fin;` (146(g)'s review).
    for lines in files.values():
        for line in lines:
            for m in re.finditer(r"\b(?:var|const)\s+(\w+)\s*=\s*&[\w.\[\]]*\.(\w+)\s*;", strip_comment(line)):
                if m.group(2) in fields:
                    pointers.add(m.group(1))

    refusals = []
    for path, lines in files.items():
        tests = test_lines(lines)
        rel = os.path.relpath(path, ROOT)
        for i, line in enumerate(lines):
            code = strip_comment(line)
            if re.search(r"\bmachine_state\s*=(?:[^=>]|$)", code):
                refusals.append(f"{rel}:{i + 1}: machine_state assigned; only fire changes a machine's state")
            if i in tests:
                continue
            if "startingAt(" in code:
                refusals.append(f"{rel}:{i + 1}: startingAt outside a test; a machine starts at its initial state")
            for f in fields:
                # `c.fin =` or `conns[i].fin =` or `all[2] =`, not
                # `.{ .fin = .queued }` (a literal's field) or `.fin =>` (a
                # switch prong).
                if re.search(r"[\w\])*]\." + f + r"(?:\[[^\]]*\])?\s*=(?:[^=>]|$)", code):
                    refusals.append(f"{rel}:{i + 1}: the machine field `{f}` replaced; fire an event instead")
            for p in pointers:
                if re.search(r"\b" + p + r"\.\*\s*=(?:[^=>]|$)", code):
                    refusals.append(f"{rel}:{i + 1}: a machine written through `{p}.*`; fire an event instead")
    for r in refusals:
        print(r)
    if not machines:
        print("lint_machine: no machine found; is the declaration's form one this lint reads?")
        return 1
    return 1 if refusals else 0


if __name__ == "__main__":
    sys.exit(main())
