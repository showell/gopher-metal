#!/bin/bash
# **EVERYTHING TOO SLOW TO RUN WHILE ITERATING**, one after another, for a box
# nobody is watching. About forty minutes.
#
#   probe/long_run.sh
#
# Four stages, in this order and never at the same time — one compute job at a
# time is the rule here, and two QEMU guests would measure each other:
#
#   1. the judge, ISOLATED   a boot per single request (what proves an answer
#                            owes nothing to an earlier one) plus every gate
#   2. the TCP table         against Linux's own TCP, including the loss checks
#   3. the ladder, at scale  one operation many times; a rung must cost the
#                            same at the end as at the start
#   4. the long boot         100,000 requests to ONE kernel, under KVM
#
# **IT BUILDS FIRST AND THEN NEVER AGAIN.** A build during the long boot would
# put a compiler on the same cores as the thing being timed, and the numbers
# that boot exists to produce would be about the compiler.
#
# Everything lands in one log; the last block of it is the verdict. Exits 1 if
# any stage failed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="$HOME/build/gopher-metal/long_run"
mkdir -p "$LOGS"
LOG="$LOGS/$(date +%Y%m%dT%H%M%S).log"
ln -sfn "$LOG" "$LOGS/latest.log"

# How long the long boot is. 20,000 rounds is about 42,000 requests: ten times
# the usual soak, and half an hour rather than the whole evening — the
# read-back every tenth round costs more as the transcript grows, which is
# most of the time past the first few thousand rounds.
export SOAK_ROUNDS="${SOAK_ROUNDS:-20000}"
export LADDER_SCALE="${LADDER_SCALE:-20}"
export JUDGE_ISOLATED=1

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say "the long run: soak $SOAK_ROUNDS rounds, ladder scale $LADDER_SCALE (about 40 minutes)"
say "log: $LOG"

# ── build once, up front ─────────────────────────────────────────────────────
say "building (kernels, the TCP table on Linux, and the Linux build of the app)"
{
    ( cd "$HERE/.." && ./port.sh && zig build kernels && zig build gopher && zig build native )
    ( cd "$HOME/showell_repos/angry-gopher/zig-server" && zig build )
} >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    say "FAILED to build; nothing ran. See $LOG"
    exit 1
fi

failed=0
stage() {
    local name="$1"; shift
    say "── $name ──"
    local began=$SECONDS
    if "$@" >> "$LOG" 2>&1; then
        say "$name: PASSED in $(( SECONDS - began )) s"
    else
        say "$name: FAILED in $(( SECONDS - began )) s"
        failed=1
    fi
}

stage "the judge, a boot per single request" "$HERE/run.sh" gopher
stage "the TCP table against Linux's TCP" "$HERE/run.sh" native
stage "the ladder at scale $LADDER_SCALE" "$HERE/run.sh" ladder
stage "the long boot" "$HERE/run.sh" soak

# ── the verdict, and the numbers worth reading first ─────────────────────────
say "── the verdict ──"
{
    grep -E "^(PASS|FAIL|ok|     ladder \|)" "$LOG" | tail -40
    echo
    echo "the long boot, every tenth window:"
    grep -E "^  round +[0-9]+0000 " "$LOG" | tail -12
    echo
    echo "what it ended on:"
    grep -E "^(soak:|ok    soak)" "$LOG" | tail -4
} | tee -a "$LOG"

say "$([ $failed = 0 ] && echo "every stage passed" || echo "a stage failed — search the log for FAIL")"
exit $failed
