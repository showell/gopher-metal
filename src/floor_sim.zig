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

const std = @import("std");
const virtio = @import("virtio.zig");
const gpt = @import("gpt.zig");
const kernel_partition = @import("kernel_partition.zig");
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

pub fn runSeed(seed: u64) Failure!void {
    try gptSeed(seed);
}

test "floor_sim: GPT, built field by field with one field wrong, a handful of seeds" {
    for (1..200) |seed| try runSeed(seed);
}
