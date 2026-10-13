#!/bin/bash
# **TIER 0: ZIG, PYTHON AND THE COVERAGE SDK, NOTHING ELSE** (metal-vmm QUEUE
# 197). The check to run on every change: the unit tests and the simulators,
# this repo's own kernels type-checked, the formatter and the lints. No QEMU, no other repo, no
# network, no root. Needs zig 0.16, python3, and ../zig-coverage-sdk at the
# commit build.zig.zon pins.
#
# **EVERY SIBLING IS POINTED AT NOTHING HERE**, so a step that reaches
# outside this repo fails in this tier instead of passing on a machine that
# happens to have the sibling beside it.
#
# What it does not check is named at the end, with the tier that does.
TIER="tier 0"
source "$(dirname "${BASH_SOURCE[0]}")/tools/tier_lib.sh"
need zig python3

NOWHERE="$HERE/.no-sibling"
ALONE=(-Dgopher-root="$NOWHERE" -Dwebbox-root="$NOWHERE" -Ddogpark-root="$NOWHERE")

# The unit tests, the simulators' own tests, this repo's kernels and host
# programs type-checked, `zig fmt --check src`, the machine lint and its
# cases. The summary is kept: each test binary's time is in it.
zig build test "${ALONE[@]}" --summary all > "$VERDICTS/tier0-test.txt" 2>&1
[ $? = 0 ] || failed+=(test)
grep -E "tests passed|error" "$VERDICTS/tier0-test.txt" | tail -5
lap "zig build test"

# The rest of src/'s neighbours that only need Python.
zig fmt --check probe droplet native > /dev/null || failed+=(fmt)
python3 droplet/check_volume_tree.py --self-test > /dev/null || failed+=(volume-tree)
# Parsed, not run: a syntax error in a judge would otherwise wait for tier 1.
python3 -c 'import ast, sys
for f in sys.argv[1:]: ast.parse(open(f).read(), f)' tools/*.py probe/*.py droplet/*.py native/*.py || failed+=(python-parses)
lap "fmt, the volume-tree self-test, every Python file parses"

cat <<'NOTE'
tier 0 does NOT check, and which tier does:
  - the coverage properties over the simulators' seeds (zig build
    properties: zig alone, but 20 min in Debug and 5 in ReleaseSafe, too
    long for every change): long.sh, at 10,000 seeds
  - the probe kernels booted, the judges' own tests, the FAT image tools,
    the droplet's boots (QEMU, dosfstools, gdisk, mtools): tier 1
  - metal-vmm against this repo's kernels: tier 2
  - src/pinned/webbox_body.zig against zig-webbox's body.zig (zig build
    pinned); gopher.elf type-checked (zig build check-apps) and built;
    the limits zig-webbox copies (tools/check_limits.py); zig-webbox's own
    tests; the site volume, the chat and Dog Park judges; metal-vmm on
    gopher.elf: tier 3
NOTE
verdict
