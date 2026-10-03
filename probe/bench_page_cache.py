#!/usr/bin/env python3
"""**WHAT THE PAGE CACHE BUYS** (QUEUE.md item 87): one chat transcript of
prod's largest size, read again and again on metal, with the data's files
kept in memory and without (`page_cache_mib = 0`). Each read is the raw
transcript, `GET /chat/c/1_2/general/raw`, as a member: the read two people
in one conversation make on every refresh.

    probe/bench_page_cache.py <gopher.elf> <angry-gopher checkout> [ROUNDS]

It builds the judge's disk (probe/judge_gopher.py's `stage`), boots once to
post a message so the application writes its own transcript, grows that
file to TRANSCRIPT_KB of messages in the same form, then boots twice more,
once each way, and times ROUNDS reads on each, after one read to warm it.
Under KVM where this user can open /dev/kvm, TCG elsewhere, and says which:
TCG's times say how the two compare, not how fast a droplet is.
"""
import http.client, os, statistics, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import judge_gopher as j

TRANSCRIPT_KB = int(os.environ.get("TRANSCRIPT_KB", "362"))  # prod's largest
PATH = "/chat/c/1_2/general"


def request(port, method, path, cookie, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    headers = {"Cookie": cookie}
    if body is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    began = time.perf_counter()
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    data = resp.read()
    took = time.perf_counter() - began
    conn.close()
    return resp.status, data, took


def boot(elf, image, scratch, conf_extra, n):
    mnt = os.path.join(scratch, "mnt")
    text = j.request_limit_text(image, n, idle_timeout_ms=60000) + conf_extra
    j.disk_write(image, mnt, "gopher-metal.conf", text)
    return j.start_kernel(elf, image, scratch, kvm=j.kvm_usable())


def stop(qemu, serial):
    try:
        qemu.wait(timeout=120)
    except Exception:
        qemu.kill()
        qemu.wait()
    return open(serial, "rb").read().decode("latin-1", "replace")


def main():
    elf, gopher_root = sys.argv[1], sys.argv[2]
    rounds = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    with tempfile.TemporaryDirectory(prefix="bench-page-cache-") as scratch:
        root = os.path.join(scratch, "root")
        mnt = os.path.join(scratch, "mnt")
        os.makedirs(mnt)
        j.stage(root, gopher_root)
        image = os.path.join(scratch, "disk.img")
        j.build_disk(image, root, mnt)
        cookie = j.mint_session("1", int(time.time()))

        # The application writes its own transcript: one message.
        qemu, port, serial = boot(elf, image, scratch, "", 1)
        status, _, _ = request(port, "POST", PATH + "/send", cookie, "markdown=the+first&cid=b1")
        stop(qemu, serial)
        if status not in (200, 303):
            sys.exit(f"posting the first message answered {status}")
        listing = j._mt("mdir", "-/", "-b", "-i", j._at(image), "::/data/chat").stdout
        names = [l[2:].rstrip("/") for l in listing.splitlines()
                 if l.startswith("::/") and l.endswith(".md") and "/uploads/" not in l]
        if not names:
            sys.exit("no transcript on the disk after posting")
        transcript = max(names, key=len)
        got = j.disk_read(image, mnt, [transcript.lstrip("/")])
        one = list(got.values())[0]
        one = one.decode() if isinstance(one, bytes) else one
        # Grown to prod's largest in the same form: the message, again and again.
        body = (one * (TRANSCRIPT_KB * 1024 // max(len(one), 1) + 1))[: TRANSCRIPT_KB * 1024]
        grown = os.path.join(scratch, "grown.md")
        with open(grown, "w") as f:
            f.write(body)
        j._mt("mcopy", "-o", "-i", j._at(image), grown, "::" + transcript)

        accel = "KVM" if j.kvm_usable() else "TCG"
        print(f"transcript {transcript}, {len(body) // 1024} KB; {rounds} reads each way, under {accel}")
        results = {}
        for label, extra in (("from the disk (page_cache_mib = 0)", "page_cache_mib = 0\n"),
                             ("kept in memory (page_cache_mib = 64)", "")):
            qemu, port, serial = boot(elf, image, scratch, extra, rounds + 2)
            request(port, "GET", PATH + "/raw", cookie)  # warms it, either way
            times = []
            for _ in range(rounds):
                status, data, took = request(port, "GET", PATH + "/raw", cookie)
                if status != 200 or len(data) < len(body) // 2:
                    sys.exit(f"{label}: answered {status}, {len(data)} bytes")
                times.append(took * 1000)
            # The host's own page says whether the reads were the cache's.
            _, host, _ = request(port, "GET", "/admin/host", cookie)
            row = host.split(b"data files in memory</td><td>")
            log = stop(qemu, serial)
            times.sort()
            results[label] = times
            print(f"  {label}: median {statistics.median(times):.1f} ms, "
                  f"90th {times[int(len(times) * 0.9) - 1]:.1f} ms, best {times[0]:.1f} ms")
            if len(row) > 1:
                print("    /admin/host: " + row[1].split(b"</td>")[0].decode())
        a, b = (statistics.median(v) for v in results.values())
        print(f"kept in memory, a read takes {b / a:.2f} of the time it took from the disk")


if __name__ == "__main__":
    main()
