#!/usr/bin/env python3
"""**THE WHOLE REHEARSAL, AS ONE COMMAND** (QUEUE.md item 59; MIGRATION.md,
CUTOVER.md steps 3-6 and 11). Run as `droplet/rehearse.sh`:

    droplet/rehearse.sh COPY [--fat 16|32] [--gib N] [--mount] [--no-writes]
    droplet/rehearse.sh --self-test

`COPY` is a copy of prod's data: a folder holding `data/` and `auth/`. It is
only read. For each FAT kind (both, unless `--fat` names one):

  1. **Check the copy** (check_volume_tree.py): anything that would not
     survive the volume is a NO-GO.
  2. **Build the volume** with mtools, no root (build_volume.py), and judge
     it with the readers that are not mtools: compare_volume.py against the
     copy, tools/fat16_read.py, fsck.fat. With `--mount`, it is built a
     second time through Linux's own vfat driver (the judge's build_disk,
     which needs `sudo -n`), and both are compared with the copy.
  3. **Boot metal on it**: probe/gopher.elf on the droplet's machine
     (droplet.sh), its site on the boot disk built here, the volume
     attached on the SCSI controller and named by its serial, serving on
     the private card, forwarded to 127.0.0.1 only. Its boot must say
     `chat's data: the volume` and pass both disk checks.
  4. **Start Linux on another copy**, inside a network namespace of its
     own (`ip netns`), listening on that namespace's loopback: prod's data
     is never on a port anyone else can reach.
  5. **Compare** (compare_hosts.py), read-only, then with `--writes`
     (unless `--no-writes`).

It prints counts and anonymised labels only, as the tools it runs do:
nothing from the copy is named. It stops every process it started and
removes the namespace and every file it made, whatever happens.

Needs: sgdisk, mkfs.vfat, mtools, fsck.fat, qemu-system-x86_64, ip (and
sudo -n for `--mount`, root for `ip netns`). Uses KVM when /dev/kvm is
usable and says when it is not (`ACCEL=tcg`: slow, but the same machine).

Exit 0 when every step is GO for every kind, 1 at the first NO-GO, 2 for a
usage error.
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
import build_volume  # noqa: E402
import check_volume_tree  # noqa: E402
import judge_gopher as G  # noqa: E402

GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
ELF = os.path.join(ROOT, "probe", "gopher.elf")
NETNS = f"gm-rehearse-{os.getpid()}"
LINUX_PORT = 9101
DEFAULT_GIB = {16: 1, 32: 3}  # FAT32 needs 65,525 clusters: 3 GiB at 32 KiB


class NoGo(Exception):
    pass


def say(step: str, verdict: str, detail: str = "") -> None:
    print(f"{verdict:5} {step}" + (f": {detail}" if detail else ""), flush=True)


def site_partition(scratch: str, serial: str) -> str:
    """The boot disk's site partition, as chat.py makes it but with mtools:
    the site's own files (the judge's staged pages, and gallery/) and a
    gopher-metal.conf serving the private card and naming the volume."""
    content = os.path.join(scratch, "site")
    G.stage(content, GOPHER_ROOT)
    for d in G.DATA_DIRS:
        shutil.rmtree(os.path.join(content, d), ignore_errors=True)
    gallery = os.path.join(GOPHER_ROOT, "gallery")
    if os.path.isdir(gallery):
        shutil.copytree(gallery, os.path.join(content, "gallery"))
    with open(os.path.join(content, "gopher-metal.conf"), "w") as f:
        f.write(f"idle_timeout_ms = 10000\ncard = private\nvolume = {serial}\n")
    fat = os.path.join(scratch, "site.fat")
    subprocess.run(["mkfs.vfat", "-F", "16", "-S", "512", "-n", "SITE", "-C", fat, str(64 * 1024)],
                   check=True, capture_output=True)
    env = dict(os.environ, TZ="UTC", MTOOLS_SKIP_CHECK="1")
    for top in sorted(os.listdir(content)):
        subprocess.run(["mcopy", "-s", "-m", "-i", fat, os.path.join(content, top), "::/"],
                       check=True, capture_output=True, env=env)
    return fat


def linux_site(scratch: str, copy: str) -> str:
    """Another copy, with the site's own files beside it, for the Linux
    server's working folder."""
    root = os.path.join(scratch, "linux")
    G.stage(root, GOPHER_ROOT)
    for d in G.DATA_DIRS:
        shutil.rmtree(os.path.join(root, d), ignore_errors=True)
        shutil.copytree(os.path.join(copy, d), os.path.join(root, d))
    gallery = os.path.join(GOPHER_ROOT, "gallery")
    if os.path.isdir(gallery):
        shutil.copytree(gallery, os.path.join(root, "gallery"))
    with open(os.path.join(root, "gopher.conf"), "w") as f:
        f.write("data_dir = data\nauth_dir = auth\n")
    return root


class Started:
    """Every process and namespace this run made, undone by `stop`."""

    def __init__(self):
        self.procs, self.netns = [], None

    def stop(self):
        for p in self.procs:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
        self.procs = []
        if self.netns:
            subprocess.run(["ip", "netns", "del", self.netns], capture_output=True)
            self.netns = None


def wait_for(path: str, words, proc, seconds: float) -> str:
    deadline = time.time() + seconds
    while time.time() < deadline:
        with open(path, "rb") as f:
            text = f.read().decode("latin-1")
        if any(w in text for w in words) or proc.poll() is not None:
            return text
        time.sleep(0.2)
    with open(path, "rb") as f:
        return f.read().decode("latin-1")


def boot_metal(started: Started, scratch: str, volume: str, serial: str) -> int:
    """Boots metal on the droplet's machine; answers the forwarded port."""
    boot = os.path.join(scratch, "boot.img")
    made = subprocess.run([os.path.join(HERE, "image.sh"), ELF, boot, site_partition(scratch, serial)],
                          capture_output=True, text=True)
    if made.returncode != 0:
        raise NoGo(f"the boot image would not build: {made.stdout.strip()[-200:]}")
    port = G.free_port()
    accel = "kvm" if G.kvm_usable() else "tcg"
    env = dict(os.environ, DISK=boot, VOLUME=volume, PRIVATE_FWD=str(port), MEMORY="1024",
               NO_DOOR="1", ACCEL=accel)
    log = os.path.join(scratch, "metal.serial")
    with open(log, "wb") as out:
        q = subprocess.Popen([os.path.join(HERE, "droplet.sh")], env=env, stdout=out, stderr=subprocess.STDOUT)
    started.procs.append(q)
    text = wait_for(log, ["listening on port 80", "stopped", "PANIC", "FAIL"], q,
                    120 if accel == "kvm" else 600)
    if "listening on port 80" not in text:
        tail = " | ".join(line for line in text.splitlines()[-3:])
        raise NoGo(f"metal did not come up ({accel}): {tail[-300:]}")
    needed = ["chat's data: the volume", f"its serial: {serial}"]
    missing = [n for n in needed if n not in text]
    checks = [line for line in text.splitlines() if "disk check" in line]
    if missing or len(checks) < 2 or any(" 0 problems" not in c for c in checks):
        raise NoGo(f"metal's boot: missing {missing}, disk checks {len(checks)} "
                   f"({sum(' 0 problems' in c for c in checks)} clean)")
    say("metal", "GO", f"booted ({'KVM' if accel == 'kvm' else 'TCG: no KVM here'}), serving the volume "
                       f"{serial}, both disk checks clean")
    return port


def start_linux(started: Started, scratch: str, copy: str) -> None:
    root = linux_site(scratch, copy)
    binary = os.path.join(GOPHER_ROOT, "zig-server", "zig-out", "bin", "zig-server")
    if not os.path.isfile(binary):
        raise NoGo(f"no Linux build at {binary}: run `zig build` in zig-server/")
    for cmd in (["ip", "netns", "add", NETNS], ["ip", "netns", "exec", NETNS, "ip", "link", "set", "lo", "up"]):
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise NoGo(f"`{' '.join(cmd[:4])}` failed: {r.stderr.strip()}")
        started.netns = NETNS
    env = dict(os.environ, GOPHER_CONFIG=os.path.join(root, "gopher.conf"), GOPHER_PORT=str(LINUX_PORT),
               GOPHER_BIND="127.0.0.1", GOPHER_GAME_FLOOR="off")
    log = open(os.path.join(scratch, "linux.log"), "wb")
    p = subprocess.Popen(["ip", "netns", "exec", NETNS, binary], cwd=root, env=env, stdout=log, stderr=log)
    started.procs.append(p)
    deadline = time.time() + 30
    while time.time() < deadline:
        r = subprocess.run(["ip", "netns", "exec", NETNS, "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                            f"http://127.0.0.1:{LINUX_PORT}/version"], capture_output=True, text=True)
        if r.stdout == "200":
            say("Linux", "GO", f"serving another copy inside namespace {NETNS}, on its loopback only")
            return
        time.sleep(0.2)
    raise NoGo("the Linux server did not answer inside its namespace")


def compare(copy: str, metal_port: int, writes: bool) -> None:
    for extra in ([], ["--writes"]) if writes else ([],):
        r = subprocess.run([sys.executable, os.path.join(HERE, "compare_hosts.py"), copy,
                            f"http://127.0.0.1:{metal_port}", f"http://127.0.0.1:{LINUX_PORT}",
                            "--netns", NETNS, *extra], capture_output=True, text=True)
        out = r.stdout.strip().splitlines()
        for line in out[:-1]:
            print(f"      {line}")
        label = "compare, with --writes" if extra else "compare, read-only"
        say(label, "GO" if r.returncode == 0 else "NO-GO", out[-1] if out else r.stderr.strip()[-200:])
        if r.returncode != 0:
            raise NoGo("the two hosts differ")


def rehearse(copy: str, fat: int, gib: int, mount: bool, writes: bool) -> None:
    size = gib << 30
    print(f"── FAT{fat}, {gib} GiB ──", flush=True)
    findings, summary = check_volume_tree.check(copy, volume=size, fat=fat)
    if findings:
        rules = {}
        for f in findings:
            rules[f.rule] = rules.get(f.rule, 0) + 1
        say("check the copy", "NO-GO", ", ".join(f"{n} {r}" for r, n in sorted(rules.items())) +
            " (droplet/check_volume_tree.py names them)")
        raise NoGo("the copy")
    say("check the copy", "GO", f"{summary['files']} files, {summary['directories']} folders, nothing found")
    started = Started()
    scratch = tempfile.mkdtemp(prefix="rehearse-")
    try:
        volume = os.path.join(scratch, "volume.img")
        try:
            serial = build_volume.build(copy, volume, fat=fat, size=size, check=False)
        except build_volume.Refused as e:
            say("build the volume", "NO-GO", str(e))
            raise NoGo("the volume")
        problems = build_volume.judge(copy, volume)
        if problems:
            say("build the volume", "NO-GO", f"{len(problems)} problem(s) found by the readers that are not mtools")
            raise NoGo("the volume")
        say("build the volume", "GO", f"mtools, serial {serial}; compare_volume, fat16_read and fsck.fat agree")
        if mount:
            other = os.path.join(scratch, "volume-mount.img")
            G.build_disk(other, copy, os.path.join(scratch, "mnt"), size=size, fat=str(fat),
                         cluster_sectors=build_volume.FAT32_CLUSTER_SECTORS if fat == 32 else None)
            problems = build_volume.judge(copy, other)
            say("build it through Linux's vfat", "GO" if not problems else "NO-GO",
                f"{len(problems)} problem(s)" if problems else "the same tree, by the same readers")
            if problems:
                raise NoGo("the mounted volume")
        port = boot_metal(started, scratch, volume, serial)
        start_linux(started, scratch, copy)
        compare(copy, port, writes)
    finally:
        started.stop()
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv) -> int:
    if argv[1:2] == ["--self-test"]:
        return self_test()
    args = argv[1:]
    flags = {"--mount": False, "--no-writes": False}
    for flag in flags:
        if flag in args:
            flags[flag] = True
            args.remove(flag)
    fats, gib = [16, 32], None
    for opt in ("--fat", "--gib"):
        if opt in args:
            i = args.index(opt)
            if i + 1 >= len(args):
                print(__doc__.strip(), file=sys.stderr)
                return 2
            if opt == "--fat":
                fats = [int(args[i + 1])]
            else:
                gib = int(args[i + 1])
            del args[i:i + 2]
    if len(args) != 1 or not all(os.path.isdir(os.path.join(args[0], d)) for d in ("data", "auth")):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if not os.path.isfile(ELF):
        print(f"rehearse: no {ELF}: ./port.sh && zig build gopher")
        return 2
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))  # so `finally` runs
    try:
        for fat in fats:
            rehearse(args[0], fat, gib or DEFAULT_GIB[fat], flags["--mount"], not flags["--no-writes"])
    except NoGo as e:
        print(f"rehearse: NO-GO at {e}")
        return 1
    print(f"rehearse: GO for FAT{' and FAT'.join(str(f) for f in fats)}")
    return 0


def self_test() -> int:
    """The judge's staged site, with a conversation written through the
    server's own front door, rehearsed end to end on both kinds; then a copy
    holding a name the volume cannot take, which must stop at step 1."""
    with tempfile.TemporaryDirectory() as d:
        site = os.path.join(d, "site")
        G.stage(site, GOPHER_ROOT)
        binary = os.path.join(GOPHER_ROOT, "zig-server", "zig-out", "bin", "zig-server")
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
        whole = subprocess.run([sys.executable, __file__, copy], capture_output=True, text=True)
        print(whole.stdout, end="")
        bad = os.path.join(d, "bad")
        shutil.copytree(copy, bad)
        with open(os.path.join(bad, "data", "chat", "a:b"), "w") as f:
            f.write("a name FAT cannot hold")
        refused = subprocess.run([sys.executable, __file__, bad, "--fat", "16"], capture_output=True, text=True)
        leftovers = subprocess.run(["ip", "netns", "list"], capture_output=True, text=True).stdout
    failures = []
    if whole.returncode != 0 or whole.stdout.count("GO    compare") < 4:
        failures.append(f"the staged site did not rehearse GO on both kinds (exit {whole.returncode})")
    if refused.returncode != 1 or "NO-GO check the copy" not in refused.stdout:
        failures.append(f"a name FAT cannot hold was not stopped at step 1: {refused.stdout[-300:]}")
    if "a:b" in whole.stdout + refused.stdout or "rehearsal" in whole.stdout:
        failures.append("the output names something from the copy")
    if "gm-rehearse-" in leftovers:
        failures.append("a namespace was left behind")
    if failures:
        print("self-test FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("self-test passed: the staged site rehearsed GO on FAT16 and FAT32 (metal on the droplet's machine, "
          "Linux in its own namespace, compared read-only and with writes), a bad name stopped at the check, "
          "nothing named and nothing left behind")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
