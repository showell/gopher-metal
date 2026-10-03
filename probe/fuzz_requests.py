#!/usr/bin/env python3
"""**REQUESTS A STRANGER COULD SEND** (QUEUE.md item 81): malformed request
lines, headers past every limit, bodies whose length lies, chunked bodies
that lie, pipelined requests, half-closed and slow connections. Each is sent
on a bare socket to metal (QEMU) and to the same application on Linux, and
what comes back is compared by its status line. Every so often metal is
asked for /version: a request that stopped it is the worst finding there is.

    probe/fuzz_requests.py <gopher.elf> <zig-server> <angry-gopher> [CASES] [SEED]

Grammar-guided from a fixed seed (SEED, 81 by default), so a failure
repeats: each finding prints its case number and the bytes sent. Exit 0
when metal answered /version throughout and every difference from Linux is
one the KNOWN table below names, with why it does not matter.
"""
import os, random, socket, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import judge_gopher as j

ROUTES = ["/", "/version", "/chat", "/login", "/login/full", "/game", "/images", "/admin",
          "/chat/conversations", "/chat/c/1_2/general/raw", "/gallery/safari.png", "/play",
          "/no/such/page", "/chat/recent"]
METHODS = ["GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "PATCH", "TRACE", "CONNECT",
           "get", "GET ", "G\x00T", "", "X" * 300, "PRI"]
VERSIONS = ["HTTP/1.1", "HTTP/1.0", "HTTP/2.0", "HTTP/1", "HTTP/1.1 ", "http/1.1", "HTTP/9.9", "", "HTTP/1.1\x00"]


def target(r: random.Random) -> str:
    t = r.choice(ROUTES)
    k = r.randrange(12)
    if k == 0:
        t += "?" + "a=" + "b" * r.choice([1, 100, 5000, 20000])
    elif k == 1:
        t = "/" + "%" + r.choice(["", "2", "zz", "00", "2f..%2f"]) + t
    elif k == 2:
        t = "/../" * r.randrange(1, 5) + t.lstrip("/")
    elif k == 3:
        t = "http://example.com" + t
    elif k == 4:
        t = "*"
    elif k == 5:
        t = t + " extra"
    elif k == 6:
        t = t + "\x7f\x01"
    elif k == 7:
        t = "/" + "é漢".encode().decode("latin-1") + t
    elif k == 8:
        t = "/" + "x/" * r.choice([50, 500, 3000])
    elif k == 9:
        t = ""
    return t


def headers(r: random.Random, body_len: int) -> list:
    h = [("Host", "metal.lynrummy.com")]
    k = r.randrange(16)
    if k == 0:
        h += [("X-Pad-%d" % i, "v" * r.choice([10, 100, 1000])) for i in range(r.choice([10, 100, 400]))]
    elif k == 1:
        h.append(("X-Long", "v" * r.choice([8000, 16000, 17000, 70000])))
    elif k == 2:
        h.append(("Content-Length", r.choice(["-1", "abc", "99999999999999999999", "1 2", "+5", "0x10", ""])))
    elif k == 3:
        h += [("Content-Length", str(body_len)), ("Content-Length", str(body_len + 5))]
    elif k == 4:
        h += [("Transfer-Encoding", "chunked"), ("Content-Length", str(body_len))]
    elif k == 5:
        h.append(("Transfer-Encoding", r.choice(["chunked", "gzip, chunked", "identity", "chunked, gzip", "xyz"])))
    elif k == 6:
        h.append(("NoColonHere", None))
    elif k == 7:
        h.append(("X-Fold", "a\r\n  folded"))
    elif k == 8:
        h.append((" Leading-Space", "x"))
    elif k == 9:
        h.append(("Cookie", "gopher_auth=" + "A" * r.choice([10, 500, 5000]) + "; gopher_uid=" + "x." * 40))
    elif k == 10:
        h.append(("Range", r.choice(["bytes=0-0", "bytes=-1", "bytes=5-1", "bytes=999999-", "bytes=0-1,2-3", "bytes=x", "pages=1"])))
    elif k == 11:
        h.append(("X-Forwarded-For", r.choice(["1.2.3.4", "garbage", "::1", "1.2.3.4, 5.6.7.8", "999.1.1.1", " " * 100])))
    elif k == 12:
        h.append(("Expect", "100-continue"))
    elif k == 13:
        h.append(("Connection", r.choice(["keep-alive", "upgrade", "close", "x" * 1000])))
    elif k == 14:
        h.append(("Content-Type", r.choice(["multipart/form-data", "multipart/form-data; boundary=", "application/x-www-form-urlencoded", "text/plain"])))
    if body_len and k not in (2, 3, 4, 5):
        h.append(("Content-Length", str(body_len)))
    return h


def body(r: random.Random) -> bytes:
    return bytes(r.randrange(256) for _ in range(r.choice([0, 0, 1, 10, 1000, 20000])))


def chunked(r: random.Random, data: bytes) -> bytes:
    """A chunked body, sometimes lying: a size past the data, bad hex, no end."""
    k = r.randrange(5)
    if k == 0:
        return b"%x\r\n" % len(data) + data + b"\r\n0\r\n\r\n"
    if k == 1:
        return b"%x\r\n" % (len(data) + 100) + data + b"\r\n0\r\n\r\n"
    if k == 2:
        return b"zz\r\n" + data + b"\r\n0\r\n\r\n"
    if k == 3:
        return b"%x\r\n" % len(data) + data
    return b"ffffffffffffffffff\r\n" + data


def case(r: random.Random) -> dict:
    """One request: its bytes, and how it is sent."""
    data = body(r)
    hs = headers(r, len(data))
    eol = r.choice([b"\r\n"] * 8 + [b"\n", b"\r"])
    line = ("%s %s %s" % (r.choice(METHODS), target(r), r.choice(VERSIONS))).encode("latin-1")
    k = r.randrange(10)
    if k == 0:
        line = bytes(r.randrange(256) for _ in range(r.choice([1, 50, 2000])))
    head = line + eol
    for name, value in hs:
        head += (name if value is None else "%s: %s" % (name, value)).encode("latin-1") + eol
    head += eol
    te_chunked = any(n == "Transfer-Encoding" and v and "chunked" in v for n, v in hs)
    payload = head + (chunked(r, data) if te_chunked else data)
    how = r.choice(["whole"] * 6 + ["pipelined", "cut", "slow"])
    if how == "pipelined":
        payload += b"GET /version HTTP/1.1\r\nHost: x\r\n\r\n"
    elif how == "cut":
        payload = payload[: r.randrange(max(1, len(payload)))]
    return {"payload": payload, "how": how}


def send(port: int, c: dict, patience: float = 20.0) -> bytes:
    """The bytes sent, our side closed for writing, and what comes back
    before the server closes. `slow` sends a byte at a time at first."""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=patience)
    except OSError as e:
        return b"!connect " + str(e).encode()
    got = b""
    try:
        if c["how"] == "slow":
            for b in c["payload"][:20]:
                s.sendall(bytes([b]))
                time.sleep(0.05)
            s.sendall(c["payload"][20:])
        else:
            s.sendall(c["payload"])
        s.shutdown(socket.SHUT_WR)
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            got += chunk
    except socket.timeout:
        got += b"!timeout"
    except OSError as e:
        got += b"!" + str(e).encode()
    finally:
        s.close()
    return got


def status(answer: bytes) -> str:
    """The first status line's code, or what happened instead."""
    if answer.startswith(b"!") and b"104" in answer.split(b"]")[0]:
        return "reset"
    if answer.startswith(b"!"):
        return answer.split(b" ")[0].decode()
    if not answer:
        return "closed"
    if not answer.startswith(b"HTTP/"):
        return "not HTTP"
    return answer.split(b"\r\n", 1)[0].split(b" ")[1].decode("latin-1")


# Differences that do not matter, by (metal, linux): each with its reason.
KNOWN = {
    ("closed", "reset"): "neither answers: Linux's kernel resets a connection closed with request bytes "
                         "it never read, where metal closes it",
}


def bare_lf_end(payload: bytes) -> bool:
    """Whether the bytes hold a head ended by a bare `\\n\\n` before any
    `\\r\\n\\r\\n`. **zig's std.http.HeadParser finds such an end or not by
    how the bytes were split into reads**: in its vector path, a vector
    holding exactly two or three CR/LF bytes is only checked at its own
    last bytes, so a `\\n\\n` inside one is missed (HEAD-PARSER-BUG.md). Linux
    reads in large pieces and metal in TCP segments, so the two may part on
    exactly these requests, and neither can be made to agree with the other.
    Caddy, in front of both, sends CRLF."""
    lf = payload.find(b"\n\n")
    crlf = payload.find(b"\r\n\r\n")
    return lf != -1 and (crlf == -1 or lf < crlf)


# ── Range, on the one route that honours it ─────────────────────────────────
#
# chat_upload serves an uploaded file with HTTP Range. A picture is posted to
# each host as the admin, and then asked for with each of these, and with as
# many made at random: the status, content-range and bytes must agree.
RANGES = ["bytes=0-0", "bytes=0-", "bytes=-1", "bytes=-0", "bytes=-300000", "bytes=-300001",
          "bytes=299999-", "bytes=300000-", "bytes=300000-300001", "bytes=5-1", "bytes=0-299999",
          "bytes=0-300000", "bytes=1-2,3-4", "bytes=", "bytes=-", "=0-1", "bytes= 0-1", "BYTES=0-1",
          "bytes=0-1 ", "bytes=18446744073709551615-", "bytes=0-18446744073709551616", "bytes=--1",
          "bytes=1--2", "bytes=0x10-", "bytes=1-1", "pages=0-1", "bytes=0-1, ", "bytes=,0-1",
          "bytes=" + "9" * 30 + "-"]
PICTURE = 300000


def range_answers(port: int, session: str, ranges: list) -> dict:
    import hashlib, http.client, json
    def get(path, headers):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        conn.request("GET", path, headers=headers)
        r = conn.getresponse()
        body = r.read()
        conn.close()
        return r.status, r.getheader("content-range"), hashlib.sha256(body).hexdigest()[:12], len(body)
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
    conn.request("POST", "/chat/c/1_2/general/upload", body=j.multipart("r.png", j.picture(PICTURE)),
                 headers={"Cookie": session, "Content-Type": f"multipart/form-data; boundary={j.UPLOAD_BOUNDARY}"})
    r = conn.getresponse()
    posted = r.read()
    conn.close()
    if r.status != 200:
        return {"upload": (r.status, posted[:80])}
    url = json.loads(posted)["url"]
    return {rng: get(url, {"Cookie": session, "Range": rng}) for rng in ranges}


def random_ranges(r: random.Random, n: int) -> list:
    nums = [0, 1, 2, PICTURE - 2, PICTURE - 1, PICTURE, PICTURE + 1, 8 << 20, (8 << 20) + 1, 2 ** 63, 2 ** 64]
    pick = lambda: str(r.choice(nums + [r.randrange(PICTURE * 2)]))
    out = []
    for _ in range(n):
        a = pick() if r.random() < 0.8 else ""
        b = pick() if r.random() < 0.6 else ""
        out.append("bytes=" + a + "-" + b + ("," + pick() + "-" if r.random() < 0.1 else ""))
    return out


def alive(port: int) -> bool:
    return status(send(port, {"payload": b"GET /version HTTP/1.1\r\nHost: x\r\n\r\n", "how": "whole"}, 30)) == "200"


def main() -> int:
    elf, linux_bin, gopher_root = sys.argv[1:4]
    cases = int(sys.argv[4]) if len(sys.argv) > 4 else 300
    seed = int(sys.argv[5]) if len(sys.argv) > 5 else 81
    r = random.Random(seed)
    with tempfile.TemporaryDirectory(prefix="fuzz-requests-") as work:
        content = os.path.join(work, "content")
        j.stage(content, gopher_root)
        image = os.path.join(work, "disk.img")
        mnt = os.path.join(work, "mnt")
        os.makedirs(mnt)
        j.build_disk(image, content, mnt)
        j.disk_write(image, mnt, "gopher-metal.conf", "idle_timeout_ms = 2000\n")
        qemu, mport, serial = j.start_kernel(elf, image, work)
        linux_root = os.path.join(work, "linux")
        os.makedirs(linux_root)
        import shutil
        shutil.rmtree(linux_root)
        shutil.copytree(content, linux_root)
        linux = j.LinuxServer(linux_bin, linux_root, os.path.join(work, "linux.log"))
        differ, stopped, std_bug = {}, None, 0
        try:
            for n in range(cases):
                c = case(r)
                m = status(send(mport, c))
                l = status(send(linux.port, c))
                if m != l and (m, l) not in KNOWN:
                    if bare_lf_end(c["payload"]):
                        std_bug += 1
                    else:
                        differ.setdefault((m, l), []).append((n, c))
                if n % 10 == 9 or m.startswith("!"):
                    if qemu.poll() is not None or not alive(mport):
                        stopped = (n, c)
                        break
            ranges = []
            if stopped is None:
                session = j.mint_session("1", int(time.time()))
                asked = RANGES + random_ranges(r, 100)
                on_metal = range_answers(mport, session, asked)
                on_linux = range_answers(linux.port, session, asked)
                ranges = [(k, on_metal.get(k), v) for k, v in on_linux.items() if on_metal.get(k) != v]
                if "upload" in on_metal or "upload" in on_linux:
                    ranges.append(("the upload", on_metal.get("upload"), on_linux.get("upload")))
                if qemu.poll() is not None or not alive(mport):
                    stopped = (cases, {"how": "range", "payload": b"(the Range pass)"})
        finally:
            linux.stop()
            qemu.kill()
            qemu.wait()
        print(f"{cases if stopped is None else stopped[0] + 1} cases, seed {seed}")
        if stopped:
            n, c = stopped
            print(f"FAIL metal stopped answering after case {n} ({c['how']}): {c['payload'][:300]!r}")
            log = open(serial, "rb").read().decode("latin-1", "replace")
            print("     its log ends: " + " | ".join(log.strip().splitlines()[-6:]))
        for (m, l), seen in sorted(differ.items(), key=lambda kv: -len(kv[1])):
            n, c = seen[0]
            print(f"DIFF metal {m}, Linux {l}: {len(seen)} case(s), the first {n} ({c['how']}): {c['payload'][:200]!r}")
        if std_bug:
            print(f"     {std_bug} case(s) parted on a bare-LF head end, std.http.HeadParser's bug "
                  "(HEAD-PARSER-BUG.md): not counted")
        print(f"Range: {len(RANGES) + 100} headers on a {PICTURE}-byte upload, "
              f"{'all answered alike' if not ranges else str(len(ranges)) + ' differ'}")
        for rng, m, l in ranges:
            print(f"DIFF Range {rng!r}: metal {m}, Linux {l}")
        for (m, l), why in KNOWN.items():
            print(f"     known: metal {m}, Linux {l}: {why}")
        return 1 if stopped or differ or ranges else 0


if __name__ == "__main__":
    sys.exit(main())
