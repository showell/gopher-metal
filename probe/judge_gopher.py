#!/usr/bin/env python3
"""The verdict on probe/gopher.zig: the same request, answered twice.

    judge_gopher.py <gopher.elf> <linux zig-server binary> <angry-gopher root> <work dir>

**LINUX IS THE ORACLE.** The claim is that porting angry-gopher to a machine
with no operating system changes nothing about what it serves. So every request
below goes to two servers built from the same source:

  - the kernel, booted in QEMU with the site on a GPT disk whose first
    partition is FAT16 — one boot per request, since it serves one and stops;
  - the ordinary Linux build, run over a copy of the same files.

and the answers must agree: status, Location, Set-Cookie, Content-Type, and the
body byte for byte. /version is compared field by field, since it names the
build and reports live memory by design.

**EVERY CASE STARTS FROM THE SAME STATE ON BOTH SIDES** — a fresh copy of the
disk for the kernel, and a fresh copy of the files and a fresh server for
Linux — because several requests write, and a write on one side must not leak
into the next case's comparison.

**A WRITE IS JUDGED TWICE.** After it, the files it touched are read back —
through the Linux VFAT driver on the kernel's disk, and straight off the Linux
server's directory — and must match, and the kernel's disk must pass fsck.

**TIME.** Routes that stamp the wall clock write a different second on each
side. A Unix time is replaced with <NOW> only if it lies inside the window in
which THAT side handled the request; a kernel whose clock was wrong would leave
a bare number, and the comparison would fail. Times staged into the fixture
(1758000000) are nowhere near either window, so pages that render them are
compared exactly — including the Eastern-time formatting.

Populating and reading the disk needs a loop mount, so this needs `sudo -n`.
Without it the whole check is SKIPPED — exit 77 — and says so.

Exit 0 when every case agrees, 1 when any does not, 77 when it could not run.
"""
import base64
import calendar
import hashlib
import hmac
import http.client
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import datetime
import zoneinfo

SECTOR = 512
PART_FIRST = 2048
STAGED_TIME = 1758000000

# Two chat members, both with the bcrypt hash golang.org/x/crypto wrote for
# angry-gopher's old server — so logging in also exercises the `$2a$` path.
MEMBER_PASSWORD = "correct horse battery staple"
MEMBER_HASH = "$2a$10$TC9LJ0KU0TIrFl9Hk8FCAeU1bThg2GoSYXAqsjQLdIBSHIxGVfDza"
SESSION_SECRET = b"gopher-metal judge secret, 32+ bytes of it"
P1 = "gopher_uid=1"
GAME1 = "data/lynrummy/1"


def case(name, method, path, cookie=None, body=None, files=()):
    return {"name": name, "method": method, "path": path, "cookie": cookie, "body": body,
            "files": list(files)}


CASES = [
    # ── pages, identity and gates ──────────────────────────────────────────
    case("index", "GET", "/"),
    case("index as a player", "GET", "/", P1),
    case("driving (embedded)", "GET", "/driving"),
    case("tutorial (embedded)", "GET", "/tutorial"),
    case("chess index", "GET", "/chess"),
    case("resume (markdown from the volume)", "GET", "/steve-resume"),
    case("resume pdf (27 KB from the volume)", "GET", "/steve-resume.pdf"),
    case("safari download page", "GET", "/safari_download"),
    case("unknown path", "GET", "/nope"),
    case("prefix boundary", "GET", "/drivingX"),
    case("old login door", "GET", "/login"),
    case("password gate", "GET", "/login/full"),
    case("admin, anonymous", "GET", "/admin"),
    case("admin, a bare uid is not a member", "GET", "/admin", P1),
    case("version", "GET", "/version"),

]


# ── one boot, many requests ──────────────────────────────────────────────────
#
# A STORY, told to one kernel and to one Linux server. "$JAR" is the gopher_uid
# cookie that side's own earlier response set, so each side carries its own
# state forward. A step with `raw` sends those bytes on a bare socket instead of
# an HTTP request, and the answer compared is whatever comes back before close.

JAR = "$JAR"


def step(name, method, path, cookie=None, body=None, raw=None, headers=(), settle=0.0, expect=()):
    """One request in a story. `settle` waits before sending it.

    **A WAIT IS NOT A WORKAROUND HERE; IT IS THE RESOLUTION OF A FAT16 DATE.**
    /chat/recent orders conversations by file modification time, and FAT16
    stores that in whole EVEN seconds while ext4 stores nanoseconds. Two writes
    300 ms apart are ordered on Linux and tied on metal — so asking both sides
    for the same order would be asking FAT16 to be ext4. Where the story cares
    about the order of two events, it makes them far enough apart that the
    coarser clock can tell them apart, and then demands exact agreement."""
    return {"name": name, "method": method, "path": path, "cookie": cookie, "body": body,
            "raw": raw, "files": [], "headers": list(headers), "settle": settle,
            "expect": list(expect)}


# **THE WIRE, NOT THE GAME.** This was a Lyn Rummy player's story — names
# herself, plays, moves, annotates — and Lyn Rummy stays on the Linux droplet.
# What it carried that is not about the game is what a server has to survive on
# an open socket, so those steps moved into the member story below rather than
# being deleted with it.

def mint_session(uid: str, issued: int) -> str:
    """A gopher_auth cookie made HERE, from the staged secret and the format in
    users.zig's signSession — not by either server. Both must honor a fresh one
    and refuse a stale one, which is session expiry, which is what the kernel's
    wall clock exists for."""
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    mac = hmac.new(SESSION_SECRET, f"{uid}\n{issued}".encode(), hashlib.sha256).digest()
    return f"gopher_auth={b64(uid.encode())}.{issued}.{b64(mac)}"


def forge_session(claimed: str, signed_for: str, issued: int) -> str:
    """A cookie that CLAIMS `claimed` but carries the valid MAC for
    `signed_for` — what someone holding their own session would try."""
    real = mint_session(signed_for, issued)            # gopher_auth=<id>.<t>.<mac>
    _, _, rest = real.partition(".")                   # <t>.<mac>
    b64 = base64.urlsafe_b64encode(claimed.encode()).rstrip(b"=").decode()
    return f"gopher_auth={b64}.{rest}"


FRESH = "$FRESH"      # minted when the story starts: must be honored
STALE = "$STALE"      # minted 400 days back: must be refused
FORGED = "$FORGED"    # a fresh one with the MAC of another id: must be refused

MEMBER_STORY = [
    step("chat, anonymous", "GET", "/chat"),
    step("a wrong password", "POST", "/login/full", None,
         "name=Steve&password=hunter2&action=login&next=%2Fchat"),
    step("the right one (a $2a$ hash)", "POST", "/login/full", None,
         "name=Steve&password=correct+horse+battery+staple&action=login&next=%2Fchat"),
    step("chat, with no conversations yet", "GET", "/chat", JAR),
    step("the conversations API", "GET", "/chat/conversations", JAR),
    step("a message, as a form post", "POST", "/chat/c/1_2/general/send", JAR,
         "markdown=hello+from+bare+metal&cid=c1"),
    step("a message, async, with markdown", "POST", "/chat/c/1_2/general/send", JAR,
         "markdown=**bold**+and+%60code%60&cid=c2", headers=["X-Chat-Async: 1"]),
    step("hostile markdown is refused at the door", "POST", "/chat/c/1_2/general/send", JAR,
         "markdown=" + "%5B" * 300 + "&cid=c3", headers=["X-Chat-Async: 1"]),
    step("the conversation page", "GET", "/chat/c/1_2/general", JAR),
    step("the raw transcript", "GET", "/chat/c/1_2/general/raw", JAR),
    step("chat now resumes the conversation", "GET", "/chat", JAR),
    # 3 seconds: more than FAT16's two-second granularity, so "metal-talk was
    # written after general" is a fact both filesystems can hold. /chat/recent
    # below is judged on the order it produces.
    step("a new topic", "POST", "/chat/c/1_2/new", JAR, "topic=metal-talk", settle=3.0),
    step("a message in it", "POST", "/chat/c/1_2/metal-talk/send", JAR,
         "markdown=a+second+topic&cid=c4", headers=["X-Chat-Async: 1"]),
    step("a reaction", "POST", "/chat/c/1_2/general/react", JAR, "id=general_1&emoji=%F0%9F%91%8D"),
    step("the reactions file", "GET", "/chat/c/1_2/general/reactions", JAR),
    step("recent activity", "GET", "/chat/recent", JAR),
    step("docs", "GET", "/chat/docs", JAR),
    step("links", "GET", "/chat/links", JAR),
    step("settings", "GET", "/settings", JAR),
    step("the admin roster (Steve is uid 1)", "GET", "/admin", JAR),
    step("the game roster", "GET", "/admin/lynrummy", JAR),
    step("someone else's DM is not his", "GET", "/chat/c/2_9/general", JAR),
    step("a session minted outside both servers", "GET", "/chat/conversations", FRESH),
    step("a session 400 days old", "GET", "/chat/conversations", STALE),
    step("a forged session", "GET", "/chat/conversations", FORGED),
    step("logging out", "POST", "/logout", JAR, "release=no"),
    step("chat, after logging out", "GET", "/chat", JAR),
    # What arrives on a socket is not always a request, and a server that takes
    # one connection at a time has to survive each of these AND answer the next
    # caller. (These four came from the Lyn Rummy story, which is gone.)
    step("garbage on the wire", "RAW", "-", raw=b"this is not http\r\n\r\n"),
    step("still serving after garbage", "GET", "/nope"),
    step("a connection that says nothing", "RAW", "-", raw=b""),
    step("still serving after silence", "GET", "/chat"),
]


# ENDURANCE: the writes, over and over, READ BACK EVERY ROUND.
#
# **STAMINA BELOW ONLY READS, AND A READ CANNOT LOSE ANYTHING.** Three GETs
# repeated 100 times prove the heaps hold steady, and prove nothing at all about
# whether what was written is still there. These rounds write to the two stores
# that matter — chat's transcript (a message appended to a conversation) and the
# game store (a move appended to a session) — and then ask for the whole thing
# back and require EVERY mark from EVERY earlier round to still be in it.
#
# So a write that lands in the wrong place, an append that truncates, a chain
# that breaks at a cluster edge, or an allocator that hands out memory twice
# shows up as a mark that has gone missing, at the round it went missing.
ENDURANCE_ROUNDS = 25


def mark(n: int) -> bytes:
    return f"mark-{n:04d}".encode()


def endurance_steps(rounds: int) -> list:
    steps = [step("log in", "POST", "/login/full", None,
                  "name=Steve&password=correct+horse+battery+staple&action=login&next=%2Fchat")]
    for n in range(1, rounds + 1):
        marks = [mark(i) for i in range(1, n + 1)]
        steps += [
            step(f"a message, round {n}", "POST", "/chat/c/1_2/general/send", JAR,
                 f"markdown={mark(n).decode()}&cid=e{n}", headers=["X-Chat-Async: 1"]),
            step(f"the whole transcript, round {n}", "GET", "/chat/c/1_2/general/raw", JAR,
                 expect=marks),
            step(f"the docs page, round {n}", "GET", "/chat/docs", JAR),
        ]
    return steps


ENDURANCE = endurance_steps(ENDURANCE_ROUNDS)


# STAMINA: the same few requests, many times, to one boot. Every answer must
# equal the first answer to that request, and the base heap — what survives
# between requests — must not grow once it has settled.
STAMINA_ROUNDS = 100
STAMINA = [
    step("index", "GET", "/"),
    step("the 27 KB pdf", "GET", "/steve-resume.pdf"),
    # Anonymous: stamina repeats one step a hundred times with no login before
    # it, so this asks for what a stranger gets — which must be the same answer
    # every time, which is the whole point of the boot.
    step("chat, anonymous", "GET", "/chat"),
]


# ── the site, staged once ────────────────────────────────────────────────────

def write(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def stage(root: str, gopher_root: str) -> None:
    pages = os.path.join(gopher_root, "pages")
    os.makedirs(os.path.join(root, "pages"))
    for name in ("home.txt", "steve-resume.md", "steve-resume.pdf", "safari-download.md"):
        shutil.copy(os.path.join(pages, name), os.path.join(root, "pages", name))
    for d in ("data/lynrummy", "data/chat", "data/users", "auth"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    write(root, "data/players/1/name", "Steve")
    write(root, "auth/1/name", "Steve")
    write(root, "auth/1/password", MEMBER_HASH)
    write(root, "auth/2/name", "apoorva")
    write(root, "auth/2/password", MEMBER_HASH)
    write(root, "auth/next-id.txt", "3\n")
    with open(os.path.join(root, "data/chat/_session_secret"), "wb") as f:
        f.write(SESSION_SECRET)
    write(root, "data/players/next-id.txt", "1\n")
    # One finished game and one puzzle session for player 1, at a fixed time.
    write(root, f"{GAME1}/lynrummy-elm/sessions/1/meta",
          f"created_at: {STAGED_TIME}\nlabel: staged\n\nboard: the judge's fixture\n")
    write(root, f"{GAME1}/lynrummy-elm/sessions/1/actions.dsl", "1) draw\n2) meld\n")
    write(root, f"{GAME1}/next-session-id.txt", "2\n")
    write(root, f"{GAME1}/puzzle/sessions/1/meta", f"created_at: {STAGED_TIME}\n\ncatalog:\n  staged\n")
    write(root, f"{GAME1}/next-puzzle-id.txt", "2\n")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kw)


def partition_last(image: str) -> int:
    info = run(["sgdisk", "-i", "1", image]).stdout
    return int(next(l for l in info.splitlines() if l.startswith("Last sector")).split()[2])


def build_disk(image: str, content: str, mnt: str) -> None:
    """A GPT disk whose first partition is FAT16, holding `content`."""
    with open(image, "wb") as f:
        f.truncate(64 * 1024 * 1024)
    run(["sgdisk", "-o", "-n", f"1:{PART_FIRST}:0", "-t", "1:0700", "-c", "1:gopher", image])
    blocks = (partition_last(image) - PART_FIRST + 1) // 2
    run(["mkfs.vfat", "-F", "16", "-S", "512", "-n", "GOPHER",
         "--offset", str(PART_FIRST), image, str(blocks)])
    mount(image, mnt, writable=True)
    try:
        for entry in os.listdir(content):
            src, dst = os.path.join(content, entry), os.path.join(mnt, entry)
            if os.path.isdir(src):
                shutil.copytree(src, dst)
            else:
                shutil.copy(src, dst)
    finally:
        umount(mnt)


def mount(image: str, mnt: str, writable: bool) -> None:
    os.makedirs(mnt, exist_ok=True)
    opts = f"loop,offset={PART_FIRST * SECTOR},noexec,nosuid,nodev,uid={os.getuid()},gid={os.getgid()}"
    if not writable:
        opts += ",ro"
    run(["sudo", "-n", "mount", "-o", opts, image, mnt])


def umount(mnt: str) -> None:
    run(["sudo", "-n", "umount", mnt])


# ── asking a server ─────────────────────────────────────────────────────────

def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def ask_raw(port: int, payload: bytes) -> dict:
    """Bytes on a bare socket, and whatever comes back before the server closes."""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=15)
    except OSError as e:
        return {"error": f"raw socket: {e}"}
    try:
        if payload:
            s.sendall(payload)
        s.shutdown(socket.SHUT_WR)
        got = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            got += chunk
    except OSError as e:
        return {"error": f"raw socket: {e}"}
    finally:
        s.close()
    return {"status": 0, "headers": {}, "body": got}


def with_jar(c: dict, jar, minted=None):
    """The step with a cookie placeholder resolved: "$JAR" is every cookie this
    side's own responses have set; the minted ones are shared by both sides."""
    cookie = c.get("cookie")
    if cookie == JAR:
        if not jar:
            return dict(c, cookie=None)
        if isinstance(jar, str):
            return dict(c, cookie=jar)
        return dict(c, cookie="; ".join(f"{k}={v}" for k, v in jar.items()))
    if minted and cookie in minted:
        return dict(c, cookie=minted[cookie])
    return c


def ask(port: int, c: dict, scratch: str, patience: int = 400) -> dict:
    """One request by Python's own HTTP client. It never follows a redirect:
    the redirect IS the answer being compared.

    **ONLY A REFUSED CONNECTION IS TRIED AGAIN**, once a second, for up to
    `patience` seconds — a guest still coming up. A request that was sent is
    never sent twice: a POST retried after a reset would write twice, and a
    failure that retrying hides is a failure the judge should report. (This
    was curl, whose process cost nine milliseconds a request and whose
    `--retry-all-errors` resent anything.) `scratch` is kept for callers that
    pass one."""
    if c.get("raw") is not None:
        return ask_raw(port, c["raw"])
    headers = {"Host": f"127.0.0.1:{port}", "User-Agent": "gopher-metal-judge", "Accept": "*/*"}
    if c["cookie"]:
        headers["Cookie"] = c["cookie"]
    body = None
    if c["body"] is not None:
        body = c["body"].encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    for h in c.get("headers", ()):
        k, v = h.split(":", 1)
        headers[k.strip()] = v.strip()
    deadline = time.time() + patience
    while True:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=min(30, patience))
        try:
            conn.connect()
            break
        except ConnectionRefusedError as e:
            conn.close()
            if time.time() + 1 > deadline:
                return {"error": f"connection refused for {patience} s: {e}"}
            time.sleep(1)
        except OSError as e:
            conn.close()
            return {"error": f"connect: {e}"}
    try:
        conn.request(c["method"], c["path"], body=body, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
    except (OSError, http.client.HTTPException) as e:
        return {"error": f"{type(e).__name__}: {e}"}
    finally:
        conn.close()
    answer_headers = {}
    for k, v in resp.getheaders():
        k, v = k.strip().lower(), v.strip()
        # Several Set-Cookie headers are several cookies; keep them all, in
        # order, rather than the last.
        answer_headers[k] = answer_headers[k] + "\n" + v if k == "set-cookie" and k in answer_headers else v
    return {"status": resp.status, "headers": answer_headers, "body": payload}


def set_request_limit(image: str, n: int, mnt: str, idle_timeout_ms: int = 10000,
                      streams: int = None, lose_one_sent_in: int = None,
                      keepalive_ms: int = None) -> None:
    mount(image, mnt, writable=True)
    try:
        with open(os.path.join(mnt, "gopher-metal.conf"), "w") as f:
            f.write(f"requests = {n}\nidle_timeout_ms = {idle_timeout_ms}\n")
            if streams is not None:
                f.write(f"streams = {streams}\n")
            if lose_one_sent_in is not None:
                f.write(f"lose_one_sent_in = {lose_one_sent_in}\n")
            if keepalive_ms is not None:
                f.write(f"keepalive_ms = {keepalive_ms}\n")
    finally:
        umount(mnt)


def silent_client(port: int, payload: bytes):
    """**A CLIENT THAT CONNECTS AND THEN SAYS (ALMOST) NOTHING.** This server
    takes one connection at a time, so this is the request that holds the whole
    site: half a request line and then silence, with the socket left open. The
    kernel must let it go on its own and answer the next caller.

    Returns the open socket, which the caller closes when it is done proving
    the point — closing it early would be the polite hangup the kernel already
    handled."""
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    if payload:
        sock.sendall(payload)
    return sock


# **THE QUICK TIER.** With JUDGE_QUICK set, the machine's waits are
# test-sized — a three-second stream keepalive, sub-second silent-client
# timeouts — and the boots that exist to be long are left out. The full run
# keeps the real values; both prove the configured number is what governs.
QUICK = bool(os.environ.get("JUDGE_QUICK"))

# **A PACKET CAPTURE, WHEN ASKED FOR.** With JUDGE_CAPTURE set, every boot
# writes what crossed its NIC to `net.pcap` beside its serial log, for tcpdump.
CAPTURE = bool(os.environ.get("JUDGE_CAPTURE"))


def kvm_usable() -> bool:
    """Whether this user can open /dev/kvm right now."""
    return os.access("/dev/kvm", os.R_OK | os.W_OK)


def start_kernel(elf: str, image: str, scratch: str, kvm: bool = False):
    """Boots the kernel and returns (qemu, port, serial path) once it has said it
    is listening.

    **`kvm` IS FOR TIMING.** Without it the CPU is emulated in software (TCG),
    which is what every correctness check here has always run on and still
    does. A number meant to say how fast this machine is belongs on hardware
    virtualization — what a deployed machine would run on — so the soak asks
    for it, and refuses rather than quietly measuring TCG under KVM's name."""
    if kvm and not kvm_usable():
        raise RuntimeError("KVM was asked for and /dev/kvm is not usable by this user")
    port = free_port()
    serial = os.path.join(scratch, "serial")
    log = open(serial, "wb")
    qemu = subprocess.Popen([
        # rtc=on: under KVM microvm leaves the CMOS clock out unless asked,
        # and this kernel reads it. See probe/run.sh.
        "qemu-system-x86_64", "-M", "microvm,rtc=on,pit=on", "-kernel", elf,
        *(["-enable-kvm"] if kvm else []),
        "-nographic", "-no-reboot", "-m", "512",
        "-global", "virtio-mmio.force-legacy=false",
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
        "-drive", f"id=d,file={image},format=raw,if=none",
        "-device", "virtio-blk-device,drive=d",
        "-cpu", "max", "-device", "virtio-rng-device",
        "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{port}-:80",
        "-device", "virtio-net-device,netdev=n0",
        *(["-object", f"filter-dump,id=cap,netdev=n0,file={os.path.join(scratch, 'net.pcap')}"]
          if CAPTURE else []),
    ], stdout=log, stderr=subprocess.STDOUT)
    log.close()
    deadline = time.time() + 30
    while time.time() < deadline and qemu.poll() is None:
        with open(serial, "rb") as seen:
            if b"listening on port 80" in seen.read():
                break
        time.sleep(0.02)
    return qemu, port, serial


def finish_kernel(qemu, serial: str):
    try:
        code = qemu.wait(timeout=60)
    except subprocess.TimeoutExpired:
        qemu.kill()
        qemu.wait()
        code = "timeout"
    text = open(serial, "rb").read().decode("latin-1", "replace")
    lines = "\n".join(l for l in text.splitlines()
                      if l.strip() and "SeaBIOS" not in l and "\x1b" not in l)
    return code, lines


def ask_kernel(elf: str, image: str, c: dict, scratch: str) -> dict:
    """One request to a fresh boot. The pristine disk says `requests = 1`, so
    the kernel stops once it has answered."""
    before = time.time()
    qemu, port, serial = start_kernel(elf, image, scratch)
    answer = ask(port, c, os.path.join(scratch, "kernel"))
    answer["guest_exit"], answer["serial"] = finish_kernel(qemu, serial)
    answer["window"] = (int(before) - 1, int(time.time()) + 1)
    return answer


class LinuxServer:
    def __init__(self, binary: str, root: str, log: str):
        self.port = free_port()
        conf = os.path.join(root, "gopher.conf")
        with open(conf, "w") as f:
            # **RELATIVE, like the kernel's.** The server runs with cwd=root, so
            # `data` is the same directory either way — but the admin roster
            # PRINTS its data root on the page, and an absolute path here would
            # be a difference between two hosts' configuration rather than
            # between two answers.
            f.write("data_dir = data\nauth_dir = auth\n")
        env = dict(os.environ, GOPHER_CONFIG=conf, GOPHER_PORT=str(self.port))
        self.log = open(log, "wb")
        # Popen gives the server's OWN pid, so stopping it stops it — not a
        # shell that happens to be its parent.
        self.proc = subprocess.Popen([binary], cwd=root, env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
                return
            except OSError:
                if self.proc.poll() is not None:
                    raise RuntimeError(f"the Linux server exited {self.proc.returncode}")
                time.sleep(0.05)
        raise RuntimeError("the Linux server never listened")

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.log.close()


def ask_linux(binary: str, content: str, c: dict, scratch: str) -> dict:
    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    before = time.time()
    server = LinuxServer(binary, root, os.path.join(scratch, "linux.log"))
    try:
        answer = ask(server.port, c, os.path.join(scratch, "linux-http"))
    finally:
        server.stop()
    answer["window"] = (int(before) - 1, int(time.time()) + 1)
    answer["root"] = root
    return answer


# ── the comparison ───────────────────────────────────────────────────────────

COMPARED_HEADERS = ("location", "set-cookie", "content-type")
UNIX_TIME = re.compile(rb"\b1[5-9]\d{8}\b")
RFC3339 = re.compile(rb"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\b")
SESSION_MAC = re.compile(rb"\.<NOW>\.[A-Za-z0-9_-]{43}")


EASTERN = zoneinfo.ZoneInfo("America/New_York")


def eastern(unix: int) -> bytes:
    """angry-gopher's formatEastern, restated with Python's own time zone rules:
    `Sep 16, 2026 · 7:32 PM EDT`."""
    d = datetime.datetime.fromtimestamp(unix, EASTERN)
    return d.strftime("%b %-d, %Y · %-I:%M %p %Z").encode()


def normalize(data: bytes, window) -> bytes:
    """Replace a time with <NOW> — but only one inside `window`, the span in which
    this side handled the request. A time outside it is left as it is, so a
    wrong clock is a difference rather than a wildcard.

    Two spellings: a Unix time, and the Eastern wall-clock text the session
    pages render. The second is minute-precise, so every minute the window
    touches is tried."""
    lo, hi = window

    def sub(m):
        return b"<NOW>" if lo <= int(m.group(0)) <= hi else m.group(0)

    data = UNIX_TIME.sub(sub, data)

    def sub_rfc(m):
        t = calendar.timegm(time.strptime(m.group(0).decode(), "%Y-%m-%dT%H:%M:%SZ"))
        return b"<NOW-RFC3339>" if lo <= t <= hi else m.group(0)

    data = RFC3339.sub(sub_rfc, data)
    # A session cookie minted in the window: its MAC covers the time, so it
    # differs whenever the time does.
    data = SESSION_MAC.sub(b".<NOW>.<MAC>", data)
    for minute in range(lo - lo % 60, hi + 60, 60):
        data = data.replace(eastern(minute), b"<NOW-EASTERN>")
    return data


def differences(c: dict, metal: dict, linux: dict) -> list:
    if "error" in linux:
        return [f"the LINUX server did not answer: {linux['error']}"]
    if "error" in metal:
        return [f"the kernel did not answer: {metal['error']}"]
    out = []
    if metal["guest_exit"] != 1:
        tail = metal["serial"].splitlines()[-3:]
        out.append(f"the guest exited {metal['guest_exit']}, not cleanly: {' | '.join(tail)}")
    if metal["status"] != linux["status"]:
        out.append(f"status {metal['status']} on metal, {linux['status']} on Linux")
    for h in COMPARED_HEADERS:
        m, l = metal["headers"].get(h), linux["headers"].get(h)
        if m is not None:
            m = normalize(m.encode("latin-1"), metal["window"]).decode("latin-1")
        if l is not None:
            l = normalize(l.encode("latin-1"), linux["window"]).decode("latin-1")
        if m != l:
            out.append(f"{h}: metal {m!r}, Linux {l!r}")
    if c["path"] == "/version":
        out += version_differences(metal["body"], linux["body"])
    else:
        mb = normalize(metal["body"], metal["window"])
        lb = normalize(linux["body"], linux["window"])
        if mb != lb:
            out.append(f"body differs: {len(mb)} bytes on metal, {len(lb)} on Linux"
                       f"{first_difference(mb, lb)}")
    return out


def version_differences(metal: bytes, linux: bytes) -> list:
    try:
        m, l = json.loads(metal), json.loads(linux)
    except ValueError as e:
        return [f"/version is not JSON: {e}"]
    out = []
    if m.keys() != l.keys():
        out.append(f"/version keys differ: {sorted(m)} vs {sorted(l)}")
    if m.get("commit") != "bare-metal":
        out.append(f"/version on metal names commit {m.get('commit')!r}, want 'bare-metal'")
    for k in ("result", "version", "rejects"):
        if m.get(k) != l.get(k):
            out.append(f"/version {k}: metal {m.get(k)!r}, Linux {l.get(k)!r}")
    if set(m.get("mem", {})) != set(l.get("mem", {})):
        out.append("/version mem fields differ")
    return out


def first_difference(a: bytes, b: bytes) -> str:
    n = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
    return f"; first difference at byte {n}: {a[n:n + 40]!r} vs {b[n:n + 40]!r}"


def file_differences(c: dict, image: str, metal: dict, linux: dict, mnt: str) -> list:
    """The files a case touched, read through the Linux VFAT driver on the
    kernel's disk and straight off the Linux server's directory. A file absent
    on both sides agrees; that is how "a move into a missing session wrote
    nothing" is checked."""
    if not c["files"]:
        return []
    out = []
    mount(image, mnt, writable=False)
    try:
        for rel in c["files"]:
            m = read_or_none(os.path.join(mnt, rel))
            l = read_or_none(os.path.join(linux["root"], rel))
            nm = None if m is None else normalize(m, metal["window"])
            nl = None if l is None else normalize(l, linux["window"])
            if nm != nl:
                out.append(f"{rel}: metal wrote {abbrev(nm)}, Linux wrote {abbrev(nl)}")
    finally:
        umount(mnt)

    # fsck.vfat has no offset option, so it checks a copy of the partition.
    part = image + ".part"
    run(["dd", f"if={image}", f"of={part}", f"bs={SECTOR}", f"skip={PART_FIRST}",
         f"count={partition_last(image) - PART_FIRST + 1}", "status=none"])
    check = subprocess.run(["fsck.vfat", "-n", part], capture_output=True, text=True)
    if check.returncode != 0:
        out.append("fsck.vfat rejects the kernel's disk: "
                   + " | ".join(check.stdout.strip().splitlines()[1:4]))
    os.remove(part)
    return out


def abbrev(b):
    if b is None:
        return "nothing"
    return repr(b if len(b) <= 60 else b[:57] + b"...")


def read_or_none(path: str):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def cookie_from(answer: dict, jar):
    """The gopher_uid a response set, or the jar unchanged."""
    sc = answer.get("headers", {}).get("set-cookie", "")
    m = re.search(r"(gopher_uid=[A-Za-z0-9]+)", sc)
    return m.group(1) if m else jar


def update_jar(answer: dict, jar: dict) -> dict:
    """Every cookie a response set, as a browser would keep them: a value
    replaces the old one, and Max-Age=0 removes it."""
    jar = dict(jar or {})
    for line in answer.get("headers", {}).get("set-cookie", "").split("\n"):
        if "=" not in line:
            continue
        pair, _, attrs = line.partition(";")
        name, _, value = pair.strip().partition("=")
        if re.search(r"(?i)max-age=0\b", attrs) or value == "":
            jar.pop(name, None)
        else:
            jar[name] = value
    return jar


def tree(root: str) -> dict:
    out = {}
    for dirpath, _, files in [w for top in ("data", "auth") for w in os.walk(os.path.join(root, top))]:
        for f in files:
            full = os.path.join(dirpath, f)
            with open(full, "rb") as fh:
                out[os.path.relpath(full, root)] = fh.read()
    return out


def run_story(elf, linux_bin, content, pristine, work, mnt, steps, label, report, minted=None,
              conf=None):
    """Tells `steps` to one kernel and one Linux server. Returns (failures,
    kernel serial log, per-step kernel answers). `conf` is more of the
    kernel's configuration."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, len(steps), mnt, **(conf or {}))

    before = time.time()
    qemu, port, serial = start_kernel(elf, image, scratch)
    metal_answers, jar = [], {}
    for i, s in enumerate(steps):
        if s.get("settle"):
            time.sleep(s["settle"])
        if qemu.poll() is not None:
            # The kernel is gone. Every later step is a failure, and asking
            # would only wait for a connection that will never come.
            metal_answers.append({"error": f"the kernel had already exited ({qemu.returncode})"})
            continue
        a = ask(port, with_jar(s, jar, minted), os.path.join(scratch, f"k{i}"))
        jar = update_jar(a, jar)
        metal_answers.append(a)
    code, log = finish_kernel(qemu, serial)
    metal_window = (int(before) - 1, int(time.time()) + 1)

    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    before = time.time()
    server = LinuxServer(linux_bin, root, os.path.join(scratch, "linux.log"))
    linux_answers, jar = [], {}
    try:
        for i, s in enumerate(steps):
            if s.get("settle"):
                time.sleep(s["settle"])
            a = ask(server.port, with_jar(s, jar, minted), os.path.join(scratch, f"l{i}"))
            jar = update_jar(a, jar)
            linux_answers.append(a)
    finally:
        server.stop()
    linux_window = (int(before) - 1, int(time.time()) + 1)

    failures = 0
    # **A REQUEST THAT WAITED A SECOND WAITED ON A TIMER.** Every answer can
    # match Linux's while each one waits out a retransmission nobody needed —
    # which is how a full run once went from three minutes to seven. On a boot
    # that loses nothing on purpose, no request waits that long for its turn.
    if not (conf or {}).get("lose_one_sent_in"):
        slow = [(n + 1, w) for n, (w, _, _, _) in enumerate(request_timings(log)) if w >= WAIT_LIMIT_US]
        if slow:
            failures += 1
            report(f"FAIL  {label}: {len(slow)} requests waited a second or more for their turn "
                   f"(request {slow[0][0]}: {slow[0][1] // 1000} ms)")
    if code != 1:
        failures += 1
        report(f"FAIL  {label}: the kernel exited {code} after the story: "
               + " | ".join(log.splitlines()[-3:]))
    for s, m, l in zip(steps, metal_answers, linux_answers):
        m = dict(m, guest_exit=1, window=metal_window, serial=log)
        l = dict(l, window=linux_window)
        diffs = differences(s, m, l)
        if diffs:
            failures += 1
            report(f"FAIL  {label}: {s['name']}  ({s['method']} {s['path']})")
            for d in diffs:
                report(f"        {d}")

    # The whole data tree, both sides, at the end of the story.
    mount(image, mnt, writable=False)
    try:
        metal_tree = tree(mnt)
    finally:
        umount(mnt)
    linux_tree = tree(root)
    for rel in sorted(set(metal_tree) | set(linux_tree)):
        m = metal_tree.get(rel)
        l = linux_tree.get(rel)
        nm = None if m is None else normalize(m, metal_window)
        nl = None if l is None else normalize(l, linux_window)
        if nm != nl:
            failures += 1
            report(f"FAIL  {label}: {rel}: metal has {abbrev(nm)}, Linux has {abbrev(nl)}")

    part = image + ".part"
    run(["dd", f"if={image}", f"of={part}", f"bs={SECTOR}", f"skip={PART_FIRST}",
         f"count={partition_last(image) - PART_FIRST + 1}", "status=none"])
    check = subprocess.run(["fsck.vfat", "-n", part], capture_output=True, text=True)
    if check.returncode != 0:
        failures += 1
        report(f"FAIL  {label}: fsck.vfat rejects the kernel's disk: "
               + " | ".join(check.stdout.strip().splitlines()[1:4]))
    shutil.rmtree(scratch, ignore_errors=True)
    return failures, log, metal_answers, len(metal_tree)


BASE_HEAP = re.compile(
    r"request \d+: .*\(base: (\d+) live bytes, (\d+) in pages, peak (\d+)\)")


def missing_marks(steps, answers, report, label) -> int:
    """**WHAT WAS WRITTEN MUST STILL BE THERE.** Every step that carries
    `expect` is a read-back, and every mark from every earlier round must be in
    the body it returned. This is the check that does not go through Linux: two
    servers agreeing on a transcript that lost round 7 would still be wrong."""
    failures = 0
    for s, a in zip(steps, answers):
        if not s["expect"]:
            continue
        body = a.get("body")
        if body is None:
            failures += 1
            report(f"FAIL  {label}: {s['name']}: no body to read the marks out of "
                   f"({a.get('error', a.get('status'))})")
            continue
        gone = [m for m in s["expect"] if m not in body]
        if gone:
            failures += 1
            report(f"FAIL  {label}: {s['name']}: {len(gone)} of {len(s['expect'])} marks are not in "
                   f"the {len(body)}-byte body it returned, first {gone[0].decode()}")
    return failures


def held_open(elf, pristine, work, mnt, ms: int):
    """One boot, one client that connects and then says nothing, and one caller
    beside it. Returns (how long the caller waited for its answer, when the
    kernel closed the silent socket, the caller's answer, what the silent socket
    read at the end, the serial log) — times in seconds from the moment the
    silent client connected."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, 2, mnt, idle_timeout_ms=ms)
    qemu, port, serial = start_kernel(elf, image, scratch)
    held = silent_client(port, b"GET / HTTP/1.1\r\n")  # half a request, then silence
    began = time.time()
    answer = ask(port, step("the caller beside the silent one", "GET", "/"),
                 os.path.join(scratch, "after"), patience=60)
    answered = time.time() - began
    # The kernel closes the silent connection when it lets it go; the socket
    # then reads end-of-stream.
    held.settimeout(ms / 1000 + 30)
    try:
        rest = held.recv(64)
    except OSError:
        rest = None
    let_go = time.time() - began
    held.close()
    _, log = finish_kernel(qemu, serial)
    shutil.rmtree(scratch, ignore_errors=True)
    return answered, let_go, answer, rest, log


def timeout_failures(elf, pristine, work, mnt, report) -> int:
    """**A CLIENT THAT SAYS NOTHING NO LONGER HOLDS ANYONE UP — AND IS STILL LET
    GO.** When the machine held one connection at a time, this gate proved that
    a caller queued behind a silent client waited out the timeout (6 s at a
    2-second setting, 18 s at 6). With a table of connections the caller must
    NOT wait: it is answered while the silent one sits in the table. The silent
    one is still closed by the kernel once it has been quiet for the setting.

    Two boots with two `idle_timeout_ms`, because "it was let go" is not the
    claim: the claim is that the setting decides WHEN, and the only way to show
    that is to change it and watch the close move."""
    failures = 0
    let_go_at = {}
    low, high = (500, 2000) if QUICK else (2000, 6000)
    for ms in (low, high):
        answered, let_go, answer, rest, log = held_open(elf, pristine, work, mnt, ms)
        let_go_at[ms] = let_go
        if answer.get("status") != 200:
            failures += 1
            report(f"FAIL  timeout: with idle_timeout_ms={ms} the caller beside a silent client "
                   f"got {answer.get('status', answer.get('error'))}, not 200")
        if answered >= ms / 1000:
            failures += 1
            report(f"FAIL  timeout: with idle_timeout_ms={ms} the caller waited {answered:.1f}s — "
                   f"as long as the silent client was allowed; it was held up behind it")
        if rest != b"":
            failures += 1
            report(f"FAIL  timeout: with idle_timeout_ms={ms} the silent client was never closed "
                   f"by the kernel (its socket read {rest!r})")
        elif not (0.8 * ms / 1000 <= let_go <= ms / 1000 + 5):
            failures += 1
            report(f"FAIL  timeout: with idle_timeout_ms={ms} the silent client was let go after "
                   f"{let_go:.1f}s")
        if "the client stopped sending" not in log:
            failures += 1
            report(f"FAIL  timeout: with idle_timeout_ms={ms} the kernel never said it let the "
                   f"silent client go: {' | '.join(log.splitlines()[-3:])}")
    moved = let_go_at[high] - let_go_at[low]
    if moved < 0.8 * (high - low) / 1000:
        failures += 1
        report(f"FAIL  timeout: raising the setting by {(high - low) / 1000:g}s moved the close by only "
               f"{moved:.1f}s — the setting does not govern it")
    if not failures:
        report(f"ok    a silent client holds nobody up and is still let go when the volume says: "
               f"closed after {let_go_at[low]:.1f}s at {low} ms and {let_go_at[high]:.1f}s at {high} ms, "
               f"with the caller beside it answered first both times")
    return failures


def parse_raw_response(raw: bytes) -> dict:
    """An HTTP response read off a bare socket, in the shape `ask` answers."""
    head, sep, body = raw.partition(b"\r\n\r\n")
    if not sep:
        return {"error": f"no complete response head in {len(raw)} bytes"}
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split(" ", 2)
    if len(parts) < 2 or not parts[1].isdigit():
        return {"error": f"not a status line: {lines[0]!r}"}
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            k, v = k.strip().lower(), v.strip()
            headers[k] = headers[k] + "\n" + v if k == "set-cookie" and k in headers else v
    return {"status": int(parts[1]), "headers": headers, "body": body}


# **MANY CLIENTS AT ONCE.** The paths are ones the single-request cases already
# prove equal to Linux, so a difference here is about holding connections, not
# about the page.
CONCURRENT_PATHS = ["/", "/steve-resume.pdf", "/nope", "/login", "/chat",
                    "/tutorial", "/driving", "/admin"]
CONNECTIONS_LINE = re.compile(r"connections: at most (\d+) at once, (\d+) turned away")


def concurrent_failures(elf, linux_bin, content, pristine, work, mnt, report) -> int:
    """Every client connects FIRST, then each sends its request — the last one
    connected sending first — and only then are the answers read. A machine that
    held one connection at a time could not get past the second connect; this
    one must hold all of them, answer each correctly, and say so in its log."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, len(CONCURRENT_PATHS), mnt)
    before = time.time()
    qemu, port, serial = start_kernel(elf, image, scratch)
    failures = 0
    socks = []
    try:
        for _ in CONCURRENT_PATHS:
            socks.append(socket.create_connection(("127.0.0.1", port), timeout=60))
        # Let every handshake reach the guest before anyone asks for anything.
        time.sleep(1.0)
        for sock, path in reversed(list(zip(socks, CONCURRENT_PATHS))):
            sock.sendall(f"GET {path} HTTP/1.1\r\nHost: judge\r\nConnection: close\r\n\r\n".encode())
        answers = []
        for sock in socks:
            got = b""
            try:
                while True:
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    got += chunk
            except OSError as e:
                answers.append({"error": f"socket: {e}"})
                continue
            answers.append(parse_raw_response(got))
    finally:
        for sock in socks:
            sock.close()
    code, log = finish_kernel(qemu, serial)
    window = (int(before) - 1, int(time.time()) + 1)

    for path, metal in zip(CONCURRENT_PATHS, answers):
        c = case(f"concurrently: {path}", "GET", path)
        linux = ask_linux(linux_bin, content, c, tempfile.mkdtemp(dir=work))
        m = dict(metal, guest_exit=code, window=window, serial=log)
        diffs = differences(c, m, linux)
        if diffs:
            failures += 1
            report(f"FAIL  concurrent: GET {path}")
            for d in diffs:
                report(f"        {d}")

    held = CONNECTIONS_LINE.search(log)
    if held is None:
        failures += 1
        report("FAIL  concurrent: the kernel never said how many connections it held")
    elif int(held.group(1)) < len(CONCURRENT_PATHS):
        failures += 1
        report(f"FAIL  concurrent: the kernel held at most {held.group(1)} at once, "
               f"with {len(CONCURRENT_PATHS)} clients connected")
    elif int(held.group(2)) != 0:
        failures += 1
        report(f"FAIL  concurrent: the kernel turned {held.group(2)} away")
    if not failures:
        report(f"ok    {len(CONCURRENT_PATHS)} clients connected at once, each answered as Linux "
               f"answered; the kernel held {held.group(1)} at once and turned none away")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


# ── a live stream ────────────────────────────────────────────────────────────

LOGIN_BODY = "name=Steve&password=correct+horse+battery+staple&action=login&next=%2Fchat"


def read_until(sock, wanted: bytes, deadline: float, got: bytes = b"") -> bytes:
    """Reads a held-open stream until `wanted` has arrived or the deadline
    passes. Answers everything read so far either way."""
    while wanted not in got and time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            chunk = sock.recv(65536)
        except OSError:
            break
        if not chunk:
            break
        got += chunk
    return got


def sse_story(port: int, scratch: str, report, label: str) -> int:
    """**A MESSAGE SENT ON ONE CONNECTION ARRIVES ON A STREAM HELD OPEN ON
    ANOTHER.** Nothing checked that before: curl runs no JavaScript and the
    stress test only opens streams to break them. Four requests:

      1. log in
      2. send a first message, which becomes the topic's backlog
      3. open the topic's stream (held open) — the backlog must come first
      4. send a second message — it must arrive on the stream, numbered 1

    The stream's body is delimited by the connection closing, not chunked:
    the host writes live frames long after the handler returned."""
    failures = 0
    login = ask(port, step("log in", "POST", "/login/full", None, LOGIN_BODY), scratch, patience=60)
    jar = update_jar(login, {})
    cookie = "; ".join(f"{k}={v}" for k, v in jar.items())
    first = ask(port, step("a first message", "POST", "/chat/c/1_2/live/send", cookie,
                           "markdown=backlog-mark&cid=b1", headers=["X-Chat-Async: 1"]),
                scratch, patience=60)
    if first.get("status") not in (200, 204):
        report(f"FAIL  {label}: the first message was answered {first.get('status', first.get('error'))}")
        return 1

    sock = socket.create_connection(("127.0.0.1", port), timeout=30)
    try:
        sock.sendall((f"GET /chat/c/1_2/live/stream?since=0 HTTP/1.1\r\nHost: judge\r\n"
                      f"Cookie: {cookie}\r\nAccept: text/event-stream\r\n\r\n").encode())
        got = read_until(sock, b"backlog-mark", time.time() + 30)
        head = got.partition(b"\r\n\r\n")[0].decode("latin-1").lower()
        if not got.startswith(b"HTTP/1.1 200"):
            failures += 1
            report(f"FAIL  {label}: the stream answered {got[:40]!r}")
        if "content-type: text/event-stream" not in head:
            failures += 1
            report(f"FAIL  {label}: the stream is not an event stream: {head!r}")
        if "transfer-encoding: chunked" in head:
            failures += 1
            report(f"FAIL  {label}: the stream is chunked; a host-kept stream must be close-delimited")
        if b"event: backlog-size\ndata: 1" not in got or b"backlog-mark" not in got:
            failures += 1
            report(f"FAIL  {label}: the backlog did not arrive first: {got[-200:]!r}")

        second = ask(port, step("a live message", "POST", "/chat/c/1_2/live/send", cookie,
                                "markdown=live-mark&cid=l1", headers=["X-Chat-Async: 1"]),
                     scratch, patience=60)
        if second.get("status") not in (200, 204):
            failures += 1
            report(f"FAIL  {label}: the live message was answered {second.get('status', second.get('error'))}")
        before = len(got)
        got = read_until(sock, b"live-mark", time.time() + 15, got)
        live = got[before:]
        if b"live-mark" not in live:
            failures += 1
            report(f"FAIL  {label}: the live message never arrived on the open stream "
                   f"({len(live)} bytes after the backlog: {live[:120]!r})")
        elif b"id: 1\n" not in live:
            failures += 1
            report(f"FAIL  {label}: the live frame is not numbered 1: {live[:120]!r}")
    finally:
        sock.close()
    if not failures:
        report(f"ok    {label}: a stream held open got its backlog first, then the message sent on "
               f"another connection, numbered 1")
    return failures


APOORVA_LOGIN = "name=apoorva&password=correct+horse+battery+staple&action=login&next=%2Fchat"


def open_stream(port: int, path: str, cookie: str):
    sock = socket.create_connection(("127.0.0.1", port), timeout=30)
    sock.sendall((f"GET {path} HTTP/1.1\r\nHost: judge\r\nCookie: {cookie}\r\n"
                  f"Accept: text/event-stream\r\n\r\n").encode())
    return sock


def tab_story(port: int, scratch: str, report, label: str, keepalive: float = 25) -> int:
    """**A CHAT TAB, AS A BROWSER HOLDS IT: THREE STREAMS AT ONCE**, fed by
    another user. Eight requests:

      1-2. Steve and Apoorva log in
      3.   Steve starts topic `tab`
      4-6. Apoorva opens her tab's streams: `tab`'s conversation,
           notifications, sidebar
      7.   Steve sends on `tab`: her conversation stream shows it as not hers,
           and her notifications say he sent it
      8.   Steve starts a NEW topic: her sidebar is told it was added

    Then `keepalive` + 2 quiet seconds, in which every one of the three must be
    pinged: the application's keepalive is 25, and the machine's can be set
    shorter. Presence also pushes "came online" events at
    moments nobody controls, so each check looks for its own event rather than
    for silence."""
    failures = 0

    def fail(msg):
        nonlocal failures
        failures += 1
        report(f"FAIL  {label}: {msg}")

    def login(body):
        return update_jar(ask(port, step("log in", "POST", "/login/full", None, body), scratch,
                              patience=60), {})

    def cookie_of(jar):
        return "; ".join(f"{k}={v}" for k, v in jar.items())

    steve = cookie_of(login(LOGIN_BODY))
    apoorva = cookie_of(login(APOORVA_LOGIN))
    if not steve or not apoorva:
        fail("a login set no session cookie")
        return failures

    def send(topic, text, cid):
        a = ask(port, step(f"send {text}", "POST", f"/chat/c/1_2/{topic}/send", steve,
                           f"markdown={text}&cid={cid}", headers=["X-Chat-Async: 1"]),
                scratch, patience=60)
        if a.get("status") not in (200, 204):
            fail(f"sending {text} was answered {a.get('status', a.get('error'))}")

    send("tab", "tab-opener", "t1")
    opened = time.time()
    conv = open_stream(port, "/chat/c/1_2/tab/stream?since=0", apoorva)
    notify = open_stream(port, "/chat/notifications", apoorva)
    sidebar = open_stream(port, "/chat/sidebar/stream", apoorva)
    socks = [conv, notify, sidebar]
    try:
        got = {s: b"" for s in socks}
        got[conv] = read_until(conv, b"tab-opener", time.time() + 30)
        # The two live-only streams answer with their head and nothing else.
        for s in (notify, sidebar):
            got[s] = read_until(s, b"\r\n\r\n", time.time() + 30)
            if not got[s].startswith(b"HTTP/1.1 200"):
                fail(f"a live-only stream answered {got[s][:40]!r}")

        send("tab", "tab-live", "t2")
        got[conv] = read_until(conv, b"tab-live", time.time() + 15, got[conv])
        live = got[conv].partition(b"tab-live")[0].rpartition(b"id: ")[2] + b"tab-live"
        if b"tab-live" not in got[conv]:
            fail("the message never reached her conversation stream")
        elif b'"mine":false' not in got[conv][got[conv].rfind(b"id: "):]:
            fail(f"his message is marked as hers on her stream: {live[:120]!r}")
        got[notify] = read_until(notify, b"Steve sent you a message on tab.", time.time() + 15, got[notify])
        if b"Steve sent you a message on tab." not in got[notify]:
            fail(f"her notifications never said he sent it: {got[notify][-160:]!r}")

        send("tab-other", "other-opener", "o1")
        got[sidebar] = read_until(sidebar, b'"sid":"tab-other"', time.time() + 15, got[sidebar])
        if b'"kind":"topic-added"' not in got[sidebar] or b'"sid":"tab-other"' not in got[sidebar]:
            fail(f"her sidebar was never told the new topic was added: {got[sidebar][-160:]!r}")

        # **A PING IS RARE.** A host that pinged every turn would flood the
        # network and still deliver a ping; so none may have come before the
        # keepalive was due…
        if time.time() - opened < 0.8 * keepalive:
            for name, s in (("conversation", conv), ("notifications", notify), ("sidebar", sidebar)):
                if b": ping" in got[s]:
                    fail(f"her {name} stream was pinged within {time.time() - opened:.0f}s of opening")
        # …and after the keepalive, each is pinged — once, or at most twice.
        marks = {s: len(got[s]) for s in socks}
        deadline = time.time() + keepalive + 2
        for s in socks:
            got[s] = read_until(s, b": ping", deadline, got[s])
        for s in socks:
            got[s] = read_until(s, b"never", time.time() + 1.0, got[s])  # whatever else came
        for name, s in (("conversation", conv), ("notifications", notify), ("sidebar", sidebar)):
            pings = got[s][marks[s]:].count(b": ping")
            if pings == 0:
                fail(f"her {name} stream was not pinged in {keepalive + 2:g} quiet seconds")
            elif pings > 2:
                fail(f"her {name} stream was pinged {pings} times in {keepalive + 3:g} seconds, "
                     f"with a {keepalive:g}-second keepalive")
    finally:
        for s in socks:
            s.close()
    if not failures:
        report(f"ok    {label}: one tab's three streams at once — his message on her conversation "
               f"(not hers), in her notifications, his new topic in her sidebar, and all three "
               f"pinged after {keepalive:g} quiet seconds")
    return failures


# ── uploads ──────────────────────────────────────────────────────────────────
#
# **A PICTURE GOES ON THE VOLUME AND COMES BACK BYTE FOR BYTE**, and an upload
# too big for the machine is refused the way Linux refuses it — which is a
# statement about the request heap, not about the route. The heap this machine
# gives a request grows past what it keeps: a fixed one failed while the body
# was still being read, and answered "400, could not read the body" where Linux
# answers "413, the limit is 10 MB" — and for a big enough upload it closed the
# connection while the client was still sending, so the client saw no answer at
# all.

UPLOAD_BOUNDARY = "----gophermetaljudge"
# Bigger than the heap the machine keeps between requests (32 MB), and bigger
# than chat's own image limit, so the answer has to come from a body that was
# read whole and then refused.
OVERSIZED_UPLOAD = 40 << 20


def picture(n: int) -> bytes:
    """`n` bytes that sniff as a PNG."""
    return b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" + bytes((k * 7 + 3) & 0xFF for k in range(n - 16))


def multipart(filename: str, data: bytes) -> bytes:
    head = (f"--{UPLOAD_BOUNDARY}\r\nContent-Disposition: form-data; name=\"file\"; "
            f"filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n").encode()
    return head + data + f"\r\n--{UPLOAD_BOUNDARY}--\r\n".encode()


# The stored file is named at random, by each side's own generator, so that is
# the one thing about an upload's answer that cannot be compared. Everything
# else in it — the conversation it landed in, the kind, the name the client
# sent — is compared exactly.
STORED_NAME = re.compile(rb"[0-9a-f]{32}")


def named(answer: dict) -> dict:
    return dict(answer, body=STORED_NAME.sub(b"<NAME>", answer["body"]))


def upload_story(port: int, session: str) -> dict:
    """Posts pictures to chat and reads one back. Answers what each step got,
    with the stored file's random name left out — it is random on both sides."""

    def send(method, path, body=None, ctype=None, expect_continue=False, timeout=120):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        headers = {"Host": f"127.0.0.1:{port}", "Accept": "*/*", "Cookie": session}
        if ctype:
            headers["Content-Type"] = ctype
        if expect_continue:
            headers["Expect"] = "100-continue"
        try:
            conn.request(method, path, body=body, headers=headers)
            r = conn.getresponse()
            out = {"status": r.status, "body": r.read(), "type": r.getheader("content-type")}
        except OSError as e:
            out = {"status": 0, "body": f"{type(e).__name__}: {e}".encode(), "type": None}
        finally:
            conn.close()
        return out

    def post(name, data, **kw):
        return send("POST", "/chat/c/1_2/general/upload", multipart(name, data),
                    f"multipart/form-data; boundary={UPLOAD_BOUNDARY}", **kw)

    small = picture(64 << 10)
    out = {}
    # **THE URL IS READ BEFORE THE NAME IS NORMALIZED.** Asking for
    # `<NAME>.png` is a 404 on both sides, and two 404s agree.
    stored = post("shot.png", small)
    out["a picture"] = named(stored)
    out["it comes back"] = {"status": 0, "body": b"the upload was refused", "type": None}
    if stored["status"] == 200:
        try:
            url = json.loads(stored["body"])["url"]
        except (ValueError, KeyError) as e:
            url = None
            out["it comes back"] = {"status": 0, "body": f"the answer was not JSON: {e}".encode(), "type": None}
        if url:
            got = send("GET", url)
            same = got["body"] == small
            out["it comes back"] = {"status": got["status"], "type": got["type"],
                                    "body": b"the same bytes" if same else b"DIFFERENT bytes"}
    out["one that waits to be told to send"] = named(post("two.png", small, expect_continue=True))
    out["not a picture"] = post("notes.txt", b"just words, not a picture at all")
    if not QUICK:
        out["bigger than the heap it keeps"] = post("huge.png", picture(OVERSIZED_UPLOAD))
    return out


def upload_failures(elf, linux_bin, content, pristine, work, mnt, report) -> int:
    """The same uploads to the machine and to Linux, and their answers compared.
    The stored file's name is random on both sides, so what is compared is the
    status, the content type, and the bytes that came back."""
    session = mint_session("1", int(time.time()))
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, 30, mnt)
    qemu, port, serial = start_kernel(elf, image, scratch)
    try:
        metal = upload_story(port, session)
    finally:
        code, log = finish_kernel(qemu, serial)

    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    server = LinuxServer(linux_bin, root, os.path.join(scratch, "linux.log"))
    try:
        linux = upload_story(server.port, session)
    finally:
        server.stop()

    failures = 0
    for name, want in linux.items():
        got = metal.get(name, {})
        if got != want:
            failures += 1
            report(f"FAIL  uploads: {name}: the machine said {abbrev(got.get('body', b''))} "
                   f"({got.get('status')}, {got.get('type')}), Linux said "
                   f"{abbrev(want.get('body', b''))} ({want['status']}, {want.get('type')})")
    # **AGREEING ON A FAILURE IS NOT PASSING.** Two servers that both refused
    # the upload, or both answered 404 for the stored file, agree perfectly.
    for side, answers in (("the machine", metal), ("Linux", linux)):
        got = answers.get("it comes back", {})
        if got.get("status") != 200 or got.get("body") != b"the same bytes":
            failures += 1
            report(f"FAIL  uploads: {side} did not give the picture back: "
                   f"{got.get('status')} {abbrev(got.get('body', b''))}")
    if not failures:
        sizes = "a 64 KB picture" + ("" if QUICK else f" and one of {OVERSIZED_UPLOAD >> 20} MB")
        report(f"ok    uploads: {sizes}, stored, read back byte for byte, and refused as Linux refuses them")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


def linux_sse_failures(linux_bin, content, work, report) -> int:
    scratch = tempfile.mkdtemp(dir=work)
    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    server = LinuxServer(linux_bin, root, os.path.join(scratch, "linux.log"))
    try:
        failures = sse_story(server.port, scratch, report, "live stream on Linux")
        # Linux's keepalive is the application's 25 seconds, and cannot be set.
        if not QUICK:
            failures += tab_story(server.port, scratch, report, "a chat tab on Linux")
        return failures
    finally:
        server.stop()
        shutil.rmtree(scratch, ignore_errors=True)


STREAMS_LINE = re.compile(r"streams: at most (\d+) held at once, (\d+) ended, (\d+) still subscribed")
FINAL_HEAP = re.compile(r"base heap holds (\d+) live bytes in (\d+) allocations")


def metal_sse_failures(elf, pristine, work, mnt, report) -> int:
    """The same live-stream story, told to the machine — whose stream table
    keeps the stream its handler handed over. Then the story's client closes
    the stream, one more request lets the kernel reach its count, and the log
    must say the stream was ended because its client went away."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, 5, mnt)  # the story's four, and one to finish on
    qemu, port, serial = start_kernel(elf, image, scratch)
    try:
        failures = sse_story(port, scratch, report, "live stream on the machine")
        ask(port, step("the last request", "GET", "/nope"), scratch, patience=60)
    finally:
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        failures += 1
        report(f"FAIL  live stream on the machine: the kernel exited {code}: "
               + " | ".join(log.splitlines()[-3:]))
    if "stream ended: its client went away" not in log:
        failures += 1
        report("FAIL  live stream on the machine: the kernel never ended the stream its client closed")
    held = STREAMS_LINE.search(log)
    if held is None or held.groups() != ("1", "1", "0"):
        failures += 1
        report(f"FAIL  live stream on the machine: the kernel's stream count reads "
               f"{held.group(0) if held else 'nothing'}, want 1 held, 1 ended, 0 still subscribed")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures + metal_tab_failures(elf, pristine, work, mnt, report)


def metal_tab_failures(elf, pristine, work, mnt, report) -> int:
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    keepalive = 3 if QUICK else 25
    set_request_limit(image, 9, mnt,  # the tab's eight, and one to finish on
                      keepalive_ms=None if keepalive == 25 else keepalive * 1000)
    qemu, port, serial = start_kernel(elf, image, scratch)
    try:
        failures = tab_story(port, scratch, report, "a chat tab on the machine", keepalive)
        ask(port, step("the last request", "GET", "/nope"), scratch, patience=60)
    finally:
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        failures += 1
        report(f"FAIL  a chat tab on the machine: the kernel exited {code}")
    if log.count("stream ended: its client went away") != 3:
        failures += 1
        report(f"FAIL  a chat tab on the machine: {log.count('stream ended: its client went away')} "
               f"streams ended because their client left, want 3")
    held = STREAMS_LINE.search(log)
    if held is None or held.groups() != ("3", "3", "0"):
        failures += 1
        report(f"FAIL  a chat tab on the machine: the stream count reads "
               f"{held.group(0) if held else 'nothing'}, want 3 held, 3 ended, 0 still subscribed")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


def boot_with(elf, pristine, work, mnt, requests, **conf):
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, requests, mnt, **conf)
    qemu, port, serial = start_kernel(elf, image, scratch)
    return scratch, qemu, port, serial


def login_cookie(port, scratch, body=LOGIN_BODY) -> str:
    jar = update_jar(ask(port, step("log in", "POST", "/login/full", None, body), scratch, patience=60), {})
    return "; ".join(f"{k}={v}" for k, v in jar.items())


def send_live(port, scratch, cookie, topic, text, cid):
    return ask(port, step(f"send {text}", "POST", f"/chat/c/1_2/{topic}/send", cookie,
                          f"markdown={text}&cid={cid}", headers=["X-Chat-Async: 1"]),
               scratch, patience=60)


def budget_failures(elf, pristine, work, mnt, report) -> int:
    """**STREAMS CANNOT STARVE REQUESTS.** With a budget of two, a third stream
    ends the OLDEST — the browser would reconnect and resume — and the other two
    go on receiving; the site goes on answering. Seven requests: log in, a first
    message, streams A, B and C, a live message, one to finish on."""
    label = "the stream budget"
    scratch, qemu, port, serial = boot_with(elf, pristine, work, mnt, 7, streams=2)
    failures = 0

    def fail(msg):
        nonlocal failures
        failures += 1
        report(f"FAIL  {label}: {msg}")

    socks = []
    try:
        cookie = login_cookie(port, scratch)
        send_live(port, scratch, cookie, "budget", "budget-opener", "b0")
        got = []
        for _ in range(3):
            sock = open_stream(port, "/chat/c/1_2/budget/stream?since=0", cookie)
            socks.append(sock)
            got.append(read_until(sock, b"budget-opener", time.time() + 30))
        # A — the oldest — was ended to make room for C: its socket reads the end.
        rest = read_until(socks[0], b"never", time.time() + 5, got[0])
        a_ended = False
        try:
            socks[0].settimeout(2)
            a_ended = socks[0].recv(64) == b""
        except OSError:
            a_ended = True
        if not a_ended:
            fail("the oldest stream was not closed when a third was opened with a budget of two")
        send_live(port, scratch, cookie, "budget", "budget-live", "b1")
        for name, k in (("B", 1), ("C", 2)):
            got[k] = read_until(socks[k], b"budget-live", time.time() + 15, got[k])
            if b"budget-live" not in got[k]:
                fail(f"stream {name}, still within the budget, never got the live message")
        if b"budget-live" in rest:
            fail("the ended stream still received the live message")
    finally:
        for sock in socks:
            sock.close()
        ask(port, step("the last request", "GET", "/nope"), scratch, patience=60)
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        fail(f"the kernel exited {code}")
    if log.count("stream ended: to make room for a newer one") != 1:
        fail(f"{log.count('stream ended: to make room for a newer one')} streams were ended to make room, want 1")
    held = STREAMS_LINE.search(log)
    if held is None or held.groups() != ("2", "3", "0"):
        fail(f"the stream count reads {held.group(0) if held else 'nothing'}, "
             f"want at most 2 held, 3 ended, 0 still subscribed")
    if not failures:
        report(f"ok    {label}: with room for two, a third stream ended the oldest; the other two "
               f"got the live message, and nothing was left subscribed")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


def churn(elf, pristine, work, mnt, n: int, report):
    """n streams opened and closed one after another — half by a polite FIN,
    half by a reset. Answers (failures, the heap's live bytes at the end)."""
    label = f"{n} streams opened and closed"
    scratch, qemu, port, serial = boot_with(elf, pristine, work, mnt, n + 3)
    failures = 0
    try:
        cookie = login_cookie(port, scratch)
        send_live(port, scratch, cookie, "churn", "churn-opener", "c0")
        for k in range(n):
            sock = open_stream(port, "/chat/c/1_2/churn/stream?since=0", cookie)
            read_until(sock, b"churn-opener", time.time() + 30)
            if k % 2:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.close()
    finally:
        ask(port, step("the last request", "GET", "/nope"), scratch, patience=60)
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        failures += 1
        report(f"FAIL  {label}: the kernel exited {code}")
    went = log.count("stream ended: its client went away")
    if went != n:
        failures += 1
        report(f"FAIL  {label}: {went} ended because their client went away, want {n}")
    held = STREAMS_LINE.search(log)
    if held is None or held.group(2) != str(n) or held.group(3) != "0":
        failures += 1
        report(f"FAIL  {label}: the stream count reads {held.group(0) if held else 'nothing'}, "
               f"want {n} ended and 0 still subscribed")
    heap = FINAL_HEAP.search(log)
    shutil.rmtree(scratch, ignore_errors=True)
    return failures, (int(heap.group(1)) if heap else None)


def churn_failures(elf, pristine, work, mnt, report) -> int:
    """**NOTHING IS KEPT PER STREAM.** The same boot with 5 streams churned and
    with 25 must end holding the same number of live bytes: anything a stream
    left behind would show up 20 times over."""
    few, many = (3, 9) if QUICK else (5, 25)
    f_few, heap_few = churn(elf, pristine, work, mnt, few, report)
    f_many, heap_many = churn(elf, pristine, work, mnt, many, report)
    failures = f_few + f_many
    if heap_few is None or heap_many is None:
        failures += 1
        report("FAIL  stream churn: a boot did not report its heap")
    elif heap_few != heap_many:
        failures += 1
        report(f"FAIL  stream churn: {heap_few} live bytes after {few} streams, {heap_many} after "
               f"{many} — {(heap_many - heap_few) / (many - few):.1f} bytes kept per stream")
    if not failures:
        report(f"ok    stream churn: {few} and then {many} streams opened and closed (half by reset), every "
               f"one ended because its client went away, nothing left subscribed, and both boots "
               f"end holding {heap_few} live bytes")
    return failures


def base_heap_trace(log: str) -> list:
    """What the base heap holds after each request: LIVE bytes."""
    return [int(m.group(1)) for m in BASE_HEAP.finditer(log)]


def base_heap_taken(log: str) -> list:
    """What the machine has handed out in whole pages to hold that — always
    more, because a page is 4096 bytes and an allocator keeps slack."""
    return [int(m.group(2)) for m in BASE_HEAP.finditer(log)]


WAIT_LIMIT_US = 900_000
TIMING = re.compile(
    r"waited (\d+) us, answered in (\d+) us, (\d+) disk requests taking (\d+) us")


def request_timings(log: str) -> list:
    """**WHAT THE MACHINE SAYS EACH REQUEST COST**, in microseconds, as
    (from the connection opening to its turn — the client finishing its request,
    then the queue — answering it, disk requests made while answering, the time
    those took). Its own clock, so curl, slirp and the
    emulator's network are all on the other side of the measurement — and the
    disk's share of the answer is its own number."""
    return [(int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)))
            for m in TIMING.finditer(log)]


def base_heap_peak(log: str) -> list:
    """**THE NUMBER THAT DECIDES WHETHER THIS CAN BE DEPLOYED.** The most memory
    ever held at once. Live bytes can sit flat forever while this climbs — which
    is exactly what a bump allocator does, since its free() reclaims only the
    block it handed out last. A peak that stops rising is a machine that can
    stay up."""
    return [int(m.group(3)) for m in BASE_HEAP.finditer(log)]


def request_heap_trace(log: str) -> list:
    return [int(m.group(1)) for m in re.finditer(r"request heap: (\d+) bytes", log)]


# ── the send side ────────────────────────────────────────────────────────────
#
# Everything above fits in a few segments and in the emulator's buffers, so
# none of it can tell a TCP that respects the peer's window from one that
# ignores it, or one that retransmits from one that doesn't. These can.

BULK_MESSAGES = 8
TCP_LINE = re.compile(r"tcp: (\d+) timeouts sent something again, (\d+) window probes, "
                      r"(\d+) peers given up on, \d+ never finished, \d+ strays reset, "
                      r"(\d+) frames lost on purpose")


def bulk_name(n: int) -> bytes:
    return f"bulk-{n:02d}".encode()


def bulk_text(n: int, repeats: int = 2200) -> str:
    """About 40 KB of markdown (at the default), form-encoded, that names
    itself first. 3300 repeats is about 60 KB, near chat's 64 KB limit."""
    return bulk_name(n).decode() + "+" + "lorem+ipsum+dolor+" * repeats


def bulk_steps() -> list:
    """Large requests and large answers: eight 40 KB messages in, then the
    whole 320 KB transcript and the conversation's page out."""
    steps = [step("log in", "POST", "/login/full", None, LOGIN_BODY)]
    for n in range(1, BULK_MESSAGES + 1):
        steps.append(step(f"a 40 KB message, {n}", "POST", "/chat/c/1_2/bulk/send", JAR,
                          f"markdown={bulk_text(n)}&cid=b{n}", headers=["X-Chat-Async: 1"]))
    names = [bulk_name(n) for n in range(1, BULK_MESSAGES + 1)]
    steps.append(step("the whole transcript", "GET", "/chat/c/1_2/bulk/raw", JAR, expect=names))
    steps.append(step("the conversation's page", "GET", "/chat/c/1_2/bulk", JAR))
    return steps


BULK = bulk_steps()


def tcp_counts(log: str):
    m = TCP_LINE.search(log)
    return None if m is None else dict(zip(("retransmits", "probes", "given_up", "lost"),
                                           map(int, m.groups())))


def bulk_failures(elf, linux_bin, content, pristine, work, mnt, report) -> int:
    """The bulk story twice: once as it comes, and once with every seventh TCP
    frame in each direction thrown away. Both must answer as Linux answered."""
    failures = 0
    runs = [("bulk", None)]
    if not QUICK:
        runs.append(("bulk, losing one frame sent in seven", {"lose_one_sent_in": 7}))
    for label, conf in runs:
        started = time.time()
        f, log, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                           BULK, label, report, conf=conf)
        f += missing_marks(BULK, answers, report, label)
        counts = tcp_counts(log)
        if counts is None:
            f += 1
            report(f"FAIL  {label}: the kernel never gave its TCP counts")
        elif conf:
            if counts["lost"] == 0 or counts["retransmits"] == 0:
                f += 1
                report(f"FAIL  {label}: {counts['lost']} frames lost and {counts['retransmits']} "
                       f"retransmissions — the loss was not exercised")
        if counts and counts["given_up"]:
            f += 1
            report(f"FAIL  {label}: the kernel gave up on {counts['given_up']} peers")
        if not f:
            sizes = [len(a.get("body", b"")) for a in answers[-2:]]
            report(f"ok    {label}: {BULK_MESSAGES} messages of 40 KB in, a {sizes[0]}-byte transcript "
                   f"and a {sizes[1]}-byte page out, all answered as Linux answered, {files} files agree "
                   f"({counts['lost']} frames lost, {counts['retransmits']} timeouts resent, "
                   f"{time.time() - started:.0f} s)")
        failures += f
    return failures


def get_on_socket(sock, path: str, cookie: str) -> None:
    sock.sendall((f"GET {path} HTTP/1.1\r\nHost: judge\r\nCookie: {cookie}\r\n"
                  f"Connection: close\r\n\r\n").encode())


def small_socket(port: int):
    """A client whose receive buffer is as small as the host allows, so that
    not reading shows up at the machine as a shut window."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
    sock.settimeout(60)
    sock.connect(("127.0.0.1", port))
    return sock


def read_all(sock, pause_after: int = None, pause: float = 0.0) -> bytes:
    got = b""
    paused = pause_after is None
    while True:
        if not paused and len(got) >= pause_after:
            time.sleep(pause)
            paused = True
        chunk = sock.recv(4096)
        if not chunk:
            return got
        got += chunk


def linux_writes_bulk(linux_bin, content, work, mnt, messages: int) -> str:
    """**THE LINUX BUILD WRITES THE BIG TRANSCRIPT; THE MACHINE SERVES IT.**
    A hundred 40 KB messages posted to the machine take most of a minute;
    posted to Linux, a second. The result is a disk image holding the site with
    that conversation already in it."""
    root = tempfile.mkdtemp(dir=work)
    tree_root = os.path.join(root, "content")
    shutil.copytree(content, tree_root)
    server = LinuxServer(linux_bin, tree_root, os.path.join(root, "linux.log"))
    try:
        cookie = login_cookie(server.port, root)
        for n in range(1, messages + 1):
            a = send_live(server.port, root, cookie, "bulk", bulk_text(n), f"b{n}")
            if a.get("status") != 204:
                raise RuntimeError(f"Linux would not take bulk message {n}: {a}")
    finally:
        server.stop()
    os.remove(os.path.join(tree_root, "gopher.conf"))
    image = os.path.join(root, "bulk.img")
    build_disk(image, tree_root, mnt)
    return image


def slow_reader_failures(elf, linux_bin, content, work, mnt, report) -> int:
    """**A CLIENT THAT READS SLOWLY GETS EVERY BYTE; ONE THAT STOPS IS LET GO.**
    The transcript is fetched three ways from one boot: at full speed; by a
    client that stops twice along the way; and by one that
    never reads at all. The second must get exactly what the first got, with
    the machine probing a shut window while it waited. The third must be let
    go after the idle timeout, and the site must go on answering."""
    label = "slow readers"
    # A pause must outlast the first retransmission timeout (a second) for the
    # window to be probed. The idle time must outlast the SECOND probe, which
    # comes three seconds after the window shut: at three seconds, a reader
    # that had only paused was let go.
    idle_ms, pause = 5000, 2.0
    # **BIG ENOUGH TO GET PAST THE HOST'S BUFFERS.** A loopback socket with a
    # 2 KB receive buffer still lets its sender queue over a megabyte, and
    # slirp holds more; a smaller answer never shuts the machine's window, and
    # the gate below says so rather than passing.
    messages = 100
    requests = 1 + 3 + 1
    bulk_image = linux_writes_bulk(linux_bin, content, work, mnt, messages)
    scratch, qemu, port, serial = boot_with(elf, bulk_image, work, mnt, requests,
                                            idle_timeout_ms=idle_ms)
    failures = 0

    def fail(msg):
        nonlocal failures
        failures += 1
        report(f"FAIL  {label}: {msg}")

    path = "/chat/c/1_2/bulk/raw"
    stalled = None
    after = {}
    try:
        cookie = login_cookie(port, scratch)
        fast = socket.create_connection(("127.0.0.1", port), timeout=60)
        get_on_socket(fast, path, cookie)
        quick = parse_raw_response(read_all(fast))
        fast.close()

        slow = small_socket(port)
        get_on_socket(slow, path, cookie)
        time.sleep(pause)
        patient = parse_raw_response(read_all(slow, pause_after=2_000_000, pause=pause))
        slow.close()

        if quick.get("status") != 200 or len(quick.get("body", b"")) < messages * 30_000:
            fail(f"the transcript at full speed was {quick.get('status')} with "
                 f"{len(quick.get('body', b''))} bytes")
        elif patient.get("body") != quick["body"]:
            fail(f"the slow reader got {len(patient.get('body', b''))} bytes "
                 f"({patient.get('error', 'status ' + str(patient.get('status')))}), "
                 f"the fast one {len(quick['body'])}, and they differ")

        stalled = small_socket(port)
        get_on_socket(stalled, path, cookie)
        started = time.time()
        after = ask(port, step("the request after", "GET", "/nope"), scratch, patience=60)
        waited = time.time() - started
    finally:
        if stalled is not None:
            stalled.close()
        code, log = finish_kernel(qemu, serial)
    if after.get("status") != 404:
        fail(f"the request after the stalled reader answered {after.get('status') or after.get('error')}")
    elif waited < idle_ms / 1000:
        fail(f"the request after the stalled reader was answered in {waited:.1f} s, before the "
             f"{idle_ms} ms idle timeout — the stalled reader was never stalled")
    if code != 1:
        fail(f"the kernel exited {code}")
    if "the client stopped taking the response" not in log:
        fail("the kernel never said it let the stalled reader go")
    counts = tcp_counts(log)
    if counts is None or counts["probes"] == 0:
        fail(f"the machine sent no window probes ({counts}) — the slow reader's window never shut, "
             f"so this proved nothing")
    if not failures:
        report(f"ok    {label}: a reader that paused twice got all {len(quick['body'])} bytes, "
               f"with {counts['probes']} window probes sent while it paused; one that never read "
               f"was let go and the next request answered {waited:.1f} s later")
    shutil.rmtree(scratch, ignore_errors=True)
    return failures


def lagging_stream_failures(elf, pristine, work, mnt, report) -> int:
    """**A TAB THAT STOPS READING LOSES ITS STREAM, NOT THE SITE.** Two streams
    on one conversation; one is read all along, the other is read once and then
    ignored while 60 KB messages are published back to back — each frame about
    120 KB, bigger than a whole send queue. The ignored one must be ended as
    not keeping up once it has taken nothing for the idle time, and the read
    one must get every message: a host that moved streams only between
    requests fell behind by part of a frame per message, and its mailbox
    dropped events once it held sixteen."""
    label = "a lagging stream"
    sent_all = 60  # far past what the host buffers, and past sixteen behind
    requests = 1 + 1 + 2 + sent_all + 1
    idle_ms = 3000
    scratch, qemu, port, serial = boot_with(elf, pristine, work, mnt, requests,
                                            idle_timeout_ms=idle_ms)
    failures = 0

    def fail(msg):
        nonlocal failures
        failures += 1
        report(f"FAIL  {label}: {msg}")

    stream_path = "/chat/c/1_2/lag/stream?since=0"
    got = {"reader": b""}
    stop = threading.Event()
    sent = 0
    socks = []
    try:
        cookie = login_cookie(port, scratch)
        send_live(port, scratch, cookie, "lag", "lag-opener", "l0")
        reader = open_stream(port, stream_path, cookie)
        socks.append(reader)
        got["reader"] = read_until(reader, b"lag-opener", time.time() + 30)
        lagger = small_socket(port)
        socks.append(lagger)
        lagger.sendall((f"GET {stream_path} HTTP/1.1\r\nHost: judge\r\nCookie: {cookie}\r\n"
                        f"Accept: text/event-stream\r\n\r\n").encode())
        read_until(lagger, b"lag-opener", time.time() + 30)

        def keep_reading():
            reader.settimeout(0.2)
            while not stop.is_set():
                try:
                    chunk = reader.recv(65536)
                except OSError:
                    continue
                if not chunk:
                    return
                got["reader"] += chunk

        t = threading.Thread(target=keep_reading, daemon=True)
        t.start()
        for n in range(1, sent_all + 1):
            answer = send_live(port, scratch, cookie, "lag", bulk_text(n, 3300), f"l{n}")
            sent = n
            if answer.get("status") != 204:
                fail(f"sending message {n} answered {answer.get('status') or answer.get('error')}")
        deadline = time.time() + 30
        while bulk_name(sent) not in got["reader"] and time.time() < deadline:
            time.sleep(0.1)
        stop.set()
        t.join()
    finally:
        for sock in socks:
            sock.close()
        for _ in range(requests - 2 - 2 - sent):
            ask(port, step("to the end", "GET", "/nope"), scratch, patience=60)
        code, log = finish_kernel(qemu, serial)
    if code != 1:
        fail(f"the kernel exited {code}")
    if log.count("stream ended: its client is not keeping up") != 1:
        fail(f"{log.count('stream ended: its client is not keeping up')} streams ended as not keeping "
             f"up after {sent} messages, want 1")
    missing = [n for n in range(1, sent + 1) if bulk_name(n) not in got["reader"]]
    if missing:
        # The evidence stays: what the reader got, beside the kernel's log.
        with open(os.path.join(scratch, "reader.bytes"), "wb") as f:
            f.write(got["reader"])
        fail(f"the stream that kept reading is missing messages {missing}; "
             f"its bytes and the kernel's log are in {scratch}")
    held = STREAMS_LINE.search(log)
    if held is None or held.groups() != ("2", "2", "0"):
        fail(f"the stream count reads {held.group(0) if held else 'nothing'}, "
             f"want 2 held, 2 ended, 0 still subscribed")
    if not failures:
        report(f"ok    {label}: of two streams sent {sent} 60 KB messages back to back, the one nobody "
               f"read was ended as not keeping up, and the one being read got all {sent}")
        shutil.rmtree(scratch, ignore_errors=True)
    return failures


class Laps:
    """How long each part of the run took, said as each ends: the judge is
    worth running only as often as it is quick."""

    def __init__(self):
        self.start = self.at = time.time()

    def __call__(self, name: str) -> None:
        now = time.time()
        print(f"      ({name}: {now - self.at:.0f} s)", flush=True)
        self.at = now

    def total(self) -> float:
        return time.time() - self.start


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip())
        return 2
    elf, linux_bin, gopher_root, work = sys.argv[1:]
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        print("SKIPPED: populating and reading the disk needs `sudo -n` for a loop mount")
        return 77
    for tool in ("sgdisk", "mkfs.vfat", "fsck.vfat", "qemu-system-x86_64"):
        if shutil.which(tool) is None:
            print(f"SKIPPED: {tool} is not installed")
            return 77

    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    content = os.path.join(work, "content")
    stage(content, gopher_root)
    pristine = os.path.join(work, "pristine.img")
    mnt = os.path.join(work, "mnt")
    build_disk(pristine, content, mnt)
    # The kernel serves until stopped unless its volume says otherwise. One
    # request per boot for the cases; run_story rewrites this for longer boots.
    set_request_limit(pristine, 1, mnt)
    lap = Laps()
    lap("staging")

    failures = 0
    # **ONE BOOT FOR ALL OF THEM, IN THE QUICK TIER.** A boot per request is
    # what proves each answer owes nothing to an earlier one; the quick tier
    # asks them all of one machine instead, still against Linux.
    cases = [] if QUICK else CASES
    if QUICK:
        steps = [step(c["name"], c["method"], c["path"], c["cookie"], c["body"]) for c in CASES]
        f, _, answers, _ = run_story(elf, linux_bin, content, pristine, work, mnt,
                                     steps, "single requests, one boot", print)
        failures += f
        if not f:
            print(f"ok    {len(CASES)} single requests to one boot, each answered as Linux answered")
    for c in cases:
        scratch = tempfile.mkdtemp(dir=work)
        image = os.path.join(scratch, "disk.img")
        shutil.copy(pristine, image)
        metal = ask_kernel(elf, image, c, scratch)
        linux = ask_linux(linux_bin, content, c, scratch)
        diffs = differences(c, metal, linux)
        if "error" not in metal and "error" not in linux:
            diffs += file_differences(c, image, metal, linux, mnt)
        label = f"{c['name']}  ({c['method']} {c['path']})"
        if diffs:
            failures += 1
            print(f"FAIL  {label}")
            for d in diffs:
                print(f"        {d}")
        else:
            extra = f", {len(c['files'])} file(s) agree" if c["files"] else ""
            print(f"ok    {label} -> {metal['status']}, {len(metal['body'])} bytes{extra}")
        shutil.rmtree(scratch, ignore_errors=True)

    per_case = failures
    lap("single requests")

    # ── the member story ─────────────────────────────────────────────────────
    now = int(time.time())
    minted = {
        FRESH: mint_session("1", now),
        STALE: mint_session("1", now - 400 * 86400),
        FORGED: forge_session("1", "2", now),
    }
    f, log, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                       MEMBER_STORY, "members", print, minted)
    failures += f
    # Each minted cookie must be answered as its name says, not merely the same
    # on both sides: two servers that both honored a stale session would agree.
    by_name = {s["name"]: a for s, a in zip(MEMBER_STORY, answers)}
    for name, want in (("a session minted outside both servers", 200),
                       ("a session 400 days old", 303), ("a forged session", 303)):
        got = by_name[name].get("status")
        if got != want:
            failures += 1
            print(f"FAIL  members: {name} answered {got}, want {want}")
    # A session the KERNEL minted must be honored by Linux: same secret, same
    # HMAC, and the kernel's clock close enough to Linux's.
    login = by_name["the right one (a $2a$ hash)"]
    metal_session = update_jar(login, {}).get("gopher_auth")
    if not metal_session:
        failures += 1
        print("FAIL  members: the kernel's login set no session cookie")
    else:
        scratch = tempfile.mkdtemp(dir=work)
        linux = ask_linux(linux_bin, content,
                          step("a kernel-minted session, on Linux", "GET", "/chat/conversations",
                               f"gopher_auth={metal_session}"), scratch)
        if linux.get("status") != 200:
            failures += 1
            print(f"FAIL  members: Linux refused the session the kernel minted ({linux.get('status')})")
        shutil.rmtree(scratch, ignore_errors=True)
    if not f and metal_session:
        print(f"ok    the member story: {len(MEMBER_STORY)} requests to ONE boot — login, chat, topics, "
              f"reactions, admin, logout — each answered as Linux answered, all {files} files agree; "
              f"a fresh minted session honored, a stale and a forged one refused, "
              f"and the kernel's own session honored by Linux")

    lap("member story")

    # ── a live stream, on both ───────────────────────────────────────────────
    failures += linux_sse_failures(linux_bin, content, work, print)
    lap("streams on Linux")
    failures += metal_sse_failures(elf, pristine, work, mnt, print)
    lap("streams on the machine")
    failures += budget_failures(elf, pristine, work, mnt, print)
    lap("stream budget")
    failures += churn_failures(elf, pristine, work, mnt, print)
    lap("stream churn")

    # ── the send side ────────────────────────────────────────────────────────
    failures += bulk_failures(elf, linux_bin, content, pristine, work, mnt, print)
    lap("bulk")
    failures += upload_failures(elf, linux_bin, content, pristine, work, mnt, print)
    lap("uploads")
    failures += slow_reader_failures(elf, linux_bin, content, work, mnt, print)
    lap("slow readers")
    failures += lagging_stream_failures(elf, pristine, work, mnt, print)
    lap("a lagging stream")

    # ── many clients at once ─────────────────────────────────────────────────
    failures += concurrent_failures(elf, linux_bin, content, pristine, work, mnt, print)
    lap("many clients")

    # ── the client that says nothing ─────────────────────────────────────────
    failures += timeout_failures(elf, pristine, work, mnt, print)
    lap("silent clients")
    if QUICK:
        print(f"{len(CASES) - per_case} of {len(CASES)} single requests, and "
              f"{'every' if failures == per_case else 'not every'} quick boot, answered as Linux "
              f"answered ({lap.total():.0f} s; the long boots are left to the full run)")
        return 1 if failures else 0

    # ── endurance: the writes, read back every round ─────────────────────────
    f, log, answers, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                       ENDURANCE, "endurance", print)
    marks = missing_marks(ENDURANCE, answers, print, "endurance")
    failures += f + marks
    # **THE WRITES ARE WHERE THE HEAP IS ACTUALLY CHURNED.** Reads allocate and
    # free in order, and a bump allocator gives back a free that was the last
    # thing it handed out — so a read-only run can look perfectly frugal while
    # the machine has no way to reclaim anything. These numbers are the honest
    # ones, and they are reported whether or not anything failed.
    live, taken, peak = base_heap_trace(log), base_heap_taken(log), base_heap_peak(log)
    if live and peak:
        at = min(6, len(peak) - 1)
        grew = peak[-1] - peak[at]
        print(f"      endurance: {live[-1]} live bytes in {taken[-1]} bytes of pages; peak "
              f"{peak[at]} after {at + 1} requests, {peak[-1]} after {len(peak)} "
              f"({grew} bytes of growth over the writes)")
        # A peak that climbs with every request is a machine with a clock on it.
        # Early rise is caches filling; a bump allocator would never stop.
        if grew > 256 * 1024:
            failures += 1
            print(f"FAIL  endurance: the peak grew {grew} bytes over {len(peak)} requests — "
                  f"this machine is not reusing what it frees")
    if not f and not marks:
        reads = sum(1 for s in ENDURANCE if s["expect"])
        print(f"ok    endurance: {ENDURANCE_ROUNDS} rounds of write-then-read-it-all-back to ONE boot "
              f"({len(ENDURANCE)} requests) — every one of the {reads} read-backs held every mark "
              f"written before it, each answered as Linux answered, and all {files} files agree")

    lap("endurance")

    # ── stamina ──────────────────────────────────────────────────────────────
    rounds = STAMINA * STAMINA_ROUNDS
    f, log, answers, _ = run_story(elf, linux_bin, content, pristine, work, mnt,
                                   rounds, "stamina", print)
    failures += f
    first = {}
    drift = 0
    for s, a in zip(rounds, answers):
        key = s["path"]
        body = a.get("body")
        if key not in first:
            first[key] = body
        elif body != first[key]:
            drift += 1
    if drift:
        failures += 1
        print(f"FAIL  stamina: {drift} answers differed from the first answer to the same request")
    trace = base_heap_trace(log)
    settled = trace[len(STAMINA) * 2:]  # after two rounds, anything cached is cached
    if len(trace) != len(rounds):
        failures += 1
        print(f"FAIL  stamina: the kernel logged {len(trace)} requests, not {len(rounds)}")
    elif settled and max(settled) != min(settled):
        failures += 1
        print(f"FAIL  stamina: the base heap grew from {min(settled)} to {max(settled)} live bytes "
              f"over {len(rounds)} requests")
    # The request heap: each request must use what the same request used in the
    # first round. One that was never reset would only ever grow.
    used = request_heap_trace(log)
    per = len(STAMINA)
    wandered = [i for i in range(per, len(used)) if used[i] != used[i % per]]
    if len(used) != len(rounds):
        failures += 1
        print(f"FAIL  stamina: the kernel logged {len(used)} request-heap figures, not {len(rounds)}")
    elif wandered:
        i = wandered[0]
        failures += 1
        print(f"FAIL  stamina: request {i + 1} ({rounds[i]['path']}) used {used[i]} bytes of its heap; "
              f"the same request used {used[i % per]} the first time")
    if not f and not drift and len(trace) == len(rounds) and not wandered and len(used) == len(rounds) \
            and (not settled or max(settled) == min(settled)):
        print(f"ok    stamina: {len(rounds)} requests to one boot, every answer the same, "
              f"base heap steady at {trace[-1]} live bytes, each request's heap the same every round "
              f"({', '.join(str(u) for u in used[:per])} bytes)")
        peaks = base_heap_peak(log)
        if peaks:
            at = peaks[min(6, len(peaks) - 1)]
            print(f"      stamina: peak memory {at} bytes after seven requests, "
                  f"{peaks[-1]} after {len(peaks)} — "
                  + ("unchanged: every request's memory is reclaimed and reused"
                     if peaks[-1] == at else f"{peaks[-1] - at} bytes of growth"))

    lap("stamina")
    print(f"{len(CASES) - per_case} of {len(CASES)} single requests, and "
          f"{'all three' if failures == per_case else 'not all three'} long-running boots, "
          f"answered as Linux answered ({lap.total():.0f} s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
