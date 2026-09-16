#!/bin/bash
# Every probe kernel, booted under QEMU's microvm machine.
#
#   probe/run.sh            all of them
#   probe/run.sh block      just one
#
# Prints a line per probe and exits 1 if any failed.
#
# Three flags here are not obvious and all three were found the hard way:
#
#   -M microvm
#       is what has virtio-mmio at all. The ordinary `pc` machine has PCI
#       instead, which is a different discovery path.
#
#   -global virtio-mmio.force-legacy=false
#       QEMU's virtio-mmio defaults to the LEGACY interface (version 1). These
#       drivers speak virtio 1.2 and refuse to pretend otherwise, so without
#       this every transport reads version 1 and nothing matches.
#
#   PVH, not multiboot
#       is in the kernels themselves: QEMU's multiboot loader refuses a 64-bit
#       ELF outright.
#
# **QEMU'S EXIT CODE IS NOT THE GUEST'S.** isa-debug-exit ends the guest with
# `code << 1 | 1`, so the kernel's 0 arrives as 1 and its 1 arrives as 3.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT="${CHECKOUT:-$HOME/showell_repos/cobblestone-u61}"
IMAGE="${IMAGE:-$CHECKOUT/codex/test/fat16-write.disk}"
WORK="$HOME/build/gopher-metal/probe"
mkdir -p "$WORK"

want="${1:-all}"
failed=0

boot() {
    local name="$1"; shift
    if [ ! -f "$HERE/$name.elf" ]; then
        echo "FAIL $name | no $name.elf; run: zig build kernels"
        failed=1
        return
    fi
    local out="$WORK/$name.out"
    timeout 60 qemu-system-x86_64 \
        -M microvm \
        -kernel "$HERE/$name.elf" \
        -nographic -no-reboot -m 512 \
        -global virtio-mmio.force-legacy=false \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        "$@" > "$out" 2>&1
    local code=$?
    # SeaBIOS's banner, the terminal escapes it prints, and any other
    # non-printable byte are the firmware's noise, not the kernel's output.
    tr -cd '\11\12\15\40-\176' < "$out" \
        | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; /SeaBIOS/d; s/^.*Booting from ROM\.\.//' \
        | grep -v '^[[:space:]]*$' > "$out.txt"
    mv "$out.txt" "$out"
    case "$code" in
        1) echo "PASS $name | $(grep -a . "$out" | tail -2 | head -1)" ;;
        3) echo "FAIL $name | $(grep -aE '^(FAIL|PANIC)' "$out" | head -1)"; failed=1 ;;
        124) echo "FAIL $name | timed out; see $out"; failed=1 ;;
        *) echo "FAIL $name | qemu exited $code; see $out"; failed=1 ;;
    esac
}

# **THE IMAGE IS ALWAYS COPIED**: the block probe writes to the last sector to
# prove the device writes where it was told, and it must never do that to a
# fixture.
if [ "$want" = all ] || [ "$want" = block ]; then
    cp "$IMAGE" "$WORK/disk.img"
    boot block \
        -drive id=d,file="$WORK/disk.img",format=raw,if=none \
        -device virtio-blk-device,drive=d
fi

# QEMU's user-mode networking answers DHCP at 10.0.2.2 with nothing
# configured, so the lease is a result that needs no second machine.
if [ "$want" = all ] || [ "$want" = net ]; then
    boot net \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0
fi

exit $failed
