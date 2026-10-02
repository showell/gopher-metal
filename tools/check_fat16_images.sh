#!/bin/bash
# fat16.zig's host tests, judged by an independent reader (QUEUE.md item 4).
#
#   tools/check_fat16_images.sh
#
# Runs `zig build test -Dfat16-images=<dir>`, which keeps every disk image
# src/fat16_test.zig made, then hands each one to tools/fat16_read.py check:
# an image the tests left healthy must check clean, and one named damaged-*,
# broken on purpose, must not. Exit 0 when both hold for every image.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

( cd "$ROOT" && zig build test -Dfat16-images="$DIR" ) || { echo "FAIL zig build test"; exit 1; }
n=$(ls "$DIR"/*.img 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "FAIL the tests kept no images in $DIR"; exit 1; }

failed=0
for img in "$DIR"/*.img; do
    name="$(basename "$img")"
    out="$(python3 "$HERE/fat16_read.py" check "$img")"
    code=$?
    case "$name" in
        damaged-*) if [ $code = 0 ]; then echo "FAIL $name: broken on purpose, and the reader found nothing"; failed=1
                   else echo "ok   $name: the reader finds the damage: $(echo "$out" | sed -n 2p | sed 's/^ *//')"; fi ;;
        *)         if [ $code != 0 ]; then echo "FAIL $name:"; echo "$out" | sed 1d; failed=1
                   else echo "ok   $name"; fi ;;
    esac
done
echo "$n images checked by tools/fat16_read.py"
exit $failed
