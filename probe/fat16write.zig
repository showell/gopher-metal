//! `fat16-write`, again, in zig on bare metal.
//!
//! Cobblestone's `codex/test/fat16-write.codex` writes HELLO.TXT and BIN.DAT
//! to a FAT16 volume and prints seven lines about what happened. That test runs
//! three other ways already — under codex-vm, through the Roc machine, and on
//! `roc-apps/floor` where its console is pinned six ways including under
//! injected faults.
//!
//! **THIS PRINTS THE SAME SEVEN LINES OR IT FAILS.** `probe/expect/` holds the
//! verdict, copied from the ladder, and `run.sh` compares. Two filesystems in
//! two languages, one disk image, one answer.

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
var buf: [4096]u8 align(4096) = undefined;

const hello_name = "HELLO.TXT";
const hello_text = "Hello, disk!";
const bin_name = "BIN.DAT";
const bin_bytes = [_]u8{ 1, 2, 3, 254 };

fn putBool(b: bool) void {
    serial.put(if (b) "True" else "False");
}

pub fn kmain() noreturn {
    serial.init();

    const base = virtio.find(virtio.device_id_block) orelse
        serial.fail("no virtio-blk device in any mmio slot");
    var blk = blk_mem.bring(base) catch serial.fail("the block device would not come up");
    const part = gpt.firstPartition(&blk, &scratch) catch serial.fail("no partition table");
    var vol = fat16.Volume.mount(&blk, &scratch, part.first_lba) catch serial.fail("the volume would not mount");

    // wrote
    var ok = true;
    vol.writeFile(hello_name, hello_text) catch {
        ok = false;
    };
    serial.put("wrote ");
    putBool(ok);
    serial.put("\n");

    // exists
    const there = (vol.find(0, hello_name) catch serial.fail("the lookup failed")) != null;
    serial.put("exists ");
    putBool(there);
    serial.put("\n");

    // readback
    serial.put("readback ");
    if (vol.find(0, hello_name) catch null) |e| {
        const n = vol.readFile(e, &buf) catch serial.fail("HELLO.TXT would not read");
        serial.put(buf[0..n]);
    } else {
        serial.put("<none>");
    }
    serial.put("\n");

    // size
    serial.put("size ");
    if (vol.find(0, hello_name) catch null) |e| {
        serial.putDec(e.size);
    } else {
        serial.put("-1");
    }
    serial.put("\n");

    // wrote-bin
    var bok = true;
    vol.writeFile(bin_name, &bin_bytes) catch {
        bok = false;
    };
    serial.put("wrote-bin ");
    putBool(bok);
    serial.put("\n");

    // bin -- each byte followed by a space, as the Codex side prints it
    serial.put("bin ");
    if (vol.find(0, bin_name) catch null) |e| {
        const n = vol.readFile(e, &buf) catch serial.fail("BIN.DAT would not read");
        for (buf[0..n]) |b| {
            serial.putDec(b);
            serial.put(" ");
        }
    } else {
        serial.put("<none>");
    }
    serial.put("\n");

    // absent
    const gone = (vol.find(0, "NOPE.XXX") catch serial.fail("the lookup failed")) != null;
    serial.put("absent ");
    putBool(gone);
    serial.put("\n");

    serial.exitQemu(0);
}

pub const panic = @import("std").debug.FullPanic(panicImpl);
fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    serial.put("PANIC: ");
    serial.put(msg);
    serial.put("\n");
    serial.exitQemu(1);
}
