//! `fat16.zig` on a disk in memory (`virtio.Block.inMemory`): mount, write,
//! read back, append, remove, fill the disk, and damage it on purpose, all
//! on the host.
//!
//! **THE VOLUMES ARE MADE FROM THE SPEC**, by `test_disk.zig`, not by
//! `fat16.zig` (Microsoft's FAT specification: the BPB, two FATs, a fixed
//! root). And the checks read the disk's bytes directly where they can: the
//! free clusters are counted in the FAT as it sits on the disk, and the two
//! FAT copies are compared byte for byte. So a test does not ask `fat16.zig` to vouch for
//! itself.
//!
//! An independent reader of the images, written from the spec in Python, is
//! QUEUE.md item 4; the images these tests make are what it reads.

const std = @import("std");
const fat16 = @import("fat16.zig");
const options = @import("fat16_test_options");
const test_disk = @import("test_disk.zig");
const testing = std.testing;
const Shape = test_disk.Shape;
const Layout = test_disk.Layout;
const small = test_disk.small;

/// `test_disk.Disk`, kept as an image when the tests are asked to keep them
/// (-Dfat16-images).
const Disk = struct {
    fn make(label: []const u8, shape: Shape, cached: bool) !*test_disk.Disk {
        const d = try test_disk.Disk.make(label, shape, cached);
        d.images_dir = options.images_dir;
        return d;
    }
};

fn pattern(buf: []u8, seed: u8) []u8 {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
    return buf;
}

// Every test runs with the FAT on the disk and with it held in memory: the
// two paths through `fatGet` and `fatSet` must agree.
const both = [_]bool{ false, true };

test "a volume formatted from the spec mounts, and its root is empty" {
    for (both) |cached| {
        const d = try Disk.make("fresh", small, cached);
        defer d.deinit();
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("", try d.names(0, &buf));
        try testing.expect(d.free() > 4085);
    }
}

test "a file is read back exactly, at every size around a sector and a cluster" {
    for (both) |cached| {
        const d = try Disk.make("sizes", small, cached);
        defer d.deinit();
        const sizes = [_]usize{ 0, 1, 511, 512, 513, 1023, 1024, 1025, 4096, 70_000 };
        var data: [70_000]u8 = undefined;
        for (sizes, 0..) |size, k| {
            var name: [16]u8 = undefined;
            const path = try std.fmt.bufPrint(&name, "f{d}.bin", .{k});
            try d.vol.writeFile(path, pattern(data[0..size], @intCast(k)));
            try d.expectFile(path, data[0..size]);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a path makes its directories, and names of every length up to max_name read back by name" {
    for (both) |cached| {
        const d = try Disk.make("names", small, cached);
        defer d.deinit();
        var name: [fat16.max_name]u8 = undefined;
        var path: [128]u8 = undefined;
        for (1..fat16.max_name + 1) |len| {
            for (name[0..len], 0..) |*c, i| c.* = "abcdefghijklmnopqrstuvwxyz0123456789-"[i % 37];
            const p = try std.fmt.bufPrint(&path, "data/chat/{s}", .{name[0..len]});
            try d.vol.writeFile(p, name[0..len]);
            try d.expectFile(p, name[0..len]);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a name longer than max_name is refused, not truncated" {
    const d = try Disk.make("toolong", small, true);
    defer d.deinit();
    const long = "a" ** (fat16.max_name + 1);
    try testing.expectError(fat16.Error.BadName, d.vol.writeFile(long, "x"));
}

test "a replaced file gives back what it held" {
    for (both) |cached| {
        const d = try Disk.make("replaced", small, cached);
        defer d.deinit();
        var data: [20_000]u8 = undefined;
        try d.vol.writeFile("data/x", pattern(&data, 1));
        const after_big = d.free();
        try d.vol.writeFile("data/x", "small");
        // 20,000 bytes took 40 clusters; "small" takes one.
        try testing.expectEqual(after_big + 39, d.free());
        try d.expectFile("data/x", "small");
        try testing.expect(d.fatsAgree());
    }
}

test "appends cross cluster boundaries and read back whole" {
    for (both) |cached| {
        const d = try Disk.make("appends", small, cached);
        defer d.deinit();
        try d.vol.writeFile("data/log", "");
        var whole: [3000]u8 = undefined;
        _ = pattern(&whole, 7);
        var at: usize = 0;
        // Pieces of awkward sizes, so that writes start and end everywhere in
        // a cluster.
        const pieces = [_]usize{ 1, 510, 2, 513, 300, 700, 974 };
        for (pieces) |n| {
            try d.vol.writeInto("data/log", @intCast(at), whole[at..][0..n]);
            at += n;
            try d.expectFile("data/log", whole[0..at]);
        }
        try testing.expectEqual(whole.len, at);
        // An overwrite in the middle, and a write past the end refused.
        try d.vol.writeInto("data/log", 100, "OVERWRITTEN");
        @memcpy(whole[100..][0..11], "OVERWRITTEN");
        try d.expectFile("data/log", &whole);
        try testing.expectError(fat16.Error.BadChain, d.vol.writeInto("data/log", whole.len + 1, "hole"));
        try testing.expect(d.fatsAgree());
    }
}

test "removing a tree gives back every cluster, directories included" {
    for (both) |cached| {
        const d = try Disk.make("removetree", small, cached);
        defer d.deinit();
        const empty = d.free();
        var data: [4000]u8 = undefined;
        var path: [64]u8 = undefined;
        for (0..40) |k| {
            const p = try std.fmt.bufPrint(&path, "data/chat/{d}_{d}/sessions/topic-{d}.md", .{ k % 5, k % 3, k });
            try d.vol.writeFile(p, pattern(data[0 .. 100 * k], @intCast(k)));
        }
        try testing.expect(d.free() < empty);
        try d.vol.removeTree("data");
        try testing.expectEqual(empty, d.free());
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("", try d.names(0, &buf));
        try testing.expect(d.fatsAgree());
    }
}

test "a directory grows past its first cluster, and every name in it is found" {
    for (both) |cached| {
        const d = try Disk.make("growth", small, cached);
        defer d.deinit();
        // Each name takes three entries; a 512-byte cluster holds sixteen.
        var path: [64]u8 = undefined;
        for (0..200) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.vol.writeFile(p, p);
        }
        for (0..200) |k| {
            const p = try std.fmt.bufPrint(&path, "data/sessions/session-{d:0>4}.md", .{k});
            try d.expectFile(p, p);
        }
        try testing.expect(d.fatsAgree());
    }
}

test "a full disk refuses the write, and the refused write leaves nothing behind" {
    for (both) |cached| {
        // The smallest FAT16 there is: 4,085 clusters of 512 bytes.
        const d = try Disk.make("full", .{ .sectors = 4085 + 1 + 2 * 17 + 32 }, cached);
        defer d.deinit();
        const big = try testing.allocator.alloc(u8, 1 << 20);
        defer testing.allocator.free(big);
        _ = pattern(big, 3);
        try d.vol.writeFile("one", big); // 2,048 clusters
        const before = d.free();
        try testing.expect(before < 2048);
        try testing.expectError(fat16.Error.Full, d.vol.writeFile("two", big));
        try testing.expectEqual(before, d.free());
        try testing.expectError(fat16.Error.NotFound, d.vol.open("two"));
        // What fits still fits, and the first file is untouched.
        try d.vol.writeFile("three", big[0..1000]);
        try d.expectFile("one", big);
        try testing.expect(d.fatsAgree());
    }
}

test "a chain that runs into a free cluster is a broken chain, not a short file" {
    for (both) |cached| {
        const d = try Disk.make("damaged-chain", small, cached);
        defer d.deinit();
        var data: [2000]u8 = undefined;
        try d.vol.writeFile("broken", pattern(&data, 9));
        const e = try d.vol.open("broken");
        // Its second cluster is marked free in both copies of the FAT.
        const l = Layout.of(d.bytes);
        for (0..2) |copy| {
            std.mem.writeInt(u16, d.bytes[l.fat_start + copy * l.fat_bytes + @as(usize, e.first_cluster) * 2 ..][0..2], 0, .little);
        }
        try d.mount(cached); // so a held FAT sees the damage too
        var out: [2000]u8 = undefined;
        try testing.expectError(fat16.Error.BadChain, d.vol.readFile(e, &out));
    }
}

test "a disk that stops answering is an error, not a hang or a wrong answer" {
    const d = try Disk.make("io-failure", small, false);
    defer d.deinit();
    try d.vol.writeFile("data/x", "before");
    d.blk.fail_after = d.blk.requests;
    try testing.expectError(fat16.Error.ReadFailed, d.vol.open("data/x"));
    try testing.expect(std.meta.isError(d.vol.writeFile("data/y", "after")));
}
