#!/usr/bin/env python3
"""**ONLY `fire` CHANGES A MACHINE'S STATE** (src/machine.zig, metal-vmm QUEUE
item 140). Zig has no private fields, so this is the guard. Run by
`zig build test`.

    tools/lint_machine.py [repo]
    tools/lint_machine.py --self-test   its cases (tools/lint_machine_cases):
                                        each line marked `// refused`, and no
                                        other, is refused

In src/, probe/ and native/, outside src/machine.zig, it refuses:
- an assignment to `machine_state`, the state's field;
- `startingAt(`, a machine made at a given state, outside a `test` block;
- an assignment to a field whose type is a machine (`fin: FinMachine`),
  outside a `test` block: a whole machine replaced is a state chosen.

A machine is any `const X = <anything>.Machine(` or `const X = Machine(`
declaration, and any alias of one (`const FM = tcp.FinMachine;`). A field is
written as `c.fin =`, `c.fins[i] =`, a local `fins[i] =` or `fin =`, through
a typed or `&`-taken pointer (`p.* =`), or through a capture (`|*m| m.* =`)
of anything naming a machine field (metal-vmm 147(f)). Exits 0 when clean,
1 with each refusal as file:line.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != "--self-test" else os.path.dirname(HERE)
CASES = os.path.join(HERE, "lint_machine_cases")
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


def strip_comment_keep(line):
    """The line with its comment cut and its strings kept (an `@import`'s
    path), for reading declarations only."""
    i = STRING.sub(lambda m: "x" * len(m.group(0)), line).find("//")
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
    declared = re.compile(r"\s*(?:pub\s+)?const\s+(\w+)\s*=\s*(?:@import\(\"[^\"]*\"\)\.|\w+\.)*Machine\(")
    for lines in files.values():
        for line in lines:
            m = declared.match(strip_comment_keep(line))
            if m:
                machines.add(m.group(1))
    # Aliases, to a fixed point: `const FM = tcp.FinMachine;`.
    while True:
        more = set()
        for lines in files.values():
            for line in lines:
                m = re.match(r"\s*(?:pub\s+)?const\s+(\w+)\s*=\s*(?:@import\(\"[^\"]*\"\)\.|\w+\.)*(\w+)\s*;", strip_comment(line))
                if m and m.group(2) in machines and m.group(1) not in machines:
                    more.add(m.group(1))
        if not more:
            break
        machines |= more
    fields = set()
    pointers = set()
    # The names each file declares of a machine's type: a bare `fin =` is
    # judged only where `fin` is one (147's review: `var fin = false;` in
    # another file is no machine).
    declared_in = {path: set() for path in files}
    for path, lines in files.items():
        for line in lines:
            for name in machines:
                # A field or a variable of the machine's type, however
                # wrapped: `fin: FinMachine`, `x: ?tcp.FinMachine`,
                # `all: [4]FinMachine`. A pointer to one is a pointer: a
                # write through it (`p.* =`) chooses a state too.
                # Not `FinMachine.Event`, a type the machine declares.
                for m in re.finditer(r"\b(\w+)\s*:\s*([^=;,(){}]*?)\b(?:\w+\.)?" + name + r"\b(?!\s*\.)", strip_comment(line)):
                    (pointers if "*" in m.group(2) else fields).add(m.group(1))
                    if "*" not in m.group(2):
                        declared_in[path].add(m.group(1))
    # A pointer taken with no type written: `var x = &c.fin;` (146(g)'s review).
    for lines in files.values():
        for line in lines:
            for m in re.finditer(r"\b(?:var|const)\s+(\w+)\s*=\s*&[\w.\[\]]*\.(\w+)(?:\[[^\]]*\])?\s*;", strip_comment(line)):
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
                # A local, bare: `fins[1] =` or `fin =`; not its declaration
                # (`var fin: T = ...`, `const fin = ...`).
                elif (f in declared_in[path] and re.search(r"(?:^|[^.\w])" + f + r"(?:\[[^\]]*\])?\s*=(?:[^=>]|$)", code)
                      and not re.search(r"\b(?:var|const)\s+" + f + r"\b", code)):
                    refusals.append(f"{rel}:{i + 1}: the machine `{f}` replaced; fire an event instead")
            for p in pointers:
                if re.search(r"\b" + p + r"(?:\.\*|\[[^\]]*\])\s*=(?:[^=>]|$)", code):
                    refusals.append(f"{rel}:{i + 1}: a machine written through `{p}.*`; fire an event instead")
            # A capture by pointer of anything naming a machine field:
            # `for (&c.fins) |*m| m.* = ...`, judged in the block it opens.
            for m in re.finditer(r"\(([^()]*)\)\s*\|\s*\*(\w+)", code):
                if not any(re.search(r"\b" + f + r"\b", m.group(1)) for f in fields):
                    continue
                name = m.group(2)
                depth = 0
                for j in range(i, len(lines)):
                    later = strip_comment(lines[j])
                    seen = later[m.end():] if j == i else later
                    if re.search(r"\b" + name + r"\.\*\s*=(?:[^=>]|$)", seen):
                        refusals.append(f"{rel}:{j + 1}: a machine written through the capture `{name}`; fire an event instead")
                    depth += seen.count("{") - seen.count("}")
                    if depth <= 0 and (j > i or "{" not in seen):
                        break
    for r in refusals:
        print(r)
    if not machines:
        print("lint_machine: no machine found; is the declaration's form one this lint reads?")
        return 1
    return 1 if refusals else 0


def self_test():
    """**THE LINT'S OWN CASES** (147(f)): every write it must refuse, marked
    `// refused` where it is, beside the forms it must let be."""
    import subprocess
    out = subprocess.run([sys.executable, os.path.abspath(__file__), CASES], capture_output=True, text=True).stdout
    got = {":".join(line.split(":")[:2]) for line in out.splitlines() if line.startswith("src/")}
    want = set()
    for d, _, names in os.walk(os.path.join(CASES, "src")):
        for n in names:
            for i, line in enumerate(open(os.path.join(d, n)).read().split("\n")):
                if line.rstrip().endswith("// refused"):
                    want.add(f"{os.path.relpath(os.path.join(d, n), CASES)}:{i + 1}")
    for w in sorted(want - got):
        print(f"lint_machine --self-test: {w} is not refused")
    for g in sorted(got - want):
        print(f"lint_machine --self-test: {g} is refused, and is not marked")
    return 0 if want == got and want else 1


if __name__ == "__main__":
    sys.exit(self_test() if sys.argv[1:] == ["--self-test"] else main())
