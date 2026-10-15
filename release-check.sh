#!/bin/bash
# **A RELEASE'S CHECKS**: the gates, then the long tier only if they pass, on
# this checkout as committed, detached, logging into <dir>:
#
#   mkdir -p <dir> && setsid nohup ./release-check.sh <dir> > /dev/null 2>&1 < /dev/null &
#
# <dir>/summary gets "GATES EXIT n" and, when the gates pass, "LONG EXIT n";
# the logs are <dir>/gates.log and <dir>/long.log. The exit code is the verdict.
set -u
dir="$(cd "${1:?usage: release-check.sh <log dir>}" && pwd)" || exit 2
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
./gates.sh > "$dir/gates.log" 2>&1; g=$?
echo "GATES EXIT $g" >> "$dir/summary"
[ $g = 0 ] || exit $g
./long.sh > "$dir/long.log" 2>&1; l=$?
echo "LONG EXIT $l" >> "$dir/summary"
exit $l
