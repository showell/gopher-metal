#!/bin/bash
# The virtio probe kernel, booted under QEMU's microvm machine against a copy
# of a disk image.
#
#   floor/probe/run.sh [image]
#
# With no image it uses a copy of Cobblestone's fat16-write.disk. **The image
# is always copied first**: the probe writes to the last sector to prove the
# device writes where it was told, and it must never do that to a fixture.
#
# Two flags here are not obvious and both were found the hard way:
#
#   -global virtio-mmio.force-legacy=false
#       QEMU's virtio-mmio defaults to the LEGACY interface (version 1). The
#       driver speaks virtio 1.2 and refuses to pretend otherwise, so without
#       this every transport reads version 1 and nothing matches.
#
#   -M microvm
#       is what has virtio-mmio at all. The ordinary `pc` machine has PCI
#       instead, which is a different discovery path.
#
# **QEMU'S EXIT CODE IS NOT THE GUEST'S.** isa-debug-exit ends the guest with
# `code << 1 | 1`, so the kernel's 0 arrives as 1 and its 1 arrives as 3. This
# script maps them back, so its own exit code means what it says.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT="${CHECKOUT:-$HOME/showell_repos/cobblestone-u61}"
IMAGE="${1:-$CHECKOUT/codex/test/fat16-write.disk}"
WORK="$HOME/build/roc-apps/gen/floor-probe"

[ -f "$HERE/probe.elf" ] || { echo "no probe.elf; run: zig build probe"; exit 2; }
[ -f "$IMAGE" ] || { echo "no such image: $IMAGE"; exit 2; }
mkdir -p "$WORK"
cp "$IMAGE" "$WORK/disk.img"

qemu-system-x86_64 \
    -M microvm \
    -kernel "$HERE/probe.elf" \
    -nographic -no-reboot -m 512 \
    -global virtio-mmio.force-legacy=false \
    -drive id=d,file="$WORK/disk.img",format=raw,if=none \
    -device virtio-blk-device,drive=d \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
code=$?

case "$code" in
    1) exit 0 ;;                      # the guest said 0
    3) echo "probe: the kernel reported a failure"; exit 1 ;;
    0) echo "probe: qemu exited without the guest ever writing 0xF4"; exit 1 ;;
    *) echo "probe: qemu exited $code"; exit 1 ;;
esac
