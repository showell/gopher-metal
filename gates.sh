#!/bin/bash
# **EVERY GATE, ON WHAT IS IN THIS TREE NOW.** Run before merging anything that
# touches the kernel:
#
#   ./gates.sh
#
# Host tests, the probes, the chat judge on QEMU's microvm and on the
# droplet-shaped machine (chat's data on a SCSI volume), the droplet boot
# checks, and metal-vmm's two checks.
#
# **gopher.elf IS REBUILT HERE.** `probe/run.sh gopher` judges whatever
# gopher.elf is on disk, and `zig build kernels` does not build it, so a gate
# that skipped this judged yesterday's kernel and passed. It assumes port.sh
# has already prepared angry-gopher's sources; it does not re-port them.
#
# **ITS EXIT CODE IS THE VERDICT.** Every step's own status is kept, through
# the pipes that trim its output, and the last line names the steps that
# failed. A chat judge that skips (77) has not passed, so it fails here.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

failed=()
zig build test --summary all 2>&1 | grep -E "tests passed|error"
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(test)
zig build kernels 2>&1 | grep error
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(kernels)
zig build gopher 2>&1 | grep error
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(gopher-build)
r=$(probe/run.sh 2>&1) || failed+=(probes)
echo "probes: $(echo "$r" | grep -c "^PASS") PASS"
echo "$r" | grep "^FAIL"
# The chat judges: the verdict line and, on a failure, every line after it.
# Each verdict is kept whole, by machine, since the next run overwrites
# run.sh's copy.
VERDICTS="${GATES_VERDICTS:-$HOME/build/gopher-metal/gates}"
mkdir -p "$VERDICTS"
for machine in microvm droplet; do
    [ $machine = droplet ] && export JUDGE_DROPLET=1
    v=$(probe/run.sh gopher 2>&1)
    code=$?
    echo "$v" | sed -n '/^\(PASS\|FAIL\|    \) *gopher/,$p'
    { [ $code = 0 ] && echo "$v" | grep -q "^PASS gopher"; } || failed+=("gopher-$machine")
    cp "$HOME/build/gopher-metal/probe/gopher.verdict" "$VERDICTS/gopher-$machine.verdict" 2>/dev/null
    unset JUDGE_DROPLET
done
b=$(droplet/boot.sh 2>&1) || failed+=(droplet-boot)
echo "droplet boot: $(echo "$b" | grep -c PASS) PASS"
echo "$b" | grep "^FAIL"
h=$(droplet/hello.sh 2>&1) || failed+=(droplet-hello)
echo "droplet hello: $(echo "$h" | grep -c PASS) PASS"
echo "$h" | grep "^FAIL"
droplet/screen.sh 2>&1 | tail -1
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(screen)
VMM="${METAL_VMM:-$HOME/showell_repos/metal-vmm}"
(cd "$VMM" && ./check.sh 2>&1 | tail -2; exit "${PIPESTATUS[0]}") || failed+=(vmm-check)
(cd "$VMM" && ./same.sh 2>&1 | tail -2; exit "${PIPESTATUS[0]}") || failed+=(vmm-same)

if [ ${#failed[@]} = 0 ]; then
    echo "GATES: PASS"
else
    echo "GATES: FAIL (${failed[*]})"
    exit 1
fi
