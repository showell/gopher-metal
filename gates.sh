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
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

zig build test --summary all 2>&1 | grep -E "tests passed|error"
zig build kernels 2>&1 | grep error
zig build gopher 2>&1 | grep error
r=$(probe/run.sh 2>&1)
echo "probes: $(echo "$r" | grep -c "^PASS") PASS"
echo "$r" | grep "^FAIL"
# The chat judges: the verdict line and, on a failure, every line after it.
# Each verdict is kept whole, by machine, since the next run overwrites
# run.sh's copy.
VERDICTS="${GATES_VERDICTS:-$HOME/build/gopher-metal/gates}"
mkdir -p "$VERDICTS"
for machine in microvm droplet; do
    [ $machine = droplet ] && export JUDGE_DROPLET=1
    probe/run.sh gopher 2>&1 | sed -n '/^\(PASS\|FAIL\|    \) *gopher/,$p'
    cp "$HOME/build/gopher-metal/probe/gopher.verdict" "$VERDICTS/gopher-$machine.verdict" 2>/dev/null
    unset JUDGE_DROPLET
done
echo "droplet boot: $(droplet/boot.sh 2>&1 | grep -c PASS) PASS"
echo "droplet hello: $(droplet/hello.sh 2>&1 | grep -c PASS) PASS"
droplet/screen.sh 2>&1 | tail -1
VMM="${METAL_VMM:-$HOME/showell_repos/metal-vmm}"
(cd "$VMM" && ./check.sh 2>&1 | tail -2; ./same.sh 2>&1 | tail -2)
