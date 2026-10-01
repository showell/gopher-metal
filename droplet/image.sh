#!/bin/bash
# **ONE PROBE, ON A DISK A DROPLET CAN BOOT.** Builds gm-image, assembles the
# boot loader, lays out the disk, and has Linux's own partition tool check it
# (`sgdisk -v`). Used by boot.sh and screen.sh.
#
#   droplet/image.sh <kernel.elf> <out.img> [volume.fat]
#
# A volume, when given, is chat's files: a FAT16 filesystem image that becomes
# partition 2.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
elf="$1"
img="$2"
volume="${3:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

(cd "$ROOT" && zig build droplet) || { echo "gm-image did not build"; exit 1; }
as --32 -o "$WORK/loader.o" "$HERE/loader.S" \
    && ld -m elf_i386 -Ttext 0x7C00 --oformat binary -o "$WORK/loader.bin" "$WORK/loader.o" \
    || { echo "loader.S did not assemble"; exit 1; }
[ -f "$elf" ] || { echo "no $elf (zig build kernels)"; exit 1; }
"$ROOT/zig-out/bin/gm-image" "$WORK/loader.bin" "$elf" "$img" ${volume:+"$volume"} > "$WORK/image.txt" 2>&1 \
    || { echo "gm-image: $(cat "$WORK/image.txt")"; exit 1; }
sgdisk -v "$img" 2>&1 | grep -q "^No problems found" \
    || { echo "sgdisk does not accept the disk:"; sgdisk -v "$img"; exit 1; }
