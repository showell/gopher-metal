#!/bin/bash
# **THE LONG TIER** (COVERAGE.md): for bug hunting, and before a deploy. Not
# for every commit; that is gates.sh.
#
#   ./long.sh                 the simulator at 10,000 seeds, then the lossy
#                             sweep of the real kernel
#   SEEDS=50000 ./long.sh     more seeds
#   ./long.sh sim | metal     one half
#
# 1. **The simulator** (`zig build properties`), plain and rough seeds, with
#    `coverage/floor-sim.txt` as its floor: every property on it must be
#    reached, and none broken.
#
# 2. **The real kernel, losing each of its frames in turn.** gopher.elf, built
#    with -Dcoverage, on metal-vmm's PC-shaped machine (TRANSPORT=pci: it
#    halts between frames and wakes on interrupts, as on a droplet), over a
#    5 ms wire. For each route, the wire eats the guest's 1st frame, then its
#    2nd, and so on through every frame the route sends, one deterministic run
#    each. **Every run must still serve the page an unhurt run serves**: TCP's
#    whole promise is that losing a frame costs time, not the answer. Every
#    run's coverage lines go to one sdk.jsonl, judged by zig-coverage-sdk's
#    report.py against `coverage/floor-metal.txt`.
#
# Needs: metal-vmm and zig-coverage-sdk as sibling checkouts (METAL_VMM,
# COVERAGE_SDK), and the judge's site volume (probe/run.sh gopher builds it).
# gopher.elf is rebuilt without -Dcoverage at the end, as gates.sh expects.
#
# **ITS EXIT CODE IS THE VERDICT**, and the last line names what failed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
VMM="${METAL_VMM:-$HOME/showell_repos/metal-vmm}"
SDK="${COVERAGE_SDK:-$HOME/showell_repos/zig-coverage-sdk}"
SITE="${SITE:-$HOME/build/gopher-metal/probe/gopher/pristine.img}"
SEEDS="${SEEDS:-10000}"
LATENCY_US="${LATENCY_US:-5000}"
# A page, a large one (many frames), and a form.
ROUTES="${ROUTES:-/ /steve-resume.pdf /login/full}"
OUT="${LONG_OUT:-$HOME/build/gopher-metal/long}"
want="${1:-all}"
case "$want" in all | sim | metal) ;; *) echo "usage: ./long.sh [sim|metal]"; exit 2 ;; esac

failed=()
began=$(date +%s)
lap() { echo "time: $1 $(( $(date +%s) - began )) s"; began=$(date +%s); }

if [ "$want" != metal ]; then
    echo "── the simulator: $SEEDS seeds, plain and rough, against coverage/floor-sim.txt"
    zig build properties -Dseeds="$SEEDS" -Dfloor=coverage/floor-sim.txt > "$OUT.sim" 2>&1
    code=$?
    grep -E 'runs failed|not satisfied|^ *(FAIL|FLOOR|STALE)|floor .*under' "$OUT.sim" | sed 's/^ *//'
    [ $code = 0 ] || failed+=(sim)
    lap "simulator"
fi

if [ "$want" != sim ]; then
    echo "── the real kernel on metal-vmm's PC-shaped machine, losing each frame in turn"
    mkdir -p "$OUT"
    rm -f "$OUT/sdk.jsonl"
    [ -f "$SITE" ] || { echo "no site volume at $SITE: run probe/run.sh gopher once"; exit 2; }
    (cd "$VMM" && zig build) || { echo "metal-vmm does not build"; exit 2; }
    zig build gopher -Dcoverage > "$OUT/build.log" 2>&1 || { echo "gopher.elf -Dcoverage does not build: $OUT/build.log"; exit 2; }
    # gopher.elf goes back to what gates.sh expects, however this ends.
    trap 'zig build gopher > "$OUT/rebuild.log" 2>&1 || echo "gopher.elf was not rebuilt without -Dcoverage: $OUT/rebuild.log"' EXIT

    # run <eat> <path>: one boot; sets code, sent, status, and the page in $OUT/page.
    run() {
        cp "$SITE" "$OUT/run.img"
        TRANSPORT=pci WIRE_LATENCY_US="$LATENCY_US" WIRE_EAT="$1" PEER_BODY="$OUT/page" \
            timeout 120 "$VMM/zig-out/bin/metal-vmm" probe/gopher.elf "$OUT/run.img" "" "$2" \
            > "$OUT/run.out" 2> "$OUT/run.err"
        code=$?
        sent=$(sed -n 's/^wire: \([0-9]*\) frames sent.*/\1/p' "$OUT/run.err")
        status=$(sed -n 's/^peer: \([0-9]*\).*/\1/p' "$OUT/run.out")
        grep -a '^coverage: ' "$OUT/run.out" | sed -e 's/^coverage: //' -e 's/\r$//' >> "$OUT/sdk.jsonl"
    }

    lost_pages=0
    for route in $ROUTES; do
        # Frame 9999 is never sent: the unhurt run, whose page every other must match.
        run 9999 "$route"
        cp "$OUT/page" "$OUT/unhurt.page"
        unhurt_status=$status
        total=${sent:-0}
        if [ "$code" != 0 ] || [ -z "$status" ] || [ "$total" = 0 ]; then
            echo "  $route: the unhurt run failed (exit $code, status '${status}'); see $OUT/run.out"
            failed+=("metal $route")
            continue
        fi
        bad=""
        for n in $(seq 1 "$total"); do
            run "$n" "$route"
            if [ "$code" != 0 ] || [ "$status" != "$unhurt_status" ] || ! cmp -s "$OUT/page" "$OUT/unhurt.page"; then
                bad="$bad #$n"
                lost_pages=$((lost_pages + 1))
                cp "$OUT/run.out" "$OUT/lost-$(echo "$route" | tr / _)-$n.out"
            fi
        done
        if [ -z "$bad" ]; then
            echo "  $route: $total frames, each lost in turn: the same page every time ($unhurt_status)"
        else
            echo "  $route: $total frames; losing these lost the page:$bad (logs in $OUT/lost-*)"
            failed+=("metal $route")
        fi
    done
    lap "lossy sweep"
    python3 "$SDK/tools/report.py" "$OUT/sdk.jsonl" --floor coverage/floor-metal.txt > "$OUT/report" 2>&1
    code=$?
    grep -E '^(FAIL|FLOOR|STALE)|^[0-9]+ runs|under the floor' "$OUT/report"
    [ $code = 0 ] || failed+=(metal-floor)
fi

if [ ${#failed[@]} = 0 ]; then
    echo "LONG: PASS"
else
    echo "LONG: FAIL (${failed[*]})"
    exit 1
fi
