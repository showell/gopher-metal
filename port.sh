#!/bin/bash
# Prepares angry-gopher's chat server to build against this machine.
#
#   port.sh
#
# **THIS IS THE WHOLE PORT.** It copies the server's sources, unchanged. Each
# file takes its `Io` from the `host_io` module,
#
#     const Io = @import("host_io").Io;
#
# and this build hands them src/host_io_metal.zig as that module, whose `Io`
# is src/io.zig; angry-gopher's build hands the same files std's. Not one
# call site moves, and no line is rewritten. See the README for why std.Io
# itself is not the seam.
#
# The copy is NOT committed here: this repo holds the change, not the code it
# is applied to.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${GOPHER_SRC:-$HOME/showell_repos/angry-gopher/zig-server/src}"
OUT="${GOPHER_PORT:-$HOME/build/gopher-metal/port}"

[ -d "$SRC" ] || { echo "no server sources at $SRC"; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$SRC"/*.zig "$OUT"/

# **NO FILE IS EDITED**: each takes its `Io` from the `host_io` module, which
# the build hands it (src/host_io_metal.zig: this machine's). A file with an
# alias straight to std's would be std's here too, so one is refused.
escaped="$(grep -l '^const Io = std\.Io;' "$OUT"/*.zig || true)"
took="$(grep -l '^const Io = @import("host_io")\.Io;' "$OUT"/*.zig | wc -l)"

# The asset table, read from the application's own build.zig rather than
# copied, so that the two cannot drift. See tools/extract_assets.py.
python3 "$HERE/tools/extract_assets.py" "$SRC/../build.zig" "$HERE/gen/assets.zig"

echo "$(ls "$OUT"/*.zig | wc -l) files copied, $took take their Io from host_io"
[ -z "$escaped" ] || { echo "these alias std's Io, not host_io's, and would be std's here: $escaped"; exit 1; }

# **WHICH angry-gopher THIS IS** (tools/verdicts.py): gates.sh and long.sh
# refuse a port that is not angry-gopher's HEAD, and an image is built only
# from a pair whose verdicts say PASS.
python3 "$HERE/tools/verdicts.py" stamp
