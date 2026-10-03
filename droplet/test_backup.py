#!/usr/bin/env python3
"""**backup.sh, AGAINST A REAL SERVER** (QUEUE.md item 98). Boots the judge's
Linux `zig-server` on the staged data and drives `droplet/backup.sh` against it
under a pseudo-terminal (so `read -rs` and `age -p`, which both read the
terminal, can be answered), with a test password. It checks that:

  - a `.tar.age` is written and nothing plaintext is left behind;
  - it decrypts with the passphrase and `check_backup.py` says it is whole;
  - a wrong admin password fails and still leaves no plaintext;
  - the retention keeps the newest KEEP and shreds the rest.

The box runs backup.sh against metal; this is the host-runnable half.

    droplet/test_backup.py [ZIG_SERVER_BINARY]
"""
import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "probe"))
import judge_gopher as G  # noqa: E402

GOPHER_ROOT = os.environ.get("GOPHER_ROOT", os.path.expanduser("~/showell_repos/angry-gopher"))
ADMIN_PW = G.MEMBER_PASSWORD  # the staged admin (Steve, uid 1)
PASSPHRASE = "a test passphrase for the backup"


def run_backup(host, out_dir, admin_pw, keep=7, timeout=60):
    """Drive backup.sh under a pty, answering its prompts. Returns (exit, output)."""
    env = dict(os.environ, GOPHER_BACKUP_KEEP=str(keep))
    pid, fd = pty.fork()
    if pid == 0:  # child: become backup.sh
        try:
            os.execvpe("bash", ["bash", os.path.join(HERE, "backup.sh"), host, out_dir], env)
        except Exception:
            os._exit(127)
    # parent: feed the prompts
    buf = b""
    sent_pw = False
    passes = 0
    status = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b""
            if chunk:
                buf += chunk
                low = buf.lower()
                if not sent_pw and b"admin password" in low:
                    os.write(fd, (admin_pw + "\n").encode())
                    sent_pw = True
                # age -p prompts "Enter passphrase (leave empty...)" then
                # "Confirm passphrase:" — answer each as it appears.
                prompts = low.count(b"enter passphrase") + low.count(b"confirm passphrase")
                while prompts > passes:
                    os.write(fd, (PASSPHRASE + "\n").encode())
                    passes += 1
                    time.sleep(0.1)
        done, st = os.waitpid(pid, os.WNOHANG)
        if done != 0:
            status = st
            break
    try:
        os.close(fd)
    except OSError:
        pass
    if status is None:  # timed out: reap it so it does not linger
        try:
            os.kill(pid, 9)
            _, status = os.waitpid(pid, 0)
        except OSError:
            status = 1 << 8
    return os.waitstatus_to_exitcode(status), buf.decode("latin-1", "replace")


def age_decrypt(src, dst, passphrase, timeout=30):
    """`age -d` a passphrase-encrypted file under a pty (it reads the passphrase
    from the terminal, like `-p` does). Returns the exit code."""
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp("age", ["age", "-d", "-o", dst, src])
        except Exception:
            os._exit(127)
    buf = b""
    sent = False
    status = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                c = os.read(fd, 4096)
            except OSError:
                c = b""
            if c:
                buf += c
                if not sent and b"passphrase" in buf.lower():
                    os.write(fd, (passphrase + "\n").encode())
                    sent = True
        done, st = os.waitpid(pid, os.WNOHANG)
        if done != 0:
            status = st
            break
    try:
        os.close(fd)
    except OSError:
        pass
    if status is None:
        try:
            os.kill(pid, 9)
            _, status = os.waitpid(pid, 0)
        except OSError:
            status = 1 << 8
    return os.waitstatus_to_exitcode(status)


def plaintext_tars(d):
    return [f for f in os.listdir(d) if f.endswith(".tar") or ".tar." in f and not f.endswith(".tar.age")]


def age_files(d):
    return sorted(f for f in os.listdir(d) if f.endswith(".tar.age"))


def main(argv):
    binary = argv[1] if len(argv) > 1 else os.path.join(GOPHER_ROOT, "zig-server", "zig-out", "bin", "zig-server")
    if not os.path.isfile(binary):
        print(f"test_backup: no zig-server at {binary}: build it in zig-server/", file=sys.stderr)
        return 2
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        site = os.path.join(tmp, "site")
        G.stage(site, GOPHER_ROOT)
        server = G.LinuxServer(binary, site, os.path.join(tmp, "server.log"))
        host = f"http://127.0.0.1:{server.port}"
        out = os.path.join(tmp, "backups")
        try:
            # 1. A good backup.
            code, log = run_backup(host, out, ADMIN_PW)
            if code != 0:
                failures.append(f"a good backup exited {code}: {log[-400:]}")
            ages = age_files(out)
            if len(ages) != 1:
                failures.append(f"expected one .tar.age, found {ages}")
            if plaintext_tars(out):
                failures.append(f"a plaintext tar was left behind: {plaintext_tars(out)}")
            # 2. It decrypts and is whole.
            if ages:
                dec = os.path.join(tmp, "dec.tar")
                if age_decrypt(os.path.join(out, ages[0]), dec, PASSPHRASE) != 0 or not os.path.exists(dec):
                    failures.append("the backup did not decrypt with its passphrase")
                else:
                    chk = subprocess.run([sys.executable, os.path.join(HERE, "check_backup.py"), dec],
                                         capture_output=True, text=True)
                    if chk.returncode != 0 or "whole:" not in chk.stdout:
                        failures.append(f"check_backup did not call the decrypted backup whole: {chk.stdout.strip()[-200:]}")
                    os.remove(dec)
            # 3. A wrong admin password fails, and leaves no plaintext.
            code, log = run_backup(host, out, "not the password")
            if code == 0:
                failures.append("a wrong admin password still succeeded")
            if plaintext_tars(out):
                failures.append(f"a failed backup left a plaintext tar: {plaintext_tars(out)}")
            # 4. Retention: with KEEP=2, three more backups leave exactly two.
            for _ in range(3):
                time.sleep(1.1)  # distinct second-stamped names
                run_backup(host, out, ADMIN_PW, keep=2)
            kept = age_files(out)
            if len(kept) != 2:
                failures.append(f"retention KEEP=2 left {len(kept)} backups, not 2: {kept}")
        finally:
            server.stop()
    if failures:
        print("test_backup FAILED:\n  " + "\n  ".join(failures))
        return 1
    print("test_backup passed: a backup is written, checked whole and encrypted; a wrong password fails; "
          "no plaintext is ever left behind; retention keeps the newest and shreds the rest")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
