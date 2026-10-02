# CC's feedback on the day

QUEUE.md item 62. Candid, as asked; the suggestions are ordered by how
much I think each would help.

## The one change that would help most: let me run the judge

Every two-host check I delivered today was rehearsed against Linux
alone. The judge itself never ran here, because building and reading its
disks needs a loop mount, and so every "Not verified: the two-host run"
in my commits is a debt left to you. Batches pile those debts up faster
than you can pay them.

The gap is smaller than it looked:
- **Building a disk needs no mount.** `build_volume.py` builds
  partitioned FAT16 and FAT32 images with mtools, and its readers
  (`compare_volume`, `fat16_read`, `fsck.fat`) agree with a mounted copy.
- **Booting metal works here.** Item 59's rehearsal booted `gopher.elf`
  on the droplet's own machine (`droplet.sh`, `ACCEL=tcg`) in seconds,
  served a volume, and compared it with Linux in a namespace. FAT16 and
  FAT32, end to end.

So the judge's `build_disk`, `set_request_limit`, `split_site_off` and its
tree reads could move to mtools (`mcopy`, `mcopy -n` back, `mdir`). Then
`probe/run.sh gopher` runs in my container, and my commits say
"verified" instead of "yours to verify".

Until then, **a gate request through QUEUE.md** would close the loop:
- I write "please run `JUDGE_ONLY=uids,caps,lynrummy` on `<commit>`";
- you paste the verdict lines back verbatim, with the commit.
I would fix what fails before starting the next item.

## The channel

QUEUE.md worked: the items were clear and had acceptance criteria, and
the "Done" notes and check-ins kept us in step. Two frictions:

- **Every rebase conflicted on QUEUE.md.** We both edit it: you add
  items at the end, and I add notes inside items. Each time I resolved
  it by hand (your text, then mine). It is cheap, but it is also where a
  note could be lost. **Suggestion:** I write only under Questions (or in
  a file of my own), and the items stay yours. Then neither side ever
  edits the other's lines.
- **A merge of an older copy of my branch.** Once, `master` took my
  commits from before a rebase (`7e633f9` merged `2f2fa65` while my
  branch's tip was already its rebased copy). My rebased copies then met
  their older twins: git dropped some as "already upstream", and
  QUEUE.md conflicted again. It cost minutes, not work. **Suggestion:**
  - merge my branch's tip as `git ls-remote` shows it at that moment,
    with a merge commit;
  - I rebase onto `master` before every push, as CLOUD.md says.
  Then what you merge is always exactly what I last pushed.

## The box's slips, as they reached me

- **The early pushes to `master`, ahead of their gates:** I did not
  notice any cost here. I build on whatever `master` is.
- **The box committing in angry-gopher mid-run:** no conflict reached me.

## Pace

I finish items faster than they can be gated, and that is fine as long
as the gate runs eventually. What hurt was not the batch size. It was:
- reviews of my own work coming a batch later. Item 52's 500-session cap
  met metal's 256-entry directory iterator, which stopped the machine,
  and I found it only in item 50;
- item 51's re-sign shipping with an open redirect and a one-shot
  lockout, which I found only in item 53.

**Suggestion:** when an item changes request handling or limits, its own
commit series ends with a short adversarial pass by me, before you merge
it. That is cheaper than a later review item. I can do this without
being asked.

## Limits

- **No loop mount:** the judge, above. This is the one that matters.
- **No KVM:** for correctness, TCG is enough. Timing numbers from here are
  only comparable to each other; I said so where I gave any.
- **No `ip`:** I installed iproute2 in the container for item 59. If the
  environment's setup script installed it, the rehearsal would run in a
  fresh session without that step.

## Direction

The goals read the same from where I sit. Two things I would add:

- **Metal's fixed sizes against the application's unbounded data.** The
  directory iterator's 256 was one: a fixed array in metal met a folder
  that grows with use, and the answer was to stop the machine. Others of
  the same kind may be waiting: the connection table, `max_path`, the
  request heap's growth, per-request arenas holding a whole listing. A
  short audit item, listing each fixed size in metal and the application
  data that could exceed it, would find them before production does.
- **One secret mints everything.** Sessions, players' cookies, and since
  item 51 every player's identity. DESIGN-sessions.md has the options. A
  procedure for a leak is worth having before the cutover, whatever Steve
  decides about lifetimes.

Item 53's three medium findings (re-sign sweep, open redirect, lost
answer) are small fixes. I would do them next, if you queue them.
