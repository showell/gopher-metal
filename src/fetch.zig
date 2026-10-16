//! **ONE GET, AND HOW IT ENDED** (metal-vmm QUEUE 225, chunks 8 and 9):
//! what the two clients of tcp.zig's `connect` share, `native/fetch.zig` on
//! Linux and `probe/fetch.zig` in the kernel. Pure: the answer is read from
//! bytes handed in, and the outcome is a value, each with its exit code.

const std = @import("std");

/// **HOW A FETCH ENDS**, one exit code each, so a judge reads the outcome
/// from the status alone. 1 is the program's own: it could not start.
pub const Outcome = enum(u8) {
    /// A 200, with as many body bytes as its content-length says (or, with
    /// none, everything up to the server's FIN).
    ok = 0,
    /// The server's machine answered the SYN with a reset: no one listens.
    refused = 2,
    /// Not established by `Deadlines.connect_ns`.
    connect_deadline = 3,
    /// Nothing heard from the server for `Deadlines.idle_ns`.
    idle_deadline = 4,
    /// Not finished by `Deadlines.total_ns`.
    total_deadline = 5,
    /// The retransmission timer ran out (`max_retries`).
    given_up = 6,
    /// The server reset an established connection.
    reset = 7,
    /// Not a 200, or a head past `head_max`, or more body than it said.
    bad_answer = 8,
    /// No ARP reply for the server's address by the connect deadline.
    no_arp = 9,
    /// The server finished before the body its content-length promised.
    short_answer = 10,

    pub fn code(o: Outcome) u8 {
        return @intFromEnum(o);
    }
};

/// The most head an answer may have.
pub const head_max = 4096;

/// **THE ANSWER, READ AS IT ARRIVES**: the head kept until its blank line,
/// then the status and content-length taken from it; the body counted, not
/// kept (the caller sinks it).
pub const Answer = struct {
    head: [head_max]u8 = undefined,
    head_len: usize = 0,
    state: enum { head, body, bad } = .head,
    status: u16 = 0,
    length: ?u64 = null,
    body_len: u64 = 0,

    /// Takes `bytes`, the next of the answer, and returns the part of them
    /// that is body.
    pub fn feed(self: *Answer, bytes: []const u8) []const u8 {
        switch (self.state) {
            .bad => return &.{},
            .body => {
                self.body_len += bytes.len;
                return bytes;
            },
            .head => {},
        }
        // The blank line may straddle two feeds: look again from three
        // bytes back.
        const from = self.head_len -| 3;
        const room = head_max - self.head_len;
        const take = @min(room, bytes.len);
        @memcpy(self.head[self.head_len..][0..take], bytes[0..take]);
        self.head_len += take;
        const end = std.mem.indexOf(u8, self.head[from..self.head_len], "\r\n\r\n") orelse {
            if (self.head_len == head_max) self.state = .bad;
            return &.{};
        };
        const head_end = from + end + 4;
        if (!self.parseHead(self.head[0..head_end])) {
            self.state = .bad;
            return &.{};
        }
        self.state = .body;
        // What came after the blank line in this feed is body.
        const body = bytes[take - (self.head_len - head_end) ..];
        self.body_len += body.len;
        return body;
    }

    fn parseHead(self: *Answer, head: []const u8) bool {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = lines.next() orelse return false;
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return false;
        var words = std.mem.tokenizeScalar(u8, status_line, ' ');
        _ = words.next();
        self.status = std.fmt.parseInt(u16, words.next() orelse return false, 10) catch return false;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            self.length = std.fmt.parseInt(u64, value, 10) catch return false;
        }
        return true;
    }

    /// The whole body is here (by its content-length).
    pub fn complete(self: *const Answer) bool {
        return self.state == .body and if (self.length) |n| self.body_len >= n else false;
    }

    /// **HOW IT ENDED, ONCE THE SERVER HAS FINISHED** (its FIN taken).
    pub fn outcome(self: *const Answer) Outcome {
        if (self.state != .body or self.status != 200) return .bad_answer;
        const n = self.length orelse return .ok; // read to the FIN
        if (self.body_len < n) return .short_answer;
        if (self.body_len > n) return .bad_answer;
        return .ok;
    }
};

/// The request: `GET path` to `host`, asking the server to close after.
pub fn writeRequest(out: []u8, host: []const u8, path: []const u8) ![]u8 {
    return std.fmt.bufPrint(out, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "every outcome has its own exit code, and none is the program's own 1" {
    var seen: [256]bool = @splat(false);
    for (std.enums.values(Outcome)) |o| {
        try testing.expect(o.code() != 1);
        try testing.expect(!seen[o.code()]);
        seen[o.code()] = true;
    }
    try testing.expectEqual(@as(u8, 0), Outcome.ok.code());
}

test "an answer fed whole, or a byte at a time, reads the same" {
    const text = "HTTP/1.0 200 OK\r\nServer: x\r\nContent-Length: 5\r\n\r\nhello";
    var whole: Answer = .{};
    try testing.expectEqualStrings("hello", whole.feed(text));
    try testing.expect(whole.complete());
    try testing.expectEqual(Outcome.ok, whole.outcome());
    var bytewise: Answer = .{};
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    for (text) |b| try body.appendSlice(testing.allocator, bytewise.feed(&.{b}));
    try testing.expectEqualStrings("hello", body.items);
    try testing.expectEqual(@as(u16, 200), bytewise.status);
    try testing.expectEqual(@as(?u64, 5), bytewise.length);
    try testing.expectEqual(Outcome.ok, bytewise.outcome());
}

test "how an answer ends: short, long, not a 200, no length, not HTTP, a head too big" {
    const Row = struct { text: []const u8, want: Outcome };
    const rows = [_]Row{
        .{ .text = "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nhello", .want = .short_answer },
        .{ .text = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhello", .want = .bad_answer },
        .{ .text = "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n", .want = .bad_answer },
        .{ .text = "HTTP/1.0 200 OK\r\n\r\nto the end", .want = .ok },
        .{ .text = "SSH-2.0-OpenSSH\r\n\r\n", .want = .bad_answer },
        .{ .text = "HTTP/1.1 200 OK\r\ncontent-length: x\r\n\r\n", .want = .bad_answer },
        .{ .text = "HTTP/1.1 200 OK\r\ncontent-len", .want = .bad_answer }, // never a blank line
    };
    for (rows, 0..) |r, k| {
        var a: Answer = .{};
        _ = a.feed(r.text);
        testing.expectEqual(r.want, a.outcome()) catch |e| {
            std.debug.print("row {d}\n", .{k});
            return e;
        };
    }
    var big: Answer = .{};
    var junk: [head_max + 10]u8 = @splat('a');
    _ = big.feed(&junk);
    try testing.expectEqual(Outcome.bad_answer, big.outcome());
}

test "the request asks for the path and for the server to close" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("GET /big HTTP/1.1\r\nHost: 10.77.0.1\r\nConnection: close\r\n\r\n", try writeRequest(&buf, "10.77.0.1", "/big"));
}
