#!/usr/bin/env python3
"""The outside verdict on probe/clock.zig.

    judge_clock.py <serial output> <host unix before> <host unix after> [pinned base]

The probe prints what it measured; this compares it with what the HOST knows,
which the probe cannot see:

  unix     must lie between the host's clock just before QEMU started and just
           after it stopped (the RTC is emulated from the host's clock).
  civil    must be the same instant as `unix` — recomputed here with Python's
           calendar.timegm, not with the probe's arithmetic.
  tsc_hz   must be within 0.5% of the host kernel's own TSC calibration: under
           QEMU's emulation the guest's timestamp counter IS the host's. The
           host's number needs `sudo -n` to read; without it that comparison
           is reported as SKIPPED.

With a pinned base (YYYY-MM-DDTHH:MM:SS, UTC), QEMU was started with
`-rtc base=…`, so the host clock does not bound `unix`: it must lie a moment
AFTER the base instead — the probe reads at its second seconds-edge — and the
civil time is checked against that instant. Pinning a second before midnight
across a leap day, and before noon, is how the rollovers and the 12-hour
edges are checked against the chip model itself.

Exit 0 and one line of evidence per check; 1 on any failure.
"""
import calendar
import re
import time
import subprocess
import sys


def host_tsc_hz():
    for cmd in (["sudo", "-n", "journalctl", "-k", "-b", "--no-pager"], ["sudo", "-n", "dmesg"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        refined = re.findall(r"tsc: Refined TSC clocksource calibration: ([0-9.]+) MHz", out)
        detected = re.findall(r"tsc: Detected ([0-9.]+) MHz", out)
        found = refined or detected
        if found:
            return float(found[-1]) * 1e6
    return None


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(__doc__.strip())
        return 2
    text = open(sys.argv[1], "rb").read().decode("latin-1")
    before, after = int(sys.argv[2]), int(sys.argv[3])
    pinned = sys.argv[4] if len(sys.argv) == 5 else None

    def field(name):
        m = re.search(rf"^{name} (.+)$", text, re.M)
        if not m:
            raise SystemExit(f"FAIL the probe printed no `{name}` line")
        return m.group(1).strip()

    unix = int(field("unix"))
    hz = int(field("tsc_hz"))
    date, clock = field("civil").split()
    y, mo, d = (int(v) for v in date.split("-"))
    h, mi, s = (int(v) for v in clock.split(":"))
    failed = False

    recomputed = calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))
    if recomputed != unix:
        print(f"FAIL civil {date} {clock} is {recomputed} by calendar.timegm, but the probe said {unix}")
        failed = True
    else:
        print(f"ok   civil {date} {clock} and unix {unix} are the same instant")

    if pinned:
        base = calendar.timegm(time.strptime(pinned, "%Y-%m-%dT%H:%M:%S"))
        if not base + 1 <= unix <= base + 15:
            print(f"FAIL unix {unix} is not just after the pinned {pinned} ({base})")
            failed = True
        else:
            print(f"ok   unix {unix} is {unix - base} s after the pinned {pinned}")
    else:
        if not before <= unix <= after + 1:
            print(f"FAIL unix {unix} is outside the host's clock [{before}, {after + 1}]")
            failed = True
        else:
            print(f"ok   unix {unix} is within the host's clock [{before}, {after + 1}]")

    host = host_tsc_hz()
    if host is None:
        print("SKIP tsc_hz: the host's own calibration needs `sudo -n` to read")
    else:
        err = abs(hz - host) / host
        verdict = "ok  " if err <= 0.005 else "FAIL"
        print(f"{verdict} tsc_hz {hz} vs the host's {host:.0f} ({err * 100:.3f}%)")
        failed = failed or err > 0.005
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
