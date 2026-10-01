#!/bin/bash
# **A DIGITALOCEAN DROPLET, AS QEMU.** Boots a disk image on a machine laid out
# the way a droplet is: what `lspci.txt` records, read off a real droplet
# (this box) on 2026-10-01. Same chipset (i440FX, a BIOS, no UEFI), same
# devices in the same PCI slots:
#
#   00:02  the screen (virtio-vga; DigitalOcean's recovery console shows it)
#   00:03  the public network card        00:04  the private network card
#   00:05  virtio-SCSI, where volumes attach
#   00:06  the boot disk                  00:07  the config drive
#   00:08  the memory balloon
#
#   DISK=image.raw droplet/droplet.sh
#
# Knobs, all environment: DISK (required), MEMORY (MB, default 2048: prod's
# size), PUBLIC_FWD (a host port forwarded to the guest's port 80 on the
# public card), MONITOR=stdio (QEMU's monitor on the terminal instead of the
# serial port, which is how shape.sh asks for the PCI list).
#
# **WHAT IS NOT A DROPLET HERE**, both chosen for testing:
#   - the exit door (0xF4, isa-debug-exit), so a test kernel can end the run.
#     It sits on the ISA bus, not PCI, so the layout is unchanged; on a real
#     droplet a write to it goes nowhere.
#   - the networks are QEMU's user networking, whose DHCP server hands out
#     10.0.2.15 on the public card and 10.116.0.15 on the private one.
#     DigitalOcean's DHCP answers with the droplet's real addresses.
#   - the processor is this box's (`-cpu host`), which is itself a droplet's.
#
# **QEMU'S EXIT CODE IS NOT THE GUEST'S.** isa-debug-exit ends the guest with
# `code << 1 | 1`, so the kernel's 0 arrives as 1.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${DISK:-}" ] || { echo "droplet.sh: set DISK to a raw disk image"; exit 2; }
[ -f "$DISK" ] || { echo "droplet.sh: no $DISK"; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The config drive is where DigitalOcean puts cloud-init's data; nothing of
# ours reads it, so an empty one of the real size holds the slot.
truncate -s 488K "$WORK/config.img"

public="user,id=public"
[ -n "${PUBLIC_FWD:-}" ] && public="$public,hostfwd=tcp:127.0.0.1:$PUBLIC_FWD-:80"

if [ "${MONITOR:-}" = stdio ]; then
    console=(-serial none -monitor stdio)
else
    console=(-serial stdio -monitor none)
fi

exec qemu-system-x86_64 \
    -M pc -accel kvm -cpu host -smp 1 -m "${MEMORY:-2048}" \
    -nodefaults -no-reboot -display none "${console[@]}" \
    -device piix3-usb-uhci,addr=01.2 \
    -device virtio-vga,addr=02.0 \
    -netdev "$public" -device virtio-net-pci,netdev=public,addr=03.0 \
    -netdev user,id=private,net=10.116.0.0/20 -device virtio-net-pci,netdev=private,addr=04.0 \
    -device virtio-scsi-pci,addr=05.0 \
    -drive id=boot,file="$DISK",format=raw,if=none -device virtio-blk-pci,drive=boot,addr=06.0,bootindex=0 \
    -drive id=config,file="$WORK/config.img",format=raw,if=none -device virtio-blk-pci,drive=config,addr=07.0 \
    -device virtio-balloon-pci,addr=08.0 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
