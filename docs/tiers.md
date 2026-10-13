# What each tier proves, and what could move down to tier 0

Written for metal-vmm QUEUE 197.3 (2026-10-13), from a read of the tests,
the simulators, the probes and the judges. The tiers are `tier0.sh` to
`tier3.sh` (README, "The checks"). **Status of the ranked list below:**
1 (sense in either format) is fixed, caee388; 3 (a volume serial with a sign
or `_`) is fixed and the config's spelling is in `src/config_text.zig`,
b6ebbe3; 9 (the queue indexes across their wrap) is pinned in virtio.zig's
own test, and virtio.zig is a unit file now. The rest are open.

Sources: `build.zig`'s `unit_files`,
`tier0-3.sh`, `long.sh`, `COVERAGE.md`, `docs/probes.md`, `probe/judge_gopher.py`
(GATES), metal-vmm `check.sh`/`same.sh`/`refused.sh`/`sweep.sh`/`timeouts.sh`/
`pc_vs_microvm.sh`. "N tests" means `test "..."` blocks counted by grep.

**Files that tier 0 never compiles as a test root and that have no tests of
their own:** `virtio.zig` (1212 lines), `stream.zig` (506), `scsi.zig` (436),
`interrupts.zig` (427), `proto.zig`, `arp.zig`, `serial.zig`, `boot.zig`,
`restarting.zig`, `tsc.zig`, `pci.zig`, `rng.zig`, and `probe/gopher.zig`
(2345 lines, 0 tests). Some are reached through imports: `virtio.Block.inMemory`
under the FAT/io tests, `proto`/`arp` under `floor_sim` and `tcp_sim`. `stream.zig`
is reached by nothing in tier 0. COVERAGE.md says the same: 0 of its 7 properties.

## Per subsystem

| subsystem | (a) tier 0 proves | (b) only a higher tier proves |
|---|---|---|
| **TCP** (`tcp.zig`, `tcp_check.zig`) | `tcp_test.zig` (81 tests: the state table, resets, challenge ACK, RTO, probes, window news); `tcp_sim` plain and rough seeds 1-8, plus crowds (loss, dup, reorder, corruption, an RFC-written peer; oracles: tcp_check invariants after every step, exactly once in order, completion bound, quiescence); `tcp_check` (8). All 23 properties reached (`properties`, `long.sh` 10k seeds). | **T1**: `ladder` and `http` probes against slirp. **T3**: judge_gopher `bulk`, `concurrent`, `lagging`, and streams on a real Linux client. metal-vmm `lossy.sh`/`long.sh` metal half (each frame of 3 routes lost in turn, the page must match; 15 of 23 properties), `timeouts.sh` (idle_timeout_ms in machine time). |
| **Net below TCP** (`proto`, `arp`, `dhcp`, `net`, `stream`) | `floor_sim`: every `parseIpv4`/`parseUdp`/`arp.parseRequest` refusal, one field wrong at a time. `dhcp.zig` (4): ACK lease time, NAK is `Refused`, the 4-to-64 s backoff, any bytes refused or parsed in bounds. `net.zig` (2): oversized send refused with the ring untouched; `rxEntry`/`txEntryOurs` classification. **`stream.zig`: nothing.** | **T1** `net` probe (a DHCP lease from slirp), `http`/`stdhttp` (curl's body). **T2** check.sh/same.sh (same serial log as QEMU, byte for byte). **T3** everything about `stream.pump` (ARP answered, frames before timers, `max_frames_per_turn`), the Spill, `waitForBytes`/`sendAll` timeouts (timeouts.sh), `Wire.lose_one_sent_in`, net's free list and `reclaim`, the MSI-X wake (pc_vs_microvm). |
| **FAT** (`disk_fat*.zig`) | `disk_fat_test` (37), `_test_dirs` (22), `_test_fat32` (31), `_test_paths` (33), `disk_fat_dirent` (22), `disk_fat_faults_test` (17, fault and lie filters: fails, lands_nothing, lands_and_fails, torn, torn_tail, garbage, then_fail, then_garbage); `fat_sim` 8 seeds (20 in `properties`, 300 in long). Properties: 61 of 73. | **T1** `vfat`, `append`, `replace`/`replace_cached`, `restore`, `stdio`: **fsck.vfat and the Linux VFAT driver** read what we wrote, and we read what Linux wrote. That is the only check that the on-disk format agrees with someone else's reader. **T2** `refused.sh` (each disk request refused in turn), `sweep.sh` + `sound.sh` (power cuts, tears, rot, then fsck). **T3** judge `damaged` (a leaked cluster is reported and served past), `endurance`. |
| **Page cache** (`page_cache.zig`) | `page_cache.zig` (12), `page_sim` (1 test, 100 seeds in properties), `io_test` "the page cache is the disk: every change interleaved with reads, under evictions and failed writes", plus the hit-count tests; `floor_sim` (every slot taken, write past end, no memory to grow). 15 of 16 properties. | **T3** judge stories through the cache, `bench_page_cache.py` (speed). The boot's budget `min(page_cache_mib, free/4)` (gopher.zig:474) is checked nowhere. |
| **virtio** (`virtio.zig`, `device_wait.zig`) | `device_wait` (3: waits, timeout at the budget and across the wrap, NEEDS_RESET at once). `mostSectors`/`mostSectorsBlk`/`segmentsFor` (disk_fat_test_fat32.zig:544, 843, 895). `read_tries` retry (io_test.zig:812). `Block.flush` through `durable` on a memory disk. **Not tested:** `Queue.offer`/`take`, the descriptor chain in `transferOnce`, `negotiateWith`, MSI-X. | **T1** `block` probe (sector 0 signature, last sector written and read back), boot.sh `block` on PCI. **T2** check.sh/same.sh. **T3** pc_vs_microvm (MSI-X wake), `sweep.sh` DISK_* knobs, 193.2 ended disk (metal-vmm). |
| **SCSI** (`scsi.zig`, `scsi_mode.zig`, `disk_failures.zig`) | `scsi_mode` (6): `selectList` (SBC-3 page sent back, a short or SCSI-2 page refused), `report`, `blockLimitsMost` within its length. `disk_failures` (4): status kinds, CHECK CONDITION by sense key, UA ASCs that ask for a cache recheck. **`scsi.zig` itself: nothing** (6 properties, 0 here). | **T2/T3 only** (metal-vmm's SCSI disk, and the DigitalOcean volume): bring-up (INQUIRY, READ CAPACITY, Block Limits), sense parsing, UNIT ATTENTION retry, MODE SENSE/SELECT turning the cache off, `recheckCache`, `synchronize` and ILLEGAL REQUEST, short transfers (`VOLUME_CACHE`, `VOLUME_SYNC_FAIL`, `sweep.sh`). |
| **Drain** (`drain.zig`, `ready.zig`) | `drain.zig` (22), `drain_sim` (1, 100 seeds), `ready.zig` (22), `ready_sim` (1, 300 seeds): every edge of the body rule, 100-continue, the upload slot, deadlines, `.ready/.waiting/.abandoned`. | **T3** judge `uploads`, `bulk`, `lagging`, `throttle`; timeouts.sh. The glue in gopher.zig (`readyNow` 880: consume, reopen window, queue `100 Continue`, `uploaderOf`) is judged only there. |
| **Log ring** (`log_ring`, `kept_log`, `request_line`, `uploads_seen`) | `log_ring` (20: ring, pieces, the 3 redactions), `kept_log` (6: cold region, alternating slots, unsealed boot, header checks), `request_line` (5, including the plants), `uploads_seen` (5, log forging), `pure_sim` (200 seeds). | **T1** `restart`/`backoff` probes (the kept log across a real reset). **T3** judge `secret` (/admin/log is redacted), droplet. |
| **Serial gate / console** (`serial_gate.zig`, `serial.zig`) | `serial_gate` (5): a port that drains, stays full, refills mid-note, FIFO bursts, dropped counts. **`serial.zig`'s deferred backlog (`put`/`drain`/`flushPending`): nothing.** | **T1** droplet `hello.sh`, `screen.sh` (VGA). **T3** every judge reads the serial log, which tests ordering only incidentally. |
| **Loader / boot** (`droplet/loader.S`, `droplet/image.zig`, `pvh`, `boot`, `pages`, `stack`, `gpt`) | `image.zig` (6: GUIDs, segment header, loader overlap refused, site entry, whole sectors), `pvh` (11: holes, the largest span, the kernel cut out, no wrap), `pages` (12, std allocator contract and soak), `stack` (9), `gpt` (3 + `floor_sim`). | **T1 only**: `loader.S` (BIOS, e820 to PVH memmap, long mode) via `boot.sh` (every probe on dirty RAM; `memory` at 3 sizes across the 4 GB hole), `hello.sh`; `memory`, `realunset` probes. `boot.zig`, `restarting.keptRegion`/`reserved`. |
| **Interrupts / timer / clock** (`interrupts`, `pit`, `rtc`, `tsc`, `idle`, `rest_count`) | `pit.settle` (2), `rtc` decode (8: BCD/binary/12h/century/garbage), `civil` (5), `idle` (5), `idle_check` (5), `rest_count` (1: a device's wake across the counter's wrap). | **T1** `clock`, `realunset` probes (PIT against RTC, 4 formats, refusing .real before set). **T2** check.sh's clock cross-checks. **T3** pc_vs_microvm (it halted, took timer and MSI-X), `clock_boots.sh`. `startApic` refusals, `arm`, `rest`, IDT and `hasErrorCode`: no tier-0 test. |
| **Restart** (`restart.zig`, `restarting.zig`) | `restart.zig` (5: record round trip, CMOS garbage is no record, the count window, backoff 0/0/0/1/5/15 min, minutes since 2020), `pure_sim`. | **T1** `restart`, `backoff` probes (four restarts, then the back-off, end to end). |
| **Store** (`store*.zig`) | `store_test` (11), `store_model` (8), `store_sim` (3 tests; 1000 seeds in properties: model vs FAT vs strict Linux, cuts, torn writes, FAT32, NoSpace), `store_linux` via unit_files. | **T3** `store_judge.zig`/`store_cost.zig` against zig-webbox's `store.zig` (need the sibling). |
| **durable** (`durable.zig`, `io.durable`) | `durable.zig` (2), `durable_sim` (1000 seeds in properties), io_test's `durable()` calls. | **T2/T3** `VOLUME_SYNC_FAIL=1`, `VOLUME_CACHE=lie`, sweep's power cuts. |
| **request_heap** | 4 tests, `pure_sim`, `floor_sim`. | **T3** judge `endurance` (peak growth under 256 KiB), `churn`; the per-request "request heap: N bytes" line. |
| **gopher.zig host glue** | Type-checked only (`zig build check-apps` is **tier 3**; tier 0's `check` covers this repo's probe kernels). 0 tests. Its pure pieces moved out already: `drain`, `ready`, `request_line`, `uploads_seen`, `boot_facts`, `admin_reset.parse`, `idle.nsOfMs`. | **T3** only: the serving loop (`nextReady`, `quiet`, `consoleTurn`), `serveOne` (431/400 answers, refusals, the post-handler disposition), held streams (`serviceStreams`, budget displacement), `serviceDraining`, `readConfig`, volume choice, `logRequest`/`noteUpload` formatting (the judge greps the log). |

## Ranked candidates: pure logic that only a higher tier proves today, and could be a host test

Ranked by the chance of a bug that tier 0 would miss. **RED** means the sketched
test fails on today's code. *Pin* means it would pass today and holds the rule
in place.

1. **SCSI sense is read as fixed format only.** At `scsi.zig:165-167`, the key is
   `sense[2] & 0x0F` and ASC/ASCQ are `[12]/[13]`, with no look at the response
   code (`0x70/0x71` fixed, `0x72/0x73` descriptor). A disk that sends descriptor
   sense reads ILLEGAL REQUEST (key 5 at byte 1, ASC 20h at byte 2) as key 0.
   Then `synchronize` (233) never marks the disk write-through, so every response
   pays a failed flush, and a UNIT ATTENTION is never retried or rechecked
   (175-190). Seam: `scsi_mode.senseOf(sense, len) {key, asc, ascq}`.
   **RED:** `senseOf(&{0x72, 0x05, 0x20, 0x00, ...}, 8)` should give key 5, ASC
   0x20; the current expression gives key 0.
2. **The write-cache state machine** (`scsi.zig:306-333` `recheckCache`; bring-up
   at 419-428; `writeCache` parse at 251-271). After a reset the cache may be
   on, the disk may refuse to turn it off, and the synchronize afterwards may
   fail. Each case sets `write_cache` and `unflushed`, and only metal-vmm reaches
   any of them. Seam: `scsi_mode.afterRecheck(on: ?bool, taken: bool, after: ?bool,
   sync_ok: bool) struct { write_cache: ?bool, unflushed: bool }` and
   `scsi_mode.wceOf(page, want, residual) ?bool`. *Pin, durability-critical:*
   refused turn-off gives `{true, unflushed}`; turned off but the sync fails gives
   `{null, unflushed}`; a residual that leaves fewer than 8 bytes, or block
   descriptors that push the page past `got`, gives null.
3. **Host config and the choice of volume** (`gopher.zig:1906-2010`
   `readConfig`, 2305 `parseSerial`, 433-460). No judge boots a bad config or a
   wrong or missing volume: grep finds those refusals only in gopher.zig. Seam:
   `src/host_config.zig` `parse(text) union{ ok: Config, refused: []const u8 }`
   plus `chooseData(attached: ?u32, named: ?u32) enum{volume, boot_disk,
   missing, wrong}`. **RED:** `parseSerial("+2DE-8831")` and `("92_E-8831")`
   should be null. `std.fmt.parseInt` accepts `+` and `_`, which `configNumber`
   (2013) exists to refuse. Also pin the duplicate key, `idle_timeout_ms = 0`,
   `lose_one_sent_in = 1`, the `streams` bounds, and `page_cache_largest_kib = 0`.
4. **What happens to a connection after its handler returns, and to held streams**
   (`gopher.zig:1115-1152`, 1239-1290, 1177-1205). The paths are: timed out, then
   abandon; spill left and established, then draining; otherwise close; at the
   stream budget, end the oldest held (1120, `oldestHeld` 1328); carry, stuck,
   ping. Seam: `host_turn.zig` over an in-memory `tcp.Table`, as tcp_sim builds
   one. **RED (with a failing allocator):** at 1127, if `dupe` of the spill fails,
   the stream is kept anyway with its head or backlog cut (`else |_| {}`). The
   same file ends a stream that missed events, because "a stream with a gap in
   it is worse than one that starts again". Expect the stream not kept.
5. **The Spill's rule in `Stream.sendAll`** (`stream.zig:350-379`). Bytes go
   straight to the send queue only while the spill is empty. Bytes are kept
   only if `buf + rest <= cap` and `spilled_bytes + rest <= spill_limit`.
   Otherwise the spill is drained first. `spilled_bytes` must return to 0 after
   `deinit`. Seam: `spillDecision(pending, cap, used, global, limit, rest)`.
   Tier 0 cannot reach stream.zig at all. *Pin the boundaries*, and decide the
   case where the spill is non-empty and the connection is gone. Today the bytes
   are appended and the write succeeds, so the request logs "ok" for an answer
   the peer never gets.
6. **The window-reopen ACK is written three times:** `stream.zig:458`
   (`c.tight(c.window())`), `gopher.zig:886` (the same), and `tcp_sim.zig:963`
   (`c.room() < our_mss`), which the sim says is "as streamFn". The sim's
   expression agrees only because its rx (4096) is at least 2·MSS. Seam:
   `tcp.Conn.consumeAnnouncing(n) bool`, called by all three. *Pin:* with
   `rx.len = 2048`, consuming from a window of 1000 to 1100 must announce under
   `tight` (1100 >= min(1460, 1024)). The sim's rule would not.
7. **The console's deferred backlog** (`serial.zig:66-127`). Bytes are kept while
   `deferred`, the backlog is written first when it fills, and `drain(budget)`
   writes across the wrap. **No seam needed:** on the host `screen.put` is a
   no-op and `putPort` goes to `captureForTest`. *Pin:* deferred put, then
   `captured()` is empty; `drain(3)` gives the first 3 bytes; filling 256 KiB
   and putting more gives the whole backlog, then the new bytes, in order.
   Needs serial.zig, or a test file for it, added to `unit_files`.
8. **UNIT ATTENTION retry and the synchronize verdict** (`scsi.zig:175-190`,
   233-245). Seam: `commandSettled` over a `fn() Outcome` stub (or a list of
   outcomes). *Pin:* 3 UAs in a row return the UA and count
   `attentions_unsettled = 1`; a UA with ASC 29h sets `cache_recheck`; a
   synchronize CHECK CONDITION with ILLEGAL REQUEST gives ok,
   `write_cache = false`, `synchronize_unknown`; GOOD with a residual is
   `blk_s_ioerr` (`transfer`, 220-223).
9. **The virtqueue's indexes across the u16 wrap, and the chain `transferOnce`
   builds** (`virtio.zig:506-555`, 1062-1085). `offer` and `take` touch only
   the `Ring`, so a test can do this today: build a `Ring(8)` in host memory,
   set `avail_idx`/`used_idx` near 65535, and offer and take 20 times. Seam for
   the chain: `buildChain(desc, header, status, addr, len, per, read)`. *Pin:*
   the last descriptor has no NEXT; data descriptors have WRITE only on reads;
   more than `most_segments` is refused; the segments add up to `len`.
   Medium-low, since tier 1's `block` probe catches a broken chain at once.
10. **Interrupt bring-up decisions** (`interrupts.zig:343-353` `startApic`
    refusals from CPUID and the APIC_BASE MSR, `arm` 401, `hasErrorCode` 98).
    Seam: `apicRefusal(edx, ecx, apic_base) ?Refusal`. *Pin:* x2APIC enabled
    (bit 10) is refused; a base other than 0xFEE00000 is refused; `arm(999)`
    leaves `armed()` false (slice_ticks 0), so the machine never rests. Check
    `hasErrorCode` against the SDM list (8, 10-14, 17, 21, 29, 30). Today only
    pc_vs_microvm and a real droplet reach these.

**Also worth a line (lower):**
- `dhcp.findOption` (`dhcp.zig:108`) starts at 240 without checking the magic
  cookie at 236. A reply with the wrong cookie is parsed.
- `net.send`/`reclaim`: the free list and `lent` bookkeeping. `reclaim` calls
  `virtio.ack`, which is MMIO, so it needs the ack pulled out first.
- `readyNow`'s `100 Continue` (`gopher.zig:895`) queues a prefix if the queue
  takes fewer than 16 bytes, and then re-queues the whole line next turn. This
  is safe only while the queue is empty, which is assumed, not checked.
- Page-cache budget (`gopher.zig:474`) and `restarting.keptRegion`/`reserved`:
  arithmetic, needs `boot.image()` injected.
