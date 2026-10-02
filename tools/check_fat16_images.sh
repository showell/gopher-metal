#!/bin/bash
# fat16.zig's host tests, judged by an independent reader (QUEUE.md item 4).
#
#   tools/check_fat16_images.sh
#
# Runs `zig build test -Dfat16-images=<dir>`, which keeps every disk image
# src/fat16_test.zig made, then hands each one to tools/fat16_read.py check:
# an image the tests left healthy must check clean, and one named damaged-*,
# broken on purpose, must not. Exit 0 when both hold for every image.
#
# The other way round too (QUEUE.md item 5): fat16_read.py make-foreign makes
# volumes with mkfs.vfat and mtools, healthy and damaged, and the same test run
# has fat16.zig's own check judge them (-Dfat16-foreign). Its verdicts, in
# judged.txt, must be the oracle's. Needs dosfstools and mtools, and fails
# without them rather than skipping.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DIR="$(mktemp -d)"
FOREIGN="$(mktemp -d)"
trap 'rm -rf "$DIR" "$FOREIGN"' EXIT

python3 "$HERE/fat16_read.py" make-foreign "$FOREIGN" || { echo "FAIL cannot make the mtools volumes"; exit 1; }
( cd "$ROOT" && zig build test -Dfat16-images="$DIR" -Dfat16-foreign="$FOREIGN" ) || { echo "FAIL zig build test"; exit 1; }
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

# Each mtools volume: judged by fat16.zig, and its verdict the oracle's.
m=0
for img in "$FOREIGN"/*.img; do
    name="$(basename "$img")"
    m=$((m + 1))
    python3 "$HERE/fat16_read.py" check "$img" >/dev/null
    oracle=$([ $? = 0 ] && echo clean || echo damaged)
    line="$(grep "^$name: " "$FOREIGN/judged.txt" 2>/dev/null)"
    ours="$(echo "$line" | sed 's/^[^:]*: \([a-z]*\).*/\1/')"
    if [ -z "$line" ]; then echo "FAIL $name: fat16.zig's check never judged it"; failed=1
    elif [ "$ours" != "$oracle" ]; then echo "FAIL $name: fat16.zig says $ours, the oracle $oracle"; failed=1
    else echo "ok   $name: both say $ours${line#*: $ours}"; fi
done
[ $m -gt 0 ] || { echo "FAIL make-foreign made no volumes"; failed=1; }
echo "$m mtools volumes judged by fat16.zig's check and by the oracle"
exit $failed
