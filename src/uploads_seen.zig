//! **DID THAT UPLOAD WORK, AND WHAT DID IT COST** (metal-vmm QUEUE 189.4):
//! the last uploads this boot saw, each with its time, path (which names its
//! topic), kind, bytes, how long it took to arrive, its turn, its disk
//! requests and its answer, and since boot a count by answer. Pure: the
//! kernel records what it saw, and /admin/host and the log say it.
//!
//! **THE ANSWER, NAMED**, from the status the upload got and whether its body
//! came whole: ok; too big (413); over quota (the upload route's only 403);
//! a kind not taken (415); writes refused (a 503 from a volume that refuses
//! them, 188.2); busy (a 503 for want of an upload slot); taken over (409:
//! the same person's newer upload took its place); the client gone (a body
//! not whole, too slow (408), or no answer at all); failed (another 5xx);
//! refused (any other 4xx).

const std = @import("std");
const request_line = @import("request_line.zig");

pub const Outcome = enum {
    ok,
    too_big,
    over_quota,
    unsupported_kind,
    writes_refused,
    busy,
    taken_over,
    client_gone,
    failed,
    refused,

    pub fn text(o: Outcome) []const u8 {
        return switch (o) {
            .ok => "ok",
            .too_big => "refused: too big",
            .over_quota => "refused: over quota",
            .unsupported_kind => "refused: a kind not taken",
            .writes_refused => "refused: writes refused",
            .busy => "refused: busy",
            .taken_over => "refused: taken over by a newer upload",
            .client_gone => "the client gone",
            .failed => "failed",
            .refused => "refused",
        };
    }
};

/// What an upload's answer is named from: its status (0: none went out),
/// whether its body came whole (all of it, not cut short by its client:
/// the drain's `cameWhole`), and how the route ended (an error's name).
pub fn classify(status: u16, whole: bool, ended: []const u8) Outcome {
    // Refused at its head, before the body was waited for: whole or not,
    // the refusal is the answer.
    switch (status) {
        413 => return .too_big,
        409 => return .taken_over,
        408 => return .client_gone,
        503 => return if (std.mem.eql(u8, ended, "ReadOnlyFileSystem")) .writes_refused else .busy,
        else => {},
    }
    if (!whole or status == 0) return .client_gone;
    return switch (status) {
        200...299 => .ok,
        403 => .over_quota,
        415 => .unsupported_kind,
        500...502, 504...599 => .failed,
        else => .refused,
    };
}

/// The kind the upload's part says it is (`image/png`), from the part's own
/// headers at the body's start, or null. Never its file name.
pub fn kindOf(body: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, body[0..@min(body.len, 1024)], "\r\n\r\n") orelse return null;
    var lines = std.mem.splitSequence(u8, body[0..head_end], "\r\n");
    while (lines.next()) |line| {
        const key = "content-type:";
        if (line.len < key.len or !std.ascii.eqlIgnoreCase(line[0..key.len], key)) continue;
        const v = std.mem.trim(u8, line[key.len..], " \t");
        return if (v.len == 0) null else v;
    }
    return null;
}

pub const Upload = struct {
    number: u64,
    unix_ms: ?i64,
    path: Text(96) = .{},
    kind: Text(48) = .{},
    bytes: u64,
    arrival_ms: u64,
    turn_ms: ?u64,
    disk_requests: u64,
    status: u16,
    /// Its body all in (194.2's `cameWhole`); a body that never arrived
    /// is said "not whole after", not "arrived in" (189's minor 9).
    came_whole: bool = true,
    outcome: Outcome,

    pub fn write(u: *const Upload, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (u.unix_ms) |ms| {
            try request_line.writeTime(w, ms);
            try w.writeByte(' ');
        }
        try w.print("request {d}: {s}", .{ u.number, u.path.slice() });
        if (u.kind.len > 0) try w.print(", {s}", .{u.kind.slice()});
        try w.print(", {d} bytes, {s} {d} ms", .{ u.bytes, if (u.came_whole) "arrived in" else "not whole after", u.arrival_ms });
        if (u.turn_ms) |t| try w.print(", its turn {d} ms", .{t});
        try w.print(", {d} disk requests: {s}", .{ u.disk_requests, u.outcome.text() });
        if (u.status != 0) try w.print(" ({d})", .{u.status});
    }
};

/// A short text kept by value (a record outlives the request it came from).
pub fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn of(s: []const u8) @This() {
            var t: @This() = .{};
            t.len = @min(s.len, n);
            @memcpy(t.buf[0..t.len], s[0..t.len]);
            return t;
        }

        pub fn slice(t: *const @This()) []const u8 {
            return t.buf[0..t.len];
        }
    };
}

pub const keep = 20;

pub const Seen = struct {
    last: [keep]Upload = undefined,
    /// Uploads recorded since boot.
    total: u64 = 0,
    counts: std.EnumArray(Outcome, u64) = .initFill(0),

    pub fn record(s: *Seen, u: Upload) void {
        s.last[@intCast(s.total % keep)] = u;
        s.total += 1;
        s.counts.getPtr(u.outcome).* += 1;
    }

    /// The `i`th newest kept, 0 the newest.
    pub fn newest(s: *const Seen, i: usize) ?*const Upload {
        if (i >= @min(s.total, keep)) return null;
        return &s.last[@intCast((s.total - 1 - i) % keep)];
    }

    /// `5 since boot: 3 ok, 1 refused: over quota, 1 the client gone`, the
    /// answers in their order, the ones with none left out.
    pub fn writeCounts(s: *const Seen, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (s.total == 0) return w.writeAll("none since boot");
        try w.print("{d} since boot:", .{s.total});
        var first = true;
        for (std.enums.values(Outcome)) |o| {
            const n = s.counts.get(o);
            if (n == 0) continue;
            try w.print("{s} {d} {s}", .{ if (first) "" else ",", n, o.text() });
            first = false;
        }
    }
};

const testing = std.testing;

test "uploads: each answer named from its status, its body and how it ended" {
    try testing.expectEqual(Outcome.ok, classify(200, true, "ok"));
    try testing.expectEqual(Outcome.too_big, classify(413, false, "(refused at its head)"));
    try testing.expectEqual(Outcome.over_quota, classify(403, true, "ok"));
    try testing.expectEqual(Outcome.unsupported_kind, classify(415, true, "ok"));
    try testing.expectEqual(Outcome.writes_refused, classify(503, true, "ReadOnlyFileSystem"));
    try testing.expectEqual(Outcome.busy, classify(503, false, "every upload slot is held"));
    try testing.expectEqual(Outcome.taken_over, classify(409, false, "a newer upload"));
    try testing.expectEqual(Outcome.client_gone, classify(408, false, "too slow"));
    try testing.expectEqual(Outcome.client_gone, classify(0, false, "EndOfStream"));
    // A body its client stopped short of (a tab closed mid-upload) is the
    // client gone, whatever its route then answered (194.2).
    try testing.expectEqual(Outcome.client_gone, classify(400, false, "ok"));
    try testing.expectEqual(Outcome.failed, classify(500, true, "OutOfMemory"));
    try testing.expectEqual(Outcome.refused, classify(400, true, "MalformedForm"));
}

test "uploads: the kind from the part's own header, any case, and never more than the header" {
    const body = "------b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"secret plans.png\"\r\nContent-Type: image/png\r\n\r\n\x89PNG...";
    try testing.expectEqualStrings("image/png", kindOf(body).?);
    try testing.expectEqualStrings("video/mp4", kindOf("--b\r\ncontent-type:  video/mp4\r\n\r\nxx").?);
    try testing.expect(kindOf("--b\r\nContent-Disposition: form-data\r\n\r\nno type") == null);
    // Past the part's headers is the file's bytes, never read for a kind.
    try testing.expect(kindOf("--b\r\n\r\nContent-Type: text/evil\r\n") == null);
}

test "uploads: the last twenty kept, newest first, and every one counted by its answer" {
    var s: Seen = .{};
    for (0..25) |i| s.record(.{
        .number = i,
        .unix_ms = null,
        .bytes = 100,
        .arrival_ms = 1,
        .turn_ms = 2,
        .disk_requests = 3,
        .status = if (i % 5 == 0) 403 else 200,
        .outcome = if (i % 5 == 0) .over_quota else .ok,
    });
    try testing.expectEqual(@as(u64, 25), s.total);
    try testing.expectEqual(@as(u64, 24), s.newest(0).?.number);
    try testing.expectEqual(@as(u64, 5), s.newest(19).?.number);
    try testing.expect(s.newest(20) == null);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.writeCounts(&w);
    try testing.expectEqualStrings("25 since boot: 20 ok, 5 refused: over quota", w.buffered());
    const none: Seen = .{};
    w = .fixed(&buf);
    try none.writeCounts(&w);
    try testing.expectEqualStrings("none since boot", w.buffered());
}

test "uploads: one upload's line says all of it, and leaves out what is not known" {
    var u: Upload = .{
        .number = 12,
        .unix_ms = 1_791_900_127_123,
        .path = .of("/gopher/chat/c/1_2/ChitChat/upload"),
        .kind = .of("image/png"),
        .bytes = 9000,
        .arrival_ms = 40,
        .turn_ms = 3,
        .disk_requests = 7,
        .status = 200,
        .outcome = .ok,
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try u.write(&w);
    try testing.expectEqualStrings("2026-10-13T14:02:07.123Z request 12: /gopher/chat/c/1_2/ChitChat/upload, image/png, 9000 bytes, arrived in 40 ms, its turn 3 ms, 7 disk requests: ok (200)", w.buffered());
    u.unix_ms = null;
    u.kind = .{};
    u.turn_ms = null;
    u.status = 0;
    u.outcome = .client_gone;
    w = .fixed(&buf);
    try u.write(&w);
    try testing.expectEqualStrings("request 12: /gopher/chat/c/1_2/ChitChat/upload, 9000 bytes, arrived in 40 ms, 7 disk requests: the client gone", w.buffered());
}
