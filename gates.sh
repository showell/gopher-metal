#!/bin/bash
# **EVERY GATE, ON WHAT IS IN THIS TREE NOW.** Run before merging anything that
# touches the kernel:
#
#   ./gates.sh            the full run, for a batch
#   ./gates.sh quick      the two-minute tier, for a single commit: host tests,
#                         the kernels, the probes, and one chat-judge story
#
# Host tests, the probes, the chat judge on QEMU's microvm and on the
# droplet-shaped machine (chat's data on a SCSI volume), the droplet boot
# checks, and metal-vmm's three checks (the microvm-shaped machine against
# QEMU, its repeatability, and the PC-shaped machine's rests).
#
# **gopher.elf IS REBUILT HERE.** `probe/run.sh gopher` judges whatever
# gopher.elf is on disk, and `zig build kernels` does not build it, so a gate
# that skipped this judged yesterday's kernel and passed. It assumes port.sh
# has already prepared angry-gopher's sources; it does not re-port them.
#
# **THE CHAT JUDGE RUNS FAT32 HERE, FAT16 IN long.sh** (QUEUE.md item 88; the
# gates essay, item 6): prod's data is a FAT32 volume. The FAT16 judge was
# nine of this run's twenty-five minutes; it now runs on every long.sh, which
# every release needs, and FAT16 is still covered here by `zig build test`
# and `tools/check_fat16_images.sh`.
#
# **ITS EXIT CODE IS THE VERDICT.** Every step's own status is kept, through
# the pipes that trim its output, and the last line names the steps that
# failed. A chat judge that skips (77) has not passed, so it fails here.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

mode="${1:-full}"
case "$mode" in
    full | quick) ;;
    *) echo "usage: ./gates.sh [quick]"; exit 2 ;;
esac

failed=()
# Each step's time, printed as "time: <step> <seconds> s", so where a run's
# minutes go is read off the output rather than guessed.
t=$SECONDS
lap() { echo "time: $1 $((SECONDS - t)) s"; t=$SECONDS; }

GOPHER_ROOT="${GOPHER_ROOT:-$HOME/showell_repos/angry-gopher}"
# **WHICH CODE THIS RUN JUDGES** (tools/verdicts.py): both commits, printed,
# and a port that is not angry-gopher's HEAD refused. A full run keeps its
# verdict for exactly this pair, which droplet/chat.py requires.
VERDICT_PAIR="$(python3 tools/verdicts.py ids)" || exit 2
export VERDICT_PAIR
python3 tools/verdicts.py pair
VERDICTS="${GATES_VERDICTS:-$HOME/build/gopher-metal/gates}"
mkdir -p "$VERDICTS"

# ── the kernels and host tests ───────────────────────────────────────────────
# The limits angry-gopher's store copies from fat16.zig and io.zig: a
# second, so first (tools/check_limits.py).
python3 tools/check_limits.py "$GOPHER_ROOT/zig-server/src" || failed+=(limits)
# The whole summary is kept: each test binary's time is in it, and this step
# is the gates' longest.
zig build test --summary all > "$VERDICTS/test-summary.txt" 2>&1
[ $? = 0 ] || failed+=(test)
grep -E "tests passed|error" "$VERDICTS/test-summary.txt"
lap "zig build test"
zig build kernels 2>&1 | grep error
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(kernels)
zig build gopher 2>&1 | grep error
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(gopher-build)
lap "kernels and gopher.elf"

# ── one chat-judge story, for the quick tier ─────────────────────────────────
# A single story (the member story: login, chat, topics, admin, logout) on one
# machine, FAT32, so a single commit is answered in two minutes instead of the
# full run's twenty. The full run below is what a batch is gated on.
if [ "$mode" = quick ]; then
    r=$(probe/run.sh 2>&1) || failed+=(probes)
    echo "probes: $(echo "$r" | grep -c "^PASS") PASS"
    echo "$r" | grep "^FAIL"
    lap "probes"
    (cd "$GOPHER_ROOT/zig-server" && zig build) > "$VERDICTS/linux-build.txt" 2>&1
    JUDGE_ONLY=members PROBE_WORK="$HOME/build/gopher-metal/probe-quick" \
        probe/run.sh gopher > "$VERDICTS/gopher-quick.run" 2>&1
    code=$?
    sed -n '/^\(PASS\|FAIL\|    \) *gopher/,$p' "$VERDICTS/gopher-quick.run"
    { [ "$code" = 0 ] && grep -q "^PASS gopher" "$VERDICTS/gopher-quick.run"; } || failed+=(gopher-quick)
    lap "one chat-judge story (members, FAT32)"
    if [ ${#failed[@]} = 0 ]; then echo "GATES quick: PASS"; else echo "GATES quick: FAIL (${failed[*]})"; exit 1; fi
    exit 0
fi

# ── the full run ─────────────────────────────────────────────────────────────
r=$(probe/run.sh 2>&1) || failed+=(probes)
echo "probes: $(echo "$r" | grep -c "^PASS") PASS"
echo "$r" | grep "^FAIL"
lap "probes"

# **GATES_PARALLEL=1 RUNS THE TWO SIDE BY SIDE** (QUEUE.md item 72), now the
# default (item 85c; the box saw it green from batch 16 on): each in its own
# scratch (PROBE_WORK), on ports each judge asks the host for, with its own
# verdict file. The Linux build they share is made once, first, so the build
# each run.sh makes finds nothing to do. `GATES_PARALLEL=0` runs them one after
# the other. The output is the same either way, in the same order.
judge() {  # judge MACHINE [FAT]: one chat judge, output to $VERDICTS/gopher-MACHINE[-fatN].run
    local machine=$1 fat="${2:-}" droplet=0 tag=$1
    [ "$machine" = droplet ] && droplet=1
    [ -n "$fat" ] && tag="$machine-fat$fat"
    # Set for this one command only: the steps after the judges must not
    # inherit it, as they did not before.
    # Through `env`: an expansion before the command ends bash's assignment
    # words, and an empty `${fat:+...}` made `PROBE_WORK=...` the command.
    env JUDGE_DROPLET=$droplet ${fat:+FAT=$fat} PROBE_WORK="$HOME/build/gopher-metal/probe-$tag" probe/run.sh gopher \
        > "$VERDICTS/gopher-$tag.run" 2>&1
    echo $? > "$VERDICTS/gopher-$tag.code"
}
report() {  # report TAG: the verdict line and, on a failure, every line after it
    local tag=$1 v code
    v=$(cat "$VERDICTS/gopher-$tag.run")
    code=$(cat "$VERDICTS/gopher-$tag.code")
    echo "$v" | sed -n '/^\(PASS\|FAIL\|    \) *gopher/,$p'
    { [ "$code" = 0 ] && echo "$v" | grep -q "^PASS gopher"; } || failed+=("gopher-$tag")
    cp "$HOME/build/gopher-metal/probe-$tag/gopher.verdict" "$VERDICTS/gopher-$tag.verdict" 2>/dev/null
}

# The two FAT32 judges, always.
if [ "${GATES_PARALLEL:-1}" = 1 ]; then
    (cd "$GOPHER_ROOT/zig-server" && zig build) > "$VERDICTS/linux-build.txt" 2>&1
    judge microvm & judge droplet & wait
    for machine in microvm droplet; do report $machine; done
    lap "gopher judges, microvm and droplet side by side (FAT32)"
else
    for machine in microvm droplet; do
        judge $machine
        report $machine
        lap "gopher judge, $machine (FAT32)"
    done
fi

# **THE FAT16 JUDGE IS long.sh's** (the gates essay, item 6): prod's data is
# FAT32, and FAT16 stays covered here by zig build test, the FAT simulator
# and tools/check_fat16_images.sh. long.sh runs the judge on every release.
echo "FAT16 chat judge: in long.sh, before every release"

# ── the droplet and metal-vmm checks ─────────────────────────────────────────
b=$(droplet/boot.sh 2>&1) || failed+=(droplet-boot)
echo "droplet boot: $(echo "$b" | grep -c PASS) PASS"
echo "$b" | grep "^FAIL"
lap "droplet boot"
h=$(droplet/hello.sh 2>&1) || failed+=(droplet-hello)
echo "droplet hello: $(echo "$h" | grep -c PASS) PASS"
echo "$h" | grep "^FAIL"
lap "droplet hello"
droplet/screen.sh 2>&1 | tail -1
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(screen)
lap "screen"
# **metal-vmm IS BUILT HERE**, for the reason gopher.elf is above: its scripts
# run whatever binary is on disk. `pc_vs_microvm.sh all` is the PC-shaped machine
# (TRANSPORT=pci): every route with the server halting between frames and
# woken by MSI-X and the APIC timer, the path a droplet runs.
VMM="${METAL_VMM:-$HOME/showell_repos/metal-vmm}"
(cd "$VMM" && zig build 2>&1 | tail -5; exit "${PIPESTATUS[0]}") || failed+=(vmm-build)
(cd "$VMM" && ./check.sh 2>&1 | tail -2; exit "${PIPESTATUS[0]}") || failed+=(vmm-check)
(cd "$VMM" && ./same.sh 2>&1 | tail -2; exit "${PIPESTATUS[0]}") || failed+=(vmm-same)
(cd "$VMM" && ./pc_vs_microvm.sh all 2>&1 | tail -2; exit "${PIPESTATUS[0]}") || failed+=(vmm-pc)
# **TIMEOUTS, IN THE MACHINE'S TIME**: what a setting governs, proved by
# moving it, read off metal-vmm's clock rather than waited out on the box's.
(cd "$VMM" && ./timeouts.sh 2>&1 | tail -3; exit "${PIPESTATUS[0]}") || failed+=(vmm-timeouts)
lap "metal-vmm check, same, rest and timeouts"

if [ ${#failed[@]} = 0 ]; then
    [ "$mode" = full ] && python3 tools/verdicts.py record gates PASS
    echo "GATES: PASS"
else
    [ "$mode" = full ] && python3 tools/verdicts.py record gates FAIL
    echo "GATES: FAIL (${failed[*]})"
    exit 1
fi
