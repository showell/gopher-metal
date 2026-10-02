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

# The kept free count (QUEUE.md item 14): each image a test left healthy has,
# beside it, the count fat16.zig kept through every operation; the oracle's
# count of free clusters in its first FAT must be the same number. A damaged
# image is not compared: its damage was made under the volume's feet.
k=0
for img in "$DIR"/*.img; do
    name="$(basename "$img" .img)"
    case "$name" in damaged-*|limit-*) continue ;; esac
    [ -f "$DIR/$name.free" ] || { echo "FAIL $name: no kept free count beside it"; failed=1; continue; }
    kept="$(cat "$DIR/$name.free")"
    counted="$(python3 -c "
import sys; sys.path.insert(0, '$HERE')
import fat16_read
v = fat16_read.Volume(open('$img', 'rb').read())
print(sum(1 for c in range(2, v.max_cluster + 1) if v.fat(c) == 0))")"
    k=$((k + 1))
    if [ "$kept" != "$counted" ]; then echo "FAIL $name: fat16.zig kept $kept free clusters, the oracle counts $counted"; failed=1; fi
done
echo "the kept free count is the oracle's on $k healthy images"

# The names test writes data/chat/<name> for every length from 1 to
# fat16.max_name, each name the first that many characters of a fixed
# alphabet. The oracle must list each, whole: a name it read under its 8.3
# alias, or cut short, is missing.
max_name=$(grep -o 'pub const max_name: usize = [0-9]*' "$ROOT/src/fat16.zig" | grep -o '[0-9]*$')
for img in "$DIR"/names-*.img; do
    name="$(basename "$img")"
    want="$(python3 -c "
a = 'abcdefghijklmnopqrstuvwxyz0123456789-'
print('\n'.join('/data/chat/' + ''.join(a[i % 37] for i in range(n)) for n in range(1, $max_name + 1)))" | sort)"
    got="$(python3 "$HERE/fat16_read.py" list "$img" | awk '$1 == "-" {print $3}' | grep '^/data/chat/' | sort)"
    if [ "$got" = "$want" ]; then echo "ok   $name: the oracle reads every name from 1 to $max_name characters by its long name"
    else echo "FAIL $name: the oracle's names differ:"; diff <(echo "$want") <(echo "$got") | head; failed=1; fi
done

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
