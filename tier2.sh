#!/bin/bash
# **TIER 2: TIER 1, AND METAL-VMM** (metal-vmm QUEUE 197): metal-vmm's
# checks against THIS checkout's probe kernels (GUESTS: it read
# ~/showell_repos/zig-metal-unikernel/probe whatever tree ran the gates).
# Needs metal-vmm beside this checkout (or METAL_VMM) and /dev/kvm; its
# check.sh compares each guest against QEMU too.
TIER="tier 2"
source "$(dirname "${BASH_SOURCE[0]}")/tools/tier_lib.sh"
need zig qemu-system-x86_64 mkfs.vfat
[ -d "$VMM" ] || { echo "$TIER: NOT RUN: no metal-vmm at $VMM (METAL_VMM=<dir>)"; exit 2; }
[ -e /dev/kvm ] || { echo "$TIER: NOT RUN: no /dev/kvm"; exit 2; }
export GUESTS="$HERE/probe"

zig build kernels 2>&1 | grep error
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(kernels)
# **metal-vmm IS BUILT HERE**: its scripts run whatever binary is on disk.
(cd "$VMM" && zig build 2>&1 | tail -5; exit "${PIPESTATUS[0]}") || failed+=(vmm-build)
(cd "$VMM" && ./check.sh 2>&1 | tail -2; exit "${PIPESTATUS[0]}") || failed+=(vmm-check)
(cd "$VMM" && ./same.sh 2>&1 | tail -2; exit "${PIPESTATUS[0]}") || failed+=(vmm-same)
lap "metal-vmm build, check and same"
verdict
