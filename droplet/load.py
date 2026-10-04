#!/usr/bin/env python3
"""Big uploads while others browse (QUEUE.md item 40).

    droplet/load.py BASE_URL SECRET_FILE [--uid 1] [--conv 1_2] [--seconds 30]
                    [--browsers 4] [--streams 4] [--upload-mb 64]
    droplet/load.py --self-test ZIG_SERVER_BINARY

The same load is run twice: once with no upload, then while one client
uploads `--upload-mb` MB videos in a loop. Each time:
- **browsers** (`--browsers` of them) fetch a handful of pages over and
  over, and the time to each answer's first byte is kept;
- **streams** (`--streams` of them) hold a topic's chat stream open, and a
  poster sends a numbered message to that topic every two seconds. Each
  stream must see each message: how long it took, and a **stall** when
  that is over 2 s or it never comes.

It reports both runs side by side: first-byte median, 90th percentile and
worst; stream delivery median and worst; stalls; uploads made.

Everything is done as `--uid` (default 1), with a session minted from the
site's secret (`auth/_session_secret`, passed as SECRET_FILE), in the
DM `--conv` (default 1_2), in a topic of its own, `load-<time>`, which it
makes. Pictures are capped at 10 MiB, so an upload of 50-100 MB is a
video: an MP4 header and zeros, which the upload's sniffing takes.
**Each user may upload 1 GiB in their lifetime.** After that an upload is
refused, but only once its body has been read, so the load goes on. The
report counts refusals apart.

Exit 0 when it ran, 1 when the server stopped answering, 2 for a usage
error.
"""
import base64
import hashlib
import hmac
import http.client
import os
import re
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
STALL_S = 2.0
POST_EVERY_S = 2.0


def mint_session(secret: bytes, uid: str, issued: int) -> str:
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    mac = hmac.new(secret, f"{uid}\n{issued}".encode(), hashlib.sha256).digest()
    return f"gopher_auth={b64(uid.encode())}.{issued}.{b64(mac)}"


class Site:
    def __init__(self, base: str, cookie: str):
        u = urllib.parse.urlsplit(base)
        self.host, self.port, self.cookie = u.hostname, u.port or 80, cookie

    def conn(self, timeout=30):
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def ask(self, method, path, body=None, headers=None):
        c = self.conn()
        try:
            h = {"Cookie": self.cookie, **(headers or {})}
            c.request(method, path, body=body, headers=h)
            r = c.getresponse()
            return r.status, r.read()
        finally:
            c.close()


def browser(site: Site, pages: list, stop: threading.Event, ttfb: list):
    while not stop.is_set():
        for p in pages:
            if stop.is_set():
                return
            c = site.conn()
            try:
                t0 = time.time()
                c.request("GET", p, headers={"Cookie": site.cookie})
                r = c.getresponse()
                ttfb.append((time.time() - t0) * 1000)
                r.read()
            except OSError:
                ttfb.append(float("inf"))
            finally:
                c.close()


def stream(site: Site, path: str, stop: threading.Event, seen: dict, ready: threading.Event):
    """Records, for each mark this stream sees, when it saw it."""
    c = site.conn(timeout=60)
    try:
        c.request("GET", path, headers={"Cookie": site.cookie, "Accept": "text/event-stream"})
        r = c.getresponse()
        ready.set()
        while not stop.is_set():
            line = r.readline()
            if not line:
                return
            for mark in re.findall(rb"loadmark-[a-z]+-\d{4}", line):
                seen.setdefault(mark.decode(), time.time())
    except OSError:
        return
    finally:
        c.close()


def poster(site: Site, topic_path: str, stop: threading.Event, posted: dict, tag: str):
    n = 0
    while not stop.wait(POST_EVERY_S):
        n += 1
        # Tagged by run: the second run's streams see the first run's
        # messages in their backlog, and must not count them as new.
        mark = f"loadmark-{tag}-{n:04d}"
        posted[mark] = time.time()
        site.ask("POST", f"{topic_path}/send", f"markdown={mark}&cid=l{n}",
                 {"Content-Type": "application/x-www-form-urlencoded", "X-Chat-Async": "1"})


def uploader(site: Site, topic_path: str, mb: int, stop: threading.Event, made: list):
    video = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2" + bytes(mb << 20)
    boundary = "loadpyboundary"
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"v.mp4\"\r\n"
            f"Content-Type: video/mp4\r\n\r\n").encode() + video + f"\r\n--{boundary}--\r\n".encode()
    while not stop.is_set():
        try:
            status, _ = site.ask("POST", f"{topic_path}/upload", body,
                                 {"Content-Type": f"multipart/form-data; boundary={boundary}"})
            made.append(status)
        except OSError:
            made.append(0)


def phase(site: Site, topic_path: str, seconds: float, browsers: int, streams: int, upload_mb: int) -> dict:
    stop = threading.Event()
    ttfb, posted, made = [], {}, []
    seen = [dict() for _ in range(streams)]
    readies = [threading.Event() for _ in range(streams)]
    threads = [threading.Thread(target=stream, args=(site, f"{topic_path}/stream", stop, seen[i], readies[i]),
                                daemon=True) for i in range(streams)]
    for t in threads:
        t.start()
    for r in readies:
        r.wait(10)
    pages = ["/", "/chat/recent", topic_path, f"{topic_path}/raw", "/chat/docs/list", "/settings"]
    workers = [threading.Thread(target=browser, args=(site, pages, stop, ttfb), daemon=True) for _ in range(browsers)]
    tag = "loaded" if upload_mb else "quiet"
    workers.append(threading.Thread(target=poster, args=(site, topic_path, stop, posted, tag), daemon=True))
    if upload_mb:
        workers.append(threading.Thread(target=uploader, args=(site, topic_path, upload_mb, stop, made), daemon=True))
    for w in workers:
        w.start()
    time.sleep(seconds)
    stop.set()
    time.sleep(STALL_S + 0.5)  # the last message's grace
    lat, stalls = [], 0
    for mark, at in posted.items():
        for s in seen:
            got = s.get(mark)
            if got is None or got - at > STALL_S:
                stalls += 1
            if got is not None:
                lat.append((got - at) * 1000)
    finite = sorted(t for t in ttfb if t != float("inf"))
    q = lambda xs, f: xs[min(len(xs) - 1, int(f * len(xs)))] if xs else float("nan")
    return {"requests": len(ttfb), "failed": len(ttfb) - len(finite),
            "ttfb_median": statistics.median(finite) if finite else float("nan"),
            "ttfb_p90": q(finite, 0.9), "ttfb_worst": finite[-1] if finite else float("nan"),
            "messages": len(posted), "deliveries": len(lat),
            "stream_median": statistics.median(lat) if lat else float("nan"),
            "stream_worst": max(lat) if lat else float("nan"), "stalls": stalls,
            "uploads": sum(1 for m in made if m == 200), "uploads_refused": sum(1 for m in made if m not in (200,))}


def report(quiet: dict, loaded: dict, out=print):
    rows = [("first byte, median (ms)", "ttfb_median"), ("first byte, 90th (ms)", "ttfb_p90"),
            ("first byte, worst (ms)", "ttfb_worst"), ("page requests", "requests"), ("failed", "failed"),
            ("stream delivery, median (ms)", "stream_median"), ("stream delivery, worst (ms)", "stream_worst"),
            ("messages posted", "messages"), ("stalls (over 2 s or never)", "stalls"),
            ("uploads made", "uploads"), ("uploads refused", "uploads_refused")]
    out(f"{'':32} {'no upload':>12} {'uploading':>12}")
    for label, k in rows:
        fmt = (lambda v: f"{v:12.1f}") if isinstance(quiet[k], float) else (lambda v: f"{v:12d}")
        out(f"{label:32} {fmt(quiet[k])} {fmt(loaded[k])}")


def run(base: str, secret: bytes, uid: str, conv: str, seconds: float, browsers: int, streams: int,
        upload_mb: int, out=print) -> tuple:
    site = Site(base, mint_session(secret, uid, int(time.time())))
    topic = f"load-{int(time.time())}"
    status, _ = site.ask("POST", f"/chat/c/{conv}/new", f"topic={topic}",
                         {"Content-Type": "application/x-www-form-urlencoded"})
    if status not in (200, 303):
        raise RuntimeError(f"could not make the topic: {status}")
    path = f"/chat/c/{conv}/{topic}"
    quiet = phase(site, path, seconds, browsers, streams, 0)
    loaded = phase(site, path, seconds, browsers, streams, upload_mb)
    report(quiet, loaded, out)
    return quiet, loaded


def main(argv) -> int:
    if argv[1:2] == ["--self-test"] and len(argv) == 3:
        return self_test(argv[2])
    args = argv[1:]
    opts = {"--uid": "1", "--conv": "1_2", "--seconds": "30", "--browsers": "4", "--streams": "4",
            "--upload-mb": "64"}
    for flag in list(opts):
        if flag in args:
            i = args.index(flag)
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 2 or not os.path.isfile(args[1]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(args[1], "rb") as f:
        secret = f.read()
    try:
        run(args[0], secret, opts["--uid"], opts["--conv"], float(opts["--seconds"]),
            int(opts["--browsers"]), int(opts["--streams"]), int(opts["--upload-mb"]))
    except (OSError, RuntimeError) as e:
        print(f"load.py: {e}", file=sys.stderr)
        return 1
    return 0


def self_test(binary: str) -> int:
    """Against a Linux server on the judge's staged site: both runs complete,
    every message reaches every stream, uploads are made, and the report has
    both columns."""
    sys.path.insert(0, os.path.join(ROOT, "probe"))
    import judge_gopher as G
    gopher_root = os.path.dirname(os.path.abspath(binary))
    while not os.path.isfile(os.path.join(gopher_root, "pages", "home.txt")):
        if gopher_root == os.path.dirname(gopher_root):
            print(f"self-test cannot run: no angry-gopher checkout above {binary}")
            return 2
        gopher_root = os.path.dirname(gopher_root)
    failures = []
    lines = []
    with tempfile.TemporaryDirectory() as d:
        site = os.path.join(d, "site")
        G.stage(site, gopher_root)
        server = G.LinuxServer(binary, site, os.path.join(d, "server.log"))
        try:
            quiet, loaded = run(f"http://127.0.0.1:{server.port}", G.SESSION_SECRET, "1", "1_2",
                                5, 2, 2, 16, lines.append)
        finally:
            server.stop()
    for name, p in (("no upload", quiet), ("uploading", loaded)):
        if p["requests"] < 10 or p["failed"]:
            failures.append(f"{name}: {p['requests']} page requests, {p['failed']} failed")
        if p["messages"] < 2 or p["stalls"]:
            failures.append(f"{name}: {p['messages']} messages, {p['stalls']} stalls")
        if p["deliveries"] != p["messages"] * 2:
            failures.append(f"{name}: {p['deliveries']} deliveries of {p['messages']} messages to 2 streams")
    if loaded["uploads"] < 1:
        failures.append(f"no upload was made ({loaded['uploads_refused']} refused)")
    if quiet["uploads"] or quiet["uploads_refused"]:
        failures.append("the quiet run uploaded")
    if failures:
        print("\n".join(lines))
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("\n".join(lines))
    print("self-test passed: both runs on a Linux server, every message to every stream within 2 s, "
          f"{loaded['uploads']} uploads of 16 MB made under load")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
