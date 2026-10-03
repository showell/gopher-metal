#!/bin/bash
# The whole cutover runbook as one command (QUEUE.md item 76): see
# droplet/cutover_drill.py. rehearse.sh does the data steps; this does the
# runbook around them — the freeze, the switch, the first day, the way back —
# against stand-ins on one machine, each GO/NO-GO line of CUTOVER.md said out
# loud.
#   droplet/cutover_drill.sh COPY [--fat 16|32] [--gib N] [--keep-writes]
#   droplet/cutover_drill.sh --self-test
exec python3 "$(dirname "${BASH_SOURCE[0]}")/cutover_drill.py" "$@"
