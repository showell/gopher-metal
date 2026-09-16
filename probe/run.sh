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
# The FAT16 probe reads Cobblestone's fat16-list.disk, whose contents are
# pinned by that test's own verdict.
if [ "$want" = all ] || [ "$want" = fat16 ]; then
    cp "${FAT16_IMAGE:-$CHECKOUT/codex/test/fat16-list.disk}" "$WORK/fat16.img"
    boot fat16 \
        -drive id=d,file="$WORK/fat16.img",format=raw,if=none \
        -device virtio-blk-device,drive=d
fi

# **THE ORACLE ROW.** This one does not judge itself: it prints what
# Cobblestone's fat16-write test prints, and its console is compared with that
# test's own verdict -- the same file roc-apps/floor's verify.sh uses for the
# Roc implementation. Two filesystems, two languages, one disk image.
if [ "$want" = all ] || [ "$want" = fat16write ]; then
    cp "${WRITE_IMAGE:-$CHECKOUT/codex/test/fat16-write.disk}" "$WORK/fat16write.img"
    boot fat16write \
        -drive id=d,file="$WORK/fat16write.img",format=raw,if=none \
        -device virtio-blk-device,drive=d
    if [ -f "$WORK/fat16write.out" ]; then
        if diff -q "$WORK/fat16write.out" "$HERE/expect/fat16write.txt" > /dev/null 2>&1; then
            echo "     fat16write | console matches the ladder verdict for fat16-write"
        else
            echo "FAIL fat16write | console differs from the ladder verdict:"
            diff "$HERE/expect/fat16write.txt" "$WORK/fat16write.out" | head -12
            failed=1
        fi
    fi
fi

# std.Io's own surface -- our Dir, the one the application's 121 filesystem
# calls are spelled against.
if [ "$want" = all ] || [ "$want" = stdio ]; then
    cp "${WRITE_IMAGE:-$CHECKOUT/codex/test/fat16-write.disk}" "$WORK/stdio.img"
    boot stdio \
        -drive id=d,file="$WORK/stdio.img",format=raw,if=none \
        -device virtio-blk-device,drive=d
fi

# **JUDGED BY fsck.vfat.** A fresh FAT16 volume from mkfs.vfat, written by our
# code, then handed to dosfstools -- which has been reading VFAT for decades and
# knows every way a long-name run can be wrong. Agreeing with our own reader
# would prove very little.
if [ "$want" = all ] || [ "$want" = vfat ]; then
    img="$WORK/vfat.img"
    rm -f "$img"
    if ! command -v mkfs.vfat > /dev/null; then
        echo "FAIL vfat | mkfs.vfat is not installed, and the check needs it"
        failed=1
    else
        # 32 MB, FAT16, 512-byte sectors, no partition table: fsck reads the
        # volume directly rather than having to find it.
        mkfs.vfat -F 16 -S 512 -n GOPHER -C "$img" 32768 > /dev/null 2>&1
        boot vfat \
            -drive id=d,file="$img",format=raw,if=none \
            -device virtio-blk-device,drive=d
        if [ -f "$WORK/vfat.out" ] && grep -aq PASS "$WORK/vfat.out"; then
            if fsck.vfat -n "$img" > "$WORK/vfat.fsck" 2>&1; then
                echo "     vfat | fsck.vfat finds no error in what we wrote"
            else
                echo "FAIL vfat | fsck.vfat rejects the volume:"
                grep -av "^fsck.fat\|^$" "$WORK/vfat.fsck" | head -8
                failed=1
            fi

            # **THE BACKUP STORY, BOTH WAYS.** Structure passing fsck is not the
            # same as the data being reachable. This mounts the volume with the
            # Linux kernel's own VFAT driver, checks it reads what we wrote, has
            # Linux write a long-named file into a directory it creates, and
            # then boots the machine again to read that back.
            #
            # Needs root, so it is skipped rather than failed where there is
            # none: a check that cannot run must not look like one that passed.
            if ! sudo -n true 2>/dev/null; then
                echo "     vfat | SKIPPED the loop-mount check: it needs root"
            else
                mnt="$WORK/mnt"
                mkdir -p "$mnt"
                sudo mount -o loop,ro,noexec,nosuid,nodev "$img" "$mnt"
                got="$(cat "$mnt/auth/damian/_session_secret" 2>/dev/null || true)"
                names="$(find "$mnt" -type f -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
                sudo umount "$mnt"
                if [ "$got" != "sixteen bytes!!!" ]; then
                    echo "FAIL vfat | Linux read [$got] where we wrote [sixteen bytes!!!]"
                    failed=1
                elif [ "$names" != "_session_secret api-key blog-comments last-seen upload-bytes " ]; then
                    echo "FAIL vfat | Linux sees different names: $names"
                    failed=1
                else
                    echo "     vfat | the Linux VFAT driver reads every name and byte we wrote"
                fi

                # Now the other direction: Linux writes, we read.
                sudo mount -o loop,noexec,nosuid,nodev "$img" "$mnt"
                sudo mkdir -p "$mnt/restored"
                printf 'linux wrote this, with a name 8.3 cannot hold\n' \
                    | sudo tee "$mnt/restored/written-by-linux.txt" > /dev/null
                sudo umount "$mnt"
                boot restore \
                    -drive id=d,file="$img",format=raw,if=none \
                    -device virtio-blk-device,drive=d
            fi
        fi
    fi
fi

# **THE APPEND, JUDGED FROM OUTSIDE.** The application never writes a whole
# file except the first time; after that every write is an append at the current
# end. This writes through the application's own three lines (createFile,
# stat, writePositionalAll) and then hands the volume to two judges that have
# never seen our code: fsck.vfat for the structure, and the Linux VFAT driver
# for the bytes -- with the expected 200 lines regenerated here in shell, so
# the comparison does not run through anything of ours.
if [ "$want" = all ] || [ "$want" = append ]; then
    img="$WORK/append.img"
    rm -f "$img"
    if ! command -v mkfs.vfat > /dev/null; then
        echo "FAIL append | mkfs.vfat is not installed, and the check needs it"
        failed=1
    else
        mkfs.vfat -F 16 -S 512 -n GOPHER -C "$img" 32768 > /dev/null 2>&1
        boot append \
            -drive id=d,file="$img",format=raw,if=none \
            -device virtio-blk-device,drive=d
        if [ -f "$WORK/append.out" ] && grep -aq PASS "$WORK/append.out"; then
            if fsck.vfat -n "$img" > "$WORK/append.fsck" 2>&1; then
                echo "     append | fsck.vfat finds no error after 600 appends"
            else
                echo "FAIL append | fsck.vfat rejects the appended volume:"
                grep -av "^fsck.fat\|^$" "$WORK/append.fsck" | head -8
                failed=1
            fi

            if ! sudo -n true 2>/dev/null; then
                echo "     append | SKIPPED the loop-mount check: it needs root"
            else
                mnt="$WORK/amnt"
                mkdir -p "$mnt"
                sudo mount -o loop,ro,noexec,nosuid,nodev "$img" "$mnt"
                # The expectation, generated HERE -- not read back through ours.
                { seq -f 'line %04g aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 1 600
                  echo 'one more'; } > "$WORK/append.want"   # the late append, through an open handle
                cp "$mnt/log.txt" "$WORK/append.got" 2>/dev/null || true
                small="$(cat "$mnt/small.txt" 2>/dev/null || true)"
                trunc_size="$(stat -c %s "$mnt/trunc.txt" 2>/dev/null || echo missing)"
                over="$(cat "$mnt/over.txt" 2>/dev/null || true)"
                nested="$(cat "$mnt/data/lynrummy/p1/lynrummy-elm/sessions/1/actions.dsl" 2>/dev/null || true)"
                sudo umount "$mnt"

                if ! cmp -s "$WORK/append.want" "$WORK/append.got"; then
                    echo "FAIL append | Linux reads a different log.txt than we appended:"
                    diff "$WORK/append.want" "$WORK/append.got" 2>&1 | head -6
                    failed=1
                elif [ "$small" != "abbccc" ]; then
                    echo "FAIL append | Linux reads [$small] where we appended [abbccc]"
                    failed=1
                elif [ "$trunc_size" != "0" ]; then
                    echo "FAIL append | Linux sees trunc.txt as [$trunc_size] bytes, want 0"
                    failed=1
                elif [ "$over" != "012XYZ6789" ]; then
                    echo "FAIL append | Linux reads [$over] where we overwrote [012XYZ6789]"
                    failed=1
                elif [ "$nested" != "$(printf '1) draw\n2) meld')" ]; then
                    echo "FAIL append | Linux reads [$nested] in the created tree"
                    failed=1
                else
                    echo "     append | the Linux VFAT driver reads all 600 lines and the late append, byte for byte"
                fi
            fi
        fi
    fi
fi

# **THE WRITES THAT TAKE THINGS AWAY.** Replace, delete and delete-tree, in a
# directory built to be fragmented with long names straddling its cluster
# edges — the shapes two FAT16 bugs needed. Judged by fsck.vfat (which must find
# nothing AND reclaim nothing: a leaked cluster is a failure here) and by
# probe/judge_replace.py, which reads the files through the Linux driver and
# checks from the raw image that the dangerous shapes were really produced.
if [ "$want" = all ] || [ "$want" = replace ]; then
    img="$WORK/replace.img"
    rm -f "$img"
    if ! command -v mkfs.vfat > /dev/null; then
        echo "FAIL replace | mkfs.vfat is not installed, and the check needs it"
        failed=1
    else
        mkfs.vfat -F 16 -S 512 -n GOPHER -C "$img" 32768 > /dev/null 2>&1
        boot replace \
            -drive id=d,file="$img",format=raw,if=none \
            -device virtio-blk-device,drive=d
        if [ -f "$WORK/replace.out" ] && grep -aq PASS "$WORK/replace.out"; then
            if fsck.vfat -n -v "$img" > "$WORK/replace.fsck" 2>&1 \
                && ! grep -qiE "reclaim|orphan|bad |wrong|truncat|lost" "$WORK/replace.fsck"; then
                echo "     replace | fsck.vfat finds nothing, and reclaims nothing"
            else
                echo "FAIL replace | fsck.vfat rejects the volume:"
                grep -aiE "reclaim|orphan|bad |wrong|truncat|lost|error" "$WORK/replace.fsck" | head -8
                failed=1
            fi

            if ! sudo -n true 2>/dev/null; then
                echo "     replace | SKIPPED the Linux read-back: it needs root"
            else
                mnt="$WORK/rmnt"
                mkdir -p "$mnt"
                sudo mount -o loop,ro,noexec,nosuid,nodev,uid="$(id -u)" "$img" "$mnt"
                if verdict="$(python3 "$HERE/judge_replace.py" "$img" "$mnt")"; then
                    echo "     replace | $verdict"
                else
                    echo "FAIL replace | $(echo "$verdict" | head -1)"
                    echo "$verdict" | tail -n +2 | sed 's/^/             /'
                    failed=1
                fi
                sudo umount "$mnt"
            fi
        fi
    fi
fi

# The clocks. clock.elf checks .awake and the arithmetic of .real once told;
# realunset.elf asks for .real WITHOUT being told, and must stop the machine
# with the message that names the fix. For that one a clean exit is the
# failure, so it has its own verdict.
if [ "$want" = all ] || [ "$want" = clock ]; then
    boot clock
    name=realunset
    if [ ! -f "$HERE/$name.elf" ]; then
        echo "FAIL $name | no $name.elf; run: zig build kernels"
        failed=1
    else
        timeout 60 qemu-system-x86_64 -M microvm -kernel "$HERE/$name.elf" \
            -nographic -no-reboot -m 512 \
            -device isa-debug-exit,iobase=0xf4,iosize=0x04 > "$WORK/$name.out" 2>&1
        code=$?
        if [ $code -eq 3 ] && grep -aq "PANIC: Io.Clock.now(.real) before setRealTime()" "$WORK/$name.out"; then
            echo "PASS $name | refused: .real before setRealTime() stops the machine"
        elif [ $code -eq 1 ]; then
            echo "FAIL $name | .real answered without being told: $(grep -a 'answered' "$WORK/$name.out")"
            failed=1
        else
            echo "FAIL $name | exited $code without the expected refusal; see $WORK/$name.out"
            failed=1
        fi
    fi
fi

# Entropy: the host's device and the CPU's instruction. -cpu max is what
# advertises RDRAND to the guest; microvm's default model does not.
if [ "$want" = all ] || [ "$want" = rng ]; then
    boot rng -cpu max -device virtio-rng-device
fi

if [ "$want" = all ] || [ "$want" = net ]; then
    boot net -cpu max -device virtio-rng-device \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0
fi

# The http probes are the only ones whose verdict is not their own output: it
# is what curl on this side gets back. QEMU forwards a host port to the guest's
# port 80, so nothing here needs a second machine or root.
#
# curl does the waiting. --retry-connrefused is the flag that matters: the
# guest is still bringing up a NIC and taking a DHCP lease while curl is
# already trying, and without it the first refused connection is fatal.
serve() {
    local name="$1" want_body="$2"
    if [ ! -f "$HERE/$name.elf" ]; then
        echo "FAIL $name | no $name.elf; run: zig build kernels"
        failed=1
        return
    fi
    local port out body
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    out="$WORK/$name.out"
    body="$WORK/$name.body"

    timeout 60 qemu-system-x86_64 \
        -M microvm \
        -kernel "$HERE/$name.elf" \
        -nographic -no-reboot -m 512 \
        -global virtio-mmio.force-legacy=false \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -cpu max -device virtio-rng-device \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:80" \
        -device virtio-net-device,netdev=n0 > "$out" 2>&1 &
    local qemu_pid=$!

    curl -sS --max-time 30 --retry 40 --retry-delay 1 --retry-connrefused \
        -o "$body" -w '%{http_code}' "http://127.0.0.1:$port/probe" > "$WORK/$name.code" 2>"$WORK/$name.err"
    local curl_code=$?
    wait $qemu_pid
    local qemu_exit=$?

    tr -cd '\11\12\15\40-\176' < "$out" \
        | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; /SeaBIOS/d; s/^.*Booting from ROM\.\.//' \
        | grep -v '^[[:space:]]*$' > "$out.txt"
    mv "$out.txt" "$out"

    if [ $curl_code -ne 0 ]; then
        echo "FAIL $name | curl failed: $(head -1 "$WORK/$name.err")"
        failed=1
    elif [ "$(cat "$WORK/$name.code")" != "200" ]; then
        echo "FAIL $name | status $(cat "$WORK/$name.code"), want 200; see $out"
        failed=1
    elif [ "$(cat "$body")" != "$want_body" ]; then
        echo "FAIL $name | body was [$(cat "$body")], want [$want_body]"
        failed=1
    elif [ $qemu_exit -ne 1 ]; then
        echo "FAIL $name | served, but the guest exited $qemu_exit; see $out"
        failed=1
    else
        echo "PASS $name | curl got \"$(cat "$body")\""
    fi
}

if [ "$want" = all ] || [ "$want" = http ]; then
    serve http "hello from no Linux"
fi

# The one that matters: the HTTP is zig's own std.http.Server, unmodified.
if [ "$want" = all ] || [ "$want" = stdhttp ]; then
    serve stdhttp "hello from std.http.Server, with no Linux under it"
fi

# **THE REAL SERVER.** angry-gopher's own driving.zig, from its own source,
# with one line changed per file by port.sh. Needs `zig build gopher`.
if [ "$want" = gopher ]; then
    serve gopher ""
fi

exit $failed
