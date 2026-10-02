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
# size), PUBLIC_FWD and PRIVATE_FWD (a host port forwarded to the guest's port
# 80 on that card), MONITOR=stdio (QEMU's monitor on the terminal instead of the
# serial port, which is how shape.sh asks for the PCI list), DIRTY=1 (below),
# MONITOR_SOCKET=path (QEMU's monitor on a unix socket, beside the serial
# port), NO_DOOR=1 (no exit door, as on a real droplet: a kernel that ends
# halts with its screen intact, and the run ends when it is told to),
# MACHINE (QEMU's machine type, default `pc`; a real droplet reports
# pc-i440fx-6.1), BIOS (a SeaBIOS image to boot instead of QEMU's own), and
# NO_SCREEN=1 (no display card in slot 02, so gopher-metal finds no screen and
# writes only to the serial port: not a droplet, a way to measure the screen),
# and VOLUME=path (a raw disk image attached as a DigitalOcean volume is, on
# the SCSI controller; VOLUME_TARGET and VOLUME_LUN place it), and ACCEL=tcg
# (software emulation and QEMU's `max` processor, for a machine with no KVM,
# such as a cloud container: slower, and not a droplet's processor; the
# default is KVM with this box's own, as on a droplet).
#
# **DIRTY=1: THE MACHINE STARTS WITH GARBAGE IN EVERY BYTE OF RAM.** QEMU's
# memory comes fresh from Linux, so it is all zeroes, and a loader or kernel
# that forgets to clear something it relies on passes anyway. Here the RAM is
# a file of 0xA5 bytes, mapped privately so the guest's writes never reach it.
# This is how the loader's clearing of .bss is tested at all: without it, the
# clock probe fails on dirty memory and passes on clean.
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
#
# **QEMU REPLACES THIS SCRIPT** (`exec`), so whoever started it holds QEMU's own
# process and stopping it stops the machine. So nothing is left to clean up
# afterwards, the two scratch files go beside the disk: `$DISK.config` and,
# with DIRTY=1, `$DISK.ram`. Every caller here keeps its disk in a temporary
# directory of its own.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${DISK:-}" ] || { echo "droplet.sh: set DISK to a raw disk image"; exit 2; }
[ -f "$DISK" ] || { echo "droplet.sh: no $DISK"; exit 2; }

# The config drive is where DigitalOcean puts cloud-init's data; nothing of
# ours reads it, so an empty one of the real size holds the slot.
truncate -s 488K "$DISK.config"

public="user,id=public"
[ -n "${PUBLIC_FWD:-}" ] && public="$public,hostfwd=tcp:127.0.0.1:$PUBLIC_FWD-:80"
private="user,id=private,net=10.116.0.0/20"
[ -n "${PRIVATE_FWD:-}" ] && private="$private,hostfwd=tcp:127.0.0.1:$PRIVATE_FWD-:80"

machine="${MACHINE:-pc}"
memory=(-M "$machine" -m "${MEMORY:-2048}")
if [ "${DIRTY:-}" = 1 ]; then
    head -c "${MEMORY:-2048}M" /dev/zero | tr '\0' '\245' > "$DISK.ram"
    memory=(-M "$machine",memory-backend=ram -m "${MEMORY:-2048}"
            -object memory-backend-file,id=ram,size="${MEMORY:-2048}M",mem-path="$DISK.ram",share=off)
fi

if [ "${MONITOR:-}" = stdio ]; then
    console=(-serial none -monitor stdio)
elif [ -n "${MONITOR_SOCKET:-}" ]; then
    console=(-serial stdio -monitor "unix:$MONITOR_SOCKET,server,nowait")
else
    console=(-serial stdio -monitor none)
fi
door=(-device isa-debug-exit,iobase=0xf4,iosize=0x04)
# A DigitalOcean volume: a disk on the SCSI controller in slot 05, which is
# there with or without one. VOLUME names a raw disk image; the target and LUN
# default to 0 and 1, and the kernel finds the disk wherever it is.
volume=()
[ -n "${VOLUME:-}" ] && volume=(-drive id=volume,file="$VOLUME",format=raw,if=none
    -device scsi-hd,drive=volume,bus=scsi.0,scsi-id="${VOLUME_TARGET:-0}",lun="${VOLUME_LUN:-1}")
screen=(-device virtio-vga,addr=02.0)
[ "${NO_SCREEN:-}" = 1 ] && screen=()
bios=()
[ -n "${BIOS:-}" ] && bios=(-bios "$BIOS")
[ "${NO_DOOR:-}" = 1 ] && door=()

accel=(-accel kvm -cpu host)
[ "${ACCEL:-kvm}" = tcg ] && accel=(-accel tcg -cpu max)

exec qemu-system-x86_64 \
    "${memory[@]}" "${bios[@]}" "${accel[@]}" -smp 1 \
    -nodefaults -no-reboot -display none "${console[@]}" \
    -device piix3-usb-uhci,addr=01.2 \
    "${screen[@]}" \
    -netdev "$public" -device virtio-net-pci,netdev=public,addr=03.0 \
    -netdev "$private" -device virtio-net-pci,netdev=private,addr=04.0 \
    -device virtio-scsi-pci,id=scsi,addr=05.0 "${volume[@]}" \
    -drive id=boot,file="$DISK",format=raw,if=none -device virtio-blk-pci,drive=boot,addr=06.0,bootindex=0 \
    -drive id=config,file="$DISK.config",format=raw,if=none -device virtio-blk-pci,drive=config,addr=07.0 \
    -device virtio-balloon-pci,addr=08.0 \
    "${door[@]}"
