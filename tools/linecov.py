#!/usr/bin/env python3
"""**WHICH LINES OF A SOURCE FILE A TEST BINARY RAN**: line coverage for zig's
unit tests, with no kcov on the box.

    tools/linecov.py src/tcp.zig <test binary> [<test binary> ...]

Each binary is run once under ptrace with a one-shot breakpoint (0xCC) at the
first address of every line of the file, from its DWARF line table
(`readelf --debug-dump=decodedline`); a breakpoint hit records its lines and
is put back as it was. The verdict is the union over the binaries: lines run,
lines with code that never ran, each printed with its text.

A line the compiler emitted no code for (a comment, a declaration, code it
inlined away) has no address, so it is neither run nor missed. Nor is a line
that is only a closing brace: Debug code gives a function's `}` an address
of its own, which a function that ends in `return` never reaches. A binary must
be a fixed-address (non-PIE) x86-64 Linux executable, as `zig build test`
makes them; one that does not exit 0 is reported, since its coverage is short.
"""
import ctypes
import os
import re
import signal
import subprocess
import sys

PTRACE_TRACEME, PTRACE_PEEKTEXT, PTRACE_POKETEXT = 0, 1, 4
PTRACE_CONT, PTRACE_KILL, PTRACE_GETREGS, PTRACE_SETREGS = 7, 8, 12, 13
RIP = 16  # user_regs_struct's rip, in 8-byte words

libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.restype = ctypes.c_long
libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]


class Regs(ctypes.Structure):
    _fields_ = [("r", ctypes.c_ulonglong * 27)]


def line_table(binary: str, source: str) -> dict:
    """{address: {line, ...}} for the lines of `source` (a path ending)."""
    out = subprocess.run(["readelf", "--debug-dump=decodedline", binary],
                         capture_output=True, text=True).stdout
    # A test's root file is named bare (`tcp.zig:`); every other file by
    # its whole path.
    want = {os.path.abspath(source), os.path.basename(source)}
    lines = {}
    current = None
    for row in out.splitlines():
        if row.endswith(":") and " " not in row:
            current = row[:-1]
            continue
        m = re.match(r"(\S+)\s+(\d+)\s+(0x[0-9a-f]+)", row)
        if m and current in want:
            lines.setdefault(int(m.group(3), 16), set()).add(int(m.group(2)))
    return lines


def peek(pid: int, addr: int) -> int:
    ctypes.set_errno(0)
    word = libc.ptrace(PTRACE_PEEKTEXT, pid, ctypes.c_void_p(addr), None)
    if word == -1 and ctypes.get_errno() != 0:
        raise OSError(ctypes.get_errno(), f"peek {addr:#x}")
    return word & 0xFFFFFFFFFFFFFFFF


def poke_byte(pid: int, addr: int, byte: int) -> int:
    """Writes one byte at `addr`; returns the byte that was there."""
    base = addr & ~7
    word = peek(pid, base)
    shift = (addr - base) * 8
    old = (word >> shift) & 0xFF
    word = (word & ~(0xFF << shift)) | (byte << shift)
    if libc.ptrace(PTRACE_POKETEXT, pid, ctypes.c_void_p(base), ctypes.c_void_p(word)) != 0:
        raise OSError(ctypes.get_errno(), f"poke {addr:#x}")
    return old


def run(binary: str, table: dict) -> tuple:
    """Runs `binary` to its end; returns (lines hit, exit status)."""
    pid = os.fork()
    if pid == 0:
        libc.ptrace(PTRACE_TRACEME, 0, None, None)
        os.execv(binary, [binary])
    os.waitpid(pid, 0)  # stopped at the exec
    saved = {addr: poke_byte(pid, addr, 0xCC) for addr in table}
    hit = set()
    sig = 0
    while True:
        libc.ptrace(PTRACE_CONT, pid, None, ctypes.c_void_p(sig))
        _, status = os.waitpid(pid, 0)
        if os.WIFEXITED(status):
            return hit, os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return hit, -os.WTERMSIG(status)
        sig = os.WSTOPSIG(status)
        if sig != signal.SIGTRAP:
            continue  # passed on to the program at the next continue
        regs = Regs()
        libc.ptrace(PTRACE_GETREGS, pid, None, ctypes.byref(regs))
        at = regs.r[RIP] - 1
        if at in saved:
            hit |= table[at]
            poke_byte(pid, at, saved.pop(at))
            regs.r[RIP] = at
            libc.ptrace(PTRACE_SETREGS, pid, None, ctypes.byref(regs))
            sig = 0


def main(argv: list) -> int:
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[2].strip())
        return 2
    source, binaries = argv[1], argv[2:]
    text = open(source).read().splitlines()
    have, ran = set(), set()
    crashed = []
    for b in binaries:
        table = line_table(b, source)
        if not table:
            continue  # another binary's tests reach this file, not this one's
        have |= {n for n in set().union(*table.values()) if text[n - 1].strip() != "}"}
        hit, code = run(b, table)
        ran |= hit
        if code != 0:
            print(f"linecov: {os.path.basename(b)} exited {code}: its coverage is short")
            crashed.append(os.path.basename(b))
    if not have:
        print(f"linecov: none of the {len(binaries)} binaries has a line of {source}")
        return 2
    ran &= have
    missed = sorted(have - ran)
    print(f"{source}: {len(ran)} of {len(have)} lines with code ran "
          f"({100 * len(ran) / max(1, len(have)):.1f}%), over {len(binaries)} binaries")
    for n in missed:
        print(f"  {n:5d}  {text[n - 1].strip()[:100]}")
    # **A BINARY THAT DID NOT FINISH FAILS THE MEASURE** (metal-vmm 146(d)):
    # every file's tests are one binary now, so a crash anywhere cuts every
    # file's coverage short, and a short measure read as a clean one hides it.
    if crashed:
        print(f"linecov: FAILED: {', '.join(crashed)} did not finish; the lines above are short")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
