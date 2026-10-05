#!/bin/bash
# **THE ANTITHESIS WIRE, OUT OF A SERIAL LOG** (src/antithesis.zig): a kernel
# built with -Dantithesis writes each assertion line to the port behind
# "antithesis: ". This writes them back out as sdk.jsonl, the file
# Antithesis reads from $ANTITHESIS_OUTPUT_DIR.
#
#   tools/antithesis_jsonl.sh <serial.log> [out.jsonl]     (default: stdout)
set -euo pipefail
log="${1:?usage: tools/antithesis_jsonl.sh <serial.log> [out.jsonl]}"
out="${2:-/dev/stdout}"
# The port may end a line with \r\n; a JSONL line ends with \n alone.
grep -a '^antithesis: ' "$log" | sed -e 's/^antithesis: //' -e 's/\r$//' > "$out"
