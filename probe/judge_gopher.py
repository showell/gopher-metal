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
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
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
    case("game admin, anonymous", "GET", "/admin/lynrummy"),
    case("admin, a bare uid is not a member", "GET", "/admin", P1),
    case("name page", "GET", "/play"),
    case("name page remembers next", "GET", "/play?next=/puzzles"),
    case("puzzles, nameless", "GET", "/puzzles"),
    case("game, nameless", "GET", "/game"),
    case("game as player 1 (the player store)", "GET", "/game", P1),
    case("game as a player with no row", "GET", "/game", "gopher_uid=99"),
    case("game, a traversal in the cookie", "GET", "/game", "gopher_uid=.."),
    case("version", "GET", "/version"),

    # ── a staged session, read back (times rendered in Eastern) ────────────
    case("session list (HTML, Eastern time)", "GET", "/game/sessions", P1),
    case("session list (JSON)", "GET", "/game/api/sessions", P1),
    case("session detail", "GET", "/game/sessions/1", P1),
    case("session bootstrap", "GET", "/game/sessions/1/actions", P1),
    case("a session that does not exist", "GET", "/game/sessions/9", P1),
    case("resume a session", "GET", "/game/1", P1),
    case("resume nonsense", "GET", "/game/abc", P1),

    # ── writes ─────────────────────────────────────────────────────────────
    case("a name that fails validation", "POST", "/play", None, "name=a%3Cb&next=%2Fgame",
         files=["data/players/next-id.txt"]),
    case("a new player", "POST", "/play", None, "name=Zed&next=%2Fgame",
         files=["data/players/p1/name", "data/players/next-id.txt"]),
    case("a new game session (stamps the time)", "POST", "/game/new-session", P1, "board: staged-by-the-judge",
         files=[f"{GAME1}/lynrummy-elm/sessions/2/meta", f"{GAME1}/next-session-id.txt"]),
    case("a move (an append, and last-seen)", "POST", "/game/sessions/1/actions", P1, "3) pass",
         files=[f"{GAME1}/lynrummy-elm/sessions/1/actions.dsl", "data/players/1/last-seen"]),
    case("an annotation (a new file by append)", "POST", "/game/sessions/1/annotations", P1, '{"note":"judged"}',
         files=[f"{GAME1}/lynrummy-elm/sessions/1/annotations.jsonl"]),
    case("a move into a missing session", "POST", "/game/sessions/9/actions", P1, "1) nope",
         files=[f"{GAME1}/lynrummy-elm/sessions/9/actions.dsl"]),
    case("the puzzle page (allocates a session, stamps the time)", "GET", "/puzzles", P1,
         files=[f"{GAME1}/puzzle/sessions/2/meta", f"{GAME1}/next-puzzle-id.txt"]),
    case("a puzzle move (creates its directory)", "POST", "/puzzles/sessions/1/puzzles/3/actions", P1, "1) solved",
         files=[f"{GAME1}/puzzle/sessions/1/puzzle_3/actions.dsl"]),
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


SEQUENCE = [
    step("a stranger at the door", "GET", "/"),
    step("sent to the name page", "GET", "/game"),
    step("names themselves", "POST", "/play", None, "name=Ann&next=%2Fgame"),
    step("plays, as Ann", "GET", "/game", JAR),
    step("starts a game", "POST", "/game/new-session", JAR, "board: ann's first"),
    step("moves", "POST", "/game/sessions/1/actions", JAR, "1) draw"),
    step("moves again", "POST", "/game/sessions/1/actions", JAR, "2) meld"),
    step("annotates", "POST", "/game/sessions/1/annotations", JAR, '{"note":"good hand"}'),
    step("lists her games", "GET", "/game/api/sessions", JAR),
    step("resumes", "GET", "/game/sessions/1/actions", JAR),
    step("starts a second game", "POST", "/game/new-session", JAR, "board: ann's second"),
    step("sees both, newest first", "GET", "/game/sessions", JAR),
    step("garbage on the wire", "RAW", "-", raw=b"this is not http\r\n\r\n"),
    step("still serving after garbage", "GET", "/nope"),
    step("a connection that says nothing", "RAW", "-", raw=b""),
    step("still serving after silence", "GET", "/play"),
    step("a second stranger names themselves", "POST", "/play", None, "name=Bob&next=%2Fpuzzles"),
    step("Bob opens the puzzles", "GET", "/puzzles", JAR),
    step("Bob solves one", "POST", "/puzzles/sessions/1/puzzles/0/actions", JAR, "1) solved"),
    step("Bob is not an admin", "GET", "/admin/lynrummy", JAR),
    step("the index knows Bob", "GET", "/", JAR),
    step("player 1's staged game is untouched", "GET", "/game/api/sessions", P1),
]

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
            step(f"a move, round {n}", "POST", "/game/sessions/1/actions", P1,
                 f"{n + 2}) draw {mark(n).decode()}"),
            step(f"every move, round {n}", "GET", "/game/sessions/1/actions", P1,
                 expect=marks),
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
    step("player 1's game list", "GET", "/game/sessions", P1),
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
    """One request by curl, which does the waiting while a guest boots. It never
    follows a redirect: the redirect IS the answer being compared."""
    if c.get("raw") is not None:
        return ask_raw(port, c["raw"])
    os.makedirs(scratch, exist_ok=True)
    hdr, out = os.path.join(scratch, "hdr"), os.path.join(scratch, "body")
    # **THE RETRIES ARE FOR A GUEST COMING UP**, where slirp drops the first SYN
    # and the next attempt is six seconds later. A caller that is waiting on a
    # BUSY kernel needs the opposite: a bound, so that a machine which never
    # lets go becomes a failure in a minute rather than in twenty. `patience`
    # is that bound, in seconds, and the retries are scaled to fit inside it.
    tries = max(1, patience // 30)
    cmd = ["curl", "-sS", "--max-time", str(min(30, patience)),
           "--retry", str(tries), "--retry-delay", "1",
           "--retry-connrefused", "--retry-all-errors", "-D", hdr, "-o", out,
           "-w", "%{http_code}", "-X", c["method"]]
    if c["cookie"]:
        cmd += ["-b", c["cookie"]]
    if c["body"] is not None:
        cmd += ["--data-raw", c["body"]]
    for h in c.get("headers", ()):
        cmd += ["-H", h]
    cmd.append(f"http://127.0.0.1:{port}{c['path']}")
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        return {"error": f"curl exited {p.returncode}: {p.stderr.strip()}"}
    headers = {}
    with open(hdr, "rb") as f:
        for line in f.read().decode("latin-1").splitlines()[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                k, v = k.strip().lower(), v.strip()
                # Several Set-Cookie headers are several cookies; keep them all,
                # in order, rather than the last.
                headers[k] = headers[k] + "\n" + v if k == "set-cookie" and k in headers else v
    with open(out, "rb") as f:
        payload = f.read()
    return {"status": int(p.stdout), "headers": headers, "body": payload}


def set_request_limit(image: str, n: int, mnt: str, read_timeout_ms: int = 10000) -> None:
    mount(image, mnt, writable=True)
    try:
        with open(os.path.join(mnt, "gopher-metal.conf"), "w") as f:
            f.write(f"requests = {n}\nread_timeout_ms = {read_timeout_ms}\n")
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


def start_kernel(elf: str, image: str, scratch: str):
    """Boots the kernel and returns (qemu, port, serial path) once it has said it
    is listening."""
    port = free_port()
    serial = os.path.join(scratch, "serial")
    log = open(serial, "wb")
    qemu = subprocess.Popen([
        "qemu-system-x86_64", "-M", "microvm", "-kernel", elf,
        "-nographic", "-no-reboot", "-m", "512",
        "-global", "virtio-mmio.force-legacy=false",
        "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
        "-drive", f"id=d,file={image},format=raw,if=none",
        "-device", "virtio-blk-device,drive=d",
        "-cpu", "max", "-device", "virtio-rng-device",
        "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{port}-:80",
        "-device", "virtio-net-device,netdev=n0",
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


def run_story(elf, linux_bin, content, pristine, work, mnt, steps, label, report, minted=None):
    """Tells `steps` to one kernel and one Linux server. Returns (failures,
    kernel serial log, per-step kernel answers)."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, len(steps), mnt)

    before = time.time()
    qemu, port, serial = start_kernel(elf, image, scratch)
    metal_answers, jar = [], {}
    for i, s in enumerate(steps):
        if s.get("settle"):
            time.sleep(s["settle"])
        if qemu.poll() is not None:
            # The kernel is gone. Every later step is a failure, and asking
            # would only wait out curl's retries.
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
    behind it. Returns (how long the caller waited, its answer, the serial log)."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, 2, mnt, read_timeout_ms=ms)
    qemu, port, serial = start_kernel(elf, image, scratch)
    held = silent_client(port, b"GET / HTTP/1.1\r\n")  # half a request, then silence
    began = time.time()
    # 60 seconds: this kernel said it was listening before the silent client
    # connected, so the only thing the caller is waiting for is the silent one
    # to be let go. Three times the longest timeout under test is 18s.
    answer = ask(port, step("the caller behind the silent one", "GET", "/"),
                 os.path.join(scratch, "after"), patience=60)
    waited = time.time() - began
    held.close()
    _, log = finish_kernel(qemu, serial)
    shutil.rmtree(scratch, ignore_errors=True)
    return waited, answer, log


def timeout_failures(elf, pristine, work, mnt, report) -> int:
    """**THE ONE-AT-A-TIME SERVER'S WORST CLIENT.** It connects, sends half a
    request line, and waits. Until this machine had a clock, the wait was bounded
    by a spin count — some unknown number of seconds — and ended in a silent
    end-of-stream as though the client had hung up politely.

    Two boots with two different `read_timeout_ms`, because "it recovered" is
    not the claim. The claim is that the configured number is what governs, and
    the only way to show that is to change it and watch the answer move."""
    failures = 0
    times = {}
    for ms in (2000, 6000):
        waited, answer, log = held_open(elf, pristine, work, mnt, ms)
        times[ms] = waited
        if answer.get("status") != 200:
            failures += 1
            report(f"FAIL  timeout: with read_timeout_ms={ms} the caller behind a silent client "
                   f"got {answer.get('status', answer.get('error'))}, not 200")
        if "the client stopped sending" not in log:
            failures += 1
            report(f"FAIL  timeout: with read_timeout_ms={ms} the kernel never said it let the "
                   f"silent client go: {' | '.join(log.splitlines()[-3:])}")
    # Three times the configured wait is what both cost, end to end — the
    # caller's own connect is retried while the kernel is busy. What matters is
    # that four more seconds of patience cost at least four more seconds.
    moved = times[6000] - times[2000]
    if moved < 4.0:
        failures += 1
        report(f"FAIL  timeout: tripling the timeout moved the wait by only {moved:.1f}s "
               f"({times[2000]:.1f}s then {times[6000]:.1f}s) — the setting does not govern")
    if not failures:
        report(f"ok    a silent client is let go after the time the volume says: the caller "
               f"behind it waited {times[2000]:.1f}s at 2000 ms and {times[6000]:.1f}s at 6000 ms, "
               f"and the machine served it either way")
    return failures


def base_heap_trace(log: str) -> list:
    """What the base heap holds after each request: LIVE bytes."""
    return [int(m.group(1)) for m in BASE_HEAP.finditer(log)]


def base_heap_taken(log: str) -> list:
    """What the machine has handed out in whole pages to hold that — always
    more, because a page is 4096 bytes and an allocator keeps slack."""
    return [int(m.group(2)) for m in BASE_HEAP.finditer(log)]


def base_heap_peak(log: str) -> list:
    """**THE NUMBER THAT DECIDES WHETHER THIS CAN BE DEPLOYED.** The most memory
    ever held at once. Live bytes can sit flat forever while this climbs — which
    is exactly what a bump allocator does, since its free() reclaims only the
    block it handed out last. A peak that stops rising is a machine that can
    stay up."""
    return [int(m.group(3)) for m in BASE_HEAP.finditer(log)]


def request_heap_trace(log: str) -> list:
    return [int(m.group(1)) for m in re.finditer(r"request heap: (\d+) bytes", log)]


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip())
        return 2
    elf, linux_bin, gopher_root, work = sys.argv[1:]
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        print("SKIPPED: populating and reading the disk needs `sudo -n` for a loop mount")
        return 77
    for tool in ("sgdisk", "mkfs.vfat", "fsck.vfat", "qemu-system-x86_64", "curl"):
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

    failures = 0
    for c in CASES:
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

    # ── the story ────────────────────────────────────────────────────────────
    f, log, _, files = run_story(elf, linux_bin, content, pristine, work, mnt,
                                 SEQUENCE, "story", print)
    failures += f
    if not f:
        print(f"ok    the story: {len(SEQUENCE)} requests to ONE boot, each answered as Linux answered, "
              f"and all {files} data files agree")

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

    # ── the client that says nothing ─────────────────────────────────────────
    failures += timeout_failures(elf, pristine, work, mnt, print)

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

    print(f"{len(CASES) - per_case} of {len(CASES)} single requests, and "
          f"{'all three' if failures == per_case else 'not all three'} long-running boots, "
          f"answered as Linux answered")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
