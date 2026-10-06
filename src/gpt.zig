//! Finding a partition on a GPT disk.
//!
//! **SECTOR 0 IS NOT THE FILESYSTEM.** On a GPT disk, LBA 0 is a protective
//! MBR whose only job is to stop old tools thinking the disk is empty; the
//! real table is at LBA 1 and the volume starts wherever it says. Cobblestone's
//! fixtures are laid out this way — one "EFI System" partition at LBA 2048 —
//! which is why its `Fat16` cites a `Gpt` chapter, and why a FAT16 reader that
//! mounts sector 0 gets a boot sector of zeros and concludes, correctly and
//! uselessly, that the volume is not FAT16.
//!
//! Only what is needed to answer "where does the data partition start?": the
//! first partition that is not gopher-metal's own kernel partition (a droplet's
//! disk has both; Cobblestone's fixtures and the judge's volumes have only the
//! data). That one type GUID is the only one interpreted; no CRCs are
//! checked, and nothing is written.

const std = @import("std");
const props = @import("coverage");
const virtio = @import("virtio.zig");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
const kernel_partition = @import("kernel_partition.zig");

pub const sector_size: u32 = 512;
pub const Error = error{ ReadFailed, NotGpt, NoPartition };

const header_lba: u32 = 1;
const signature = "EFI PART";

pub const Partition = struct {
    first_lba: u32,
    last_lba: u32,

    pub fn sectors(self: Partition) u32 {
        return self.last_lba - self.first_lba + 1;
    }
};

fn le32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

fn eql16(a: *const [16]u8, b: *const [16]u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// A 64-bit little-endian field, truncated: every address here is a sector
/// number on a disk small enough that the high word is zero, and a disk where
/// it is not is a disk this machine cannot address anyway.
fn le64(b: []const u8) u64 {
    return @as(u64, le32(b[0..4])) | (@as(u64, le32(b[4..8])) << 32);
}

/// The first partition in the table that is not the kernel's, or an error.
/// `scratch` is one sector of identity-mapped memory the device writes into.
pub fn dataPartition(blk: *virtio.Block, scratch: *[sector_size]u8) Error!Partition {
    if (blk.read(header_lba, @intFromPtr(scratch)) != virtio.blk_s_ok) {
        props.reachable(@src(), "gpt: the header cannot be read", null);
        return Error.ReadFailed;
    }
    for (signature, 0..) |c, i| {
        if (scratch[i] != c) {
            props.reachable(@src(), "gpt: no EFI PART signature, so not GPT", null);
            return Error.NotGpt;
        }
    }

    const entries_lba = le64(scratch[72..80]);
    const entry_count = le32(scratch[80..84]);
    const entry_size = le32(scratch[84..88]);
    if (entry_count == 0 or entry_size < 128 or entry_size > sector_size) {
        props.reachable(@src(), "gpt: a table with no entries, or entries of a size this reader refuses", .{ .count = entry_count, .size = entry_size });
        return Error.NotGpt;
    }

    const per_sector = sector_size / entry_size;
    var index: u32 = 0;
    while (index < entry_count) : (index += 1) {
        const lba: u32 = @intCast(entries_lba + index / per_sector);
        if (index % per_sector == 0) {
            if (blk.read(lba, @intFromPtr(scratch)) != virtio.blk_s_ok) {
                props.reachable(@src(), "gpt: a sector of entries cannot be read", .{ .lba = lba });
                return Error.ReadFailed;
            }
        }
        const e = scratch[(index % per_sector) * entry_size ..][0..128];

        // An all-zero type GUID is an unused slot, and the table is mostly
        // unused slots.
        var used = false;
        for (e[0..16]) |b| {
            if (b != 0) used = true;
        }
        if (!used) continue;
        if (eql16(e[0..16], &kernel_partition.type_guid)) {
            props.reachable(@src(), "gpt: the kernel's own partition is passed over", null);
            continue;
        }

        const first = le64(e[32..40]);
        const last = le64(e[40..48]);
        if (first == 0 or last < first) {
            props.reachable(@src(), "gpt: a partition with no first sector, or ending before it starts, is passed over", null);
            continue;
        }
        props.alwaysLessThanOrEqualTo(@src(), first, last, "gpt: a partition answered starts no later than it ends", null);
        return .{ .first_lba = @intCast(first), .last_lba = @intCast(last) };
    }
    props.reachable(@src(), "gpt: no partition but the kernel's, so no data partition", .{ .entries = entry_count });
    return Error.NoPartition;
}
