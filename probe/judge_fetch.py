#!/usr/bin/env python3
"""The client kernel (probe/fetch.elf) against Linux, under QEMU.

    probe/run.sh fetch      (or: probe/judge_fetch.py <fetch.elf> <work dir>)

metal-vmm QUEUE 225, chunk 9. `python3 -m http.server` serves a 2-byte /tiny
and a 300 KB /big on 127.0.0.1, which QEMU's user networking shows the guest
as 10.0.2.2. Each case boots fetch.elf once with a command line and is
judged by QEMU's exit code (isa-debug-exit: the kernel's outcome code
`<< 1 | 1`, src/fetch.zig's `qemuExit`) and, for a 200, by the body's
length and FNV-1a hash, which the kernel prints:

  a 200          /tiny, 2 bytes                      QEMU 1
  300 KB         /big, by its hash                   QEMU 1
  refused        a port nobody listens on            QEMU 5
  no ARP         an address nobody has               QEMU 19, at the connect deadline
  no deadline    a command line without idle_ms      QEMU 3, the kernel refusing to start

Exit 0 when every case passes."""
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

QEMU = ["qemu-system-x86_64", "-M", "microvm,rtc=on,pit=on", "-nographic", "-no-reboot", "-m", "512",
        "-global", "virtio-mmio.force-legacy=false", "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
        "-cpu", "max", "-device", "virtio-rng-device",
        "-netdev", "user,id=n0", "-device", "virtio-net-device,netdev=n0"]
DEADLINES = "connect_ms=1000 idle_ms=5000 total_ms=15000"


def pattern(n: int) -> bytes:
    return bytes((k * 7 + 3) & 0xFF for k in range(n))


def fnv1a(data: bytes) -> int:
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def boot(elf, line, out):
    started = time.time()
    with open(out, "wb") as f:
        p = subprocess.run(QEMU + ["-kernel", elf, "-append", line], stdout=f, stderr=subprocess.STDOUT, timeout=120)
    text = open(out, "rb").read().decode("latin-1")
    said = re.search(r"outcome: .*", text)
    failed = re.search(r"(FAIL|PANIC): .*", text)
    return p.returncode, (said.group(0) if said else failed.group(0) if failed else "said nothing"), time.time() - started


def main() -> int:
    elf, work = sys.argv[1], sys.argv[2]
    os.makedirs(work, exist_ok=True)
    www = tempfile.mkdtemp(dir=work, prefix="www-")
    big = pattern(300_000)
    with open(os.path.join(www, "tiny"), "wb") as f:
        f.write(b"ok")
    with open(os.path.join(www, "big"), "wb") as f:
        f.write(big)
    port, unused = free_port(), free_port()
    http = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"], cwd=www,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    failures = 0
    try:
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.5).close()
                break
            except OSError:
                time.sleep(0.05)
        cases = [
            ("a 200", f"fetch 10.0.2.2 {port} /tiny {DEADLINES}", 1, b"ok"),
            ("300 KB", f"fetch 10.0.2.2 {port} /big {DEADLINES}", 1, big),
            ("refused", f"fetch 10.0.2.2 {unused} /tiny {DEADLINES}", 5, None),
            ("no ARP", f"fetch 10.0.2.9 {port} /tiny {DEADLINES}", 19, None),
            ("no deadline", f"fetch 10.0.2.2 {port} /tiny connect_ms=1000 total_ms=15000", 3, None),
        ]
        for name, line, want, body in cases:
            code, said, took = boot(elf, line, os.path.join(work, "fetch.out"))
            ok = code == want
            if ok and body is not None:
                ok = f"{len(body)} body bytes, fnv1a {fnv1a(body):016x}" in said
            if ok and name == "no deadline":
                ok = "no defaults" in said
            print(f"{'ok  ' if ok else 'FAIL'}  fetch, {name}: QEMU {code} (want {want}); {said} ({took:.1f} s)")
            failures += 0 if ok else 1
    finally:
        http.terminate()
        http.wait()
    print("every case passed" if not failures else f"{failures} cases failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
