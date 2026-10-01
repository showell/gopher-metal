#!/bin/bash
# **WHAT THE RECOVERY CONSOLE WOULD SHOW.** On a real droplet nobody reads the
# serial port; DigitalOcean's recovery console shows the screen. So this boots
# a probe the way a droplet would — no exit door, so the kernel halts when it
# is done and the screen stays as it left it — waits for PASS on the serial
# port, then copies the screen's text memory (0xB8000, 80x25, a character and
# a colour byte each) out through QEMU's monitor.
#
# The judge: every line the kernel said on the serial port is on the screen,
# in the same order, along with the loader's lines before them. The screen is
# printed, and a picture of it kept as screen.ppm when SCREEN_PPM names a path.
#
#   droplet/screen.sh            the memory probe
#   droplet/screen.sh clock      another
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
probe="${1:-memory}"
qemu_pid=""
trap '[ -n "$qemu_pid" ] && kill "$qemu_pid" 2>/dev/null; rm -rf "$WORK"' EXIT

"$HERE/image.sh" "$ROOT/probe/$probe.elf" "$WORK/disk.img" || exit 1

NO_DOOR=1 MONITOR_SOCKET="$WORK/monitor" DISK="$WORK/disk.img" \
    "$HERE/droplet.sh" > "$WORK/serial.txt" 2>&1 &
qemu_pid=$!

# The kernel halts after PASS or FAIL rather than leaving, so the serial port
# is watched for either, for up to a minute.
for _ in $(seq 1 600); do
    grep -aq '^PASS\|^FAIL' "$WORK/serial.txt" 2>/dev/null && break
    sleep 0.1
done
grep -aq '^PASS' "$WORK/serial.txt" || { echo "FAIL screen  the probe did not pass:"; cat "$WORK/serial.txt"; exit 1; }

python3 - "$WORK" "${SCREEN_PPM:-}" <<'PY'
import socket, sys, time, os
work, ppm = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(work, "monitor"))
def ask(cmd):
    s.sendall((cmd + "\n").encode())
    time.sleep(0.3)
ask(f'pmemsave 0xb8000 4000 "{work}/screen.bin"')
if ppm:
    ask(f'screendump "{ppm}"')
ask("quit")
PY
wait "$qemu_pid" 2>/dev/null
qemu_pid=""

python3 - "$WORK" <<'PY'
import sys
work = sys.argv[1]
raw = open(f"{work}/screen.bin", "rb").read()
screen = [bytes(raw[(r * 80 + c) * 2] for c in range(80)).decode("latin-1").rstrip() for r in range(25)]
said = [l.rstrip("\r\n").rstrip() for l in open(f"{work}/serial.txt", encoding="latin-1")]
said = [l for l in said if l]
print("  ┌" + "─" * 80 + "┐")
for line in screen:
    print("  │" + line.ljust(80) + "│")
print("  └" + "─" * 80 + "┘")
# Each serial line, in order, among the screen's rows.
at = 0
for line in said:
    while at < len(screen) and screen[at] != line[:80]:
        at += 1
    if at == len(screen):
        print(f"FAIL screen  the serial port said {line!r}, and the screen does not show it there")
        sys.exit(1)
    at += 1
print(f"PASS screen  all {len(said)} lines the serial port carried are on the screen, in order")
PY
