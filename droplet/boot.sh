#!/bin/bash
# **THE PROBES, BOOTED THE WAY A DROPLET BOOTS THEM.** Each one is put on a
# disk with the boot loader (gm-image), the disk is checked as a GPT disk by
# Linux's own tool (`sgdisk -v`), and the droplet-shaped QEMU starts it from
# its BIOS. A probe passes when it prints PASS and leaves through the door
# with 0.
#
#   droplet/boot.sh          every probe below
#   droplet/boot.sh clock    just one
#
# Only the probes that need no virtio device are here so far: a droplet's
# devices are on PCI, and the kernels still look for them where QEMU's microvm
# puts them. `memory` boots at three sizes, because the memory map is the one
# thing the loader builds from what the BIOS says, and 4 GB is where the map
# gets a hole in it (the PCI window, under 4 GB) and a region above it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
want="${1:-all}"

(cd "$ROOT" && zig build droplet) || { echo "FAIL build  gm-image did not build"; exit 1; }
as --32 -o "$WORK/loader.o" "$HERE/loader.S" \
    && ld -m elf_i386 -Ttext 0x7C00 --oformat binary -o "$WORK/loader.bin" "$WORK/loader.o" \
    || { echo "FAIL build  loader.S did not assemble"; exit 1; }

failed=0
# probe:memory-in-MB
for one in memory:512 memory:2048 memory:4096 clock:2048; do
    probe="${one%%:*}"
    memory="${one##*:}"
    [ "$want" = all ] || [ "$want" = "$probe" ] || continue
    elf="$ROOT/probe/$probe.elf"
    [ -f "$elf" ] || { echo "FAIL $probe  no $elf (zig build kernels)"; failed=1; continue; }
    img="$WORK/$probe.img"
    if ! "$ROOT/zig-out/bin/gm-image" "$WORK/loader.bin" "$elf" "$img" > "$WORK/image.txt" 2>&1; then
        echo "FAIL $probe  gm-image: $(cat "$WORK/image.txt")"; failed=1; continue
    fi
    if ! sgdisk -v "$img" 2>&1 | grep -q "^No problems found"; then
        echo "FAIL $probe  sgdisk does not accept the disk:"; sgdisk -v "$img"; failed=1; continue
    fi
    began=$(date +%s%N)
    MEMORY="$memory" DISK="$img" timeout 120 "$HERE/droplet.sh" > "$WORK/out.txt" 2>&1
    code=$?
    ms=$(( ($(date +%s%N) - began) / 1000000 ))
    # The door turns the guest's 0 into QEMU's 1.
    if [ "$code" = 1 ] && [ "$(tail -1 "$WORK/out.txt" | tr -d '\r')" = PASS ]; then
        printf 'PASS %-7s %5s MB  %s (%s ms)\n' "$probe" "$memory" \
            "$(grep -m1 'total ram\|tsc_hz' "$WORK/out.txt" | sed 's/^ *//')" "$ms"
    else
        echo "FAIL $probe  $memory MB, exit $code:"; sed 's/^/    /' "$WORK/out.txt"; failed=1
    fi
done
exit $failed
