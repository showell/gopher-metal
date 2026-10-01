#!/bin/bash
# **IS droplet.sh STILL A DROPLET?** Two checks, each against something
# outside this script:
#
#   1. QEMU's PCI list, slot by slot, against `lspci.txt` (a real droplet's):
#      every slot and function holds the same vendor:device. A moved, swapped
#      or missing device is a failure.
#   2. The BIOS boots the disk: `hello.S`, one sector, must print its line on
#      COM1 and exit 0 through the door.
#
#   droplet/shape.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failed=0

# ── 1. the PCI list ──────────────────────────────────────────────────────────
# lspci: "00:03.0 Ethernet controller [0200]: ... [1af4:1000]"
sed -E 's/^00:([0-9a-f]{2})\.([0-7]) .*\[([0-9a-f]{4}:[0-9a-f]{4})\]$/\1.\2 \3/' \
    "$HERE/lspci.txt" > "$WORK/droplet.ids"
truncate -s 1M "$WORK/empty.img"
# QEMU: "Bus  0, device   3, function 0:" then "    Ethernet controller: PCI device 1af4:1000"
(echo "info pci"; sleep 1; echo quit) | MONITOR=stdio DISK="$WORK/empty.img" "$HERE/droplet.sh" 2>&1 \
    | tr -d '\r' > "$WORK/info.txt"
awk '
    /Bus +0, device/ { gsub(/,/, ""); dev = $4; fn = $6; sub(/:/, "", fn); next }
    /PCI device/     { printf "%02x.%s %s\n", dev, fn, $NF }
' "$WORK/info.txt" > "$WORK/qemu.ids"
if diff "$WORK/droplet.ids" "$WORK/qemu.ids" > "$WORK/pci.diff"; then
    echo "PASS pci    $(wc -l < "$WORK/qemu.ids") functions, every slot the droplet's"
else
    echo "FAIL pci    (< the droplet, > QEMU)"; cat "$WORK/pci.diff"; failed=1
fi

# ── 2. the BIOS boots the disk ───────────────────────────────────────────────
as --32 -o "$WORK/hello.o" "$HERE/hello.S" \
    && ld -m elf_i386 -Ttext 0x7C00 --oformat binary -o "$WORK/hello.bin" "$WORK/hello.o" \
    || { echo "FAIL boot   hello.S did not assemble"; exit 1; }
[ "$(stat -c %s "$WORK/hello.bin")" = 512 ] || { echo "FAIL boot   hello.bin is not one sector"; exit 1; }
truncate -s 1M "$WORK/hello.img"
dd if="$WORK/hello.bin" of="$WORK/hello.img" conv=notrunc status=none
DISK="$WORK/hello.img" timeout 30 "$HERE/droplet.sh" > "$WORK/boot.txt" 2>&1
code=$?
if [ "$code" = 1 ] && grep -q "booted from the disk's first sector" "$WORK/boot.txt"; then
    echo "PASS boot   the BIOS read the first sector and ran it"
else
    echo "FAIL boot   exit $code"; cat "$WORK/boot.txt"; failed=1
fi
exit $failed
