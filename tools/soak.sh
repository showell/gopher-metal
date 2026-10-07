#!/usr/bin/env bash
# **THE SOAK, DETACHED** (src/explore_soak.zig): the seed explorer and blind
# runs on fat, store and tcp, round after round, until `-Dsoak-hours` (7)
# are up. Overnight only; stop it before a morning's gates (kill its PID).
#
#   tools/soak.sh                      the defaults: 1000 runs a column, 7 hours
#   tools/soak.sh -Dsoak-sims=tcp      any `zig build soak` option passes through
#
# It runs from a worktree of its own at this checkout's commit
# (../gopher-metal-soak), so this checkout stays free to edit, and logs to
# ~/soak-logs/, outside every repo. Both trees must be clean: the log's first
# line names the two commits, and with the run's explorer seed and number
# they are all a failure needs to be reproduced.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sdk=$(cd "$here/../zig-coverage-sdk" && pwd)
for repo in "$here" "$sdk"; do
    if [ -n "$(git -C "$repo" status --porcelain)" ]; then
        echo "soak: $repo has uncommitted changes; commit them first" >&2
        exit 2
    fi
done
commit=$(git -C "$here" rev-parse --short HEAD)
sdk_commit=$(git -C "$sdk" rev-parse --short HEAD)
tree=$(dirname "$here")/gopher-metal-soak
if [ -d "$tree" ]; then
    git -C "$tree" checkout -q --detach "$commit"
else
    git -C "$here" worktree add -q --detach "$tree" "$commit"
fi
mkdir -p "$HOME/soak-logs"
log=$HOME/soak-logs/soak-$(date +%Y-%m-%d-%H%M).log
echo "gopher-metal $commit, zig-coverage-sdk $sdk_commit, started $(date '+%F %T'), options: ${*:-the defaults}" > "$log"
cd "$tree"
setsid nohup zig build soak "$@" >> "$log" 2>&1 < /dev/null &
echo "soak: PID $!, log $log"
