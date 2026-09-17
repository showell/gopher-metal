#!/usr/bin/env python3
"""Boots the ladder kernel, plays the host's part in its network rungs, and
says, rung by rung, whether each operation's cost stayed flat.

    judge_ladder.py <ladder.elf> <disk image> <work dir> <scale>
    judge_ladder.py <serial log>          only the verdict, on a log already taken

The host's part: a UDP echo server the kernel's `udp_echo` rung talks to, and
a client that makes the connections the `tcp_conn` rung serves — one after
another, each a tiny request read to the close.

A rung is FLAT when the cheapest of its last three tenths cost no more than
CLIMB times the cheapest of its second to fourth. **THE CHEAPEST, NOT THE
MEAN**: an emulated machine has spikes — a tenth at twice its neighbours'
cost, and the next back to normal — and growth is what lifts the floor, not
what adds a spike. The first tenth is left out: it pays for caches filling,
which is the opposite of the growth this looks for. Disk
requests per tenth must not climb either — a rung whose cost is flat only
because each operation did less would be flat for the wrong reason.
Exit 0 when every rung is flat, 1 otherwise."""
import os
import re
import socket
import subprocess
import sys
import threading
import time

CLIMB = 1.5
RUNG = re.compile(r"^rung (\w+): (\d+) ops; ns per op by tenth:((?: \d+)+); "
                  r"disk requests by tenth:((?: \d+)+)$", re.M)
RUNGS = ["cpu", "alloc", "read_same", "write_same", "write_spread", "append", "replace",
         "udp_echo", "tcp_conn", "tcp_to_request", "tcp_to_close"]
TCP_CONNECTIONS = 200  # per unit of scale; the kernel's count, restated


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def echo_server():
    """A UDP echo on the host's loopback; slirp delivers the guest's datagrams
    for 10.0.2.2 to it. Answers (port, stop)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.2)
    stop = threading.Event()

    def serve():
        while not stop.is_set():
            try:
                data, peer = sock.recvfrom(2048)
            except OSError:
                continue
            sock.sendto(data, peer)
        sock.close()

    threading.Thread(target=serve, daemon=True).start()
    return sock.getsockname()[1], stop


def connect_many(port: int, count: int) -> int:
    """`count` connections, one after another. Answers how many got 'ok'."""
    good = 0
    for _ in range(count):
        with socket.create_connection(("127.0.0.1", port), timeout=30) as c:
            c.sendall(b"GET / HTTP/1.1\r\nHost: ladder\r\n\r\n")
            got = b""
            while True:
                chunk = c.recv(4096)
                if not chunk:
                    break
                got += chunk
        good += got.endswith(b"\r\n\r\nok")
    return good


def run(elf: str, image: str, work: str, scale: int) -> str:
    """Boots the kernel and serves its network rungs. Answers the serial log."""
    echo_port, stop = echo_server()
    tcp_port = free_port()
    serial = os.path.join(work, "ladder.out")
    with open(serial, "wb") as log:
        qemu = subprocess.Popen([
            "qemu-system-x86_64", "-M", "microvm,rtc=on,pit=on",
            "-kernel", elf, "-append", f"scale={scale} echo_port={echo_port}",
            "-nographic", "-no-reboot", "-m", "512",
            "-global", "virtio-mmio.force-legacy=false",
            "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
            "-drive", f"id=d,file={image},format=raw,if=none",
            "-device", "virtio-blk-device,drive=d",
            "-cpu", "max", "-device", "virtio-rng-device",
            "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{tcp_port}-:80",
            "-device", "virtio-net-device,netdev=n0",
        ], stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.time() + 120 + 60 * scale
        while qemu.poll() is None and time.time() < deadline:
            if b"tcp_conn: listening" in open(serial, "rb").read():
                good = connect_many(tcp_port, TCP_CONNECTIONS * scale)
                print(f"     ladder | {good} of {TCP_CONNECTIONS * scale} connections answered")
                break
            time.sleep(0.05)
        qemu.wait(timeout=max(1, deadline - time.time()))
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"     ladder | the host's part failed: {e}")
        qemu.kill()
        qemu.wait()
    finally:
        stop.set()
    print(f"     ladder | qemu exited {qemu.returncode}")
    return open(serial, "rb").read().decode("latin-1")


def parse(log: str) -> dict:
    out = {}
    for m in RUNG.finditer(log):
        out[m.group(1)] = {
            "ops": int(m.group(2)),
            "ns": [int(x) for x in m.group(3).split()],
            "requests": [int(x) for x in m.group(4).split()],
        }
    return out


def verdict(r: dict):
    """(flat, the growth ratio) for one rung."""
    ns = r["ns"]
    early = min(ns[1:4])
    late = min(ns[7:10])
    ratio = late / early if early else float("inf")
    req = r["requests"]
    requests_climb = req[8] + req[9] > 1.5 * (req[1] + req[2]) + 2
    return ratio <= CLIMB and not requests_climb, ratio, requests_climb


def main() -> int:
    if len(sys.argv) == 2:
        log = open(sys.argv[1], "rb").read().decode("latin-1")
        exited = None
    elif len(sys.argv) == 5:
        started = time.time()
        log = run(sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]))
        exited = "PASS" in log
        print(f"     ladder | scale {sys.argv[4]}, {time.time() - started:.0f} s")
    else:
        print(__doc__.strip())
        return 2
    rungs = parse(log)
    failed = 0
    if exited is False:
        print("FAIL ladder        | the kernel did not finish: " + " | ".join(log.splitlines()[-3:]))
        failed = 1
    for name in RUNGS:
        r = rungs.get(name)
        if r is None:
            print(f"FAIL {name:12} | the rung never reported")
            failed = 1
            continue
        flat, ratio, requests_climb = verdict(r)
        per_op = r["requests"][9] * 10 / r["ops"]
        line = (f"{name:12} | {r['ops']} ops, {r['ns'][1]:>9} ns -> {r['ns'][9]:>9} ns per op "
                f"(x{ratio:.2f}), {per_op:.2f} disk requests per op")
        if flat:
            print(f"PASS {line}")
        else:
            why = "disk requests climb" if requests_climb else f"cost climbs past x{CLIMB}"
            print(f"FAIL {line}: {why}")
            print(f"       ns by tenth: {' '.join(map(str, r['ns']))}")
            print(f"       requests by tenth: {' '.join(map(str, r['requests']))}")
            failed = 1
    return failed


if __name__ == "__main__":
    raise SystemExit(main())
