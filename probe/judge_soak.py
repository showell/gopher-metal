#!/usr/bin/env python3
"""**THE LONG BOOT.** One kernel, thousands of requests, reads and writes mixed,
and nobody watching.

The stories prove this machine answers as Linux answers. The stamina boot proves
300 reads do not move its heaps. Neither of them answers the question that
decides whether a thing can be deployed: *does it still work in an hour?*

So this one boots once and keeps going, and asks four things the whole way:

  1. **Is anything lost?** Every round writes a numbered mark to chat's
     transcript and to a game session. Every tenth round reads the whole
     transcript back and requires marks that are thousands of requests old to
     still be in it — and at the end the FAT16 volume is read by the LINUX
     driver, not by ours, and must hold every mark that was ever written.
  2. **Is memory reclaimed?** The kernel reports, after every request, what its
     allocator holds and the most it has ever held. The peak must stop rising.
  3. **Does it slow down?** Rounds per second, reported as it goes. A machine
     whose directory walk is linear in the number of files gets slower; one
     whose allocator fragments gets slower.
  4. **Is the filesystem still sound?** fsck.vfat at the end, and the answer
     bodies must keep growing as the transcript does.

Run it through `probe/run.sh soak`. It takes as long as it takes — the point is
that it is longer than anything that could pass by accident.
"""

import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import judge_gopher as J  # noqa: E402

# How many rounds. Each is three requests, plus a transcript read every tenth.
ROUNDS = int(os.environ.get("SOAK_ROUNDS", "2000"))
# How often the whole transcript is read back and checked.
EVERY = 10
# How often to say where it has got to.
REPORT = 100


def mark(n: int) -> bytes:
    return f"soak-{n:06d}".encode()


def plan(rounds: int) -> int:
    """How many requests the kernel will be asked for — it is told exactly, and
    stops when it has served them, so this has to be right."""
    return 1 + rounds * 2 + rounds // EVERY


# **CHAT, NOT THE GAME.** Lyn Rummy stays on the Linux droplet; what this
# machine is a candidate for is chat. So the writes are chat's and the reads
# rotate through what a chat client actually asks for: the index, the activity
# page (which stats every conversation — the walk that gets slower as the store
# grows), the conversation list, and the 27 KB PDF off the volume, which is the
# one read whose cost should NOT move as the store grows and is therefore the
# control.
reads = [
    lambda n: J.step(f"index {n}", "GET", "/", J.JAR),
    lambda n: J.step(f"recent {n}", "GET", "/chat/recent", J.JAR),
    lambda n: J.step(f"conversations {n}", "GET", "/chat/conversations", J.JAR),
    lambda n: J.step(f"the pdf {n}", "GET", "/steve-resume.pdf", J.JAR),
]


def sample(n: int, rand) -> list:
    """Marks to look for in a transcript that has `n` of them: the newest few,
    the oldest few, and a handful from the middle. Checking all of them every
    time is quadratic, and the ones that matter are the old ones — a store that
    loses the beginning is the failure this is looking for."""
    want = {i for i in (1, 2, n, n - 1, n // 2) if 1 <= i <= n}
    while len(want) < min(12, n):
        want.add(rand.randint(1, n))
    return [mark(i) for i in sorted(want)]


def soak(elf: str, gopher_root: str, work: str) -> int:
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    content = os.path.join(work, "content")
    J.stage(content, gopher_root)
    image = os.path.join(work, "soak.img")
    mnt = os.path.join(work, "mnt")
    J.build_disk(image, content, mnt)
    total = plan(ROUNDS)
    J.set_request_limit(image, total, mnt)

    scratch = os.path.join(work, "asks")
    os.makedirs(scratch)
    rand = random.Random(20260917)

    print(f"soak: {ROUNDS} rounds, {total} requests, one boot", flush=True)
    qemu, port, serial = J.start_kernel(elf, image, scratch)
    began = time.time()
    failures = 0
    jar = {}
    last_len = 0
    asked = 0
    # **WHAT EACH KIND OF REQUEST COSTS, AND HOW THAT MOVES.** A cumulative
    # rate hides a curve: the first soak read 34 req/s at round 100 and 11 at
    # round 1500, which is an average of a machine that had already fallen to
    # four. So these are per window, and reset each time they are reported —
    # and the PDF is in the list as a control, because its cost has no reason
    # to move at all.
    cost, seen_of = {}, {}
    window_began = time.time()
    window_asked = 0

    def send(s):
        nonlocal asked
        asked += 1
        return J.ask(port, J.with_jar(s, jar, None), scratch, patience=120)

    answer = send(J.step("log in", "POST", "/login/full", None,
                         "name=Steve&password=correct+horse+battery+staple&action=login&next=%2Fchat"))
    jar = J.update_jar(answer, jar)
    if answer.get("status") not in (200, 303):
        print(f"FAIL soak: could not log in: {answer.get('status', answer.get('error'))}")
        return 1

    for n in range(1, ROUNDS + 1):
        tag = mark(n).decode()
        for kind, s in (
            ("send", J.step(f"send {n}", "POST", "/chat/c/1_2/general/send", J.JAR,
                            f"markdown={tag}&cid=s{n}", headers=["X-Chat-Async: 1"])),
            (("index", "recent", "conversations", "pdf")[n % len(reads)], reads[n % len(reads)](n)),
        ):
            began_step = time.time()
            a = send(s)
            cost[kind] = cost.get(kind, 0.0) + (time.time() - began_step)
            seen_of[kind] = seen_of.get(kind, 0) + 1
            jar = J.update_jar(a, jar)
            # 204 is what an async send answers, and 303 what a form post
            # answers. Anything else — including a 500 the machine survived —
            # is a failure worth stopping for.
            if a.get("status") not in (200, 201, 204, 303):
                failures += 1
                print(f"FAIL soak: round {n}: {s['name']} answered "
                      f"{a.get('status', a.get('error'))}", flush=True)
                if failures > 5:
                    print("FAIL soak: giving up after six failures", flush=True)
                    break

        if n % EVERY == 0:
            began_step = time.time()
            a = send(J.step(f"transcript {n}", "GET", "/chat/c/1_2/general/raw", J.JAR))
            cost["transcript"] = cost.get("transcript", 0.0) + (time.time() - began_step)
            seen_of["transcript"] = seen_of.get("transcript", 0) + 1
            body = a.get("body")
            if body is None:
                failures += 1
                print(f"FAIL soak: round {n}: the transcript did not come back "
                      f"({a.get('error')})", flush=True)
            else:
                gone = [m for m in sample(n, rand) if m not in body]
                if gone:
                    failures += 1
                    print(f"FAIL soak: round {n}: {len(gone)} marks missing from a "
                          f"{len(body)}-byte transcript, first {gone[0].decode()}", flush=True)
                # A transcript that stops growing is one that stopped recording.
                if len(body) <= last_len:
                    failures += 1
                    print(f"FAIL soak: round {n}: the transcript is {len(body)} bytes, "
                          f"and was {last_len} ten rounds ago", flush=True)
                last_len = len(body)

        if n % REPORT == 0:
            log = open(serial, "rb").read().decode("latin-1", "replace")
            peaks = J.base_heap_peak(log)
            live = J.base_heap_trace(log)
            heaps = J.request_heap_trace(log)
            elapsed = time.time() - began
            window = time.time() - window_began
            each = "  ".join(
                f"{k} {1000 * cost[k] / seen_of[k]:.0f}ms"
                for k in ("send", "index", "recent", "conversations", "pdf", "transcript")
                if seen_of.get(k))
            # And what the KERNEL says, for the same window: the harness is on
            # the other side of these numbers, so a gap between them is the
            # cost of everything that is not the server.
            timings = J.request_timings(log)[-(asked - window_asked):]
            answered = sorted(t[1] for t in timings) or [0]
            waited = sorted(t[0] for t in timings) or [0]
            disk_n = sorted(t[2] for t in timings) or [0]
            disk_us = sorted(t[3] for t in timings) or [0]
            kernel = (f"kernel: answered median {answered[len(answered) // 2] / 1000:.1f}ms "
                      f"worst {answered[-1] / 1000:.1f}ms; "
                      f"disk median {disk_n[len(disk_n) // 2]} requests "
                      f"{disk_us[len(disk_us) // 2] / 1000:.1f}ms; "
                      f"waiting for the client median {waited[len(waited) // 2] / 1000:.1f}ms")
            print(f"  round {n:>6}  {asked:>6} req  {elapsed / 60:6.1f} min  "
                  f"{(asked - window_asked) / max(window, 0.001):5.1f} req/s now  "
                  f"live {live[-1] if live else '?'}  peak {peaks[-1] if peaks else '?'}  "
                  f"heap {max(heaps[-30:]) if heaps else '?'}  transcript {last_len}\n"
                  f"          harness: {each}\n"
                  f"          {kernel}", flush=True)
            cost, seen_of = {}, {}
            window_began, window_asked = time.time(), asked
        if failures > 5:
            break

    # **THE KERNEL WAS TOLD EXACTLY HOW MANY REQUESTS TO SERVE**, and stops when
    # it has. If it is short — a curl retry that never reached it, a connection
    # it dropped — it would sit waiting for a caller that is not coming, and
    # `finish_kernel` would kill it after a minute and call that a failure of
    # the soak rather than of the arithmetic. So the tail is made up with
    # requests that cost nothing, and a kernel needing more than a handful of
    # them is itself worth seeing.
    drained = 0
    while drained < 100:
        seen = len(J.base_heap_peak(open(serial, "rb").read().decode("latin-1", "replace")))
        if seen >= total:
            break
        send(J.step("draining", "GET", "/nope", None))
        drained += 1
    if drained:
        print(f"      soak: {drained} request(s) of tail to let the kernel reach its count",
              flush=True)

    code, log = J.finish_kernel(qemu, serial)
    elapsed = time.time() - began

    # ── what the machine said about itself ──────────────────────────────────
    peaks = J.base_heap_peak(log)
    live = J.base_heap_trace(log)
    heaps = J.request_heap_trace(log)
    if code != 1:
        failures += 1
        print(f"FAIL soak: the kernel exited {code}: " + " | ".join(log.splitlines()[-3:]))
    if len(peaks) < asked:
        failures += 1
        print(f"FAIL soak: the kernel logged {len(peaks)} requests, not {asked}")
    if peaks:
        settled = peaks[min(20, len(peaks) - 1)]
        if peaks[-1] - settled > 1024 * 1024:
            failures += 1
            print(f"FAIL soak: peak memory grew from {settled} to {peaks[-1]} over "
                  f"{len(peaks)} requests — this machine is not reusing what it frees")

    # ── and what the Linux driver says about the volume ─────────────────────
    J.mount(image, mnt, writable=False)
    try:
        found = None
        for root, _, names in os.walk(os.path.join(mnt, "data", "chat")):
            for name in names:
                path = os.path.join(root, name)
                with open(path, "rb") as f:
                    blob = f.read()
                if mark(1) in blob:
                    found = (path, blob)
        if found is None:
            failures += 1
            print("FAIL soak: no file on the volume holds the marks that were written")
        else:
            path, blob = found
            missing = [n for n in range(1, ROUNDS + 1) if mark(n) not in blob]
            if missing:
                failures += 1
                print(f"FAIL soak: {len(missing)} of {ROUNDS} marks are not in "
                      f"{os.path.relpath(path, mnt)} as Linux reads it, first {missing[0]}")
            else:
                print(f"ok    soak: all {ROUNDS} marks are in "
                      f"{os.path.relpath(path, mnt)} ({len(blob)} bytes), read by the "
                      f"Linux VFAT driver")
    finally:
        J.umount(mnt)

    part = image + ".part"
    J.run(["dd", f"if={image}", f"of={part}", f"bs={J.SECTOR}", f"skip={J.PART_FIRST}",
           f"count={J.partition_last(image) - J.PART_FIRST + 1}", "status=none"])
    check = subprocess.run(["fsck.vfat", "-n", part], capture_output=True, text=True)
    if check.returncode != 0:
        failures += 1
        print("FAIL soak: fsck.vfat rejects the volume: " + check.stdout.strip()[:300])

    print(f"soak: {asked} requests in {elapsed / 60:.1f} min "
          f"({asked / max(elapsed, 1):.1f} req/s); live {live[-1] if live else '?'} bytes, "
          f"peak {peaks[-1] if peaks else '?'} bytes, "
          f"request heap up to {max(heaps) if heaps else '?'} bytes")
    return failures


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.strip())
        return 2
    elf, gopher_root, work = sys.argv[1:]
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        print("SKIPPED: populating and reading the disk needs `sudo -n` for a loop mount")
        return 77
    return 1 if soak(elf, gopher_root, work) else 0


if __name__ == "__main__":
    sys.exit(main())
