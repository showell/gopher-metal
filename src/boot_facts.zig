//! **WHAT THE BOOT FOUND, KEPT AS A HOST FACT** (metal-vmm QUEUE 193, gap
//! 10). Reads that failed at boot and answered when tried again, and how the
//! FAT's copies stood at mount, were boot log lines only: after about a
//! ring's worth of requests they were gone from /admin/log. This says them
//! on /admin/host for as long as the machine runs.

const std = @import("std");
const Mirrors = @import("disk_fat_fat.zig").Mirrors;

/// One disk's boot: `reads_retried` (its Block's, which stops counting
/// when boot ends), and its volume's mount, if it has one.
pub fn write(w: *std.Io.Writer, reads_retried: u64, mounted: ?Mirrors) !void {
    try w.print("{d} reads failed at boot and answered when tried again; ", .{reads_retried});
    const m = mounted orelse return w.writeAll("no FAT mounted");
    try w.writeAll("the FAT's copies at mount: ");
    switch (m.found) {
        .agree => return w.writeAll("agreed"),
        .past_weighing => try w.writeAll("differed (past weighing)"),
        .unchecked => try w.writeAll("differed (no room to weigh them)"),
        .unweighed => try w.writeAll("differed (could not be weighed)"),
        .weighed => try w.writeAll("differed (weighed)"),
        .tied => try w.writeAll("differed (checked alike)"),
    }
    switch (m.repair) {
        .refused => try w.writeAll(", the first held, and the disk REFUSED the repair"),
        .none => try w.writeAll(", the first held, neither written"),
        .written => try w.print(", {d} sectors of the {s} written from the {s}", .{
            m.repaired, if (m.trusted == 1) "first" else "second", if (m.trusted == 1) "second" else "first",
        }),
    }
}

const testing = std.testing;

fn said(reads_retried: u64, mounted: ?Mirrors) ![]const u8 {
    const S = struct {
        var buf: [512]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    try write(&w, reads_retried, mounted);
    return w.buffered();
}

test "host facts carry the reads retried at boot, and how the FAT's copies stood at mount" {
    try testing.expectEqualStrings("3 reads failed at boot and answered when tried again; no FAT mounted", try said(3, null));
    try testing.expectEqualStrings("0 reads failed at boot and answered when tried again; the FAT's copies at mount: agreed", try said(0, .{}));
    try testing.expectEqualStrings("0 reads failed at boot and answered when tried again; the FAT's copies at mount: differed (weighed), 7 sectors of the first written from the second", try said(0, .{ .found = .weighed, .repair = .written, .repaired = 7, .trusted = 1 }));
    try testing.expectEqualStrings("1 reads failed at boot and answered when tried again; the FAT's copies at mount: differed (past weighing), the first held, and the disk REFUSED the repair", try said(1, .{ .found = .past_weighing, .repair = .refused }));
    try testing.expectEqualStrings("0 reads failed at boot and answered when tried again; the FAT's copies at mount: differed (could not be weighed), the first held, neither written", try said(0, .{ .found = .unweighed }));
    try testing.expectEqualStrings("0 reads failed at boot and answered when tried again; the FAT's copies at mount: differed (checked alike), the first held, neither written", try said(0, .{ .found = .tied }));
}
