//! A kernel that mounts a FAT16 volume over virtio-blk and reads it.
//!
//! The fixture is Cobblestone's `fat16-list.disk`, and the expectations below
//! are its test's own verdict — `CODEX.CDX` in the root, an `EFI` directory,
//! and `EFI/BOOT/BOOTX64.EFI` under it. That makes this a comparison rather
//! than a demonstration: the Roc `Fat16` chapter in `roc-apps/floor` is green
//! against the same image, so two independent filesystems are being asked the
//! same questions about the same bytes.

const metal = @import("metal");
const serial = metal.serial;
const virtio = metal.virtio;
const gpt = metal.gpt;
const fat16 = metal.fat16;

comptime {
    _ = metal.boot;
}

var blk_mem: virtio.BlockMemory align(4096) = .{};
var scratch: [fat16.sector_size]u8 align(4096) = undefined;
var file: [512 * 1024]u8 align(4096) = undefined;

/// What `fat16-list`'s verdict says is on this volume.
const want_root = [_][]const u8{ "EFI", "CODEX.CDX" };
const want_path = "EFI/BOOT/BOOTX64.EFI";

const Seen = struct {
    names: [16][12]u8 = undefined,
    lens: [16]u8 = undefined,
    count: usize = 0,

    fn each(self: *Seen, e: fat16.Entry) void {
        if (self.count >= self.names.len) return;
        self.names[self.count] = e.name;
        self.lens[self.count] = e.name_len;
        self.count += 1;
    }

    fn has(self: *const Seen, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (eql(self.names[i][0..self.lens[i]], name)) return true;
        }
        return false;
    }
};

pub fn kmain() noreturn {
    serial.init();
    serial.put("gopher-metal fat16 probe\n");

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");

    // **SECTOR 0 IS NOT THE FILESYSTEM.** These fixtures are GPT disks with a
    // protective MBR, so the volume starts wherever the table says.
    const part = gpt.firstPartition(&blk, &scratch) catch |e| switch (e) {
        error.NotGpt => serial.fail("no GPT header at LBA 1"),
        error.NoPartition => serial.fail("the GPT table has no partition in it"),
        else => serial.fail("the partition table would not read"),
    };
    serial.put("  partition: LBA ");
    serial.putDec(part.first_lba);
    serial.put("..");
    serial.putDec(part.last_lba);
    serial.put("\n");

    var vol = fat16.Volume.mount(&blk, &scratch, part.first_lba) catch |e| switch (e) {
        error.NotFat16 => serial.fail("this volume is not FAT16"),
        error.BadBootSector => serial.fail("the boot sector does not describe a volume"),
        else => serial.fail("the volume would not mount"),
    };
    serial.put("  mounted: ");
    serial.putDec(vol.sectors_per_cluster);
    serial.put(" sectors a cluster, root at ");
    serial.putDec(vol.root_start);
    serial.put(", data at ");
    serial.putDec(vol.data_start);
    serial.put("\n");

    var seen = Seen{};
    vol.list(0, &seen, Seen.each) catch serial.fail("the root directory would not list");
    serial.put("  root:");
    var i: usize = 0;
    while (i < seen.count) : (i += 1) {
        serial.put(" ");
        serial.put(seen.names[i][0..seen.lens[i]]);
    }
    serial.put("\n");

    for (want_root) |name| {
        if (!seen.has(name)) {
            serial.put("  missing: ");
            serial.put(name);
            serial.put("\n");
            serial.fail("the root is not what fat16-list's verdict says it is");
        }
    }

    // A path two directories deep, which is the part a flat reader gets wrong.
    const entry = vol.open(want_path) catch serial.fail("EFI/BOOT/BOOTX64.EFI would not open");
    serial.put("  ");
    serial.put(want_path);
    serial.put(": ");
    serial.putDec(entry.size);
    serial.put(" bytes\n");
    if (entry.size == 0) serial.fail("that file is empty, which the fixture's is not");

    // Reading it proves the cluster chain is walked, not just the directory.
    const n = vol.readFile(entry, &file) catch |e| switch (e) {
        error.TooBig => serial.fail("the file is larger than this probe's buffer"),
        error.BadChain => serial.fail("its cluster chain does not end"),
        else => serial.fail("the file would not read"),
    };
    if (n != entry.size) serial.fail("the read came up short of the size the directory gave");
    serial.put("  read ");
    serial.putDec(n);
    serial.put(" bytes; first two: ");
    serial.putHex(file[0], 2);
    serial.putHex(file[1], 2);
    serial.put("\n");

    // A PE executable, which BOOTX64.EFI is: "MZ".
    if (file[0] != 'M' or file[1] != 'Z') serial.fail("that is not the file the fixture holds");

    // And a name that is not there must not be found.
    if ((vol.find(0, "NOSUCH.TXT") catch serial.fail("the lookup failed")) != null) {
        serial.fail("a name that is not on the volume was found anyway");
    }

    serial.pass();
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub const panic = @import("std").debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
