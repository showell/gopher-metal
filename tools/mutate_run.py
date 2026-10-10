"""What mutate_tcp.py and mutate_guards.py share: running `zig build test`
on a mutant and saying what the run judged (metal-vmm 147(a,b,e)).

**ONLY A TEST THAT FAILED KILLS A MUTANT.** A run that failed for any other
reason judged nothing:

  - `did not compile`: a compile error, in any file;
  - `timed out`: the run outlived its time;
  - `unclassified`: anything else (the compiler or a test binary killed by
    a signal, as out of memory does; fmt; the lint; a step that failed
    without a test named). Never `killed`.

Each of those fails the run that asked, as a survivor does.

**A TIMEOUT KILLS EVERY PROCESS THE RUN STARTED**: zig runs the compiler
and the test binaries as its children, which a kill of zig alone leaves
running, holding the pipe a read waits on. The build runs in a process
group of its own, and the group is killed.
"""
import os
import re
import signal
import subprocess
import time

# A test that failed or panicked, as zig's test runner names it.
TEST_FAILED = re.compile(r"error: '[^']+' (failed|terminated with signal (ABRT|SEGV|TRAP|BUS|ILL|FPE))")
# A test binary's summary with a failure counted in it.
TEST_COUNTED = re.compile(r"run test \S+ .*\b\d+ (fail|crash|leak)")
COMPILE_ERROR = re.compile(r"\.zig:\d+:\d+: error:")


def build(args, cwd, timeout_s):
    """(exit code, or None when it timed out; the output; seconds)."""
    began = time.time()
    p = subprocess.Popen(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout_s)
        return p.returncode, out, time.time() - began
    except subprocess.TimeoutExpired:
        kill(p)
        out, _ = p.communicate()
        return None, out, time.time() - began
    except BaseException:  # an interrupt: nothing the run started outlives it
        kill(p)
        raise


def kill(p):
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def verdict(code, out):
    """What a run of `zig build test` on a mutant judged."""
    if code is None:
        return "timed out"
    if code == 0:
        return "SURVIVED"
    # A compile error first: a test that failed beside it may not have
    # built the mutant at all.
    if COMPILE_ERROR.search(out):
        return "did not compile"
    if TEST_FAILED.search(out) or TEST_COUNTED.search(out):
        return "killed"
    return "unclassified"


def tail(out, lines=15):
    return "\n".join(out.splitlines()[-lines:])
