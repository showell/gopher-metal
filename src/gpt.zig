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
//! Only what is needed to answer "where does the first partition start?". No
//! GUIDs are interpreted, no CRCs are checked, and nothing is written.

const virtio = @import("virtio.zig");

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

/// A 64-bit little-endian field, truncated: every address here is a sector
/// number on a disk small enough that the high word is zero, and a disk where
/// it is not is a disk this machine cannot address anyway.
fn le64(b: []const u8) u64 {
    return @as(u64, le32(b[0..4])) | (@as(u64, le32(b[4..8])) << 32);
}

/// The first partition in the table, or an error. `scratch` is one sector of
/// identity-mapped memory the device writes into.
pub fn firstPartition(blk: *virtio.Block, scratch: *[sector_size]u8) Error!Partition {
    if (blk.read(header_lba, @intFromPtr(scratch)) != virtio.blk_s_ok) return Error.ReadFailed;
    for (signature, 0..) |c, i| {
        if (scratch[i] != c) return Error.NotGpt;
    }

    const entries_lba = le64(scratch[72..80]);
    const entry_count = le32(scratch[80..84]);
    const entry_size = le32(scratch[84..88]);
    if (entry_count == 0 or entry_size < 128 or entry_size > sector_size) return Error.NotGpt;

    const per_sector = sector_size / entry_size;
    var index: u32 = 0;
    while (index < entry_count) : (index += 1) {
        const lba: u32 = @intCast(entries_lba + index / per_sector);
        if (index % per_sector == 0) {
            if (blk.read(lba, @intFromPtr(scratch)) != virtio.blk_s_ok) return Error.ReadFailed;
        }
        const e = scratch[(index % per_sector) * entry_size ..][0..128];

        // An all-zero type GUID is an unused slot, and the table is mostly
        // unused slots.
        var used = false;
        for (e[0..16]) |b| {
            if (b != 0) used = true;
        }
        if (!used) continue;

        const first = le64(e[32..40]);
        const last = le64(e[40..48]);
        if (first == 0 or last < first) continue;
        return .{ .first_lba = @intCast(first), .last_lba = @intCast(last) };
    }
    return Error.NoPartition;
}
