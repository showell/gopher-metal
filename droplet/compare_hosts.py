#!/usr/bin/env python3
"""Two hosts serving the same data, page by page (QUEUE.md item 28): the
rehearsal's comparison, kept for the cutover day.

    droplet/compare_hosts.py COPY A_URL B_URL [--uid 1] [--secret FILE] [--netns NAME]
    droplet/compare_hosts.py --self-test ZIG_SERVER_BINARY

`COPY` is the data both hosts serve (it holds `data/` and `auth/`); it is
only read, to know which pages exist. Each page is asked of both hosts as
`--uid` (default 1, the admin), with a session minted from the copy's own
secret (`data/chat/_session_secret`, or `--secret`), and compared by status
and SHA-256 of the body. With `--netns NAME`, B is asked through
`ip netns exec NAME`, as the box reaches metal's private card.

**IT PRINTS COUNTS AND ANONYMISED LABELS ONLY.** The data is real: no topic
name, channel name, doc slug, file name or content is printed. A difference
is named like `dm 3, topic 12, raw`, numbered in the copy's sorted order, so
the operator can find it in the copy without this output holding it.

Walked, for the user: every conversation they are in (DMs and channels),
each topic's page, `raw` and `reactions`, and every upload; their docs, each
one; and recent, docs, links, images, code, settings, conversations, the
admin roster and the game roster. Not compared, on purpose: /admin/host
(each host describes itself), /version (the build), a topic's `download`
(an archive of file times, which FAT keeps in 2-second steps), and streams.

**ASKING IS NOT READ-ONLY.** A topic page records it as the user's last
topic (`data/chat/users/<uid>/last-conv` and `last-sessions/`), which
`conversations` and `/chat` then show. Both hosts are asked the same pages
in the same order, so their bookmarks move alike. On the cutover day that
means the walk changes `--uid`'s bookmarks on prod as well as on metal.

Exit status: 0 when every page is the same on both, 1 when any differs, 2
for a usage error.
"""
import base64
import hashlib
import hmac
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def mint_session(secret: bytes, uid: str, issued: int) -> str:
    """A gopher_auth cookie in users.zig's signSession format, as
    judge_gopher.mint_session makes one, from any secret."""
    b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    mac = hmac.new(secret, f"{uid}\n{issued}".encode(), hashlib.sha256).digest()
    return f"gopher_auth={b64(uid.encode())}.{issued}.{b64(mac)}"


def pages(copy: str, uid: str) -> list:
    """Every page to compare, as (label, path), from what is in `copy`."""
    q = lambda s: urllib.parse.quote(s, safe="")
    chat = os.path.join(copy, "data", "chat")
    out = [(name, path) for name, path in (
        ("recent", "/chat/recent"), ("docs list", "/chat/docs/list"), ("links", "/chat/links"),
        ("images", "/chat/images"), ("code", "/chat/code"), ("conversations", "/chat/conversations"),
        ("settings", "/settings"), ("admin roster", "/admin"), ("game roster", "/admin/lynrummy"),
    )]

    def topics(kind: str, n: int, conv_dir: str, base: str):
        sessions = os.path.join(conv_dir, "sessions")
        if not os.path.isdir(sessions):
            return
        sids = sorted(f[:-3] for f in os.listdir(sessions) if f.endswith(".md"))
        for t, sid in enumerate(sids, 1):
            label = f"{kind} {n}, topic {t}"
            url = f"{base}/{q(sid)}"
            out.extend([(label, url), (f"{label}, raw", f"{url}/raw"), (f"{label}, reactions", f"{url}/reactions")])
            up = os.path.join(sessions, sid + ".uploads")
            if os.path.isdir(up):
                for u, name in enumerate(sorted(os.listdir(up)), 1):
                    out.append((f"{label}, upload {u}", f"{url}/uploads/{q(name)}"))

    if os.path.isdir(chat):
        dms = sorted(d for d in os.listdir(chat) if "_" in d and uid in d.split("_")
                     and os.path.isdir(os.path.join(chat, d)))
        for n, conv in enumerate(dms, 1):
            topics("dm", n, os.path.join(chat, conv), f"/chat/c/{q(conv)}")
        channels = os.path.join(chat, "channels")
        if os.path.isdir(channels):
            names = sorted(d for d in os.listdir(channels) if os.path.isdir(os.path.join(channels, d)))
            for n, name in enumerate(names, 1):
                topics("channel", n, os.path.join(channels, name), f"/channel/{q(name)}")
        docs = os.path.join(chat, "users", uid, "docs")
        if os.path.isdir(docs):
            for n, f in enumerate(sorted(f for f in os.listdir(docs) if f.endswith(".md")), 1):
                out.append((f"doc {n}", f"/chat/docs/{q(f[:-3])}"))
    return out


def fetch(base: str, path: str, cookie: str, netns: str = None) -> tuple:
    """(status, sha256 of the body) for `path` on `base`, by curl, redirects
    not followed: a redirect is an answer to compare."""
    cmd = ["curl", "-sS", "-o", "-", "-w", "\n%{http_code}", "-H", f"Cookie: {cookie}", base.rstrip("/") + path]
    if netns:
        cmd = ["ip", "netns", "exec", netns] + cmd
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0:
        return ("no answer", "")
    body, _, status = r.stdout.rpartition(b"\n")
    return (status.decode(), hashlib.sha256(body).hexdigest())


def compare(copy: str, a: str, b: str, uid: str = "1", secret: bytes = None, netns: str = None) -> tuple:
    """(how many pages, [(label, what differs)]), with no name from the data."""
    if secret is None:
        with open(os.path.join(copy, "data", "chat", "_session_secret"), "rb") as f:
            secret = f.read()
    cookie = mint_session(secret, uid, int(time.time()))
    walked = pages(copy, uid)
    differ = []
    for label, path in walked:
        sa, ha = fetch(a, path, cookie)
        sb, hb = fetch(b, path, cookie, netns)
        if sa != sb:
            differ.append((label, f"status {sa} on A, {sb} on B"))
        elif ha != hb:
            differ.append((label, f"status {sa} on both, the bodies differ"))
    return len(walked), differ


def report(n: int, differ: list) -> None:
    for label, what in differ:
        print(f"DIFFERS  {label}: {what}")
    print(f"compare_hosts: {n} pages, {n - len(differ)} identical, {len(differ)} different")


def main(argv) -> int:
    if len(argv) == 3 and argv[1] == "--self-test":
        return self_test(argv[2])
    args = argv[1:]
    opts = {"--uid": "1", "--secret": None, "--netns": None}
    for flag in list(opts):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                print(__doc__.strip(), file=sys.stderr)
                return 2
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 3 or not os.path.isdir(args[0]):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    secret = None
    if opts["--secret"]:
        with open(opts["--secret"], "rb") as f:
            secret = f.read()
    n, differ = compare(args[0], args[1], args[2], opts["--uid"], secret, opts["--netns"])
    report(n, differ)
    return 1 if differ else 0


# ── the self-test ───────────────────────────────────────────────────────────

def self_test(binary: str) -> int:
    """On the judge's staged site, with two Linux servers: identical copies
    compare identical, and a copy with one file changed is caught, in output
    that holds no name or word from the data."""
    sys.path.insert(0, os.path.join(ROOT, "probe"))
    import judge_gopher as G
    # angry-gopher's checkout: the folder above the binary that holds pages/.
    gopher_root = os.path.dirname(os.path.abspath(binary))
    while not os.path.isfile(os.path.join(gopher_root, "pages", "home.txt")):
        if gopher_root == os.path.dirname(gopher_root):
            print(f"self-test cannot run: no angry-gopher checkout above {binary}")
            return 2
        gopher_root = os.path.dirname(gopher_root)
    failures = []
    with tempfile.TemporaryDirectory() as d:
        site = os.path.join(d, "site")
        G.stage(site, gopher_root)
        # Data through the server's own front door, so the sidecars are its.
        cookie = mint_session(G.SESSION_SECRET, "1", int(time.time()))
        server = G.LinuxServer(binary, site, os.path.join(d, "fill.log"))
        try:
            base = f"http://127.0.0.1:{server.port}"
            for topic, words in (("secret-plans", "the+quiet+word"), ("Second-Topic", "another+line")):
                subprocess.run(["curl", "-sS", "-o", "/dev/null", "-H", f"Cookie: {cookie}",
                                "--data", f"topic={topic}", f"{base}/chat/c/1_2/new"], check=True)
                for k in range(2):
                    subprocess.run(["curl", "-sS", "-o", "/dev/null", "-H", f"Cookie: {cookie}",
                                    "-H", "X-Chat-Async: 1", "--data", f"markdown={words}+{k}&cid=c{k}",
                                    f"{base}/chat/c/1_2/{topic}/send"], check=True)
            subprocess.run(["curl", "-sS", "-o", "/dev/null", "-H", f"Cookie: {cookie}",
                            "--data", "msg=1&emoji=%F0%9F%91%8D",
                            f"{base}/chat/c/1_2/secret-plans/react"], check=True)
        finally:
            server.stop()
        G.write(site, "data/chat/users/1/docs/private-notes.md", "# private notes\nsomething only Steve wrote\n")

        copies = []
        for name in ("a", "b"):
            path = os.path.join(d, name)
            shutil.copytree(site, path)
            copies.append(path)

        def run(label):
            servers = [G.LinuxServer(binary, c, os.path.join(d, f"{label}-{i}.log")) for i, c in enumerate(copies)]
            try:
                urls = [f"http://127.0.0.1:{s.port}" for s in servers]
                got = compare(copies[0], *urls)
                # Pages that answered, not a session both refused alike: a
                # redirect to the login page on both would compare "identical".
                # Asked after the walk, and of both: a topic page moves the
                # user's bookmark, which other pages show.
                cookie = mint_session(G.SESSION_SECRET, "1", int(time.time()))
                for path in ("/chat/recent", "/chat/c/1_2/secret-plans", "/chat/c/1_2/secret-plans/raw",
                             "/chat/docs/private-notes", "/admin"):
                    for url in urls:
                        status, _ = fetch(url, path, cookie)
                        if status != "200":
                            failures.append(f"{path} answered {status}, not 200")
                return got
            finally:
                for s in servers:
                    s.stop()

        n, differ = run("same")
        if n < 15:
            failures.append(f"only {n} pages walked")
        if differ:
            failures.append(f"identical copies differ: {differ}")

        # One reaction more, on B only: that topic's reactions differ, and
        # nothing in the report names it.
        rx = os.path.join(copies[1], "data/chat/1_2/sessions/secret-plans.reactions.jsonl")
        with open(rx) as f:
            line = f.readline()
        with open(rx, "a") as f:
            f.write(line)
        n2, differ = run("changed")
        labels = [l for l, _ in differ]
        if not any(l.endswith("reactions") for l in labels):
            failures.append(f"the changed reactions were not found: {differ}")
        import io
        import contextlib
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            report(n2, differ)
        printed = out.getvalue()
        for secret_word in ("secret-plans", "Second-Topic", "quiet", "private-notes", "Steve", "apoorva", "1_2"):
            if secret_word in printed:
                failures.append(f"the report names {secret_word!r}")
    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print(f"self-test passed: {n} pages of two identical copies identical; a reaction added to one "
          f"copy found ({len(differ)} page(s) differ), and the report names nothing from the data")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
