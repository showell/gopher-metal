#!/bin/bash
# **THE LONG TIER** (COVERAGE.md): for bug hunting, and before a deploy. Not
# for every commit; that is gates.sh.
#
#   ./long.sh                 the simulator at 10,000 seeds, then the lossy
#                             sweep of the real kernel
#   SEEDS=50000 ./long.sh     more seeds
#   ./long.sh sim | metal     one half
#
# 1. **The simulators** (`zig build properties`, ReleaseSafe): TCP's plain and
#    rough seeds and FAT's, with `coverage/floor-sim.txt` as their floor:
#    every property on it must be reached, and none broken.
#
# 2. **The chat judge on FAT16** (QEMU's microvm, the whole story): moved
#    here from gates.sh, whose FAT32 judges are what prod runs.
#
# 3. **The real kernel, losing each of its frames in turn.** gopher.elf, built
#    with -Dcoverage, on metal-vmm's PC-shaped machine (TRANSPORT=pci: it
#    halts between frames and wakes on interrupts, as on a droplet), over a
#    5 ms wire. For each route, the wire eats the guest's 1st frame, then its
#    2nd, and so on through every frame the route sends, one deterministic run
#    each. **Every run must still serve the page an unhurt run serves**: TCP's
#    whole promise is that losing a frame costs time, not the answer. Every
#    run's coverage lines go to one sdk.jsonl, judged by zig-coverage-sdk's
#    report.py against `coverage/floor-metal.txt`.
#
#    **IN PRODUCTION'S SHAPE** (QUEUE B24, 2026-10-08): every boot of 3
#    and 4 has a copy of the site volume attached as a SCSI disk, so chat's
#    data is on a volume, as on the droplet. No gate ran that shape until
#    then, and its first run found metal-vmm crashing on virtio-scsi's third
#    queue and every write's residual wrong.
#
# 4. **The real kernel, with a peer that misbehaves**: one run each for a
#    reset (exact and not), a peer that vanishes, a window it shuts, a
#    damaged segment, a SYN flood that fills the table, and a request
#    segment lost so the next arrives ahead (the table in the script).
#    The flood's real client drips its request (PEER_DRIP_US): the site
#    serves one request and stops, so a client answered at once ends the
#    run before any half-open is older than min_rto_ns, the age at which
#    one gives way to a new SYN (tcp.zig oldestHalfOpen). In production's
#    shape, 1000 SYNs 100 us apart reached it in no run.
#    Their coverage joins the same sdk.jsonl.
#
# 5. **Seeded fault schedules, with a volume** (metal-vmm's sweep.sh,
#    `VOLUME_SITE`): `VOLUME_SEEDS` seeds (100), each a whole schedule drawn
#    over the wire, the peer, the disk and the volume. A seed that fails, as
#    sweep.sh judges it (a page its faults do not excuse, an exit, a disk or
#    volume left unsound, a broken property), fails this tier. It runs the
#    -Dcoverage kernel: sweep.sh refuses one that reports no property, since
#    "no property broken" would hold of it vacuously (2026-10-09), and
#    through metal-vmm's coverage door its pages are the release kernel's.
#
# Needs: metal-vmm and zig-coverage-sdk as sibling checkouts (METAL_VMM,
# COVERAGE_SDK), the judge's site volume (probe/run.sh gopher builds it), and
# mtools (mcopy) for a copy of it that asks for two requests.
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
FAT_SEEDS="${FAT_SEEDS:-300}"
LATENCY_US="${LATENCY_US:-5000}"
VOLUME_SEEDS="${VOLUME_SEEDS:-100}"
# A page, a large one (many frames), and a form.
ROUTES="${ROUTES:-/ /steve-resume.pdf /login/full}"
OUT="${LONG_OUT:-$HOME/build/gopher-metal/long}"
want="${1:-all}"
case "$want" in all | sim | metal) ;; *) echo "usage: ./long.sh [sim|metal]"; exit 2 ;; esac

# **WHICH CODE THIS RUN JUDGES** (tools/verdicts.py), as gates.sh does. Only
# a whole run at full size keeps a verdict: a release asks for this tier as
# it is, not a smaller one.
VERDICT_PAIR="$(python3 tools/verdicts.py ids)" || exit 2
export VERDICT_PAIR
python3 tools/verdicts.py pair
keeps_verdict=no
[ "$want" = all ] && [ "$SEEDS" -ge 10000 ] && [ "$FAT_SEEDS" -ge 300 ] && keeps_verdict=yes

failed=()
began=$(date +%s)
lap() { echo "time: $1 $(( $(date +%s) - began )) s"; began=$(date +%s); }

if [ "$want" != metal ]; then
    echo "── the simulators: $SEEDS TCP seeds, plain and rough, and $FAT_SEEDS FAT seeds, against coverage/floor-sim.txt"
    # ReleaseSafe: a sweep this long is nearly all running (build.zig).
    zig build properties -Dseeds="$SEEDS" -Dfat-seeds="$FAT_SEEDS" -Dsweep-optimize=ReleaseSafe \
        -Dfloor=coverage/floor-sim.txt > "$OUT.sim" 2>&1
    code=$?
    grep -E 'runs failed|not satisfied|^ *(FAIL|FLOOR|STALE)|floor .*under' "$OUT.sim" | sed 's/^ *//'
    [ $code = 0 ] || failed+=(sim)
    lap "simulator"
fi

if [ "$want" != sim ]; then
    # **THE FAT16 CHAT JUDGE** (moved here from gates.sh, the gates essay's
    # item 6): the whole chat story on QEMU's microvm with the data on FAT16,
    # every run. First, on gopher.elf as a release builds it: the coverage
    # build below replaces it.
    echo "── the chat judge on FAT16 (microvm)"
    zig build gopher > "$OUT.fat16-build" 2>&1 || { echo "gopher.elf does not build: $OUT.fat16-build"; exit 2; }
    env JUDGE_DROPLET=0 FAT=16 PROBE_WORK="$HOME/build/gopher-metal/probe-microvm-fat16" probe/run.sh gopher \
        > "$OUT.fat16" 2>&1
    code=$?
    sed -n '/^\(PASS\|FAIL\|    \) *gopher/,$p' "$OUT.fat16"
    { [ "$code" = 0 ] && grep -q "^PASS gopher" "$OUT.fat16"; } || failed+=(fat16-judge)
    lap "chat judge, FAT16"

    echo "── the real kernel on metal-vmm's PC-shaped machine, losing each frame in turn"
    mkdir -p "$OUT"
    rm -f "$OUT/sdk.jsonl"
    [ -f "$SITE" ] || { echo "no site volume at $SITE: run probe/run.sh gopher once"; exit 2; }
    (cd "$VMM" && zig build) || { echo "metal-vmm does not build"; exit 2; }
    # **TWO KERNELS, TWO JOBS** (2026-10-07): the production build is what
    # each page is judged on, since it is what ships; the -Dcoverage build
    # runs every case again only to say what it reached, its pages unjudged.
    # A coverage kernel prints its catalog to the console, a byte an exit,
    # about nine seconds of the guest's time a boot once the floor was named,
    # and that alone made a late lost frame's resend miss the two seconds a
    # guest gives its connections after its last request: v19's first
    # long.sh failed every route that way while its production kernel served
    # each page whole.
    zig build gopher -Dcoverage > "$OUT/build.log" 2>&1 || { echo "gopher.elf -Dcoverage does not build: $OUT/build.log"; exit 2; }
    cp probe/gopher.elf "$OUT/gopher-coverage.elf"
    zig build gopher > "$OUT/rebuild.log" 2>&1 || { echo "gopher.elf does not build: $OUT/rebuild.log"; exit 2; }
    JUDGED=probe/gopher.elf
    COUNTED="$OUT/gopher-coverage.elf"

    # run <eat> <path> [kernel]: one boot; sets code, sent, status, and the
    # page in $OUT/page. The judged kernel unless another is named.
    run() {
        cp "$SITE" "$OUT/run.img"
        cp "$SITE" "$OUT/run.vol"
        # A page is this run's or none: metal-vmm writes none for an answer
        # it kept only in part, and a page left by the run before would be
        # judged in its place.
        rm -f "$OUT/page"
        TRANSPORT=pci VOLUME="$OUT/run.vol" WIRE_LATENCY_US="$LATENCY_US" WIRE_EAT="$1" PEER_BODY="$OUT/page" \
            timeout 120 "$VMM/zig-out/bin/metal-vmm" "${3:-$JUDGED}" "$OUT/run.img" "" "$2" \
            > "$OUT/run.out" 2> "$OUT/run.err"
        code=$?
        sent=$(sed -n 's/^wire: \([0-9]*\) frames sent.*/\1/p' "$OUT/run.err")
        status=$(sed -n 's/^peer: \([0-9]*\).*/\1/p' "$OUT/run.out")
        grep -a '^coverage: ' "$OUT/run.out" | sed -e 's/^coverage: //' -e 's/\r$//' >> "$OUT/sdk.jsonl"
    }

    lost_pages=0
    for route in $ROUTES; do
        # Frame 9999 is never sent: the unhurt run, whose page every other must match.
        run 9999 "$route" "$COUNTED"
        run 9999 "$route"
        rm -f "$OUT/unhurt.page"
        cp "$OUT/page" "$OUT/unhurt.page" 2>/dev/null
        unhurt_status=$status
        total=${sent:-0}
        if [ "$code" != 0 ] || [ -z "$status" ] || [ "$total" = 0 ] || [ ! -f "$OUT/unhurt.page" ]; then
            echo "  $route: the unhurt run failed (exit $code, status '${status}', page $([ -f "$OUT/unhurt.page" ] && echo written || echo 'not written')); see $OUT/run.out and run.err"
            failed+=("metal $route")
            continue
        fi
        bad=""
        for n in $(seq 1 "$total"); do
            run "$n" "$route" "$COUNTED"
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

    # **THE PEER MISBEHAVES**, one run per way (metal-vmm's KNOBS.md, "The peer:
    # a worse client"). A client that stays (`page`) must still get the
    # page an unhurt run gets; one that hurts itself (`end`: a reset, a
    # vanish) is owed nothing, and the run may end with the guest idle,
    # waiting on a request that never comes. Either way metal-vmm must end
    # the run itself: no panic, no timeout, no guest that never rests.
    # `two` is the site volume asking for two requests, so the guest stays up
    # after the first and its table gives up on a silent peer. A `page` run
    # is on `one`: an idle end prints no page. The shut window lasts 1.5 s,
    # inside the 2 s a guest that has served its last request gives its
    # connections before it stops; a longer one is cut by that stop, which
    # only a request limit causes (the site has none).
    cp "$SITE" "$OUT/two.img"
    printf 'requests = 2\nidle_timeout_ms = 10000\n' > "$OUT/two.conf"
    mcopy -o -i "$OUT/two.img@@1M" "$OUT/two.conf" ::/gopher-metal.conf || { echo "mcopy (mtools) could not write the two-request volume"; exit 2; }
    printf 'GET / HTTP/1.1\r\nHost: lynrummy.com\r\nX-Pad: %s\r\nConnection: close\r\n\r\n' "$(head -c 900 /dev/zero | tr '\0' a)" > "$OUT/req1k"
    for route in / /steve-resume.pdf; do
        run 9999 "$route"
        cp "$OUT/page" "$OUT/unhurt$(echo "$route" | tr / _).page"
    done
    rough_bad=""
    while read -r name volume route must knobs; do
        [ -z "$name" ] && continue
        img="$SITE"
        [ "$volume" = two ] && img="$OUT/two.img"
        for kernel in "$COUNTED" "$JUDGED"; do
            cp "$img" "$OUT/run.img"
            cp "$SITE" "$OUT/run.vol"
            # shellcheck disable=SC2086 # knobs are words on purpose
            env TRANSPORT=pci VOLUME="$OUT/run.vol" WIRE_LATENCY_US="$LATENCY_US" PATIENCE_S=60 PEER_BODY="$OUT/page" $knobs \
                timeout 300 "$VMM/zig-out/bin/metal-vmm" "$kernel" "$OUT/run.img" "" "$route" \
                > "$OUT/run.out" 2> "$OUT/run.err"
            code=$?
            grep -a '^coverage: ' "$OUT/run.out" | sed -e 's/^coverage: //' -e 's/\r$//' >> "$OUT/sdk.jsonl"
        done
        ok=yes
        case "$code" in
            0) ;;
            1) grep -q '^error: GuestIdle$' "$OUT/run.err" || ok=no ;;
            *) ok=no ;;
        esac
        if [ "$must" = page ] && ! cmp -s "$OUT/page" "$OUT/unhurt$(echo "$route" | tr / _).page"; then ok=no; fi
        if [ $ok = yes ]; then
            if [ "$code" = 0 ]; then echo "  rough $name: answered $(sed -n 's/^peer: \([0-9]*\).*/\1/p' "$OUT/run.out" | head -1)"
            else echo "  rough $name: no answer owed; the guest ended idle"; fi
        else
            rough_bad="$rough_bad $name"
            cp "$OUT/run.err" "$OUT/rough-$name.err"
            cp "$OUT/run.out" "$OUT/rough-$name.out"
            echo "  rough $name: FAILED (exit $code; logs in $OUT/rough-$name.*)"
        fi
    done <<EOF
reset          one /steve-resume.pdf end  PEER_RESET_AT=30000
reset-inexact  one /steve-resume.pdf end  PEER_RESET_AT=30000 PEER_RESET_OFF=100
vanish         two /steve-resume.pdf end  PEER_VANISH_AFTER=3000
shut-window    one /steve-resume.pdf page PEER_SHUT_AFTER=5000 PEER_SHUT_FOR_US=1500000
damaged        one /                 page PEER_DAMAGE=3
flood          one /                 page PEER_FLOOD=1000 PEER_FLOOD_GAP_US=1000 PEER_DRIP_US=100000 PEER_MSS=10
ahead          one /                 page PEER_REQUEST=$OUT/req1k PEER_MSS=100 PEER_EAT=6
EOF
    [ -z "$rough_bad" ] || failed+=("metal rough:$rough_bad")
    lap "rough peer"

    echo "── seeded fault schedules with a volume attached: $VOLUME_SEEDS seeds (metal-vmm's sweep.sh)"
    VOLUME_SITE="$SITE" SITE="$SITE" KERNEL="$COUNTED" "$VMM/sweep.sh" 1 "$VOLUME_SEEDS" > "$OUT/volume-sweep" 2>&1
    code=$?
    grep -iE '^[0-9]+ seeds:|FAULT_SEED=[0-9]+: FAIL|nothing can be judged' "$OUT/volume-sweep"
    [ $code = 0 ] || { echo "  the volume sweep failed (exit $code): $OUT/volume-sweep"; failed+=(volume-sweep); }
    lap "volume sweep"
    python3 "$SDK/tools/report.py" "$OUT/sdk.jsonl" --floor coverage/floor-metal.txt > "$OUT/report" 2>&1
    code=$?
    grep -E '^(FAIL|FLOOR|STALE)|^[0-9]+ runs|under the floor' "$OUT/report"
    [ $code = 0 ] || failed+=(metal-floor)
fi

if [ ${#failed[@]} = 0 ]; then
    if [ $keeps_verdict = yes ]; then python3 tools/verdicts.py record long PASS
    else echo "no verdict kept: only a whole run ($want) at full size (SEEDS>=10000, FAT_SEEDS>=300) keeps one"; fi
    echo "LONG: PASS"
else
    [ $keeps_verdict = yes ] && python3 tools/verdicts.py record long FAIL
    echo "LONG: FAIL (${failed[*]})"
    exit 1
fi
