# Working here from a cloud session

This is for Claude Code running in the cloud ("CC"). Read it at the start of
every session, then read `QUEUE.md`.

## Who does what

- **Steve** decides. He relays between the two Claudes only when he wants to;
  the default channel is git.
- **The box Claude** works on Steve's development droplet. It has KVM, QEMU,
  loop mounts, the gates (`./gates.sh`), the droplet images, and read access
  to prod. It merges your branch, runs the gates on it, builds images, deploys
  with Steve, and measures on the real droplet.
- **You (CC)**: adversarial reading, design, and testing that runs on ordinary
  Linux. You have no KVM, no `vfat` mount, and no access to any droplet or to
  prod. Do not try to get them.

**Run unattended for as long as the queue gives you work.** Steve wants to
check in rarely. When something is the box Claude's or Steve's to do, write it
under "Questions" in `QUEUE.md` and take the next item. Do not wait.

## Code is code

**The kernel runs with no OS under it, but nothing about that changes what
its code is.** Most of `src/` is logic: TCP, FAT16, HTTP parsing, GPT, DHCP,
the path routing in `io.zig`, the virtio rings' bookkeeping. Logic runs, and
is tested, on Linux like any other code. What is truly bare-metal is thin: port
and MMIO reads and writes, `hlt`, interrupt entry. A fake can stand in for
each of them.

So treat "this needs QEMU" as a smell, not a fact. When you meet something only
the QEMU gates check, ask how to check it on Linux:

- **Extract the decision from the I/O**, and test the decision.
- **Fake the device:**
  - an in-memory disk behind `virtio.Block`'s interface, so `fat16.zig` and
    `io.zig` mount, write and read back on the host;
  - a fake virtio queue that completes descriptors, so the drivers'
    bookkeeping is tested;
  - a fake clock.
- **Bring an independent oracle.** For example, a small FAT16 reader in
  Python, written from the spec rather than from our code, which reads an
  image our code wrote. That replaces the Linux `vfat` mount the judge uses
  and you cannot.
- **Simulate**, as `tcp_sim.zig` does.

Every bug the QEMU gates catch that a host test could have caught first is a
gap worth closing. The flaky lagging-stream check of 2026-10-02 is an example
of the opposite kind: it was about timing on a real machine, which belongs to
the gates.

## Git is the channel

- **Push to `claude/elegant-keller-an3ccr` only.** Never push to `master`.
- **Rebase on `origin/master` before every push.** The box Claude merges your
  branch, so a stale base costs it a conflict.
- **One topic per commit.** Its message says:
  - what changed and why;
  - what you verified (`zig build test`, `zig build kernels`, `zig fmt
    --check`, a simulator's seeds), and what you could not.
- **Compile before pushing, always.** The session-start hook installs zig.
- **`QUEUE.md` is shared.**
  - Mark an item yours in your branch when you start it.
  - Mark it done in the commit that finishes it.
  - Add items you discover under "Proposed", with one line each on why.
- **The box Claude answers on `master`:**
  - in `QUEUE.md`, under "Answers";
  - in a `REVIEW-*.md` file;
  - or in the merge itself.

  Fetch `origin/master` to see them.

## Limits

- Do not edit:
  - deployment state: `droplet/volume-serial`, prod's Caddy file;
  - anything that names a real machine's address.
- Never weaken a test to make it pass, and never make a gate skip silently.
  If a test is wrong, say why in the commit that changes it.
- Do not change `gates.sh` or `probe/run.sh` without saying so in `QUEUE.md`.
  Those run on a machine you cannot see.
- The kernel must stay testable on both Linux and QEMU, and angry-gopher must
  stay buildable and testable on Linux. Steve's rule: neither side may make
  the other untestable.
- Reviews follow `REVIEW-interrupts.md`'s shape:
  - what holds up;
  - findings by severity, each with the failure it causes and how likely it
    is;
  - fix shapes;
  - nothing fixed in the review commit itself.
