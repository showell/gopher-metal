#!/bin/bash
# **TIER 1: TIER 0, AND QEMU** (metal-vmm QUEUE 197). This repo's own probe
# kernels, built and booted under QEMU and judged; the judges' own tests;
# the droplet's boot loader and image on a PC-shaped machine. No other repo.
# Needs qemu-system-x86_64, dosfstools (mkfs.vfat, fsck.vfat), gdisk
# (sgdisk), mtools, curl, binutils (as, ld), and `sudo -n` for the loop
# mounts three probes judge a volume with (without it they say SKIPPED,
# which fails). The droplet's boots use KVM; ACCEL=tcg runs them without.
TIER="tier 1"
source "$(dirname "${BASH_SOURCE[0]}")/tools/tier_lib.sh"
need zig python3 qemu-system-x86_64 mkfs.vfat fsck.vfat sgdisk mcopy curl as ld

zig build kernels 2>&1 | grep error
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(kernels)
lap "kernels"

# The probes (probe/run.sh all): the judges' own tests first, then every
# probe kernel on QEMU's microvm.
r=$(probe/run.sh 2>&1) || failed+=(probes)
echo "probes: $(echo "$r" | grep -c "^PASS") PASS"
echo "$r" | grep "^FAIL"
lap "probes"
python3 tools/fat16_read.py --self-test > /dev/null || failed+=(fat16-read)
lap "fat16_read self-test"

b=$(droplet/boot.sh 2>&1) || failed+=(droplet-boot)
echo "droplet boot: $(echo "$b" | grep -c PASS) PASS"
echo "$b" | grep "^FAIL"
lap "droplet boot"
h=$(droplet/hello.sh 2>&1) || failed+=(droplet-hello)
echo "droplet hello: $(echo "$h" | grep -c PASS) PASS"
echo "$h" | grep "^FAIL"
lap "droplet hello"
droplet/screen.sh 2>&1 | tail -1
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(screen)
lap "screen"

# **A CHECK SKIPPED IS NO PASS** (the normalization hunt, 2026-10-10).
skipped=$(echo "$r" | grep "SKIPPED" || true)
if [ -n "$skipped" ]; then echo "$skipped"; failed+=(skipped); fi
verdict
