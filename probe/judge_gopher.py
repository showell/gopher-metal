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


def step(name, method, path, cookie=None, body=None, raw=None):
    return {"name": name, "method": method, "path": path, "cookie": cookie, "body": body,
            "raw": raw, "files": []}


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


def with_jar(c: dict, jar):
    """The step with "$JAR" replaced by this side's current cookie."""
    if c.get("cookie") != JAR:
        return c
    return dict(c, cookie=jar)


def ask(port: int, c: dict, scratch: str) -> dict:
    """One request by curl, which does the waiting while a guest boots. It never
    follows a redirect: the redirect IS the answer being compared."""
    if c.get("raw") is not None:
        return ask_raw(port, c["raw"])
    os.makedirs(scratch, exist_ok=True)
    hdr, out = os.path.join(scratch, "hdr"), os.path.join(scratch, "body")
    cmd = ["curl", "-sS", "--max-time", "30", "--retry", "40", "--retry-delay", "1",
           "--retry-connrefused", "--retry-all-errors", "-D", hdr, "-o", out,
           "-w", "%{http_code}", "-X", c["method"]]
    if c["cookie"]:
        cmd += ["-b", c["cookie"]]
    if c["body"] is not None:
        cmd += ["--data-raw", c["body"]]
    cmd.append(f"http://127.0.0.1:{port}{c['path']}")
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        return {"error": f"curl exited {p.returncode}: {p.stderr.strip()}"}
    headers = {}
    with open(hdr, "rb") as f:
        for line in f.read().decode("latin-1").splitlines()[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
    with open(out, "rb") as f:
        payload = f.read()
    return {"status": int(p.stdout), "headers": headers, "body": payload}


def set_request_limit(image: str, n: int, mnt: str) -> None:
    mount(image, mnt, writable=True)
    try:
        with open(os.path.join(mnt, "gopher-metal.conf"), "w") as f:
            f.write(f"requests = {n}\n")
    finally:
        umount(mnt)


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
            f.write(f"data_dir = {root}/data\nauth_dir = {root}/auth\n")
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
    m = re.match(r"(gopher_uid=[A-Za-z0-9]+)", sc)
    return m.group(1) if m else jar


def tree(root: str) -> dict:
    out = {}
    for dirpath, _, files in os.walk(os.path.join(root, "data")):
        for f in files:
            full = os.path.join(dirpath, f)
            with open(full, "rb") as fh:
                out[os.path.relpath(full, root)] = fh.read()
    return out


def run_story(elf, linux_bin, content, pristine, work, mnt, steps, label, report):
    """Tells `steps` to one kernel and one Linux server. Returns (failures,
    kernel serial log, per-step kernel answers)."""
    scratch = tempfile.mkdtemp(dir=work)
    image = os.path.join(scratch, "disk.img")
    shutil.copy(pristine, image)
    set_request_limit(image, len(steps), mnt)

    before = time.time()
    qemu, port, serial = start_kernel(elf, image, scratch)
    metal_answers, jar = [], None
    for i, s in enumerate(steps):
        a = ask(port, with_jar(s, jar), os.path.join(scratch, f"k{i}"))
        jar = cookie_from(a, jar)
        metal_answers.append(a)
    code, log = finish_kernel(qemu, serial)
    metal_window = (int(before) - 1, int(time.time()) + 1)

    root = os.path.join(scratch, "linux")
    shutil.copytree(content, root)
    before = time.time()
    server = LinuxServer(linux_bin, root, os.path.join(scratch, "linux.log"))
    linux_answers, jar = [], None
    try:
        for i, s in enumerate(steps):
            a = ask(server.port, with_jar(s, jar), os.path.join(scratch, f"l{i}"))
            jar = cookie_from(a, jar)
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


def base_heap_trace(log: str) -> list:
    return [int(m.group(1)) for m in re.finditer(r"request \d+: .*\(base: (\d+) live bytes\)", log)]


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

    print(f"{len(CASES) - per_case} of {len(CASES)} single requests, and "
          f"{'both' if failures == per_case else 'not both'} long-running boots, "
          f"answered as Linux answered")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
