"""**WHAT A BIG UPLOAD COSTS THE MACHINE.** On the droplet machine (KVM), a
member uploads 1.8 MB, 10 MB and 100 MB while a second client asks GET /
every 50 ms. Prints, per upload: the client's wall time, the kernel's own log
lines for it (how long it took to arrive, the turn, its DISK REQUESTS), and the
longest any GET / waited.

    python3 probe/bench_upload.py <work dir>     # needs KVM; ./port.sh, zig build gopher first

**THE NUMBER THAT CARRIES TO PROD IS THE DISK REQUEST COUNT**, not the times:
QEMU's disk here answers a request in ~0.1 ms, prod's network volume (write
cache off) in ~2 ms (a 1.8 MB upload's 93 requests took 0.18 s there,
2026-10-11). On v28: 93, 218 and 2,017 requests (64 KiB each at most), so
a 100 MB upload's turn is ~4-8 s on prod. The transfer is not the cost
(~60 MB/s here, drained before the turn).
"""
import os, sys, time, threading, http.client, re, shutil

os.environ["JUDGE_DROPLET"] = "1"
GM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AG = os.environ.get("GOPHER_ROOT", os.path.join(os.path.dirname(GM), "angry-gopher"))
sys.path.insert(0, os.path.join(GM, "probe"))
import judge_gopher as j  # noqa: E402

work = sys.argv[1]
os.makedirs(work, exist_ok=True)
content = os.path.join(work, "content")
mnt = os.path.join(work, "mnt")
image = os.path.join(work, "data.img")
if not os.path.isdir(content):
    j.stage(content, AG)
j.build_disk(image, content, mnt, size=1 << 30, fat="32", cluster_sectors=16)
j.set_request_limit(image, 100000, mnt)
elf = os.path.join(GM, "probe", "gopher.elf")
session = j.mint_session("1", int(time.time()))

qemu, port, serial = j.start_kernel(elf, image, work)
print(f"booted, port {port}, KVM {j.kvm_usable()}", flush=True)


def ask(method, path, body=None, ctype=None, timeout=600):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    headers = {"Host": "lynrummy.com", "Cookie": session}
    if ctype:
        headers["Content-Type"] = ctype
    t0 = time.monotonic()
    conn.request(method, path, body=body, headers=headers)
    r = conn.getresponse()
    data = r.read()
    conn.close()
    return r.status, data, time.monotonic() - t0


def payload(n, kind):
    if kind == "image":
        return j.picture(n), "big.png"
    head = b"\x00\x00\x00\x18ftypisom"
    return head + os.urandom(n - len(head)), "big.mp4"


try:
    ask("GET", "/")  # warm
    # A topic is made by its first message; an upload to one not there is a 404.
    st, _, _ = ask("POST", "/chat/c/1_2/general/send", b"markdown=pictures+follow&cid=u1",
                   "application/x-www-form-urlencoded")
    print("topic made:", st, flush=True)
    for label, n, kind in [("1.8 MB photo", 1_800_000, "image"),
                           ("10 MB image (the cap)", 10 * 1024 * 1024 - 4096, "image"),
                           ("100 MB video (the cap)", 100 * 1024 * 1024 - 4096, "video")]:
        data, name = payload(n, kind)
        body = j.multipart(name, data)
        waits, stop = [], threading.Event()

        def poll():
            while not stop.is_set():
                t0 = time.monotonic()
                try:
                    s, _, el = ask("GET", "/", timeout=120)
                    waits.append((t0, el, s))
                except Exception as e:  # noqa: BLE001
                    waits.append((t0, time.monotonic() - t0, str(e)))
                time.sleep(0.05)

        before = open(serial, "rb").read()
        th = threading.Thread(target=poll)
        th.start()
        time.sleep(0.3)
        s, resp, el = ask("POST", "/chat/c/1_2/general/upload", body,
                          f"multipart/form-data; boundary={j.UPLOAD_BOUNDARY}")
        time.sleep(1.0)
        stop.set()
        th.join()
        log = open(serial, "rb").read()[len(before):].decode("utf-8", "replace")
        print(f"\n== {label}: {len(body):,} bytes sent, answered {s} in {el:.2f} s "
              f"({len(body) / el / 1e6:.1f} MB/s through QEMU's user networking)")
        print(f"   {resp[:120]!r}")
        worst = max(waits, key=lambda w: w[1]) if waits else None
        if worst:
            print(f"   GET / beside it: {len(waits)} asked, longest {worst[1] * 1000:.0f} ms "
                  f"(status {worst[2]}), median {sorted(w[1] for w in waits)[len(waits) // 2] * 1000:.0f} ms")
        for line in log.splitlines():
            if "upload" in line or "drained" in line or "body" in line:
                i = log.splitlines().index(line)
                print("   " + "\n   ".join(log.splitlines()[i:i + 3]))
finally:
    qemu.kill()
    qemu.wait()
    print("\nserial log:", serial)
