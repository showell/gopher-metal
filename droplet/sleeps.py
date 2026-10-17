#!/usr/bin/env python3
"""**A KERNEL THAT SLEEPS, ON A REAL TIMER** (docs/designs/DESIGN-sleep.md,
chunk 3). metal-vmm judges the sleep in its own time (its sleeps.sh); this is
the one check of a real processor's TSC-deadline timer and a real network
card's MSI-X wake, under QEMU with KVM on the droplet-shaped machine.

    droplet/sleeps.py            (probe/sleeper.elf built: zig build sleeper)

The sleeper (probe/sleeper/) wakes every 500 ms and says each wake on the
console. This reads the console as it comes and times each line on the
host's own monotonic clock:

- **the timer**: eight wakes in a row, each 495-600 ms after the one before
  in the host's time. A timer that never fired would wake at the longest
  rest (10 s); one a machine never armed would never halt at all;
- **asleep between them**: the host's facts (`/facts`) before and after the
  wakes: fewer than 200 rests across them, where the 1 ms slice would be
  about 4,000; a sleep between each two (a machine never armed pauses and
  counts no rest at all); and no missed wake;
- **a frame wakes a sleep**: five requests, each connected within 50 ms. A
  card whose interrupt did not wake the machine would answer at the next
  wake, 250 ms on average;
- **the guest's clock against the host's**: the guest's own times for the
  same wakes, as parts per million of skew. Reported, not judged: it is
  the PIT calibration's error, a droplet's real drift.

About 6 s. Exit 0 when every check holds; 1 otherwise, naming each; 2 when it
cannot run.
"""
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ELF = os.path.join(ROOT, "probe", "sleeper.elf")
PERIOD_MS = 500
WAKES = 8
WAKE = re.compile(r"^\s*wake (\d+) due (\d+) at (\d+) unix")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Unarmed(Exception):
    """The host's facts name no rests and no sleeps."""


def facts(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/facts", timeout=5) as r:
        text = r.read().decode()
    rests = re.search(r"^rests: (\d+),", text, re.M)
    sleeps = re.search(r"^sleeps: (\d+) while quiescent, (\d+) ended by a device, (\d+) by the longest rest \((\d+) ms\), (\d+) missed wakes", text, re.M)
    if not rests or not sleeps:
        # A machine that never armed its interrupts says neither: it never rests.
        raise Unarmed(text)
    return {"rests": int(rests[1]), "sleeps": int(sleeps[1]), "by_device": int(sleeps[2]), "missed": int(sleeps[5])}


def main():
    if not os.path.exists(ELF):
        print(f"sleeps.py: NOT RUN: no {ELF} (zig build sleeper)")
        return 2
    if not os.path.exists("/dev/kvm"):
        print("sleeps.py: NOT RUN: no /dev/kvm")
        return 2
    failed = []
    began = time.monotonic()
    with tempfile.TemporaryDirectory() as work:
        site = os.path.join(work, "site")
        os.makedirs(os.path.join(site, "data"))
        with open(os.path.join(site, "data", "sleeper.conf"), "w") as f:
            f.write(f"period_ms = {PERIOD_MS}\n")
        conf = os.path.join(work, "conf")
        with open(conf, "w") as f:
            f.write("requests = 1000\n")
        disk = os.path.join(work, "disk.img")
        made = subprocess.run([sys.executable, os.path.join(HERE, "app_image.py"), ELF, site, conf, disk], capture_output=True, text=True)
        if made.returncode != 0:
            print(f"sleeps.py: NOT RUN: app_image.py failed: {made.stdout}{made.stderr}")
            return 2
        port = free_port()
        env = dict(os.environ, NO_DOOR="1", PUBLIC_FWD=str(port), DISK=disk)
        qemu = subprocess.Popen([os.path.join(HERE, "droplet.sh")], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        lines = []  # (host monotonic ns, line)
        wakes = []  # (host ns, guest due ns, guest at ns)

        def read():
            for raw in qemu.stdout:
                t = time.monotonic_ns()
                line = raw.decode("latin-1").rstrip("\r\n")
                lines.append((t, line))
                m = WAKE.match(line)
                if m:
                    wakes.append((t, int(m[2]), int(m[3])))

        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        try:
            return judge(qemu, lines, wakes, port, failed, began)
        except Unarmed as e:
            print("  FAIL asleep: the host's facts name no rests and no sleeps: the machine never armed its interrupts")
            print("    " + "\n    ".join(str(e).splitlines()[:12]))
            print("SLEEPS (QEMU): FAIL (asleep)")
            return 1
        finally:
            qemu.kill()
            qemu.wait()


def judge(qemu, lines, wakes, port, failed, began):
    """The checks, on a running sleeper; what failed is appended to `failed`."""
    deadline = time.monotonic() + 60
    while not wakes and time.monotonic() < deadline and qemu.poll() is None:
        time.sleep(0.02)
    if not wakes:
        print("sleeps.py: FAIL boot: the sleeper never woke; its console:")
        for _, line in lines[-30:]:
            print("    " + line)
        return 1
    # The first wake is at boot, before the network is up for us:
    # let it settle a wake, then read the facts and time the rest.
    while len(wakes) < 2 and time.monotonic() < deadline:
        time.sleep(0.02)
    before = facts(port)
    first = len(wakes)
    while len(wakes) < first + WAKES and time.monotonic() < deadline:
        time.sleep(0.02)
    after = facts(port)
    timed = wakes[first - 1:first + WAKES]
    if len(timed) < WAKES + 1:
        failed.append("timer")
        print(f"  FAIL timer: {len(timed) - 1} wakes in a minute, not {WAKES}")
    else:
        gaps = [(b[0] - a[0]) / 1e6 for a, b in zip(timed, timed[1:])]
        bad = [g for g in gaps if g < 495 or g > 600]
        if bad:
            failed.append("timer")
            print(f"  FAIL timer: host gaps (ms) {', '.join(f'{g:.1f}' for g in gaps)}: want each 495-600")
        else:
            print(f"  timer: {WAKES} wakes, host gaps {min(gaps):.1f}-{max(gaps):.1f} ms")
        host_span = timed[-1][0] - timed[0][0]
        guest_span = timed[-1][2] - timed[0][2]
        print(f"  clock: the guest's {guest_span / 1e6:.1f} ms against the host's {host_span / 1e6:.1f} ms, {(guest_span / host_span - 1) * 1e6:+.0f} ppm (reported, not judged)")
    rests = after["rests"] - before["rests"]
    slept = after["sleeps"] - before["sleeps"]
    # A machine never armed pauses and counts no rest at all, so the
    # sleeps are counted too: at least one between two wakes.
    if rests >= 200 or slept < WAKES - 1 or after["missed"] != 0:
        failed.append("asleep")
        print(f"  FAIL asleep: {rests} rests and {slept} sleeps across {WAKES} wakes (want under 200, and at least {WAKES - 1}), {after['missed']} missed wakes (want 0)")
    else:
        print(f"  asleep: {rests} rests across {WAKES} wakes, {after['sleeps'] - before['sleeps']} sleeps, no missed wake")
    connects = []
    for k in range(5):
        time.sleep(0.137 * (k + 1))  # somewhere inside a sleep
        t0 = time.monotonic()
        with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
            connects.append((time.monotonic() - t0) * 1000)
            s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            while s.recv(65536):
                pass
    last = facts(port)
    if max(connects) >= 50 or last["by_device"] <= after["by_device"]:
        failed.append("woken")
        print(f"  FAIL woken: connects (ms) {', '.join(f'{c:.1f}' for c in connects)} (want each under 50), sleeps a device ended {after['by_device']} then {last['by_device']}")
    else:
        print(f"  woken: 5 requests into sleeps, connected in {max(connects):.1f} ms at most; {last['by_device'] - after['by_device']} sleeps ended by a device")
    print(f"time: {time.monotonic() - began:.1f} s")
    if failed:
        print(f"SLEEPS (QEMU): FAIL ({' '.join(failed)})")
        return 1
    print("SLEEPS (QEMU): PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
