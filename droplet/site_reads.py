#!/usr/bin/env python3
"""What the site's own files cost metal per request, by its own clock
(QUEUE.md item 61).

    droplet/site_reads.py [N]        N rounds (default 20)

Boots probe/gopher.elf under QEMU on the judge's staged site, on a disk
built without root (build_volume.py's mtools path), asks each of a few
pages N times, and reads the kernel's own line for each request:
`answered in X us, N disk requests taking Y us`. It prints the median of
each, per page, leaving out each page's first two (the first read of a
file, and warm-up).

The pages: /tutorial is embedded in the binary (no file); the others read a
file from the boot disk (pages/home.txt, the resume, its PDF, the Safari
page). Under TCG the times are slow and only comparable to each other;
the box measures for real on the droplet.

Exit 0 when it ran, 1 when the kernel did not answer.
"""
import http.client
import os
import re
import statistics
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
import build_volume  # noqa: E402
import judge_gopher as G  # noqa: E402

GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
PAGES = ["/tutorial", "/steve-resume", "/", "/steve-resume.pdf", "/safari_download"]
LINE = re.compile(r"request \d+: GET (\S+) -> [^\n]*\n\s+waited \d+ us, answered in (\d+) us, "
                  r"(\d+) disk requests taking (\d+) us")


def main(argv) -> int:
    rounds = int(argv[1]) if len(argv) > 1 else 20
    with tempfile.TemporaryDirectory() as d:
        site = os.path.join(d, "site")
        G.stage(site, GOPHER_ROOT)
        with open(os.path.join(site, "gopher-metal.conf"), "w") as f:
            f.write("idle_timeout_ms = 10000\n")
        img = os.path.join(d, "disk.img")
        build_volume.build(site, img, fat=16, size=64 << 20, check=False)
        qemu, port, serial = G.start_kernel(os.path.join(ROOT, "probe", "gopher.elf"), img, d)
        try:
            for _ in range(rounds):
                for p in PAGES:
                    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                    c.request("GET", p)
                    c.getresponse().read()
                    c.close()
            time.sleep(1)
        except OSError as e:
            print(f"site_reads.py: the kernel did not answer: {e}")
            return 1
        finally:
            qemu.kill()
            qemu.wait()
        with open(serial, "rb") as f:
            log = f.read().decode("latin-1")
    by = {}
    for path, answered, requests, disk in LINE.findall(log):
        by.setdefault(path, []).append((int(answered), int(requests), int(disk)))
    print(f"{'page':20} {'n':>4} {'answered (us)':>14} {'disk requests':>14} {'disk (us)':>10}")
    for p in PAGES:
        rows = by.get(p, [])[2:]
        if not rows:
            print(f"{p:20} no answers logged")
            continue
        med = lambda k: statistics.median(r[k] for r in rows)
        print(f"{p:20} {len(rows):4d} {med(0):14.0f} {med(1):14.0f} {med(2):10.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
