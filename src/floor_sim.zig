//! **THE GROUND UNDER THE STORE, UNDER A SEED** (metal-vmm QUEUE item 76).
//! Small drives for the modules the Store will sit on that no other
//! simulator reaches, each built field by field with one field made wrong,
//! rather than from random bytes, so every refusal is met on purpose.
//!
//! - **GPT** (`gptSeed`): a disk in memory (`virtio.Block.inMemory`) with a
//!   protective MBR, a header and a table of entries, the data partition
//!   among unused slots and perhaps behind the kernel's own. Then one thing
//!   wrong, or nothing: the signature, the entry count or size, a read that
//!   fails at the header or at the table, the data partition missing, or
//!   its first sector zero or after its last. Oracle: the answer is exactly
//!   the one the wrong thing calls for, and with nothing wrong the data
//!   partition is the one answered.
//! - **The page cache's rare refusals** (`pageSeed`), which `page_sim`'s
//!   small budgets never make: every one of its 4096 slots taken (one seed
//!   in a hundred, since it costs 16 MB), a write past a kept file's end,
//!   and no memory to grow a copy. Oracle: the copy concerned is gone, the
//!   rest are as they were, and the count stays within the slots.
//! - **The log ring's redactor** (`redactSeed`): a line built part by part,
//!   a key naming a secret, `=` or `:`, perhaps a space, a quote or none,
//!   and a value that may be empty. Oracle: a non-empty value never comes
//!   out, and a line with an empty quoted value comes out as it went in.
//! - **FAT on a damaged volume** (`fatSeed`): `fat_sim` only ever meets a
//!   healthy volume and a failing disk. Here a small volume is formatted
//!   (`test_disk`), given a directory and a file of a few clusters through
//!   `fat16.zig`, then one thing is made wrong: a boot sector field, the
//!   file's or directory's first cluster on the disk, its size, a link in
//!   its chain, or a buffer or path handed in. Oracle: the operation answers
//!   exactly the error that thing calls for, and nothing panics.
//! - **The parsers** (`protoSeed`, `arpSeed`), metal-vmm item 78: a UDP
//!   datagram and an ARP request, each built field by field as a sender
//!   writes it, then one field made wrong, with the IP header's checksum
//!   made right again where the field is in it, so each wrong field meets
//!   the check meant for it and not the checksum's. Oracle: the parser
//!   refuses exactly when a field is wrong, and gives back every field when
//!   none is.
//! - **The request heap's growth** (`heapSeed`): two blocks, and the first
//!   asked to grow in place, which an arena can only do for its last.
//!   Oracle: it answers no, the block keeps its bytes, and what the request
//!   asked for (`used`) is unchanged.

const std = @import("std");
const virtio = @import("virtio.zig");
const gpt = @import("gpt.zig");
const kernel_partition = @import("kernel_partition.zig");
const PageCache = @import("page_cache.zig").PageCache;
const log_ring = @import("log_ring.zig");
const fat16 = @import("fat16.zig");
const test_disk = @import("test_disk.zig");
const proto = @import("proto.zig");
const arp = @import("arp.zig");
const RequestHeap = @import("request_heap.zig").RequestHeap;
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const Failure = error{SimulationFailed};

fn fail(seed: u64, comptime fmt: []const u8, args: anytype) Failure {
    std.debug.print("floor_sim seed {d}: " ++ fmt ++ "\n", .{seed} ++ args);
    return error.SimulationFailed;
}

// ── GPT ─────────────────────────────────────────────────────────────────────

const Wrong = enum { nothing, signature, no_entries, small_entries, big_entries, header_unread, table_unread, no_data, zero_first, backwards };

const data_guid = [16]u8{ 0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7 };

fn put32(b: []u8, v: u32) void {
    std.mem.writeInt(u32, b[0..4], v, .little);
}
fn put64(b: []u8, v: u64) void {
    std.mem.writeInt(u64, b[0..8], v, .little);
}

pub fn gptSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const wrong = r.enumValue(Wrong);
    const sectors = 64;
    var disk: [sectors * 512]u8 = @splat(0);
    // The header at LBA 1, its table from LBA 2.
    const entry_size: u32 = switch (wrong) {
        .small_entries => r.intRangeLessThan(u32, 1, 128),
        .big_entries => r.intRangeAtMost(u32, 513, 4096),
        else => ([_]u32{ 128, 256, 512 })[r.uintLessThan(usize, 3)],
    };
    const entry_count: u32 = if (wrong == .no_entries) 0 else r.intRangeAtMost(u32, 1, 32);
    const h = disk[512..1024];
    @memcpy(h[0..8], if (wrong == .signature) "EFI PARX" else "EFI PART");
    put64(h[72..80], 2);
    put32(h[80..84], entry_count);
    put32(h[84..88], entry_size);
    // Which slot holds the data partition, and perhaps the kernel's before it.
    const valid_size = entry_size >= 128 and entry_size <= 512;
    var want: ?gpt.Partition = null;
    if (entry_count > 0 and valid_size) {
        const per = 512 / entry_size;
        const slot = r.uintLessThan(u32, entry_count);
        const kernel_slot: ?u32 = if (slot > 0 and r.boolean()) r.uintLessThan(u32, slot) else null;
        const at = struct {
            fn entry(d: []u8, i: u32, size: u32, per_sector: u32) []u8 {
                return d[(2 + i / per_sector) * 512 + (i % per_sector) * size ..][0..128];
            }
        };
        if (kernel_slot) |k| {
            const e = at.entry(&disk, k, entry_size, per);
            @memcpy(e[0..16], &kernel_partition.type_guid);
            put64(e[32..40], 34);
            put64(e[40..48], 40);
        }
        const first = r.intRangeAtMost(u64, 41, 50);
        const last = first + r.intRangeAtMost(u64, 0, 10);
        if (wrong != .no_data) {
            const e = at.entry(&disk, slot, entry_size, per);
            @memcpy(e[0..16], &data_guid);
            switch (wrong) {
                .zero_first => {
                    put64(e[32..40], 0);
                    put64(e[40..48], last);
                },
                .backwards => {
                    put64(e[32..40], last + 1);
                    put64(e[40..48], first);
                },
                else => {
                    put64(e[32..40], first);
                    put64(e[40..48], last);
                    want = .{ .first_lba = @intCast(first), .last_lba = @intCast(last) };
                },
            }
        }
    }
    var blk = virtio.Block.inMemory(&disk);
    if (wrong == .header_unread) blk.fail_after = 0;
    if (wrong == .table_unread) blk.fail_after = 1;
    var scratch: [512]u8 = undefined;
    const got = gpt.dataPartition(&blk, &scratch);
    const expected: gpt.Error!gpt.Partition = switch (wrong) {
        .nothing => want.?,
        .signature, .no_entries, .small_entries, .big_entries => error.NotGpt,
        .header_unread, .table_unread => error.ReadFailed,
        .no_data, .zero_first, .backwards => error.NoPartition,
    };
    if (expected) |p| {
        const g = got catch |e| return fail(seed, "{s}: wanted LBA {d}-{d}, got {s}", .{ @tagName(wrong), p.first_lba, p.last_lba, @errorName(e) });
        if (g.first_lba != p.first_lba or g.last_lba != p.last_lba)
            return fail(seed, "{s}: wanted LBA {d}-{d}, got {d}-{d}", .{ @tagName(wrong), p.first_lba, p.last_lba, g.first_lba, g.last_lba });
    } else |want_err| {
        const g = got catch |e| {
            if (e != want_err) return fail(seed, "{s}: wanted {s}, got {s}", .{ @tagName(wrong), @errorName(want_err), @errorName(e) });
            return;
        };
        return fail(seed, "{s}: wanted {s}, got LBA {d}-{d}", .{ @tagName(wrong), @errorName(want_err), g.first_lba, g.last_lba });
    }
}

// ── the page cache ──────────────────────────────────────────────────────────

pub fn pageSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7061_6765); // "page"
    const r = prng.random();
    const gpa = std.testing.allocator;
    const page = PageCache.page;
    if (seed % 100 == 0) {
        // Every slot taken: the next file sends the oldest away.
        const c = gpa.create(PageCache) catch return fail(seed, "no memory for the cache", .{});
        defer gpa.destroy(c);
        c.* = PageCache.init(gpa, (PageCache.slots + 1) * page, page);
        defer c.clear();
        var name: [16]u8 = undefined;
        for (0..PageCache.slots + 1) |k| {
            const n = std.fmt.bufPrint(&name, "f{d}", .{k}) catch unreachable;
            c.put(n, "x");
        }
        if (c.count != PageCache.slots) return fail(seed, "{d} files kept, not {d}", .{ c.count, PageCache.slots });
        if (c.get("f0") != null) return fail(seed, "the oldest file stayed when every slot was taken", .{});
        if (c.get("f4096") == null) return fail(seed, "the newest file was not kept", .{});
        return;
    }
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    const c = gpa.create(PageCache) catch return fail(seed, "no memory for the cache", .{});
    defer gpa.destroy(c);
    c.* = PageCache.init(failing.allocator(), 8 * page, 6 * page);
    defer c.clear();
    const len = r.intRangeAtMost(usize, 1, page);
    var bytes: [2 * 4096]u8 = undefined;
    r.bytes(&bytes);
    c.put("data/a", bytes[0..len]);
    c.put("data/b", "kept");
    if (r.boolean()) {
        // Past the end: the disk would refuse it, and the copy cannot know.
        c.wrote("data/a", len + r.intRangeAtMost(usize, 1, 100), "z");
    } else {
        // Growing past the page it has, with no memory left for the next.
        failing.fail_index = failing.alloc_index;
        c.wrote("data/a", len, bytes[0 .. page + 1]);
    }
    if (c.get("data/a") != null) return fail(seed, "a copy that could not be kept exact is still kept", .{});
    const b = c.get("data/b") orelse return fail(seed, "another file's copy was lost", .{});
    if (!std.mem.eql(u8, b, "kept")) return fail(seed, "another file's copy changed", .{});
}

// ── the log ring's redactor ─────────────────────────────────────────────────

pub fn redactSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7265_6461_6374); // "redact"
    const r = prng.random();
    const keys = log_ring.Redactor.value_keys;
    var line: [128]u8 = undefined;
    var n: usize = 0;
    const put = struct {
        fn s(buf: []u8, at: *usize, text: []const u8) void {
            @memcpy(buf[at.*..][0..text.len], text);
            at.* += text.len;
        }
    };
    put.s(&line, &n, "GET /x?");
    put.s(&line, &n, keys[r.uintLessThan(usize, keys.len)]);
    put.s(&line, &n, if (r.boolean()) "=" else ":");
    if (r.boolean()) put.s(&line, &n, " ");
    const quote: ?u8 = switch (r.uintLessThan(u8, 3)) {
        0 => '"',
        1 => '\'',
        else => null,
    };
    const empty = quote != null and r.boolean();
    var secret: [12]u8 = undefined;
    for (&secret) |*c| c.* = "QWXZJ"[r.uintLessThan(usize, 5)];
    if (quote) |q| put.s(&line, &n, &.{q});
    if (!empty) put.s(&line, &n, &secret);
    if (quote) |q| put.s(&line, &n, &.{q});
    put.s(&line, &n, " done\n");
    var buf: [256]u8 = undefined;
    var ring = log_ring.Ring.init(&buf);
    ring.write(line[0..n]);
    var out: [256]u8 = undefined;
    const got = ring.read(&out);
    if (empty) {
        if (!std.mem.eql(u8, got, line[0..n])) return fail(seed, "an empty quoted value changed the line: {s} became {s}", .{ line[0..n], got });
    } else if (std.mem.indexOf(u8, got, &secret) != null) {
        return fail(seed, "a secret came out: {s}", .{got});
    }
}

// ── FAT on a damaged volume ─────────────────────────────────────────────────

const FatWrong = enum {
    fats_overflow,
    sum_overflow,
    loop_layout,
    too_many_clusters,
    cache_short,
    check_short,
    dir_read_whole,
    dir_read_at,
    room_short,
    first_outside_read,
    first_outside_layout,
    first_outside_append,
    size_long_whole,
    size_long_at,
    size_long_skip,
    reserved_at,
    reserved_skip,
    reserved_layout,
    reserved_write,
    reserved_write_skip,
    dir_first_outside,
    empty_path,
    past_4gib,
};

fn le16put(b: []u8, v: u16) void {
    std.mem.writeInt(u16, b[0..2], v, .little);
}

fn noFindings(_: void, _: fat16.Finding) void {}

pub fn fatSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6661_7464_616d); // "fatdam"
    const r = prng.random();
    const wrong = r.enumValue(FatWrong);
    const d = test_disk.Disk.make("damaged-floor", test_disk.small, false) catch return fail(seed, "no disk", .{});
    defer d.deinit();
    const v = &d.vol;
    const cluster_bytes = v.sectors_per_cluster * fat16.sector_size;
    // A file of a few clusters, in a directory.
    const clusters = r.intRangeAtMost(u32, 3, 6);
    var content: [6 * 512]u8 = undefined;
    r.bytes(&content);
    const size = clusters * cluster_bytes - r.uintLessThan(u32, cluster_bytes);
    _ = v.makePath("data/dir") catch |e| return fail(seed, "makePath: {s}", .{@errorName(e)});
    v.writeFile("data/f.bin", content[0..size]) catch |e| return fail(seed, "writeFile: {s}", .{@errorName(e)});
    var entry = v.open("data/f.bin") catch |e| return fail(seed, "open: {s}", .{@errorName(e)});
    // `slot` is the entry's byte offset in its sector.
    const dirent = d.bytes[entry.lba * 512 + entry.slot ..][0..32];
    const fat_at = v.fat_start * 512 + entry.first_cluster * 2;
    var out: [8 * 512]u8 = undefined;

    const Want = fat16.Error;
    var want: Want = undefined;
    const got: anyerror!void = switch (wrong) {
        .fats_overflow, .sum_overflow, .too_many_clusters => blk: {
            // The boot sector, as FAT32 reads it: a FAT size of 32 bits.
            const b = d.bytes[0..512];
            le16put(b[22..24], 0);
            if (wrong == .fats_overflow) {
                b[16] = 2;
                std.mem.writeInt(u32, b[36..40], 0x8000_0000 + r.uintLessThan(u32, 0x1000), .little);
                want = Want.BadBootSector;
            } else if (wrong == .sum_overflow) {
                // One FAT that fits, and reserved sectors past what is left.
                b[16] = 1;
                std.mem.writeInt(u32, b[36..40], 0xFFFF_FF00 + r.uintLessThan(u32, 0xF0), .little);
                le16put(b[14..16], 0x100 + r.uintLessThan(u16, 0x100));
                want = Want.BadBootSector;
            } else {
                b[13] = 1;
                le16put(b[19..21], 0);
                std.mem.writeInt(u32, b[32..36], 0xFFFF_0000 + r.uintLessThan(u32, 0xF000), .little);
                std.mem.writeInt(u32, b[36..40], 64, .little);
                want = Want.TooManyClusters;
            }
            var scratch: [512]u8 align(16) = undefined;
            break :blk if (fat16.Volume.mount(&d.blk, &scratch, 0)) |_| {} else |e| e;
        },
        .cache_short => blk: {
            want = Want.TooBig;
            const short = std.testing.allocator.alloc(u8, v.fatBytes() - 1 - r.uintLessThan(usize, 512)) catch return fail(seed, "no memory", .{});
            defer std.testing.allocator.free(short);
            break :blk if (v.cacheFat(short)) |_| {} else |e| e;
        },
        .check_short => blk: {
            want = Want.TooBig;
            const short = std.testing.allocator.alloc(u8, v.checkBytes() - 1) catch return fail(seed, "no memory", .{});
            defer std.testing.allocator.free(short);
            break :blk if (v.check(short, {}, noFindings)) |_| {} else |e| e;
        },
        .dir_read_whole, .dir_read_at => blk: {
            want = Want.NotFound;
            const dir = v.open("data/dir") catch |e| return fail(seed, "open dir: {s}", .{@errorName(e)});
            break :blk if (wrong == .dir_read_whole)
                (if (v.readFile(dir, &out)) |_| {} else |e| e)
            else
                (if (v.readAt(dir, 0, &out)) |_| {} else |e| e);
        },
        .room_short => blk: {
            want = Want.TooBig;
            break :blk if (v.readFile(entry, out[0 .. size - 1])) |_| {} else |e| e;
        },
        .first_outside_read, .first_outside_layout => blk: {
            want = Want.BadChain;
            entry.first_cluster = @intCast(v.max_cluster + 1 + r.uintLessThan(u32, 100));
            break :blk if (wrong == .first_outside_read)
                (if (v.readAt(entry, 0, &out)) |_| {} else |e| e)
            else
                (if (v.layout(entry)) |_| {} else |e| e);
        },
        .first_outside_append => blk: {
            want = Want.BadChain;
            le16put(dirent[26..28], @intCast(v.max_cluster + 1));
            break :blk v.writeInto("data/f.bin", size, "more");
        },
        .size_long_whole, .size_long_at, .size_long_skip => blk: {
            want = Want.BadChain;
            entry.size = size + 2 * cluster_bytes;
            break :blk switch (wrong) {
                .size_long_whole => if (v.readFile(entry, &out)) |_| {} else |e| e,
                .size_long_at => if (v.readAt(entry, 0, &out)) |_| {} else |e| e,
                else => if (v.readAt(entry, (clusters + 1) * cluster_bytes, &out)) |_| {} else |e| e,
            };
        },
        .reserved_at, .reserved_skip, .reserved_layout, .reserved_write, .reserved_write_skip => blk: {
            // The file's first link points at cluster 1, which is reserved.
            want = Want.BadChain;
            le16put(d.bytes[fat_at..][0..2], 1);
            break :blk switch (wrong) {
                .reserved_at => if (v.readAt(entry, 0, &out)) |_| {} else |e| e,
                .reserved_skip => if (v.readAt(entry, cluster_bytes + 1, &out)) |_| {} else |e| e,
                .reserved_layout => if (v.layout(entry)) |_| {} else |e| e,
                .reserved_write => v.writeInto("data/f.bin", 0, content[0 .. 2 * cluster_bytes]),
                else => v.writeInto("data/f.bin", cluster_bytes + 1, "x"),
            };
        },
        .loop_layout => blk: {
            // The file's last link goes back to its first.
            want = Want.BadChain;
            const last = entry.first_cluster + clusters - 1;
            le16put(d.bytes[v.fat_start * 512 + last * 2 ..][0..2], @intCast(entry.first_cluster));
            break :blk if (v.layout(entry)) |_| {} else |e| e;
        },
        .dir_first_outside => blk: {
            want = Want.BadChain;
            const dir = v.open("data/dir") catch |e| return fail(seed, "open dir: {s}", .{@errorName(e)});
            le16put(d.bytes[dir.lba * 512 + dir.slot ..][26..28], @intCast(v.max_cluster + 1));
            break :blk v.writeFile("data/dir/x", "y");
        },
        .empty_path => blk: {
            want = Want.BadName;
            // `writeFile` refuses an empty name before it looks for a
            // parent; `remove` and `rename` look first.
            const path = ([_][]const u8{ "", "/", "//" })[r.uintLessThan(usize, 3)];
            break :blk if (r.boolean()) v.remove(path) else v.rename(path, "data/g");
        },
        .past_4gib => blk: {
            // A file of nearly 4 GiB cannot be made here; its entry can say
            // it is one, and a write at its end reaches past.
            want = Want.TooBig;
            std.mem.writeInt(u32, dirent[28..32], 0xFFFF_FFFF, .little);
            break :blk v.writeInto("data/f.bin", 0xFFFF_FFFF, "xy");
        },
    };
    if (got) |_| return fail(seed, "{s}: wanted {s}, and it was taken", .{ @tagName(wrong), @errorName(want) }) else |e| {
        if (e != want) return fail(seed, "{s}: wanted {s}, got {s}", .{ @tagName(wrong), @errorName(want), @errorName(e) });
    }
}

// ── the parsers ─────────────────────────────────────────────────────────────

const UdpWrong = enum { nothing, short_frame, ethertype, version, options, fragment_offset, more_fragments, total_short, checksum, total_long, not_udp, udp_short, udp_len_short, udp_len_long };

fn ipChecksum(ip: []u8) void {
    ip[10] = 0;
    ip[11] = 0;
    std.mem.writeInt(u16, ip[10..12], proto.checksum(ip[0..20]), .big);
}

pub fn protoSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x7072_6f74_6f); // "proto"
    const r = prng.random();
    const wrong = r.enumValue(UdpWrong);
    var frame: [1600]u8 = undefined;
    const payload_len = r.intRangeAtMost(usize, 0, 200);
    r.bytes(frame[proto.udp_payload_at..][0..payload_len]);
    var src_mac: [6]u8 = undefined;
    r.bytes(&src_mac);
    const src_ip = [4]u8{ 10, 0, 2, r.int(u8) };
    const dst_ip = [4]u8{ 10, 0, 2, 15 };
    const sport = r.int(u16);
    const dport = r.int(u16);
    var len = proto.writeUdp(&frame, src_mac, .{ 2, 0, 0, 0, 0, 1 }, src_ip, dst_ip, sport, dport, payload_len);
    // Ethernet pads a short frame: a few bytes past the datagram are fine.
    const pad = r.uintLessThan(usize, 8);
    @memset(frame[len..][0..pad], 0);
    len += pad;
    const ip = frame[proto.eth_header_len..][0..20];
    const udp = frame[proto.eth_header_len + 20 ..][0..8];
    const total = std.mem.readInt(u16, ip[2..4], .big);
    switch (wrong) {
        .nothing => {},
        .short_frame => len = r.uintLessThan(usize, proto.eth_header_len + 20),
        .ethertype => std.mem.writeInt(u16, frame[12..14], 0x86DD, .big),
        .version => {
            ip[0] = (([_]u8{ 0, 6, 15 })[r.uintLessThan(usize, 3)] << 4) | 5;
            ipChecksum(ip);
        },
        .options => {
            ip[0] = 0x40 | ([_]u8{ 4, 6, 15 })[r.uintLessThan(usize, 3)];
            ipChecksum(ip);
        },
        .fragment_offset => {
            std.mem.writeInt(u16, ip[6..8], 0x4000 | r.intRangeAtMost(u16, 1, 0x1FFF), .big);
            ipChecksum(ip);
        },
        .more_fragments => {
            std.mem.writeInt(u16, ip[6..8], 0x2000, .big);
            ipChecksum(ip);
        },
        .total_short => {
            std.mem.writeInt(u16, ip[2..4], r.uintLessThan(u16, 20), .big);
            ipChecksum(ip);
        },
        .checksum => ip[10] ^= r.intRangeAtMost(u8, 1, 255),
        .total_long => {
            std.mem.writeInt(u16, ip[2..4], @intCast(len - proto.eth_header_len + r.intRangeAtMost(usize, 1, 100)), .big);
            ipChecksum(ip);
        },
        .not_udp => {
            ip[9] = ([_]u8{ proto.proto_tcp, 1, 99 })[r.uintLessThan(usize, 3)];
            ipChecksum(ip);
        },
        .udp_short => {
            std.mem.writeInt(u16, ip[2..4], 20 + r.uintLessThan(u16, 8), .big);
            ipChecksum(ip);
        },
        .udp_len_short => std.mem.writeInt(u16, udp[4..6], r.uintLessThan(u16, 8), .big),
        .udp_len_long => std.mem.writeInt(u16, udp[4..6], @intCast(total - 20 + r.intRangeAtMost(usize, 1, 100)), .big),
    }
    const got = proto.parseUdp(frame[0..len]);
    if (wrong == .nothing) {
        const d = got orelse return fail(seed, "a good datagram was refused", .{});
        if (d.src_port != sport or d.dst_port != dport or !std.mem.eql(u8, &d.src_ip, &src_ip) or d.payload.len != payload_len)
            return fail(seed, "a good datagram came back changed", .{});
    } else if (got != null) return fail(seed, "{s}: a datagram with it wrong was taken", .{@tagName(wrong)});
}

const ArpWrong = enum { nothing, short_frame, ethertype, hardware, protocol, lengths, reply };

pub fn arpSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6172_70); // "arp"
    const r = prng.random();
    const wrong = r.enumValue(ArpWrong);
    var frame: [64]u8 = @splat(0);
    var sender_mac: [6]u8 = undefined;
    r.bytes(&sender_mac);
    const sender_ip = [4]u8{ 10, 0, 2, r.int(u8) };
    const target_ip = [4]u8{ 10, 0, 2, 15 };
    proto.writeEth(&frame, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, sender_mac, proto.ethertype_arp);
    const a = frame[proto.eth_header_len..];
    std.mem.writeInt(u16, a[0..2], 1, .big);
    std.mem.writeInt(u16, a[2..4], proto.ethertype_ipv4, .big);
    a[4] = 6;
    a[5] = 4;
    std.mem.writeInt(u16, a[6..8], 1, .big);
    @memcpy(a[8..14], &sender_mac);
    @memcpy(a[14..18], &sender_ip);
    @memcpy(a[24..28], &target_ip);
    var len: usize = proto.eth_header_len + 28 + r.uintLessThan(usize, 18);
    switch (wrong) {
        .nothing => {},
        .short_frame => len = r.uintLessThan(usize, proto.eth_header_len + 28),
        .ethertype => std.mem.writeInt(u16, frame[12..14], proto.ethertype_ipv4, .big),
        .hardware => std.mem.writeInt(u16, a[0..2], r.intRangeAtMost(u16, 2, 40), .big),
        .protocol => std.mem.writeInt(u16, a[2..4], 0x86DD, .big),
        .lengths => if (r.boolean()) {
            a[4] = r.intRangeAtMost(u8, 7, 20);
        } else {
            a[5] = 16;
        },
        .reply => std.mem.writeInt(u16, a[6..8], ([_]u16{ 2, 3, 4 })[r.uintLessThan(usize, 3)], .big),
    }
    const got = arp.parseRequest(frame[0..len]);
    if (wrong == .nothing) {
        const q = got orelse return fail(seed, "a good ARP request was refused", .{});
        if (!std.mem.eql(u8, &q.sender_mac, &sender_mac) or !std.mem.eql(u8, &q.sender_ip, &sender_ip) or !std.mem.eql(u8, &q.target_ip, &target_ip))
            return fail(seed, "a good ARP request came back changed", .{});
    } else if (got != null) return fail(seed, "{s}: an ARP packet with it wrong was taken as a request", .{@tagName(wrong)});
}

// ── the request heap ────────────────────────────────────────────────────────

pub fn heapSeed(seed: u64) Failure!void {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x6865_6170); // "heap"
    const r = prng.random();
    var heap = RequestHeap.init(std.testing.allocator, r.uintLessThan(usize, 4096));
    defer heap.deinit();
    const a_alloc = heap.allocator();
    const a = a_alloc.alloc(u8, r.intRangeAtMost(usize, 1, 500)) catch return fail(seed, "no memory", .{});
    r.bytes(a);
    var before: [500]u8 = undefined;
    @memcpy(before[0..a.len], a);
    _ = a_alloc.alloc(u8, r.intRangeAtMost(usize, 1, 500)) catch return fail(seed, "no memory", .{});
    const used = heap.used;
    if (a_alloc.remap(a, a.len + r.intRangeAtMost(usize, 1, 4096)) != null)
        return fail(seed, "the first of two blocks grew in place", .{});
    if (!std.mem.eql(u8, a, before[0..a.len])) return fail(seed, "a block that could not grow lost its bytes", .{});
    if (heap.used != used) return fail(seed, "a growth that did not happen was counted", .{});
    heap.reset();
}

pub fn runSeed(seed: u64) Failure!void {
    try gptSeed(seed);
    try pageSeed(seed);
    try redactSeed(seed);
    try fatSeed(seed);
    try protoSeed(seed);
    try arpSeed(seed);
    try heapSeed(seed);
}

test "floor_sim: GPT, built field by field with one field wrong, a handful of seeds" {
    for (1..200) |seed| try runSeed(seed);
}
