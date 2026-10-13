"""Dog Park's judge: the same requests to Dog Park's play server on Linux and
to probe/dogpark.elf on a QEMU machine, and every answer, and every file left
on the data disk, must be the same.

**ONE BOOT, ONE STORY.** The kernel serves exactly the story's requests and
stops; the Linux server serves the same requests from a folder laid out as
the disk is. Then a second boot (and a second Linux start) on what the first
left behind: what a human set must still be there. Both hosts start from the
same signing secret, so a cookie minted here is honoured by both and the
answers carry no randomness but a stranger's new cookie, which is compared by
its shape and then used.

Builds both (the build is timed apart from the judge) and runs from
zig-metal-unikernel's root:

    python3 probe/judge_dogpark.py

DOGPARK_ROOT names the checkout (default ../dog-park). Exits non-zero on any
difference.
"""
import base64
import hashlib
import hmac
import http.client
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import judge_gopher as j  # noqa: E402

GM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOGPARK = os.path.abspath(os.environ.get("DOGPARK_ROOT", os.path.join(GM, "..", "dog-park")))
# **ONE webbox ON BOTH SIDES.** The kernel takes webbox from -Dwebbox-root,
# Dog Park's Linux build from its build.zig.zon's ../zig-webbox: the judge
# refuses to compare two hosts built on two different libraries.
GOPHER_ROOT = os.path.realpath(os.environ.get("GOPHER_ROOT", os.path.join(GM, "..", "angry-gopher")))
WEBBOX_ROOT = os.path.realpath(os.environ.get("WEBBOX_ROOT", os.path.join(GM, "..", "zig-webbox")))
ELF = os.path.join(GM, "probe", "dogpark.elf")
LINUX = os.path.join(DOGPARK, "zig-out", "bin", "dog-park-play")

# webbox's site_secret: at least 32 bytes, read as they are.
SECRET = b"dog park judge secret, 32+ bytes of it, the same on both hosts"
# app.zig's human_cookie, in webbox's signed.zig format.
COOKIE_NAME = "dogpark_human"
COOKIE_LABEL = b"dogpark_human\n"
ALICE = "a11ce" + "0" * 27
BOB = "b0b" + "0" * 29


def mint(human: str, issued: int) -> str:
    mac = hmac.new(SECRET, COOKIE_LABEL + human.encode() + b"\n" + str(issued).encode(), hashlib.sha256).digest()
    return f"{COOKIE_NAME}={human}.{issued}.{base64.urlsafe_b64encode(mac).rstrip(b'=').decode()}"


def site_dirs() -> list:
    """assets.zon's .site: what the play server reads at request time."""
    text = open(os.path.join(DOGPARK, "assets.zon")).read()
    m = re.search(r"\.site\s*=\s*\.\{([^}]*)\}", text)
    if not m:
        raise SystemExit(f"{DOGPARK}/assets.zon names no .site")
    return re.findall(r'"([^"]+)"', m.group(1))


def content(root: str) -> None:
    """What either host starts from: the site's directories, an empty data
    folder (the dogs are laid out at the first start), and the secret."""
    for d in site_dirs():
        shutil.copytree(os.path.join(DOGPARK, d), os.path.join(root, d))
    os.makedirs(os.path.join(root, "data"))
    os.makedirs(os.path.join(root, "auth"))
    with open(os.path.join(root, "auth", "_session_secret"), "wb") as f:
        f.write(SECRET)


# A step: (name, method, path, who, body). `who` is None (no cookie), ALICE or
# BOB (minted here), or "stranger" (the cookie this host's /me handed out).
J = "application/json"
FIRST = [
    ("the page", "GET", "/", None, None),
    ("its script", "GET", "/park.js", None, None),
    ("the cows' rule", "GET", "/cows.wasm", None, None),
    ("nowhere", "GET", "/nowhere", None, None),
    ("the page by POST", "POST", "/", None, b""),
    ("/me by POST", "POST", "/me", ALICE, b""),
    ("/leash by GET", "GET", "/leash", ALICE, None),
    ("tiles as no one", "POST", "/tiles", None, b'{"tiles":[]}'),
    ("a stranger arrives", "GET", "/me", None, None),
    ("the stranger, known", "GET", "/me", "stranger", None),
    ("Alice, first sight", "GET", "/me", ALICE, None),
    ("Alice's viewport", "POST", "/viewport", ALICE, b'{"park_x":1200,"park_y":700}'),
    ("Alice's tiles", "POST", "/tiles", ALICE, b'{"tiles":[{"col":0,"row":0,"is":"new"},{"col":1,"row":0,"is":"new"}]}'),
    ("Alice's tiles, one held", "POST", "/tiles", ALICE, b'{"tiles":[{"col":0,"row":0,"is":"held"},{"col":1,"row":1,"is":"new"}]}'),
    ("a tile outside", "POST", "/tiles", ALICE, b'{"tiles":[{"col":10,"row":0,"is":"new"}]}'),
    ("too many tiles", "POST", "/tiles", ALICE,
     ('{"tiles":[' + ",".join(f'{{"col":{i % 10},"row":{i // 10},"is":"new"}}' for i in range(26)) + "]}").encode()),
    ("a body that does not read", "POST", "/tiles", ALICE, b'{"tiles":'),
    ("Alice leashes 0", "POST", "/leash", ALICE, b'{"dog":0}'),
    ("Alice leashes 1", "POST", "/leash", ALICE, b'{"dog":1}'),
    ("Bob wants 1", "POST", "/leash", BOB, b'{"dog":1}'),
    ("no such dog", "POST", "/leash", BOB, b'{"dog":100000}'),
    # Dog 0 at (155, 350) heads for cow 0 at (250, 250): the cow steps aside.
    ("Alice's dog scares a cow", "POST", "/move", ALICE, b'{"dog":0,"path":[[165,340]]}'),
    ("Alice drags 1 along a path", "POST", "/move", ALICE, b'{"dog":1,"path":[[360,160],[372,171],[385,180],[399,191]]}'),
    ("Alice moves 1", "POST", "/move", ALICE, b'{"dog":1,"path":[[2345,1234]]}'),
    ("a move outside", "POST", "/move", ALICE, b'{"dog":1,"path":[[-5,10]]}'),
    ("a move with no path", "POST", "/move", ALICE, b'{"dog":1,"path":[]}'),
    ("a path past 100 points", "POST", "/move", ALICE,
     ('{"dog":1,"path":[' + ",".join(f"[{2000 + i},1234]" for i in range(101)) + "]}").encode()),
    ("Bob releases 1", "POST", "/release", BOB, b'{"dog":1}'),
    ("Alice, again", "GET", "/me", ALICE, None),
    ("Alice releases 1", "POST", "/release", ALICE, b'{"dog":1}'),
]
# After a restart: the viewport came back from disk, the leash (memory only)
# did not, and the moved dog stands where it was left.
SECOND = [
    ("Alice, after a restart", "GET", "/me", ALICE, None),
    ("Bob, after a restart", "GET", "/me", BOB, None),
    ("the moved dog's tile", "POST", "/tiles", BOB, b'{"tiles":[{"col":4,"row":2,"is":"new"}]}'),
]
COMPARED_HEADERS = ("content-type", "allow", "cache-control")
STRANGER = re.compile(r"^dogpark_human=([0-9a-f]{32})\.(\d+)\.[A-Za-z0-9_-]{43}; Path=/; Max-Age=31536000; "
                      r"HttpOnly; Secure; SameSite=Lax$")


def ask(port: int, steps: list) -> list:
    issued = int(time.time())
    cookies = {ALICE: mint(ALICE, issued), BOB: mint(BOB, issued)}
    answers = []
    for name, method, path, who, body in steps:
        headers = {"Host": "dogpark"}
        if who is not None:
            if who not in cookies:
                answers.append({"error": f"no cookie for {who}"})
                continue
            headers["Cookie"] = cookies[who]
        if body is not None:
            headers["Content-Type"] = J
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
            c.request(method, path, body=body, headers=headers)
            r = c.getresponse()
            data = r.read()
            c.close()
        except Exception as e:  # noqa: BLE001
            answers.append({"error": f"{type(e).__name__}: {e}"})
            continue
        a = {"status": r.status, "body": data,
             "headers": {h: r.getheader(h) for h in COMPARED_HEADERS}, "set-cookie": r.getheader("set-cookie")}
        m = STRANGER.match(a["set-cookie"] or "")
        if m:
            cookies["stranger"] = a["set-cookie"].split(";")[0]
            a["set-cookie"] = "<a new human's cookie>"
        answers.append(a)
    return answers


def data_files(root: str) -> dict:
    out = {}
    for d, _, files in os.walk(os.path.join(root, "data")):
        for f in files:
            p = os.path.join(d, f)
            out[os.path.relpath(p, root).lower()] = open(p, "rb").read()
    return out


def on_metal(image: str, work: str, steps: list) -> tuple:
    mnt = os.path.join(work, "mnt")
    j.set_request_limit(image, len(steps), mnt)
    qemu, port, serial = j.start_kernel(ELF, image, work)
    try:
        answers = ask(port, steps)
    finally:
        code, log = j.finish_kernel(qemu, serial)
    taken = os.path.join(work, "taken")
    shutil.rmtree(taken, ignore_errors=True)
    j.disk_take(image, mnt, taken, names=["data", "DATA"])
    return answers, data_files(taken), code, log


def on_linux(root: str, steps: list, log: str) -> tuple:
    """The play server started in `root` (no DOGPARK_CONFIG: its data/ and
    auth/ there, as the kernel's are on the disk), asked, and stopped."""
    port = j.free_port()
    env = dict(os.environ, DOGPARK_PORT=str(port))
    env.pop("DOGPARK_CONFIG", None)
    with open(log, "wb") as out:
        proc = subprocess.Popen([LINUX], cwd=root, env=env, stdout=out, stderr=subprocess.STDOUT)
        try:
            deadline = time.time() + 20
            while True:
                try:
                    j.socket.create_connection(("127.0.0.1", port), timeout=1).close()
                    break
                except OSError:
                    if proc.poll() is not None or time.time() > deadline:
                        raise SystemExit(f"the Linux server never listened (exit {proc.poll()}): {log}")
                    time.sleep(0.02)
            answers = ask(port, steps)
        finally:
            proc.terminate()
            proc.wait(timeout=10)
    return answers, data_files(root)


def compare(label: str, steps: list, metal: list, linux: list) -> list:
    out = []
    for (name, method, path, _, _), m, l in zip(steps, metal, linux):
        if "error" in m or "error" in l:
            out.append(f"{label} {name} ({method} {path}): metal {m.get('error', m.get('status'))}, "
                       f"Linux {l.get('error', l.get('status'))}")
            continue
        for k in ("status", "set-cookie", "headers"):
            if m[k] != l[k]:
                out.append(f"{label} {name} ({method} {path}): {k} differs: metal {m[k]!r}, Linux {l[k]!r}")
        if m["body"] != l["body"]:
            out.append(f"{label} {name} ({method} {path}): the body differs: {j.first_difference(m['body'], l['body'])}")
    return out


def files_compare(label: str, metal: dict, linux: dict) -> list:
    out = []
    for rel in sorted(set(metal) | set(linux)):
        if metal.get(rel) != linux.get(rel):
            out.append(f"{label} {rel}: metal {j.abbrev(metal.get(rel))}, Linux {j.abbrev(linux.get(rel))}")
    return out


def main() -> int:
    linux_webbox = os.path.realpath(os.path.join(DOGPARK, "..", "zig-webbox"))
    if linux_webbox != WEBBOX_ROOT:
        print(f"FAIL dogpark | the kernel's webbox is {WEBBOX_ROOT}, the Linux build's {linux_webbox} "
              "(dog-park's build.zig.zon): not one library")
        return 1
    t0 = time.time()
    # Dog Park's first: it makes zig-out/web/cows.wasm, which the kernel
    # compiles in (its assets.zon's `.embedded`).
    for cmd, cwd in ((["zig", "build"], DOGPARK),
                     (["zig", "build", "dogpark", f"-Ddogpark-root={DOGPARK}", f"-Dgopher-root={GOPHER_ROOT}", f"-Dwebbox-root={WEBBOX_ROOT}"], GM)):
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"{' '.join(cmd)} in {cwd} failed:\n{r.stderr[-3000:]}")
            return 1
    print(f"time: build {time.time() - t0:.0f} s")
    t1 = time.time()
    work = tempfile.mkdtemp(prefix="judge-dogpark-")
    start = os.path.join(work, "content")
    content(start)
    image = os.path.join(work, "disk.img")
    j.build_disk(image, start, os.path.join(work, "mnt"))
    linux_root = os.path.join(work, "linux")
    shutil.copytree(start, linux_root)

    problems = []
    seen = {}
    for label, steps in (("first boot:", FIRST), ("after a restart:", SECOND)):
        metal, metal_files, code, log = on_metal(image, work, steps)
        linux, linux_files = on_linux(linux_root, steps, os.path.join(work, f"linux-{len(seen)}.log"))
        if code != 1:  # isa-debug-exit's 1: stopped at its request limit, as the chat judge expects
            problems.append(f"{label} the kernel exited {code!r}, not at its limit of {len(steps)} requests ({work}/serial)")
        problems += compare(label, steps, metal, linux)
        problems += files_compare(label, metal_files, linux_files)
        seen[label] = (metal, linux_files)
    problems += [f"disk check: {d}" for d in j.DISK_CHECK_FAILURES]

    # What the story is for, said on the Linux side (the comparison carries it
    # to metal): the restart kept the viewport and the move, not the leash.
    # Dog 0 moves (10, -10), east then north (dog-park's cows.zig: a police
    # car on a grid). Cow 0, at (250, 250), is ahead of it both ways and out
    # of its lanes: the east part moves it north half as far, 5 px, the north
    # part east 5 px. Half pixels.
    first = dict(zip([st[0] for st in FIRST], seen["first boot:"][0]))
    scare = first["Alice's dog scares a cow"].get("body")
    if scare != b'{"moved":0,"park_x":165,"park_y":340,"cows":[{"id":0,"half_x":510,"half_y":490}]}':
        problems.append(f"first boot: dog 0's move did not step cow 0 to half pixels (510, 490): {scare!r}")
    after = seen["after a restart:"][0]
    if after and after[0].get("body") != b'{"viewport":{"at":{"park_x":1200,"park_y":700}},"leash":{"none":{}}}':
        problems.append(f"after a restart: Alice's /me is {after[0].get('body')!r}, not her kept viewport and no leash")
    if after and b'{"id":1,"emoji":' not in after[2].get("body", b"") or b'"park_x":2345,"park_y":1234}' not in after[2].get("body", b""):
        problems.append(f"after a restart: dog 1 is not at (2345, 1234) on its tile: {j.abbrev(after[2].get('body'))}")

    steps = len(FIRST) + len(SECOND)
    for p in problems:
        print("FAIL", p)
    verdict = "FAIL" if problems else "PASS"
    print(f"{verdict} dogpark | {steps} requests over two boots, and the data they left, "
          f"{'answered as Linux answered' if not problems else f'{len(problems)} differences'} ({time.time() - t1:.0f} s)")
    if not problems:
        shutil.rmtree(work)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
