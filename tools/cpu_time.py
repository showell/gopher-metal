#!/usr/bin/env python3
"""**A TEST BINARY'S CPU TIME, NOT ITS WALL TIME** (metal-vmm QUEUE 198.12).

build.zig runs every test binary through this (`setExecCmd`): it runs the
binary with its arguments and its stdin and stdout untouched (zig's test
runner speaks to the build over them), waits for it with wait4, and writes
the binary's user and system time, its wall time and its name to
`<dir>/<name>.cpu`, and on the next line the binary's path (to run it
alone). Wall time under
`-j` measures the other binaries beside it as much as the test; CPU time is
the same on 2 cores and on 8. tools/test_budget.py reads the files.

    python3 tools/cpu_time.py <dir> <name> <binary> [args...]

Exits as the binary did: its code, or its signal raised again.
"""
import os
import signal
import sys
import time


def main(argv):
    out_dir, name, cmd = argv[1], argv[2], argv[3:]
    start = time.monotonic()
    pid = os.posix_spawn(cmd[0], cmd, os.environ)
    _, status, usage = os.wait4(pid, 0)
    wall = time.monotonic() - start
    os.makedirs(out_dir, exist_ok=True)
    safe = "".join(c if c.isalnum() or c in "._=-" else "_" for c in name)
    with open(os.path.join(out_dir, safe + ".cpu"), "w", encoding="utf-8") as f:
        f.write(f"{usage.ru_utime + usage.ru_stime:.3f} {wall:.3f} {name}\n{cmd[0]}\n")
    if os.WIFSIGNALED(status):
        sig = os.WTERMSIG(status)
        signal.signal(sig, signal.SIG_DFL)
        os.kill(os.getpid(), sig)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
