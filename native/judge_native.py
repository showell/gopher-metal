#!/usr/bin/env python3
"""Asks the TCP table questions with Linux's own TCP as the other side.

    native/judge_native.py        (run by `probe/run.sh native`)

`zig build native` makes `zig-out/bin/gm-serve`: src/tcp.zig as an ordinary
Linux program on the TAP device gmtap0, answering at 10.77.0.2. This script
creates the device if it is missing (with sudo), starts the server, and runs
each check against it. Every check is a fact about the table that took a QEMU
boot to ask before, and takes seconds here:

  connections   thousands of connections one after another, at a cost per
                connection that does not climb — and none left half-closed
                on Linux's side
  lazy close    clients that close a moment after the answer: their FIN
                comes after they acknowledged ours
  concurrent    many clients at once
  bytes         a large answer arrives exactly, read fast and read slowly
  half-close    a client that shuts its side after asking still gets it all
  reset         a client that resets part-way leaves nothing behind
  keepalive     Linux's keepalive probes are answered
  loss          frames lost toward the table (netem) and from it
                (GM_LOSE_SENT) are recovered

Exit 0 when every check passes."""
import hashlib
import os
import socket
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVE = os.path.join(HERE, "..", "zig-out", "bin", "gm-serve")
TAP = "gmtap0"
ADDR = "10.77.0.2"
failures = 0


def sh(cmd, check=True):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, check=check)


def ensure_tap():
    if sh(f"ip link show {TAP}", check=False).returncode == 0:
        return
    user = os.environ.get("USER", "steve")
    sh(f"sudo -n ip tuntap add dev {TAP} mode tap user {user}")
    sh(f"sudo -n ip addr add 10.77.0.1/24 dev {TAP}")
    sh(f"sudo -n ip link set {TAP} up")


def netem(spec):
    sh(f"sudo -n tc qdisc del dev {TAP} root", check=False)
    if spec:
        sh(f"sudo -n tc qdisc add dev {TAP} root netem {spec}")


class Server:
    def __init__(self, **env):
        self.log = open(os.path.join(HERE, "..", "zig-out", "serve.log"), "wb")
        self.proc = subprocess.Popen([SERVE], env=dict(os.environ, **env),
                                     stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                get("/tiny", timeout=0.5)
                return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("the native server never answered")

    def stats(self) -> dict:
        body = get("/stats")
        return {k: int(v) for k, v in (line.split() for line in body.decode().splitlines())}

    def stop(self):
        try:
            get("/quit", timeout=2)
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


def get(path, timeout=10, rcvbuf=None, pause_after=None, pause=0.0, close_after=0.0) -> bytes:
    """One request; answers the body, checked against its content-length.
    `close_after` waits that long after the answer ends before closing."""
    s = socket.socket()
    if rcvbuf:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.settimeout(timeout)
    try:
        s.connect((ADDR, 80))
        s.sendall(f"GET {path} HTTP/1.1\r\nHost: native\r\n\r\n".encode())
        got = b""
        paused = pause_after is None
        while True:
            if not paused and len(got) >= pause_after:
                time.sleep(pause)
                paused = True
            chunk = s.recv(65536)
            if not chunk:
                break
            got += chunk
        if close_after:
            time.sleep(close_after)
    finally:
        s.close()
    head, _, body = got.partition(b"\r\n\r\n")
    length = int(head.split(b"content-length: ")[1].split(b"\r\n")[0])
    if len(body) != length:
        raise OSError(f"{path}: {len(body)} bytes of {length}")
    return body


def pattern(n: int) -> bytes:
    return bytes((k * 7 + 3) & 0xFF for k in range(n))


def report(ok: bool, name: str, detail: str, started: float):
    global failures
    took = f"({time.time() - started:.1f} s)"
    if ok:
        print(f"ok    {name}: {detail} {took}")
    else:
        failures += 1
        print(f"FAIL  {name}: {detail} {took}")


def half_closed_on_linux() -> set:
    """Linux sockets to the table still waiting on it to finish closing, by
    local address — so a check counts only the ones its own run left."""
    out = sh(f"ss -Htan state last-ack state fin-wait-1 state fin-wait-2 state closing dst {ADDR}",
             check=False).stdout
    return {l.split()[-2] for l in out.splitlines() if l.strip()}


def check_connections(server, count=5000):
    started = time.time()
    already = half_closed_on_linux()
    times = []
    for _ in range(count):
        t = time.perf_counter()
        body = get("/tiny")
        times.append(time.perf_counter() - t)
        if body != b"ok":
            return report(False, "connections", f"an answer was {body!r}", started)
    tenth = count // 10
    means = [sum(times[k * tenth:(k + 1) * tenth]) / tenth for k in range(10)]
    early, late = min(means[1:4]), min(means[7:10])
    time.sleep(0.5)
    lingering = len(half_closed_on_linux() - already)
    st = server.stats()
    detail = (f"{count} one after another, {means[1] * 1e6:.0f} -> {means[9] * 1e6:.0f} us each "
              f"(x{late / early:.2f}); {lingering} left half-closed on Linux's side; "
              f"table: {st['strays']} strays reset, {st['retransmits']} retransmits; "
              f"the path measured at {st['measured_us']} us over {st['samples']} round trips")
    # **THE PATH IS MEASURED, NOT ASSUMED.** A table that never took a sample
    # would fall back to the floor and wait tens of milliseconds for a peer
    # that answers in tens of microseconds.
    report(late <= 1.5 * early and lingering == 0 and st["in_use"] == 0
           and st["samples"] >= count, "connections", detail, started)


def check_lazy_close(server, count=30):
    """**A CLIENT THAT CLOSES A MOMENT LATER.** Linux acknowledges our FIN at
    once and sends its own only when the program closes; a table that forgot
    the connection when its FIN was acknowledged never acknowledges that
    second FIN, and Linux sits in LAST-ACK. (Linux usually sends both
    together, which is why the connections check above cannot see this;
    QEMU's network did not, and its connection list grew until every frame
    was slow.)"""
    started = time.time()
    already = half_closed_on_linux()
    for _ in range(count):
        get("/tiny", close_after=0.1)
    time.sleep(0.5)
    lingering = len(half_closed_on_linux() - already)
    st = server.stats()
    report(lingering == 0 and st["in_use"] == 0, "lazy close",
           f"{count} clients that close 100 ms after the answer: {lingering} left in LAST-ACK on "
           f"Linux's side, {st['in_use']} in the table", started)


def check_concurrent(clients=48, each=20):
    started = time.time()
    errors = []

    def client():
        for _ in range(each):
            try:
                if get("/tiny") != b"ok":
                    errors.append("wrong answer")
            except OSError as e:
                errors.append(str(e))

    threads = [threading.Thread(target=client) for _ in range(clients)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    report(not errors, "concurrent", f"{clients} clients x {each}: "
           + (f"{len(errors)} failed, first: {errors[0]}" if errors else "every answer right"), started)


def check_bytes(server):
    started = time.time()
    n = 5_000_000
    want = hashlib.md5(pattern(n)).hexdigest()
    fast = hashlib.md5(get(f"/bytes/{n}", timeout=30)).hexdigest()
    before = server.stats()["probes"]
    slow = hashlib.md5(get(f"/bytes/{n}", timeout=30, rcvbuf=4096,
                           pause_after=100_000, pause=2.0)).hexdigest()
    probes = server.stats()["probes"] - before
    report(fast == want and slow == want and probes > 0, "bytes",
           f"5 MB read fast and read with a 2 s pause: {'exact' if fast == slow == want else 'WRONG'}; "
           f"{probes} window probes during the pause", started)


def check_half_close():
    started = time.time()
    s = socket.create_connection((ADDR, 80), timeout=10)
    s.sendall(b"GET /bytes/200000 HTTP/1.1\r\nHost: native\r\n\r\n")
    s.shutdown(socket.SHUT_WR)
    got = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        got += chunk
    s.close()
    body = got.partition(b"\r\n\r\n")[2]
    report(body == pattern(200_000), "half-close",
           f"asked, shut its side, and got {len(body)} of 200000 bytes", started)


def check_reset(server):
    started = time.time()
    s = socket.create_connection((ADDR, 80), timeout=10)
    s.sendall(b"GET /bytes/5000000 HTTP/1.1\r\nHost: native\r\n\r\n")
    s.recv(10_000)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    s.close()
    time.sleep(0.5)
    in_use = server.stats()["in_use"]
    report(in_use == 0, "reset", f"a client reset part-way; {in_use} connections left in the table", started)


def check_keepalive():
    started = time.time()
    s = socket.create_connection((ADDR, 80), timeout=10)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 1)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 1)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 2)
    time.sleep(5)  # five idle seconds: probes every second, dead after two unanswered
    try:
        s.sendall(b"GET /tiny HTTP/1.1\r\nHost: native\r\n\r\n")
        got = s.recv(4096)
        ok = got.endswith(b"ok")
    except OSError as e:
        ok, got = False, str(e).encode()
    s.close()
    report(ok, "keepalive", "an idle connection probed by Linux for 5 s still answers"
           if ok else f"the connection died while idle: {got!r}", started)


def check_loss():
    started = time.time()
    netem("loss 5%")
    try:
        server = Server(GM_LOSE_SENT="13")
        try:
            wrong = 0
            for _ in range(100):
                if get("/tiny", timeout=30) != b"ok":
                    wrong += 1
            big = get("/bytes/300000", timeout=60) == pattern(300_000)
            st = server.stats()
        finally:
            server.stop()
    finally:
        netem(None)
    # **THE PEER'S DUPLICATE ACKNOWLEDGEMENTS DO THE WORK A TIMER WOULD.** With
    # a bulk answer in flight, Linux says what is missing at once, and this
    # check fails if the table waited for its own clock every time instead.
    report(wrong == 0 and big and st["fast_retransmits"] > 0, "loss",
           f"5% lost toward the table and 1 in 13 from it: 100 small answers ({wrong} wrong) and "
           f"300 KB {'exact' if big else 'WRONG'}; {st['retransmits']} retransmits, "
           f"{st['fast_retransmits']} of them asked for by the peer", started)


def main() -> int:
    if not os.path.exists(SERVE):
        print("FAIL  no zig-out/bin/gm-serve: run `zig build native`")
        return 1
    ensure_tap()
    netem(None)
    begun = time.time()
    server = Server()
    try:
        check_connections(server)
        check_lazy_close(server)
        check_concurrent()
        check_bytes(server)
        check_half_close()
        check_reset(server)
        check_keepalive()
    finally:
        server.stop()
    # Loss waits out real retransmission timers on both sides; the quick tier
    # leaves it to the full run.
    if not os.environ.get("JUDGE_QUICK"):
        check_loss()
    print(f"{'every check passed' if not failures else f'{failures} checks failed'} "
          f"({time.time() - begun:.0f} s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
