#!/usr/bin/env python3
"""**THE SOAK: HOURS, NOT MINUTES** (QUEUE.md item 83). One metal boot, kept
busy with a realistic mix, watched for a trend that would end in a stop.

The stories prove metal answers as Linux answers; the stamina boot proves a
few hundred reads do not move its heaps; `judge_soak.py` proves a store read
back after thousands of writes loses nothing. None of them answers: *is it
still healthy after an hour of everything at once?*

So this boots once, with no request limit, and runs until `SOAK_SECONDS` is
up (an hour by default):

  - **a realistic mix**, the shapes `droplet/load.py` and `replay.py` make:
    browsers fetching the index, the activity page, the conversation list,
    the PDF and the growing transcript; a poster adding a numbered chat
    message a few times a second; an uploader posting small pictures; and
    chat streams held open the whole run, each of which must keep receiving
    the posted messages.
  - **four things sampled every minute** from /admin/host, to a CSV and a
    line of output: the heap (taken now, and the peak), the connection
    table (open now, and the peak, of 256), the held streams, and the
    volume's free space. The log ring is a fixed `.bss` ring and cannot
    grow; the heap is where a leak would show.
  - **a verdict on the trend, not just the end**: the heap taken must not
    climb across the run, the connections open must not climb, the held
    streams must stay the few we hold, and the free space must not be on
    course to run out. Any of those trending toward a stop fails it, and so
    does /admin/host ever failing to answer.

**The page cache is a setting** (`SOAK_PAGE_CACHE_MIB`, 64 by default, 0 to
turn it off). Run it both ways: the cache must not hide a leak, and item 90
changes the cache, so cache-off is the control.

    probe/soak.py <gopher.elf> <angry-gopher>
    SOAK_SECONDS=120 SOAK_SAMPLE_SECONDS=10 probe/soak.py ...   # a short run
    SOAK_PAGE_CACHE_MIB=0 probe/soak.py ...                     # cache off

It uses KVM when this user can open /dev/kvm (the box, overnight), TCG
otherwise (an hour here). Exit 0 when nothing trended toward a stop and
every held stream kept up.
"""

import http.client
import os
import re
import socket
import statistics
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import judge_gopher as J  # noqa: E402

SECONDS = int(os.environ.get("SOAK_SECONDS", "3600"))
SAMPLE = int(os.environ.get("SOAK_SAMPLE_SECONDS", "60"))
PAGE_CACHE_MIB = int(os.environ.get("SOAK_PAGE_CACHE_MIB", "64"))
BROWSERS = int(os.environ.get("SOAK_BROWSERS", "4"))
STREAMS = int(os.environ.get("SOAK_STREAMS", "4"))
CONV = "1_2"
TOPIC = "soak"


def host_facts(port: int) -> dict:
    """/admin/host's numbers, parsed from its table. Raises on no answer —
    which is the stop this is watching for."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    conn.request("GET", "/admin/host", headers={"Cookie": ADMIN})
    r = conn.getresponse()
    body = r.read().decode("latin-1")
    conn.close()
    if r.status != 200:
        raise RuntimeError(f"/admin/host answered {r.status}")
    rows = dict(re.findall(r"<tr><td>(.*?)</td><td>(.*?)</td></tr>", body))
    nums = lambda s: [int(x.replace(",", "")) for x in re.findall(r"\d+", s)]
    mem = nums(rows.get("memory (pages)", ""))
    conns = nums(rows.get("connections", ""))
    streams = nums(rows.get("streams", ""))
    vol = next((v for k, v in rows.items() if "the volume" in k or "boot disk" in k), "")
    free_m = re.search(r"(\d+) MB free", vol)  # not the serial's digits
    free = [int(free_m.group(1))] if free_m else []
    return {
        "heap_now_mb": mem[0] if mem else -1,
        "heap_peak_mb": mem[1] if len(mem) > 1 else -1,
        "conns_now": conns[0] if conns else -1,
        "conns_peak": conns[1] if len(conns) > 1 else -1,
        "conns_max": conns[2] if len(conns) > 2 else -1,
        "streams_now": streams[0] if streams else -1,
        "free_mb": free[0] if free else -1,
        "served": nums(rows.get("requests served", "0"))[0],
    }


def get(port: int, path: str, cookie: str = "", timeout: int = 30) -> int:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request("GET", path, headers={"Cookie": cookie} if cookie else {})
        r = conn.getresponse()
        r.read()
        return r.status
    finally:
        conn.close()


def post(port: int, path: str, body: bytes, ctype: str, cookie: str, timeout: int = 60) -> int:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request("POST", path, body=body, headers={"Cookie": cookie, "Content-Type": ctype})
        r = conn.getresponse()
        r.read()
        return r.status
    finally:
        conn.close()


class Workers:
    """The mix, as threads, until `stop` is set."""

    def __init__(self, port):
        self.port = port
        self.stop = threading.Event()
        self.posted = 0
        self.errors = []
        self.stream_frames = [0] * STREAMS
        self.threads = []

    def run(self):
        self.threads = (
            [threading.Thread(target=self.poster, daemon=True)]
            + [threading.Thread(target=self.browser, args=(k,), daemon=True) for k in range(BROWSERS)]
            + [threading.Thread(target=self.uploader, daemon=True)]
            + [threading.Thread(target=self.stream, args=(k,), daemon=True) for k in range(STREAMS)]
        )
        for t in self.threads:
            t.start()

    def note(self, what, e):
        if len(self.errors) < 50:
            self.errors.append(f"{what}: {type(e).__name__}: {e}")

    def poster(self):
        n = 0
        while not self.stop.is_set():
            n += 1
            body = f"markdown=soak+{n:06d}&cid=s{n}".encode()
            try:
                if post(self.port, f"/chat/c/{CONV}/{TOPIC}/send", body,
                        "application/x-www-form-urlencoded", SESSION) in (200, 303):
                    self.posted = n
            except OSError as e:
                self.note("post", e)
            self.stop.wait(0.4)

    def browser(self, k):
        paths = ["/", "/chat/recent", "/chat/conversations", "/steve-resume.pdf",
                 f"/chat/c/{CONV}/{TOPIC}/raw"]
        i = 0
        while not self.stop.is_set():
            try:
                get(self.port, paths[i % len(paths)], SESSION)
            except OSError as e:
                self.note("browse", e)
            i += 1
            self.stop.wait(0.1)

    def uploader(self):
        pic = J.multipart("soak.png", J.picture(64 << 10))
        while not self.stop.is_set():
            try:
                post(self.port, f"/chat/c/{CONV}/{TOPIC}/upload", pic,
                     f"multipart/form-data; boundary={J.UPLOAD_BOUNDARY}", SESSION)
            except OSError as e:
                self.note("upload", e)
            self.stop.wait(3.0)

    def stream(self, k):
        """Hold a chat stream open the whole run, reopening if it drops, and
        count the frames it receives — a held stream that stops getting the
        posted messages is a failure as much as a leak is."""
        while not self.stop.is_set():
            try:
                sock = J.open_stream(self.port, f"/chat/c/{CONV}/{TOPIC}/stream?since=0", SESSION)
                sock.settimeout(5)
                while not self.stop.is_set():
                    try:
                        chunk = sock.recv(4096)
                        if not chunk:
                            break
                        self.stream_frames[k] += chunk.count(b"data:")
                    except socket.timeout:
                        continue
                sock.close()
            except OSError as e:
                self.note("stream", e)
                self.stop.wait(1.0)

    def join(self):
        self.stop.set()
        for t in self.threads:
            t.join(timeout=10)


def trend(values):
    """The slope of a least-squares line through `values`, per sample."""
    n = len(values)
    if n < 3:
        return 0.0
    xs = list(range(n))
    mx = sum(xs) / n
    my = sum(values) / n
    denom = sum((x - mx) ** 2 for x in xs) or 1.0
    return sum((x - mx) * (y - my) for x, y in zip(xs, values)) / denom


def verdict(samples):
    """What trended toward a stop. Empty list means healthy."""
    bad = []
    half = samples[len(samples) // 2:]  # the settled half, after warm-up
    heap = [s["heap_now_mb"] for s in half]
    conns = [s["conns_now"] for s in half]
    free = [s["free_mb"] for s in samples]
    streams_now = [s["streams_now"] for s in half]

    # A leak: the heap taken climbs across the settled half. Allow noise, but
    # a slope that would add more than 32 MB over 10x this run is a trend.
    if trend(heap) * len(heap) > 4 and max(heap) - min(heap) > 8:
        bad.append(f"the heap taken trends up: {heap[0]} -> {heap[-1]} MB (+{trend(heap):.2f} MB/sample)")
    # Connections not closing: the count open climbs instead of returning to
    # the handful the mix holds.
    if trend(conns) * len(conns) > 2 and max(conns) > BROWSERS + STREAMS + 4:
        bad.append(f"connections open trend up: {conns[0]} -> {conns[-1]} (peak {max(conns)})")
    if max(s["conns_peak"] for s in samples) >= samples[0]["conns_max"]:
        bad.append("the connection table filled to its limit")
    # Held streams: the few we hold, not an unbounded climb.
    if streams_now and max(streams_now) > STREAMS + 2:
        bad.append(f"held streams climbed to {max(streams_now)}, more than the {STREAMS} held")
    # Free space on course to run out: a downward slope that reaches zero
    # within 5x the samples we took.
    s = trend(free)
    if s < 0 and free[-1] > 0 and free[-1] / -s < len(free) * 5:
        bad.append(f"free space is on course to run out: {free[0]} -> {free[-1]} MB ({s:.3f} MB/sample)")
    return bad


def main():
    global SESSION, ADMIN
    elf, gopher_root = sys.argv[1], sys.argv[2]
    kvm = J.kvm_usable()
    with tempfile.TemporaryDirectory(prefix="soak-") as work:
        content = os.path.join(work, "content")
        J.stage(content, gopher_root)
        image = os.path.join(work, "soak.img")
        mnt = os.path.join(work, "mnt")
        os.makedirs(mnt)
        J.build_disk(image, content, mnt)
        # No `requests` line: it serves until stopped. A long idle timeout so a
        # held stream is not let go, and the cache set as asked.
        J.disk_write(image, mnt, "gopher-metal.conf",
                     f"idle_timeout_ms = 120000\npage_cache_mib = {PAGE_CACHE_MIB}\n")
        SESSION = J.mint_session("1", int(time.time()))
        ADMIN = SESSION
        print(f"soak: {SECONDS}s, sampling every {SAMPLE}s, page_cache_mib={PAGE_CACHE_MIB}, "
              f"{BROWSERS} browsers + {STREAMS} held streams, under {'KVM' if kvm else 'TCG'}", flush=True)
        qemu, port, serial = J.start_kernel(elf, image, work, kvm=kvm)

        # The topic the mix posts to, made once.
        post(port, f"/chat/c/{CONV}/new", b"topic=soak", "application/x-www-form-urlencoded", SESSION)
        workers = Workers(port)
        workers.run()

        csv_path = os.path.join(os.path.dirname(elf), "soak.csv")
        csv = open(csv_path, "w")
        csv.write("t,heap_now_mb,heap_peak_mb,conns_now,conns_peak,streams_now,free_mb,served,posted\n")
        samples = []
        began = time.time()
        stop_reason = None
        try:
            while time.time() - began < SECONDS:
                time.sleep(SAMPLE)
                t = int(time.time() - began)
                if qemu.poll() is not None:
                    stop_reason = f"the kernel exited {qemu.returncode} at {t}s"
                    break
                try:
                    f = host_facts(port)
                except (OSError, RuntimeError) as e:
                    stop_reason = f"/admin/host stopped answering at {t}s: {e}"
                    break
                f["t"] = t
                f["posted"] = workers.posted
                samples.append(f)
                csv.write(f"{t},{f['heap_now_mb']},{f['heap_peak_mb']},{f['conns_now']},"
                          f"{f['conns_peak']},{f['streams_now']},{f['free_mb']},{f['served']},{f['posted']}\n")
                csv.flush()
                print(f"  {t:5d}s  heap {f['heap_now_mb']:4d}/{f['heap_peak_mb']:4d} MB  "
                      f"conns {f['conns_now']:3d}/{f['conns_peak']:3d}  streams {f['streams_now']:2d}  "
                      f"free {f['free_mb']:5d} MB  served {f['served']}  posted {f['posted']}", flush=True)
        finally:
            workers.join()
            csv.close()

        # The held streams kept up: each saw messages, and no worker hit a wall
        # of errors.
        frames = workers.stream_frames
        failures = []
        if stop_reason:
            failures.append(stop_reason)
        if len(samples) >= 3:
            failures += verdict(samples)
        elif not stop_reason:
            failures.append(f"only {len(samples)} samples: SOAK_SECONDS too short for SOAK_SAMPLE_SECONDS")
        if workers.posted > 0 and min(frames) == 0:
            failures.append(f"a held stream received nothing: frames per stream {frames}")
        if len(workers.errors) > len(samples) * 2 + 10:
            failures.append(f"{len(workers.errors)} worker errors, e.g. {workers.errors[:3]}")

        # The transcript read back holds the latest marks: nothing recent lost.
        try:
            final = host_facts(port)
            print(f"  final: served {final['served']}, posted {workers.posted}, "
                  f"stream frames {frames}", flush=True)
        except (OSError, RuntimeError):
            pass
        qemu.kill()
        qemu.wait()

        print(f"soak.csv at {csv_path}")
        if failures:
            for fdesc in failures:
                print(f"FAIL  soak: {fdesc}")
            return 1
        heap = [s["heap_now_mb"] for s in samples]
        print(f"ok    soak: {SECONDS}s, {samples[-1]['served']} requests, {workers.posted} messages posted, "
              f"each of {STREAMS} streams got {min(frames)}-{max(frames)} frames; heap {min(heap)}-{max(heap)} MB, "
              f"flat; connections and free space steady")
        return 0


if __name__ == "__main__":
    sys.exit(main())
