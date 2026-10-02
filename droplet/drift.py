#!/usr/bin/env python3
"""Two hosts' clocks, compared over time (QUEUE.md item 39): metal's
against prod's, over the private network.

    droplet/drift.py A_URL B_URL [--every 60] [--for 3600] [--netns NAME]
    droplet/drift.py --self-test [ZIG_SERVER_BINARY]

Every `--every` seconds for `--for` seconds, each host is asked for
`/version`, whose `now_ms` is its wall clock in milliseconds. A sample takes
the quickest of five requests to each host, and the host's offset from this
machine is its `now_ms` less the request's midpoint: the round trip halved
out, so a slow network is not counted as a slow clock. A line per sample
shows B's offset from A and both round trips. At the end comes a straight
line fitted to B less A over time: where it started, its drift in ppm and
seconds a day, and how far the samples scatter about it.

**WHY NOT THE DATE HEADER:** neither host sends one, and whole seconds
cannot show a drift of milliseconds a day. `now_ms` is in angry-gopher's
/version from `30350218` on.

With `--netns NAME`, the whole script runs inside `ip netns exec NAME`, so
both hosts are timed by the same process: run it where both can be reached.

Exit 0 when it ran, 1 when a host stopped answering, 2 for a usage error.
"""
import http.client
import json
import os
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TRIES = 5


def offset(url: str) -> tuple:
    """(offset in ms of the host's clock from this machine's, round trip in
    ms) from the quickest of TRIES requests."""
    u = urllib.parse.urlsplit(url)
    best = None
    for _ in range(TRIES):
        conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=10)
        try:
            conn.connect()
            t0 = time.time()
            conn.request("GET", "/version")
            r = conn.getresponse()
            body = r.read()
            t1 = time.time()
        finally:
            conn.close()
        now = json.loads(body)["now_ms"]
        rtt = (t1 - t0) * 1000
        off = now - (t0 + t1) * 500
        if best is None or rtt < best[1]:
            best = (off, rtt)
    return best


def fit(points: list) -> tuple:
    """Least squares over (seconds, ms): (ms at the start, ms per second,
    the residuals' standard deviation in ms)."""
    if len(points) < 2:
        return (points[0][1] if points else 0.0, 0.0, 0.0)
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx if sxx else 0.0
    start = my - slope * mx
    resid = [y - (start + slope * x) for x, y in zip(xs, ys)]
    return start, slope, statistics.pstdev(resid)


def run(a: str, b: str, every: float, total: float, out=print) -> list:
    """The samples, as (seconds since the first, B less A in ms, rtt A, rtt B)."""
    samples = []
    first = time.time()
    while True:
        t = time.time() - first
        oa, ra = offset(a)
        ob, rb = offset(b)
        samples.append((t, ob - oa, ra, rb))
        out(f"{t:8.0f} s   B - A = {ob - oa:+9.1f} ms   round trips {ra:5.1f} / {rb:5.1f} ms")
        if t + every > total:
            return samples
        time.sleep(max(0.0, first + t + every - time.time()))


def summary(samples: list) -> dict:
    start, slope, scatter = fit([(s[0], s[1]) for s in samples])
    return {"samples": len(samples), "start_ms": start, "ppm": slope * 1000, "scatter_ms": scatter,
            "rtt_a_ms": statistics.median(s[2] for s in samples),
            "rtt_b_ms": statistics.median(s[3] for s in samples)}


def report(s: dict, out=print) -> None:
    out(f"drift.py: {s['samples']} samples. B was {s['start_ms']:+.1f} ms from A at the start, "
        f"and drifts {s['ppm']:+.2f} ppm ({s['ppm'] * 86400 / 1e6:+.3f} s a day); "
        f"samples scatter {s['scatter_ms']:.1f} ms about that line. "
        f"Median round trips {s['rtt_a_ms']:.1f} / {s['rtt_b_ms']:.1f} ms.")


def main(argv) -> int:
    if argv[1:2] == ["--self-test"]:
        return self_test(argv[2] if len(argv) > 2 else None)
    args = argv[1:]
    opts = {"--every": "60", "--for": "3600", "--netns": None}
    for flag in list(opts):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                print(__doc__.strip(), file=sys.stderr)
                return 2
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if opts["--netns"]:
        rest = [a for a in argv[1:] if a not in ("--netns", opts["--netns"])]
        return subprocess.call(["ip", "netns", "exec", opts["--netns"], sys.executable, argv[0], *rest])
    try:
        samples = run(args[0], args[1], float(opts["--every"]), float(opts["--for"]))
    except (OSError, ValueError, KeyError) as e:
        print(f"drift.py: a host stopped answering: {e}", file=sys.stderr)
        return 1
    report(summary(samples))
    return 0


# ── the self-test ───────────────────────────────────────────────────────────

class Skewed:
    """An HTTP server whose /version clock is this machine's, offset by
    `offset_ms` and running fast by `ppm`: a host with a wrong clock."""

    def __init__(self, offset_ms: float, ppm: float):
        import http.server
        start = time.time()

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                now = time.time()
                skewed = (now + (now - start) * ppm / 1e6) * 1000 + offset_ms
                body = json.dumps({"result": "success", "now_ms": int(skewed)}).encode()
                self.send_response(200)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()


def self_test(binary: str = None) -> int:
    failures = []
    quiet = lambda *a: None
    with tempfile.TemporaryDirectory() as d:
        server = None
        if binary:
            # A real zig-server for A: its /version must carry now_ms.
            sys.path.insert(0, os.path.join(ROOT, "probe"))
            import judge_gopher as G
            os.makedirs(os.path.join(d, "data"))
            os.makedirs(os.path.join(d, "auth"))
            server = G.LinuxServer(binary, d, os.path.join(d, "server.log"))
            a = f"http://127.0.0.1:{server.port}"
        else:
            right = Skewed(0, 0)
            a = right.url
        try:
            # B: 2.5 s ahead, gaining 2,000 ppm (7.2 s an hour), so the trend
            # shows in a short run.
            wrong = Skewed(2500, 2000)
            s = summary(run(a, wrong.url, 0.5, 10, quiet))
            if abs(s["start_ms"] - 2500) > 50:
                failures.append(f"the offset read {s['start_ms']:.0f} ms, not 2500")
            if abs(s["ppm"] - 2000) > 200:
                failures.append(f"the drift read {s['ppm']:.0f} ppm, not 2000")
            # A host against itself: no offset, no drift.
            same = summary(run(a, a, 0.5, 5, quiet))
            if abs(same["start_ms"]) > 20 or abs(same["ppm"]) > 200:
                failures.append(f"a host against itself read {same['start_ms']:.1f} ms, {same['ppm']:.0f} ppm")
            wrong.stop()
        finally:
            if server:
                server.stop()
    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print(f"self-test passed: a clock 2,500 ms ahead and gaining 2,000 ppm read as "
          f"{s['start_ms']:+.0f} ms and {s['ppm']:+.0f} ppm; a host against itself as "
          f"{same['start_ms']:+.1f} ms" + (", against a real zig-server's now_ms" if binary else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
