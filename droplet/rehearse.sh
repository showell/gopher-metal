#!/bin/bash
# The whole rehearsal as one command (QUEUE.md item 59): see droplet/rehearse.py.
#   droplet/rehearse.sh COPY [--fat 16|32] [--gib N] [--mount] [--no-writes]
exec python3 "$(dirname "${BASH_SOURCE[0]}")/rehearse.py" "$@"
