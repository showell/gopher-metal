#!/bin/bash
# Prepares angry-gopher's chat server to build against this machine.
#
#   port.sh
#
# **THIS IS THE WHOLE PORT.** It copies the server's sources and changes one
# line in each of the files that has it:
#
#     const Io = std.Io;   ->   const Io = @import("metal").io;
#
# Not one call site moves. All 121 of the server's filesystem calls are spelled
# `Io.Dir.cwd().something(io, ...)`, so pointing that alias at src/io.zig is the
# entire change. See the README for why std.Io itself is not the seam.
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

before="$(grep -l '^const Io = std\.Io;' "$OUT"/*.zig | wc -l)"
sed -i 's|^const Io = std\.Io;|const Io = @import("metal").io;|' "$OUT"/*.zig
after="$(grep -l 'const Io = @import("metal")\.io;' "$OUT"/*.zig | wc -l)"

echo "$(ls "$OUT"/*.zig | wc -l) files copied, $before had the alias, $after now point at this machine"
[ "$before" = "$after" ] || { echo "the edit did not take on every file"; exit 1; }
