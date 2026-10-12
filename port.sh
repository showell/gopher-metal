#!/bin/bash
# Prepares this tree to build angry-gopher's chat server for this machine.
#
#   port.sh
#
# **NOTHING IS COPIED** (Phase B step 2b): build.zig compiles the server from
# angry-gopher's checkout (`-Dgopher-root`, ../angry-gopher by default). Each
# file takes its `Io` from the `host_io` module,
#
#     const Io = @import("host_io").Io;
#
# and this build hands them src/host_io_metal.zig as that module, whose `Io`
# is src/io.zig; angry-gopher's build hands the same files std's. Not one
# call site moves, and no line is rewritten. See the README for why std.Io
# itself is not the seam.
#
# **WHAT IS LEFT FOR THIS SCRIPT: THE ASSET LIST** (step 3 makes it a build
# input, and this script goes): gen/assets.zig, the front-end artifacts each
# page embeds by name, from the table in angry-gopher's zig-server/build.zig.
# Then the same freshness the build asks (tools/verdicts.py): a source that
# aliases std's Io is refused here too, so it is said before a build.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOPHER_ROOT="${GOPHER_ROOT:-$HOME/showell_repos/angry-gopher}"
export GOPHER_ROOT
SRC="$GOPHER_ROOT/zig-server/src"

[ -d "$SRC" ] || { echo "no server sources at $SRC"; exit 2; }
python3 "$HERE/tools/extract_assets.py" "$SRC/../build.zig" "$HERE/gen/assets.zig"
took="$(grep -l '^const Io = @import("host_io")\.Io;' "$SRC"/*.zig | wc -l)"
echo "angry-gopher $(git -C "$GOPHER_ROOT" rev-parse --short HEAD): $(ls "$SRC"/*.zig | wc -l) files, $took take their Io from host_io"
state="$(python3 "$HERE/tools/verdicts.py" fresh)"
[ "$state" = fresh ] || { echo "$state"; exit 1; }
