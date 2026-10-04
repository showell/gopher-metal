#!/usr/bin/env python3
"""**THE WHOLE CUTOVER RUNBOOK, AS ONE COMMAND** (QUEUE.md item 76; the runbook
is CUTOVER.md). `droplet/rehearse.sh` rehearses the data steps (3-6 and 11);
this rehearses the *runbook* around them — the freeze, the switch, the first
day, and the way back — against stand-ins on one machine, so each of
CUTOVER.md's GO/NO-GO lines becomes a line here that says GO or NO-GO.

    droplet/cutover_drill.sh COPY [--fat 16|32] [--gib N] [--keep-writes]
    droplet/cutover_drill.sh --self-test

The stand-ins, all on this one machine:

  prod      angry-gopher on Linux (`zig-server`), in a network namespace of
            its own, reached only over a veth from this host — as prod's
            Caddy reaches it over the private network, and nothing else can.
  the proxy a small HTTP proxy in this host's namespace, standing in for
            prod's Caddy: it forwards to one upstream, adds `X-Forwarded-For`
            as Caddy does, answers 502 when its upstream is down, and is
            *switched* from prod to metal and back. (A real Caddy is not
            used even when installed: this proxy is the one piece whose
            switch the drill drives, and it needs no root or config file.)
  metal     probe/gopher.elf on the droplet's machine (droplet.sh), the
            volume attached on the SCSI controller, forwarded to this host.

The run walks CUTOVER.md in order: freeze prod (the proxy goes 502), copy its
data and close the unsigned-cookie window, check/build/compare the volume,
boot metal on it, compare metal against prod page by page (read-only and with
writes), switch the proxy to metal, do the first-day checks (identity,
uptime, a backup that `check_backup.py` says is whole), then the way back —
freeze metal, take the volume off it with `extract_volume.py`, serve the
extracted tree on Linux again, and confirm metal's writes came back.

Like rehearse.sh it prints counts and anonymised labels only; nothing from
the copy is named. It stops everything it started — the servers, the QEMU, the
proxy, the namespace and its veth — and removes its scratch, whatever happens.
A run killed outright leaves them under `~/build/gopher-metal/cutover-drill/`
(or `$DRILL_SCRATCH`) and its namespace `gm-drill-<pid>`; the next run removes
both and says so.

**Run it as yourself**, where `sudo -n` works (the namespace and veth need
root; the servers run as you). It uses KVM when `/dev/kvm` is usable and says
so when it is not (slow TCG, the same machine).

The admin password the first-day backup needs is `$DRILL_ADMIN_PASSWORD`
(default the staged site's, so `--self-test` needs nothing set).

Exit 0 when every step is GO, 1 at the first NO-GO, 2 for a usage error.
"""
import base64
import hashlib
import hmac
import http.client
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
import build_volume  # noqa: E402
import check_volume_tree  # noqa: E402
import judge_gopher as G  # noqa: E402
import rehearse as R  # noqa: E402  (the data steps, and the machinery they share)

PID = os.getpid()
NETNS = f"gm-drill-{PID}"
NETNS_PREFIX = "gm-drill-"
VETH_H = f"dh{PID}"           # this host's end of the veth (<= 15 chars)
VETH_N = f"dn{PID}"           # prod's end, inside the namespace
HOST_IP = "10.123.0.1"       # this host, as prod's Caddy host would be
NS_IP = "10.123.0.2"         # prod, on the private network
PROD_PORT = 9101             # prod listens here inside its namespace
SCRATCH = os.environ.get("DRILL_SCRATCH", os.path.expanduser("~/build/gopher-metal/cutover-drill"))
ADMIN_PASSWORD = os.environ.get("DRILL_ADMIN_PASSWORD", G.MEMBER_PASSWORD)

NoGo = R.NoGo
say = R.say


def as_root(cmd):
    return cmd if os.geteuid() == 0 else ["sudo", "-n", *cmd]


def in_netns(cmd, env=None):
    """`cmd` inside this run's namespace, dropped back to this user, with `env`
    set — the same shape rehearse.py uses."""
    drop = [] if os.geteuid() == 0 else ["setpriv", f"--reuid={os.getuid()}",
                                         f"--regid={os.getgid()}", "--clear-groups", "--"]
    pre = ["env", *(f"{k}={v}" for k, v in env.items())] if env else []
    return as_root(["ip", "netns", "exec", NETNS, *drop, *pre, *cmd])


def count_files(*dirs):
    n = 0
    for d in dirs:
        for _, _, files in os.walk(d):
            n += len(files)
    return n


def mint(uid, issued, secret):
    """A gopher_auth cookie in users.zig's signSession format, from the copy's
    own secret (so both hosts honor it), the way judge_gopher mints one."""
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    mac = hmac.new(secret, f"{uid}\n{issued}".encode(), hashlib.sha256).digest()
    return f"gopher_auth={b64(uid.encode())}.{issued}.{b64(mac)}"


# ── the proxy that stands in for prod's Caddy ─────────────────────────────────
class Proxy(ThreadingHTTPServer):
    """One upstream at a time, switched under a lock. Forwards every method,
    adds X-Forwarded-For as Caddy does, and answers 502 when the upstream is
    down or unset (`point Caddy at nothing`)."""
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port):
        super().__init__(("127.0.0.1", port), Handler)
        self.port = self.server_address[1]
        self.lock = threading.Lock()
        self.upstream = None  # (host, port) or None

    def retarget(self, upstream):
        with self.lock:
            self.upstream = upstream

    def start(self):
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.shutdown()
        self.server_close()


HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailers", "transfer-encoding", "upgrade"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # one request per connection: no keep-alive to juggle

    def log_message(self, *a):
        pass

    def _bad_gateway(self, why):
        body = f"502 Bad Gateway: {why}".encode()
        self.send_response_only(502, "Bad Gateway")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _proxy(self):
        with self.server.lock:
            up = self.server.upstream
        if up is None:
            self._bad_gateway("no upstream")
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        prior = self.headers.get("X-Forwarded-For")
        client = self.client_address[0]
        headers["X-Forwarded-For"] = f"{prior}, {client}" if prior else client
        headers["X-Forwarded-Proto"] = "http"
        headers.setdefault("X-Forwarded-Host", self.headers.get("Host", ""))
        try:
            conn = http.client.HTTPConnection(up[0], up[1], timeout=60)
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        except OSError as e:
            self._bad_gateway(str(e))
            return
        self.send_response_only(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() in HOP or k.lower() == "content-length":
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        conn.close()

    do_GET = do_POST = do_HEAD = do_PUT = do_DELETE = _proxy


# ── reaching the proxy (as a browser through Caddy would) ─────────────────────
def through_proxy(port, method, path, headers=None, body=None, timeout=60):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    conn.request(method, path, body=body, headers=headers or {})
    resp = conn.getresponse()
    data = resp.read()
    status = resp.status
    setcookies = [v for k, v in resp.getheaders() if k.lower() == "set-cookie"]
    conn.close()
    return status, data, setcookies


def proxy_code(port, path="/version"):
    try:
        return through_proxy(port, "GET", path, timeout=10)[0]
    except OSError:
        return 0


# ── prod, in its own namespace, reached over a veth ───────────────────────────
def make_netns(started):
    steps = [
        as_root(["ip", "netns", "add", NETNS]),
        as_root(["ip", "link", "add", VETH_H, "type", "veth", "peer", "name", VETH_N]),
        as_root(["ip", "link", "set", VETH_N, "netns", NETNS]),
        as_root(["ip", "addr", "add", f"{HOST_IP}/24", "dev", VETH_H]),
        as_root(["ip", "link", "set", VETH_H, "up"]),
        as_root(["ip", "netns", "exec", NETNS, "ip", "addr", "add", f"{NS_IP}/24", "dev", VETH_N]),
        as_root(["ip", "netns", "exec", NETNS, "ip", "link", "set", VETH_N, "up"]),
        as_root(["ip", "netns", "exec", NETNS, "ip", "link", "set", "lo", "up"]),
    ]
    started.netns = NETNS  # so Started.stop() removes the namespace (and VETH_N with it)
    started.veth_h = VETH_H
    for cmd in steps:
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise NoGo(f"`{' '.join(c for c in cmd if c != 'sudo')[:60]}` failed: {r.stderr.strip()}")


def start_prod(started, scratch, data_src, name="prod"):
    """angry-gopher on Linux, in the namespace, bound on the veth so the proxy
    reaches it and nothing outside the namespace does. `data_src` holds
    data/ and auth/."""
    work = R.linux_site(scratch, data_src)
    binary = os.path.join(R.GOPHER_ROOT, "zig-server", "zig-out", "bin", "zig-server")
    if not os.path.isfile(binary):
        raise NoGo(f"no Linux build at {binary}: run `zig build` in zig-server/")
    env = {"GOPHER_CONFIG": os.path.join(work, "gopher.conf"), "GOPHER_PORT": str(PROD_PORT),
           "GOPHER_BIND": "0.0.0.0", "GOPHER_GAME_FLOOR": "off", "HOME": os.path.expanduser("~"),
           "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    log = open(os.path.join(scratch, f"{name}.log"), "wb")
    p = subprocess.Popen(in_netns(["sh", "-c", 'cd "$0" && exec "$1"', work, binary], env),
                         cwd=work, stdout=log, stderr=log)
    started.procs.append(p)
    deadline = time.time() + 30
    while time.time() < deadline:
        r = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                            f"http://{NS_IP}:{PROD_PORT}/version"], capture_output=True, text=True)
        if r.stdout == "200":
            return p
        if p.poll() is not None:
            break
        time.sleep(0.2)
    raise NoGo(f"the {name} server did not answer on the private network")


# ── the comparison (CUTOVER steps 6 and 11), reusing rehearse's walker ────────
def compare_hosts(copy, metal_port, writes):
    prod_url = f"http://{NS_IP}:{PROD_PORT}"
    metal_url = f"http://127.0.0.1:{metal_port}"
    for extra in ([], ["--writes"]) if writes else ([],):
        r = subprocess.run([sys.executable, os.path.join(HERE, "compare_hosts.py"), copy,
                            metal_url, prod_url, *extra], capture_output=True, text=True)
        out = r.stdout.strip().splitlines()
        for line in out[:-1]:
            print(f"      {line}")
        label = "11. compare metal with prod's Linux, with --writes" if extra \
            else "6/11. compare metal with prod's Linux, read-only"
        say(label, "GO" if r.returncode == 0 else "NO-GO", out[-1] if out else r.stderr.strip()[-200:])
        if r.returncode != 0:
            raise NoGo("the two hosts differ")


# ── the drill ─────────────────────────────────────────────────────────────────
def drill(src, fat, gib, keep_writes):
    size = gib << 30
    print(f"── the cutover, on stand-ins: FAT{fat}, {gib} GiB ──", flush=True)
    started = R.Started()
    started.veth_h = None
    scratch = os.path.join(SCRATCH, f"drill-{PID}")
    os.makedirs(scratch)
    proxy = Proxy(G.free_port())
    proxy.start()
    try:
        # prod is up behind the proxy, as the live site.
        make_netns(started)
        prod = start_prod(started, scratch, src, "prod")
        proxy.retarget((NS_IP, PROD_PORT))
        if proxy_code(proxy.port) != 200:
            raise NoGo("the site did not come up behind the proxy")
        say("the site is up behind the proxy", "GO",
            f"prod in namespace {NETNS}, reached only over the veth")

        # 1. Freeze prod.
        prod.terminate()
        prod.wait(10)
        code = proxy_code(proxy.port)
        say("1. freeze prod (the proxy answers 502)", "GO" if code == 502 else "NO-GO",
            f"/version through the proxy is {code}")
        if code != 502:
            raise NoGo("the frozen site did not answer 502")

        # 2. Copy the data, and close the unsigned-cookie window.
        prod_data = os.path.join(scratch, "linux")  # what prod served (linux_site's root)
        copy = os.path.join(scratch, "copy")
        os.makedirs(copy)
        for d in G.DATA_DIRS:
            shutil.copytree(os.path.join(prod_data, d), os.path.join(copy, d))
        a = count_files(*(os.path.join(prod_data, d) for d in G.DATA_DIRS))
        b = count_files(*(os.path.join(copy, d) for d in G.DATA_DIRS))
        # Same count AND not nothing: 0 == 0 would pass a copy of an empty tree.
        say("2. copy prod's data (same file count)", "GO" if a == b and b > 0 else "NO-GO", f"{b} files")
        if a != b or b == 0:
            raise NoGo("the copy has a different file count" if a != b else "the copy is empty")
        window = os.path.join(copy, "data", "players", "unsigned-window")
        # Absent is a real state: the window opens (for 30 days) the first time
        # an unsigned cookie is asked about (uid_cookie.windowOpen), and prod
        # may never have been asked. Either way, this step's write is what
        # closes it, so the proof is the file holding exactly this step's `now`.
        before = open(window).read().strip() if os.path.exists(window) else "absent (not yet opened)"
        now = int(time.time())
        with open(window, "w") as f:
            f.write(f"{now}\n")
        shut = int(open(window).read().strip())
        moved = shut == now
        say("2. close the unsigned-cookie window", "GO" if moved else "NO-GO",
            f"was {before}, now {shut}: re-signs an unsigned cookie once"
            if moved else f"did not read back as {now} (was {before}, now {shut})")
        if not moved:
            raise NoGo("the unsigned-cookie window did not close")

        # 3. Check it.
        findings, summary = check_volume_tree.check(copy, volume=size, fat=fat)
        if findings:
            rules = {}
            for fnd in findings:
                rules[fnd.rule] = rules.get(fnd.rule, 0) + 1
            say("3. check the copy", "NO-GO", ", ".join(f"{n} {r}" for r, n in sorted(rules.items())))
            raise NoGo("the copy")
        say("3. check the copy", "GO", f"{summary['files']} files, {summary['directories']} folders, nothing found")

        # 4. Build the volume.
        volume = os.path.join(scratch, "prod-volume.img")
        try:
            serial = build_volume.build(copy, volume, fat=fat, size=size, check=False)
        except build_volume.Refused as e:
            say("4. build the volume", "NO-GO", str(e))
            raise NoGo("the volume")
        problems = build_volume.judge(copy, volume)
        if problems:
            say("4. build the volume", "NO-GO", f"{len(problems)} problem(s) found by the non-mtools readers")
            raise NoGo("the volume")
        say("4. build the volume", "GO", f"serial {serial}; compare_volume, fat16_read and fsck.fat agree")

        # 5. Compare once more, by hand.
        again = build_volume.judge(copy, volume)
        say("5. compare the volume with the copy", "GO" if not again else "NO-GO",
            "the volume holds the copy exactly" if not again else f"{len(again)} problem(s)")
        if again:
            raise NoGo("the volume")

        # 7-10. Build the boot image and boot metal on the volume (the drill writes
        # the image metal boots directly; on the day the recovery console dd's the
        # volume onto the droplet's disk — step 8 — which one machine cannot stand in
        # for). boot_metal checks the boot lines CUTOVER step 10 names.
        metal_port = R.boot_metal(started, scratch, volume, serial)
        metal_proc = started.procs[-1]
        say("7-10. metal boots on the volume", "GO",
            f"serial {serial}, both disk checks clean, listening (step 8's dd is the one "
            f"step one machine cannot stand in for)")

        # 6/11. Compare metal with prod's Linux, page by page. prod's own server
        # is frozen; this serves the frozen data on the private network, as
        # CUTOVER step 11 does on loopback, and is stopped afterwards (the
        # runbook's "Stop the loopback server") so the way back can reuse its port.
        frozen = start_prod(started, os.path.join(scratch, "frozen"), copy, "frozen")
        compare_hosts(copy, metal_port, writes=True)
        frozen.terminate()
        frozen.wait(10)

        # 12. Switch the proxy from prod to metal.
        proxy.retarget(("127.0.0.1", metal_port))
        secret = open(os.path.join(copy, "data", "chat", "_session_secret"), "rb").read()
        vcode = proxy_code(proxy.port, "/version")
        _, host_body, _ = through_proxy(proxy.port, "GET", "/admin/host",
                                        {"Cookie": mint("1", int(time.time()), secret)})
        is_metal = b"gopher-metal" in host_body
        say("12. switch the proxy to metal", "GO" if vcode == 200 and is_metal else "NO-GO",
            f"/version is {vcode}, /admin/host names " + ("gopher-metal" if is_metal else "NOT gopher-metal"))
        if vcode != 200 or not is_metal:
            raise NoGo("the switch")
        # login, post a message, and see it (CUTOVER step 12's third GO).
        if not post_and_see(proxy.port, secret):
            say("12. log in, post a message, and see it", "NO-GO", "the message did not come back")
            raise NoGo("the switch")
        say("12. log in, post a message, and see it", "GO", "posted through the proxy and read back")

        # The first day: identity and uptime grow, a backup is whole.
        first_day(proxy.port, scratch)

        # The way back.
        way_back(started, scratch, proxy, metal_proc, volume, copy)
    finally:
        proxy.stop()
        started.stop()
        if getattr(started, "veth_h", None):
            subprocess.run(as_root(["ip", "link", "del", started.veth_h]), capture_output=True)
        if not keep_writes:
            shutil.rmtree(scratch, ignore_errors=True)
        else:
            print(f"      (kept {scratch})")


def post_and_see(port, secret):
    """As the admin, through the proxy: a topic in their own DM, a message in
    it, then read it back. No one else sees uid 1's self-DM."""
    cookie = mint("1", int(time.time()), secret)
    h = {"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"}
    through_proxy(port, "POST", "/chat/c/1_1/new", h, "topic=drill")
    msg = f"cutover drill {int(time.time())}"
    hs = dict(h, **{"X-Chat-Async": "1"})
    through_proxy(port, "POST", "/chat/c/1_1/drill/send", hs,
                  f"markdown={msg.replace(' ', '+')}&cid=c1")
    # The topic page loads its messages client-side; `raw` is the server-rendered
    # transcript, which is what compare_hosts walks too.
    status, body, _ = through_proxy(port, "GET", "/chat/c/1_1/drill/raw", {"Cookie": cookie})
    return status == 200 and msg.encode() in body


def first_day(port, scratch):
    cookie = None
    # /admin/host: metal's identity and a growing uptime.
    secret_cookie = {"Cookie": mint("1", int(time.time()), _secret_of(scratch))}
    _, b1, _ = through_proxy(port, "GET", "/admin/host", secret_cookie)
    time.sleep(1.5)  # more than one of the host clock's whole seconds
    _, b2, _ = through_proxy(port, "GET", "/admin/host", secret_cookie)
    is_metal = b"gopher-metal" in b2
    u1, u2 = _uptime(b1), _uptime(b2)
    # **IT MUST GROW, not merely not-shrink** (QUEUE.md item 99): a stuck clock
    # that showed the same uptime twice passed the old `>=`. `>` with a 1.5 s
    # wait, against a whole-second uptime, demands the clock actually moved.
    grew = u1 is not None and u2 is not None and u2 > u1
    free = b"free" in b2.lower()  # the volume's free space, informational
    say("first day: /admin/host, identity and uptime", "GO" if is_metal and grew else "NO-GO",
        f"gopher-metal, up for {u2} s (was {u1}, so it grew)" + (", free space shown" if free else "")
        if is_metal and grew else f"not metal's page, or uptime did not grow (was {u1}, now {u2})")
    if not (is_metal and grew):
        raise NoGo("the first-day checks")
    # A backup, taken as the runbook takes it: log in with the password, then
    # ask for the archive with it, and let check_backup.py say it is whole.
    body = (f"name=Steve&password={ADMIN_PASSWORD.replace(' ', '+')}&action=login&next=%2Fchat")
    _, _, cookies = through_proxy(port, "POST", "/login/full", {"Content-Type": "application/x-www-form-urlencoded"}, body)
    jar = next((c.split(";", 1)[0] for c in cookies if c.startswith("gopher_auth=")), None)
    if not jar:
        say("first day: a backup, whole", "NO-GO",
            f"the admin password did not log in (set DRILL_ADMIN_PASSWORD)")
        raise NoGo("the first-day backup")
    status, tar, _ = through_proxy(port, "POST", "/admin/backup",
                                   {"Cookie": jar, "Content-Type": "application/x-www-form-urlencoded"},
                                   f"password={ADMIN_PASSWORD.replace(' ', '+')}")
    path = os.path.join(scratch, "gopher-backup.tar")
    with open(path, "wb") as f:
        f.write(tar)
    chk = subprocess.run([sys.executable, os.path.join(HERE, "check_backup.py"), path],
                         capture_output=True, text=True)
    whole = chk.returncode == 0 and "whole:" in chk.stdout
    say("first day: a backup, whole", "GO" if whole else "NO-GO",
        chk.stdout.strip().splitlines()[-1] if chk.stdout.strip() else f"status {status}")
    if not whole:
        raise NoGo("the first-day backup")


def _secret_of(scratch):
    return open(os.path.join(scratch, "copy", "data", "chat", "_session_secret"), "rb").read()


def _uptime(body):
    """The 'up for N s' the host page prints, as an int, or None."""
    text = body.decode("latin-1")
    i = text.find("up for")
    if i < 0:
        return None
    rest = text[i + 6:].lstrip()
    num = ""
    for ch in rest:
        if ch.isdigit():
            num += ch
        elif num:
            break
    return int(num) if num else None


def way_back(started, scratch, proxy, metal_proc, volume, copy):
    # 1. Freeze metal: the proxy points at nothing, so no more writes land.
    proxy.retarget(None)
    code = proxy_code(proxy.port)
    say("way back 1. freeze metal (the proxy answers 502)", "GO" if code == 502 else "NO-GO",
        f"/version through the proxy is {code}")
    if code != 502:
        raise NoGo("the frozen metal did not answer 502")
    # Power metal down, as the recovery console does before dd: nothing is
    # reading or writing the volume while it is taken off.
    metal_proc.terminate()
    metal_proc.wait(15)
    # 2. Take the data off metal (extract_volume.py): every name, byte and time,
    # checked against the volume it came from. That self-check IS the comparison
    # the volume path can make on one machine (metal is down); the backup path
    # above kept metal up and compared live.
    back = os.path.join(scratch, "back")
    ex = subprocess.run([sys.executable, os.path.join(HERE, "extract_volume.py"), volume, back],
                        capture_output=True, text=True)
    ok = ex.returncode == 0
    say("way back 2. extract_volume (the tree matches the volume)", "GO" if ok else "NO-GO",
        ex.stdout.strip().splitlines()[-1] if ex.stdout.strip() else ex.stderr.strip()[-200:])
    if not ok:
        raise NoGo("extract_volume")
    # Metal's writes survived the round trip: the drill posted a topic, and
    # --writes posted another with an upload, so the extracted tree holds more
    # files than the copy metal first served.
    grew = count_files(os.path.join(back, "data")) > count_files(os.path.join(copy, "data"))
    say("way back 2. metal's writes came back", "GO" if grew else "NO-GO",
        f"{count_files(os.path.join(back, 'data'))} files on the volume vs {count_files(os.path.join(copy, 'data'))} copied over")
    if not grew:
        raise NoGo("metal's writes did not survive the round trip")
    # 3-4. Linux again, on the extracted tree, and 5. the proxy back to prod.
    start_prod(started, os.path.join(scratch, "wayback"), back, "wayback")
    proxy.retarget((NS_IP, PROD_PORT))
    _, body, _ = through_proxy(proxy.port, "GET", "/admin/host",
                              {"Cookie": mint("1", int(time.time()), _secret_of(scratch))})
    is_linux = b"Linux, zig-server" in body
    say("way back 3-5. Linux again, the proxy back on prod", "GO" if is_linux else "NO-GO",
        "/admin/host names Linux, zig-server" if is_linux else "/admin/host does not name Linux")
    if not is_linux:
        raise NoGo("the way back")


# ── leftovers, from a run that was killed before its finally ──────────────────
def clear_leftovers():
    said = []
    os.makedirs(SCRATCH, exist_ok=True)
    for name in sorted(os.listdir(SCRATCH)):
        pid = name.rsplit("-", 1)[-1]
        if name.startswith("drill-") and pid.isdigit() and not R.pid_alive(int(pid)):
            shutil.rmtree(os.path.join(SCRATCH, name), ignore_errors=True)
            said.append(f"scratch {name}")
    listed = subprocess.run(["ip", "netns", "list"], capture_output=True, text=True).stdout.split()
    for ns in listed:
        pid = ns[len(NETNS_PREFIX):]
        if ns.startswith(NETNS_PREFIX) and pid.isdigit() and not R.pid_alive(int(pid)):
            subprocess.run(as_root(["ip", "netns", "del", ns]), capture_output=True)
            said.append(f"namespace {ns}")
            subprocess.run(as_root(["ip", "link", "del", f"dh{pid}"]), capture_output=True)
    return said


def main(argv):
    if argv[1:2] == ["--self-test"]:
        return self_test()
    args = argv[1:]
    keep = "--keep-writes" in args
    if keep:
        args.remove("--keep-writes")
    fat, gib = 32, None
    for opt in ("--fat", "--gib"):
        if opt in args:
            i = args.index(opt)
            if i + 1 >= len(args):
                print(__doc__.strip(), file=sys.stderr)
                return 2
            val = int(args[i + 1])
            if opt == "--fat":
                fat = val
            else:
                gib = val
            del args[i:i + 2]
    if len(args) != 1 or not all(os.path.isdir(os.path.join(args[0], d)) for d in G.DATA_DIRS):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if not os.path.isfile(R.ELF):
        print(f"cutover_drill: no {R.ELF}: ./port.sh && zig build gopher")
        return 2
    if os.geteuid() != 0 and subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        print("cutover_drill: the namespace and veth need root: run as root, or where `sudo -n` works")
        return 2
    for what in clear_leftovers():
        print(f"cutover_drill: removed {what}, left by a run that was killed")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))  # so `finally` runs
    try:
        drill(args[0], fat, gib or R.DEFAULT_GIB[fat], keep)
    except NoGo as e:
        print(f"cutover_drill: NO-GO at {e}")
        return 1
    print(f"cutover_drill: GO — the whole runbook, on stand-ins (FAT{fat})")
    return 0


def self_test():
    """The judge's staged site, with a conversation written through the front
    door, run through the whole runbook once on FAT32 (prod's kind). Then the
    checks: it reached GO, it named nothing from the data, and it left no
    namespace or veth behind."""
    with tempfile.TemporaryDirectory() as d:
        site = os.path.join(d, "site")
        G.stage(site, R.GOPHER_ROOT)
        binary = os.path.join(R.GOPHER_ROOT, "zig-server", "zig-out", "bin", "zig-server")
        server = G.LinuxServer(binary, site, os.path.join(d, "fill.log"))
        try:
            cookie = G.mint_session("1", int(time.time()))
            base = f"http://127.0.0.1:{server.port}"
            subprocess.run(["curl", "-sS", "-o", "/dev/null", "-H", f"Cookie: {cookie}",
                            "--data", "topic=rehearsal", f"{base}/chat/c/1_2/new"], check=True)
            subprocess.run(["curl", "-sS", "-o", "/dev/null", "-H", f"Cookie: {cookie}", "-H", "X-Chat-Async: 1",
                            "--data", "markdown=hello&cid=c1", f"{base}/chat/c/1_2/rehearsal/send"], check=True)
        finally:
            server.stop()
        copy = os.path.join(d, "copy")
        os.makedirs(copy)
        for top in G.DATA_DIRS:
            shutil.copytree(os.path.join(site, top), os.path.join(copy, top))
        whole = subprocess.run([sys.executable, __file__, copy, "--fat", "32"],
                               capture_output=True, text=True)
        print(whole.stdout, end="")
        leftovers = subprocess.run(["ip", "netns", "list"], capture_output=True, text=True).stdout
    failures = []
    if whole.returncode != 0:
        failures.append(f"the staged site did not run GO through the runbook (exit {whole.returncode}): "
                        f"{whole.stdout.strip().splitlines()[-1] if whole.stdout.strip() else whole.stderr[-300:]}")
    for need in ("1. freeze prod", "12. switch the proxy to metal", "way back 2. extract_volume",
                 "way back 3-5. Linux again"):
        if f"GO    {need}" not in whole.stdout and not any(l.startswith("GO") and need in l
                                                           for l in whole.stdout.splitlines()):
            failures.append(f"the runbook step {need!r} was not reached GO")
    if "rehearsal" in whole.stdout:
        failures.append("the output names something from the data")
    if NETNS_PREFIX in leftovers:
        failures.append("a namespace was left behind")
    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: the staged site ran the whole cutover runbook GO on stand-ins — prod frozen "
          "behind the proxy, the volume built and metal booted on it, the proxy switched to metal, the "
          "first-day backup whole, and the way back through extract_volume to Linux — naming nothing and "
          "leaving nothing behind")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
