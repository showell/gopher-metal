#!/bin/bash
# **TIER 1: TIER 0, AND QEMU** (metal-vmm QUEUE 197). This repo's own probe
# kernels, built and booted under QEMU and judged; the judges' own tests;
# the droplet's boot loader and image on a PC-shaped machine. No other repo.
# Needs qemu-system-x86_64, dosfstools (mkfs.vfat, fsck.vfat), gdisk
# (sgdisk), mtools, curl, binutils (as, ld), and `sudo -n` for the loop
# mounts three probes judge a volume with (without it they say SKIPPED,
# which fails). The droplet's boots use KVM; ACCEL=tcg runs them without.
#
# **SKIP="word …"** leaves slow steps out (tools/skip_lib.sh): native,
# probes, droplet-boot, droplet-hello, droplet-sleeps, screen. A run with a skip ends NOT A
# PASS, exit 3, and keeps no verdict.
TIER="tier 1"
source "$(dirname "${BASH_SOURCE[0]}")/tools/tier_lib.sh"
need zig python3 qemu-system-x86_64 mkfs.vfat fsck.vfat sgdisk mcopy curl as ld

# **LINUX AS THE WITNESS, NATIVELY** (metal-vmm QUEUE 225's gate, step 1-2;
# the box, 2026-10-16: in no tier until then): src/tcp.zig as a Linux
# program on the TAP device gmtap0, against Linux's own TCP, as server
# (judge_native's checks) and as client (gm-fetch's cases); quick leaves out
# the loss check's real timers (long.sh's). About 25 s, all protocol waits;
# no QEMU, so before the probes. Needs `sudo -n` for the TAP and netem: a
# box without it fails this step, it does not pass it.
if ! skip native; then
    if ! sudo -n true 2> /dev/null; then
        echo "native: cannot run: needs sudo -n (the TAP device and netem)"
        failed+=(native)
    elif ! zig build native > "$VERDICTS/tier1-native-build.txt" 2>&1; then
        echo "native: the build failed: $VERDICTS/tier1-native-build.txt"
        failed+=(native)
    else
        JUDGE_QUICK=1 python3 native/judge_native.py > "$VERDICTS/tier1-native.txt" 2>&1 || failed+=(native)
        grep "^FAIL" "$VERDICTS/tier1-native.txt"
        echo "native: $(tail -1 "$VERDICTS/tier1-native.txt")"
    fi
    lap "native: tcp.zig against Linux's TCP"
fi
zig build kernels 2>&1 | grep error
[ "${PIPESTATUS[0]}" = 0 ] || failed+=(kernels)
lap "kernels"

# The probes (probe/run.sh all): the judges' own tests first, then every
# probe kernel on QEMU's microvm.
if ! skip probes; then
    r=$(probe/run.sh 2>&1) || failed+=(probes)
    echo "probes: $(echo "$r" | grep -c "^PASS") PASS"
    echo "$r" | grep "^FAIL"
    lap "probes"
fi
python3 tools/fat16_read.py --self-test > /dev/null || failed+=(fat16-read)
lap "fat16_read self-test"

if ! skip droplet-boot; then
    b=$(droplet/boot.sh 2>&1) || failed+=(droplet-boot)
    echo "droplet boot: $(echo "$b" | grep -c PASS) PASS"
    echo "$b" | grep "^FAIL"
    lap "droplet boot"
fi
if ! skip droplet-hello; then
    h=$(droplet/hello.sh 2>&1) || failed+=(droplet-hello)
    echo "droplet hello: $(echo "$h" | grep -c PASS) PASS"
    echo "$h" | grep "^FAIL"
    lap "droplet hello"
fi
# **A KERNEL THAT SLEEPS, ON A REAL TIMER** (droplet/sleeps.py): the
# sleeper waking every 500 ms under KVM, timed on the host's clock, asleep
# between, and woken by a request; about 10 s.
if ! skip droplet-sleeps; then
    zig build sleeper > /dev/null 2>&1 || failed+=(droplet-sleeps)
    z=$(python3 droplet/sleeps.py 2>&1) || failed+=(droplet-sleeps)
    echo "$z" | grep -E "FAIL|NOT RUN|clock:|^SLEEPS"
    lap "droplet sleeps"
fi
if ! skip screen; then
    droplet/screen.sh 2>&1 | tail -1
    [ "${PIPESTATUS[0]}" = 0 ] || failed+=(screen)
    lap "screen"
fi

# **A CHECK SKIPPED IS NO PASS** (the normalization hunt, 2026-10-10).
skipped=$(echo "${r:-}" | grep "SKIPPED" || true)
if [ -n "$skipped" ]; then echo "$skipped"; failed+=(skipped); fi
verdict
