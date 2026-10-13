#!/bin/bash
# **EVERY GATE, ON WHAT IS IN THIS TREE NOW: THE FOUR TIERS IN ORDER**
# (metal-vmm QUEUE 197), cheapest first, stopping at the first that fails:
#
#   ./gates.sh            tiers 0, 1, 2 and 3, for a batch
#   ./gates.sh quick      tiers 0 and 1, then gopher.elf built and one
#                         chat-judge story (./tier3.sh quick), for a commit
#
#   tier0.sh  zig, Python and the coverage SDK: unit tests, simulators,
#             this repo's kernels type-checked, lints, properties
#   tier1.sh  + QEMU: the probe kernels booted and judged, the droplet's boots
#   tier2.sh  + metal-vmm: its checks against this checkout's kernels
#   tier3.sh  + zig-webbox and the applications: gopher.elf and dogpark.elf
#             judged, the site volume, metal-vmm on gopher.elf
#
# Each tier is a script of its own, and says what it needs and what it does
# not check. long.sh stays the release tier.
#
# **ITS EXIT CODE IS THE VERDICT**, as each tier's is: a tier that could not
# run (2: something it needs is missing) has not passed, so it fails here.
# A full run that passes records its verdict for exactly the checkouts it
# judged (tools/verdicts.py), which droplet/chat.py requires.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

mode="${1:-full}"
case "$mode" in
    full | quick) ;;
    *) echo "usage: ./gates.sh [quick]"; exit 2 ;;
esac

source tools/tier_lib.sh
# **WHICH CODE THIS RUN JUDGES**, before any tier: the checkouts, printed,
# and one the build cannot take refused. The build reads them live: an edit
# during the run changes its content id, and `record` keeps no verdict.
VERDICT_PAIR="$(python3 tools/verdicts.py ids)" || exit 2
export VERDICT_PAIR
python3 tools/verdicts.py pair

start=$SECONDS
label=""; [ "$mode" = quick ] && label=" quick"
run_tier() {
    local script=$1; shift
    echo "── $script $* ──"
    "./$script" "$@"
    local code=$?
    echo "time: $script $((SECONDS - start)) s since the gates began"
    if [ "$code" != 0 ]; then
        [ "$mode" = full ] && python3 tools/verdicts.py record gates FAIL
        echo "GATES${label}: FAIL (${script%.sh}${*:+ $*})"
        exit 1
    fi
}

run_tier tier0.sh
run_tier tier1.sh
if [ "$mode" = quick ]; then
    run_tier tier3.sh quick
    echo "GATES quick: PASS"
    exit 0
fi
run_tier tier2.sh
run_tier tier3.sh
python3 tools/verdicts.py record gates PASS
echo "GATES: PASS"
