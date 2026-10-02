#!/bin/bash
# **THE CLOCK, BOOTED MANY TIMES** (QUEUE.md item 67). One boot of about 120
# on the droplet machine once stopped with "the clocks would not come up":
# the timestamp counter's rate, measured against the PIT, did not settle.
# This boots probe/clock.elf (the same calibration, then the RTC at its edge)
# on the droplet machine N times and counts how many came up.
#
#   droplet/clock_boots.sh [N]          N boots, default 360
#
# **HOW MANY IS FAIR.** The failure seen was about 1 in 120. If the rate were
# still that, N boots with no failure would happen by chance with
# probability (119/120)^N: 5% at N = 360 (the rule of three, 3/N). So 360
# clean boots say, at 95%, that the failure is now rarer than 1 in 120; 1,000
# say rarer than 1 in 330. Under KVM a boot takes a couple of seconds; under
# TCG (ACCEL=tcg, set when /dev/kvm is not usable) several.
#
# Prints one line per failure (its boot number and the kernel's last lines)
# and a total. Exit 0 when every boot came up, 1 otherwise.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
N="${1:-360}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$HERE/image.sh" "$ROOT/probe/clock.elf" "$WORK/disk.img" > "$WORK/image.txt" 2>&1 \
    || { echo "clock_boots: the image would not build: $(tail -1 "$WORK/image.txt")"; exit 1; }
accel=kvm
[ -r /dev/kvm ] && [ -w /dev/kvm ] || accel=tcg

failed=0
started=$(date +%s)
for i in $(seq 1 "$N"); do
    cp "$WORK/disk.img" "$WORK/boot.img"
    ACCEL=$accel DIRTY=1 MEMORY=2048 DISK="$WORK/boot.img" timeout 120 "$HERE/droplet.sh" > "$WORK/serial.txt" 2>&1
    code=$?
    # isa-debug-exit: the kernel's 0 (PASS) arrives as 1.
    if [ "$code" != 1 ] || ! grep -aq '^PASS' "$WORK/serial.txt"; then
        failed=$((failed + 1))
        echo "FAIL boot $i (exit $code): $(tr -cd '\11\12\40-\176' < "$WORK/serial.txt" | grep -a . | tail -3 | tr '\n' '|')"
        cp "$WORK/serial.txt" "$WORK/failed-$i.txt"
    fi
done
echo "clock_boots: $((N - failed)) of $N boots came up ($accel, $(( $(date +%s) - started )) s)"
[ "$failed" = 0 ]
