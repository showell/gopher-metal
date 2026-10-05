#!/bin/bash
# **COVERAGE LINES, OUT OF A SERIAL LOG** (COVERAGE.md): a kernel built with
# -Dcoverage writes each property line to the port behind "coverage: ". This
# writes them back out as JSONL, for zig-coverage-sdk's tools/report.py.
#
#   tools/coverage_jsonl.sh <serial.log> [out.jsonl]     (default: stdout)
set -euo pipefail
log="${1:?usage: tools/coverage_jsonl.sh <serial.log> [out.jsonl]}"
out="${2:-/dev/stdout}"
# The port may end a line with \r\n; a JSONL line ends with \n alone.
grep -a '^coverage: ' "$log" | sed -e 's/^coverage: //' -e 's/\r$//' > "$out"
