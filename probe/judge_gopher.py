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
body byte for byte (the one exception, /version, is compared field by field,
because it reports the build's name and live memory by design).

A write is judged a second way too: after the kernel handles it, the disk image
is mounted read-only through the Linux VFAT driver and the files it wrote are
compared with the ones the Linux server wrote.

Populating and reading the disk needs a loop mount, so this needs `sudo -n`.
Without it the whole check is SKIPPED — exit 77 — and says so; it never passes
by default.

Exit 0 when every case agrees, 1 when any does not, 77 when it could not run.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

SECTOR = 512
PART_FIRST = 2048


# ── the cases ────────────────────────────────────────────────────────────────
#
# (name, method, path, cookie, form body). None of these stamps the wall clock:
# the kernel does not know it yet, and refuses rather than guessing.

READS = [
    ("index", "GET", "/", None, None),
    ("index as a player", "GET", "/", "gopher_uid=1", None),
    ("driving (embedded)", "GET", "/driving", None, None),
    ("tutorial (embedded)", "GET", "/tutorial", None, None),
    ("chess index", "GET", "/chess", None, None),
    ("resume (markdown from the volume)", "GET", "/steve-resume", None, None),
    ("resume pdf (27 KB from the volume)", "GET", "/steve-resume.pdf", None, None),
    ("safari download page", "GET", "/safari_download", None, None),
    ("unknown path", "GET", "/nope", None, None),
    ("prefix boundary", "GET", "/drivingX", None, None),
    ("old login door", "GET", "/login", None, None),
    ("password gate", "GET", "/login/full", None, None),
    ("admin, anonymous", "GET", "/admin", None, None),
    ("game admin, anonymous", "GET", "/admin/lynrummy", None, None),
    ("admin, a bare uid is not a member", "GET", "/admin", "gopher_uid=1", None),
    ("name page", "GET", "/play", None, None),
    ("name page remembers next", "GET", "/play?next=/puzzles", None, None),
    ("puzzles, nameless", "GET", "/puzzles", None, None),
    ("game, nameless", "GET", "/game", None, None),
    ("game as player 1 (the player store)", "GET", "/game", "gopher_uid=1", None),
    ("game as a player with no row", "GET", "/game", "gopher_uid=99", None),
    ("game, a traversal in the cookie", "GET", "/game", "gopher_uid=..", None),
    ("version", "GET", "/version", None, None),
]

WRITES = [
    # Rejected before anything is written.
    ("a name that fails validation", "POST", "/play", None, "name=a%3Cb&next=%2Fgame"),
    # The one allocating write: a counter bump and a new player row.
    ("a new player", "POST", "/play", None, "name=Zed&next=%2Fgame"),
]

# What the allocating write must leave on disk, read back on both sides.
WRITTEN_FILES = ["data/players/p1/name", "data/players/next-id.txt"]


# ── the site, staged once ────────────────────────────────────────────────────

def stage(root: str, gopher_root: str) -> None:
    pages = os.path.join(gopher_root, "pages")
    os.makedirs(os.path.join(root, "pages"))
    for name in ("home.txt", "steve-resume.md", "steve-resume.pdf", "safari-download.md"):
        shutil.copy(os.path.join(pages, name), os.path.join(root, "pages", name))
    for d in ("data/players/1", "data/lynrummy", "data/chat", "data/users", "auth"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    with open(os.path.join(root, "data/players/1/name"), "w") as f:
        f.write("Steve")
    with open(os.path.join(root, "data/players/next-id.txt"), "w") as f:
        f.write("1\n")


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kw)


def build_disk(image: str, content: str, mnt: str) -> None:
    """A GPT disk whose first partition is FAT16, holding `content`."""
    with open(image, "wb") as f:
        f.truncate(64 * 1024 * 1024)
    run(["sgdisk", "-o", "-n", f"1:{PART_FIRST}:0", "-t", "1:0700", "-c", "1:gopher", image])
    info = run(["sgdisk", "-i", "1", image]).stdout
    last = int(next(l for l in info.splitlines() if l.startswith("Last sector")).split()[2])
    blocks = (last - PART_FIRST + 1) // 2
    run(["mkfs.vfat", "-F", "16", "-S", "512", "-n", "GOPHER",
         "--offset", str(PART_FIRST), image, str(blocks)])
    mount(image, mnt, writable=True)
    try:
        for entry in os.listdir(content):
            src = os.path.join(content, entry)
            dst = os.path.join(mnt, entry)
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


def ask(port: int, method: str, path: str, cookie, body, scratch: str) -> dict:
    """One request by curl, which does the waiting while a guest boots. It never
    follows a redirect: the redirect IS the answer being compared."""
    hdr, out = os.path.join(scratch, "hdr"), os.path.join(scratch, "body")
    cmd = ["curl", "-sS", "--max-time", "30", "--retry", "40", "--retry-delay", "1",
           "--retry-connrefused", "--retry-all-errors", "-D", hdr, "-o", out,
           "-w", "%{http_code}", "-X", method]
    if cookie:
        cmd += ["-b", cookie]
    if body is not None:
        cmd += ["--data-raw", body]
    cmd.append(f"http://127.0.0.1:{port}{path}")
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


def boot_and_ask(elf: str, image: str, case, scratch: str) -> dict:
    _, method, path, cookie, body = case
    port = free_port()
    serial = os.path.join(scratch, "serial")
    with open(serial, "wb") as log:
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
        answer = ask(port, method, path, cookie, body, scratch)
        try:
            code = qemu.wait(timeout=60)
        except subprocess.TimeoutExpired:
            qemu.kill()
            qemu.wait()
            code = "timeout"
    text = open(serial, "rb").read().decode("latin-1", "replace")
    answer["guest_exit"] = code
    answer["serial"] = "\n".join(l for l in text.splitlines()
                                 if l.strip() and "SeaBIOS" not in l and "\x1b" not in l)
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
                time.sleep(0.1)
        raise RuntimeError("the Linux server never listened")

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.log.close()


# ── the comparison ───────────────────────────────────────────────────────────

COMPARED_HEADERS = ("location", "set-cookie", "content-type")


def differences(path: str, metal: dict, linux: dict) -> list:
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
    if path == "/version":
        out += version_differences(metal["body"], linux["body"])
    elif metal["body"] != linux["body"]:
        out.append(f"body differs: {len(metal['body'])} bytes on metal, {len(linux['body'])} on Linux"
                   f"{first_difference(metal['body'], linux['body'])}")
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


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip())
        return 2
    elf, linux_bin, gopher_root, work = sys.argv[1:]
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        print("SKIPPED: populating and reading the disk needs `sudo -n` for a loop mount")
        return 77
    for tool in ("sgdisk", "mkfs.vfat", "qemu-system-x86_64", "curl"):
        if shutil.which(tool) is None:
            print(f"SKIPPED: {tool} is not installed")
            return 77

    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    content = os.path.join(work, "content")
    stage(content, gopher_root)
    pristine = os.path.join(work, "pristine.img")
    build_disk(pristine, content, os.path.join(work, "mnt"))

    linux_root = os.path.join(work, "linux")
    shutil.copytree(content, linux_root)
    server = LinuxServer(linux_bin, linux_root, os.path.join(work, "linux.log"))
    failures = 0
    try:
        for case in READS + WRITES:
            name, method, path = case[0], case[1], case[2]
            scratch = tempfile.mkdtemp(dir=work)
            image = os.path.join(scratch, "disk.img")
            shutil.copy(pristine, image)
            metal = boot_and_ask(elf, image, case, scratch)
            linux_scratch = scratch + "-linux"
            os.makedirs(linux_scratch)
            linux = ask(server.port, method, path, case[3], case[4], linux_scratch)
            diffs = differences(path, metal, linux)
            if case[0] == "a new player" and not diffs:
                diffs += written_differences(image, linux_root, os.path.join(work, "mnt"))
            if diffs:
                failures += 1
                print(f"FAIL  {name}  ({method} {path})")
                for d in diffs:
                    print(f"        {d}")
            else:
                size = len(metal["body"])
                print(f"ok    {name}  ({method} {path}) -> {metal['status']}, {size} bytes")
    finally:
        server.stop()

    total = len(READS) + len(WRITES)
    print(f"{total - failures} of {total} requests answered the same on bare metal as on Linux")
    return 1 if failures else 0


def written_differences(image: str, linux_root: str, mnt: str) -> list:
    """The files the write left behind, read through the Linux VFAT driver on
    the kernel's disk and straight off the Linux server's directory."""
    out = []
    mount(image, mnt, writable=False)
    try:
        for rel in WRITTEN_FILES:
            m = read_or_none(os.path.join(mnt, rel))
            l = read_or_none(os.path.join(linux_root, rel))
            if m != l:
                out.append(f"{rel}: metal wrote {m!r}, Linux wrote {l!r}")
    finally:
        umount(mnt)
    # fsck.vfat has no offset option, so it checks a copy of the partition.
    part = image + ".part"
    info = run(["sgdisk", "-i", "1", image]).stdout
    last = int(next(l for l in info.splitlines() if l.startswith("Last sector")).split()[2])
    run(["dd", f"if={image}", f"of={part}", f"bs={SECTOR}", f"skip={PART_FIRST}",
         f"count={last - PART_FIRST + 1}", "status=none"])
    check = subprocess.run(["fsck.vfat", "-n", part], capture_output=True, text=True)
    if check.returncode != 0:
        out.append("fsck.vfat rejects the kernel's disk after the write: "
                   + " | ".join(check.stdout.strip().splitlines()[1:4]))
    return out


def read_or_none(path: str):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


if __name__ == "__main__":
    raise SystemExit(main())
