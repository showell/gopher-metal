#!/bin/bash
# **THE DROPLET KERNEL, JUDGED HERE BEFORE IT GOES THERE.** Boots hello.elf the
# way a droplet would (no exit door, dirty RAM), with a host port forwarded to
# port 80 on each card, waits for it to say it is listening, and fetches from
# the public card and the private one in turn, three times each. Each answer
# must name the card it came in on and count the request, and the screen must
# show every request logged.
#
#   droplet/hello.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
qemu_pid=""
trap '[ -n "$qemu_pid" ] && kill "$qemu_pid" 2>/dev/null; rm -rf "$WORK"' EXIT

"$HERE/image.sh" "$ROOT/probe/hello.elf" "$WORK/disk.img" || exit 1
public=$(( 20000 + RANDOM % 10000 ))
private=$(( public + 1 ))
NO_DOOR=1 DIRTY=1 PUBLIC_FWD=$public PRIVATE_FWD=$private MONITOR_SOCKET="$WORK/monitor" \
    DISK="$WORK/disk.img" "$HERE/droplet.sh" > "$WORK/serial.txt" 2>&1 &
qemu_pid=$!

for _ in $(seq 1 600); do
    grep -aq 'listening on port 80\|^FAIL' "$WORK/serial.txt" 2>/dev/null && break
    sleep 0.1
done
grep -aq 'listening on port 80' "$WORK/serial.txt" || { echo "FAIL hello  it never listened:"; cat "$WORK/serial.txt"; exit 1; }

failed=0
n=0
for round in 1 2 3; do
    for card in public private; do
        n=$((n + 1))
        if [ "$card" = public ]; then port=$public; else port=$private; fi
        got=$(curl -sS --max-time 10 "http://127.0.0.1:$port/round$round" 2>&1)
        want="hello from no Linux, on the $card card, request $n"
        if [ "$got" = "$want" ]; then
            echo "PASS hello  $card: $got"
        else
            echo "FAIL hello  $card: wanted \"$want\", got \"$got\""; failed=1
        fi
    done
done

python3 - "$WORK" <<'PY'
import socket, sys, time, os
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(sys.argv[1], "monitor"))
for cmd in [f'pmemsave 0xb8000 4000 "{sys.argv[1]}/screen.bin"', "quit"]:
    s.sendall((cmd + "\n").encode())
    time.sleep(0.3)
PY
wait "$qemu_pid" 2>/dev/null
qemu_pid=""

python3 - "$WORK" "$n" <<'PY' || failed=1
import sys
work, n = sys.argv[1], int(sys.argv[2])
raw = open(f"{work}/screen.bin", "rb").read()
screen = [bytes(raw[(r * 80 + c) * 2] for c in range(80)).decode("latin-1").rstrip() for r in range(25)]
for line in screen:
    if line.strip():
        print("    | " + line)
logged = [l for l in screen if l.startswith("  request ")]
if len(logged) != n:
    print(f"FAIL hello  the screen logged {len(logged)} requests, not {n}")
    sys.exit(1)
print(f"PASS hello  the screen logged all {n} requests")
PY
exit $failed
