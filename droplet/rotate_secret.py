#!/usr/bin/env python3
"""Change a site's session secret, and check that it took (QUEUE.md item
66; SECRET-LEAK.md says when and why).

    droplet/rotate_secret.py URL --days N [--name Steve]
    droplet/rotate_secret.py --self-test ZIG_SERVER_BINARY

It asks for the admin's password (unechoed), logs in as `--name` (default
Steve), and posts /admin/secret with the password and `--days`: how long
players' cookies signed with the old secret are still taken and renewed.
Then it checks, and prints GO or NO-GO for each:
- the session it logged in with has ended;
- the password logs in again, and that session reaches /admin.

Run it on prod, against metal's private address, as backups are taken
(CUTOVER.md): never through Caddy from a home connection, since the
password crosses the wire.

Exit 0 when the secret was changed and checks out, 1 otherwise, 2 for a
usage error.
"""
import getpass
import http.client
import os
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


class Site:
    def __init__(self, base: str):
        u = urllib.parse.urlsplit(base)
        self.host, self.port = u.hostname, u.port or 80

    def ask(self, method: str, path: str, cookie: str = None, form: dict = None):
        c = http.client.HTTPConnection(self.host, self.port, timeout=60)
        try:
            headers = {}
            body = None
            if cookie:
                headers["Cookie"] = cookie
            if form is not None:
                body = urllib.parse.urlencode(form)
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            c.request(method, path, body=body, headers=headers)
            r = c.getresponse()
            return r.status, r.getheader("set-cookie") or "", r.read()
        finally:
            c.close()

    def login(self, name: str, password: str):
        """The gopher_auth cookie a login sets, or None."""
        status, set_cookie, _ = self.ask("POST", "/login/full", form={"name": name, "password": password,
                                                                       "action": "login", "next": "/"})
        for part in set_cookie.split(","):
            part = part.strip()
            if part.startswith("gopher_auth=") and not part.startswith("gopher_auth=;"):
                return part.split(";", 1)[0]
        return None


def rotate(base: str, name: str, password: str, days: int, out=print) -> bool:
    site = Site(base)
    before = site.login(name, password)
    if not before:
        out("NO-GO log in: the name and password did not log in")
        return False
    status, _, body = site.ask("POST", "/admin/secret", before, {"password": password, "days": str(days)})
    if status != 200 or b"The secret is changed" not in body:
        out(f"NO-GO change the secret: /admin/secret answered {status}")
        return False
    out(f"GO    change the secret: done; players' cookies renewed for {days} day(s)")
    status, _, _ = site.ask("GET", "/admin", before)
    if status == 200:
        out("NO-GO the old session: it still reaches /admin")
        return False
    out(f"GO    the old session: ended ({status})")
    after = site.login(name, password)
    status = site.ask("GET", "/admin", after)[0] if after else None
    if status != 200:
        out(f"NO-GO log in again: {'no session' if not after else status}")
        return False
    out("GO    log in again: the password works, and the new session reaches /admin")
    return True


def main(argv) -> int:
    if len(argv) == 3 and argv[1] == "--self-test":
        return self_test(argv[2])
    args = argv[1:]
    opts = {"--days": None, "--name": "Steve"}
    for flag in list(opts):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                print(__doc__.strip(), file=sys.stderr)
                return 2
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 1 or opts["--days"] is None or not opts["--days"].isdigit():
        print(__doc__.strip(), file=sys.stderr)
        return 2
    password = getpass.getpass(f"{opts['--name']}'s password: ")
    return 0 if rotate(args[0], opts["--name"], password, int(opts["--days"])) else 1


# ── the self-test ───────────────────────────────────────────────────────────

def self_test(binary: str) -> int:
    """On the judge's staged site, on a Linux server and on metal booted
    under QEMU: the procedure checks out, and a player's cookie signed
    before the change is renewed with the new secret."""
    sys.path.insert(0, os.path.join(ROOT, "probe"))
    sys.path.insert(0, HERE)
    import build_volume
    import judge_gopher as G
    gopher_root = os.path.dirname(os.path.abspath(binary))
    while not os.path.isfile(os.path.join(gopher_root, "pages", "home.txt")):
        if gopher_root == os.path.dirname(gopher_root):
            print(f"self-test cannot run: no angry-gopher checkout above {binary}")
            return 2
        gopher_root = os.path.dirname(gopher_root)
    failures, lines = [], []

    def check(name: str, base: str):
        site = Site(base)
        old_uid = G.mint_uid("p1", int(time.time()))  # p1, signed with the staged secret
        if not rotate(base, "Steve", G.MEMBER_PASSWORD, 3, lambda s: lines.append(f"{name}: {s}")):
            failures.append(f"{name}: the procedure did not check out")
            return
        status, set_cookie, _ = site.ask("GET", "/play", old_uid)
        if status != 303 or "gopher_uid=p1." not in set_cookie:
            failures.append(f"{name}: a player's old cookie answered {status}, not renewed")
        new_uid = set_cookie.split(";", 1)[0]
        if b"Currently playing as <strong>Nikhil</strong>" not in site.ask("GET", "/play", new_uid)[2]:
            failures.append(f"{name}: the renewed cookie does not name the player")
        if site.login("Steve", "not the password"):
            failures.append(f"{name}: a wrong password logged in")

    with tempfile.TemporaryDirectory() as d:
        site = os.path.join(d, "site")
        G.stage(site, gopher_root)
        server = G.LinuxServer(binary, site, os.path.join(d, "linux.log"))
        try:
            check("Linux", f"http://127.0.0.1:{server.port}")
        finally:
            server.stop()
        metal_site = os.path.join(d, "metal-site")
        G.stage(metal_site, gopher_root)
        with open(os.path.join(metal_site, "gopher-metal.conf"), "w") as f:
            f.write("idle_timeout_ms = 10000\n")
        img = os.path.join(d, "disk.img")
        build_volume.build(metal_site, img, fat=16, size=64 << 20, check=False)
        qemu, port, _ = G.start_kernel(os.path.join(ROOT, "probe", "gopher.elf"), img, d)
        try:
            check("metal", f"http://127.0.0.1:{port}")
        finally:
            qemu.kill()
            qemu.wait()
    print("\n".join(lines))
    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: on Linux and on metal, the secret changed, the old session ended, the password "
          "logged in again, and a player's old cookie was renewed with the new secret")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
