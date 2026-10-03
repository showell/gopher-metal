//! The log ring (QUEUE.md item 6): the last `capacity` bytes of what this
//! machine logged, kept in memory so a status page can serve them.
//!
//! **IT IS A RING OF BYTES, NOT OF LINES.** A write lands whole however long
//! it is; when the ring is full the oldest bytes go. So a line longer than
//! the ring keeps its last `capacity` bytes, and a reader that starts after a
//! wrap starts mid-line. `read` therefore begins at the first whole line once
//! anything has been lost, and says how much was lost before it.
//!
//! **SECRETS ARE TAKEN OUT ON THE WAY IN** (`Redactor`). The serial port has
//! always carried the log, but it reaches only whoever holds the console;
//! the ring is to be served over HTTP. What this machine logs today, read
//! for it (the commit that added this file says where):
//!
//!   - no header, body, password, hash, api-key, session cookie or session
//!     secret is logged anywhere, and the application's own `std.log` and
//!     `std.debug.print` have no sink on this machine;
//!   - **the one line that can carry a secret is the request line**, which
//!     logs each request's target with its query string. The application
//!     puts none there, but a client may (`?password=...`), and an upload's
//!     URL carries the random id that names it.
//!
//! So the filter takes out a value after a key naming a secret, the id in an
//! upload's path, and the rest of a `Cookie:` or `Authorization:` line, for
//! the line someone adds tomorrow. It is a filter on spellings, so it cannot
//! catch a secret logged under no key at all, such as a bare cookie value:
//! the rule is still never to log one.
//!
//! No allocation, no locks: `serial.put` is the only writer, and the one
//! interrupt handler that logs (the NMI's) writes the port alone
//! (`serial.putPort`), never this, for the reason it skips the screen: it may
//! have interrupted a write part-way.

const std = @import("std");

/// A ring over a buffer it is given. The buffer is separate so that the ring
/// itself, a few words, can live in `.data` where the loader writes it,
/// **THE REQUEST LOG WRITES THE PATH, NEVER THE QUERY** (QUEUE.md item 95,
/// REVIEW-secrets.md finding 1). The redactor below takes a secret VALUE out of
/// a query by its key; this takes the whole query off the request target before
/// it is ever logged, so a future query-borne token under a key the redactor
/// does not know never reaches the ring `/admin/host` serves or `kept_log`. The
/// path is what a reader of the log wants; the query is not the log's to keep.
pub fn withoutQuery(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

test "the request log keeps the path and drops the query, secret or not" {
    try testing.expectEqualStrings("/login/full", withoutQuery("/login/full?password=hunter2&next=/chat"));
    try testing.expectEqualStrings("/x", withoutQuery("/x?token=0123456789abcdef"));
    try testing.expectEqualStrings("/chat/c/1_2/topic", withoutQuery("/chat/c/1_2/topic")); // no query, unchanged
    try testing.expectEqualStrings("/", withoutQuery("/?")); // empty query
    try testing.expectEqualStrings("", withoutQuery("")); // nothing at all
}

/// while the buffer lives in `.bss` (see `serial.ring`).
pub const Ring = struct {
    buf: []u8,
    /// Where the next byte goes.
    head: usize = 0,
    /// Bytes ever stored. Past `buf.len`, the oldest are gone.
    total: u64 = 0,
    redactor: Redactor = .{},

    pub fn init(buf: []u8) Ring {
        return .{ .buf = buf };
    }

    /// Stores `bytes`, with any secret in them taken out. A write longer
    /// than the ring keeps its tail.
    pub fn write(self: *Ring, bytes: []const u8) void {
        for (bytes) |b| self.redactor.feed(b, self, store);
    }

    fn store(self: *Ring, b: u8) void {
        self.buf[self.head] = b;
        self.head = (self.head + 1) % self.buf.len;
        self.total += 1;
    }

    /// How many bytes are held.
    pub fn len(self: *const Ring) usize {
        return @intCast(@min(self.total, self.buf.len));
    }

    /// How many bytes were stored and are no longer held.
    pub fn lost(self: *const Ring) u64 {
        return self.total -| self.buf.len;
    }

    /// What is held, oldest first, as at most two pieces of the ring.
    pub fn parts(self: *const Ring) [2][]const u8 {
        if (self.total <= self.buf.len) return .{ self.buf[0..self.head], self.buf[0..0] };
        return .{ self.buf[self.head..], self.buf[0..self.head] };
    }

    /// What is held, oldest first, copied into `out`: everything, unless
    /// something has been lost, in which case from the first whole line.
    /// A ring that holds no line start at all (one line longer than the
    /// ring) answers what it holds. If `out` is shorter, its newest
    /// bytes.
    pub fn read(self: *const Ring, out: []u8) []u8 {
        const p = self.parts();
        var skip: usize = 0;
        if (self.lost() > 0) {
            if (std.mem.indexOfScalar(u8, p[0], '\n')) |i| {
                skip = i + 1;
            } else if (std.mem.indexOfScalar(u8, p[1], '\n')) |i| {
                skip = p[0].len + i + 1;
            }
            // A newline as the very last byte leaves nothing whole after it.
            if (skip == self.len()) skip = 0;
        }
        const held = self.len() - skip;
        const n = @min(held, out.len);
        // The newest `n` of the held bytes: begin `held - n` past `skip`.
        var from = skip + (held - n);
        var at: usize = 0;
        for (p) |piece| {
            if (from >= piece.len) {
                from -= piece.len;
                continue;
            }
            const take = @min(piece.len - from, n - at);
            @memcpy(out[at..][0..take], piece[from..][0..take]);
            at += take;
            from = 0;
        }
        return out[0..n];
    }
};

/// **THE FILTER, ONE BYTE AT A TIME**, so a key or a value split across two
/// `serial.put` calls is still found: `serial.putDec` and friends write a line
/// in pieces, and the request line goes out in six.
///
/// Three kinds of key, matched without case:
///
///   - **a header whose whole value is secret** (`cookie:`, which also ends
///     `set-cookie:`, and `authorization:`): the rest of the line goes;
///   - **a word naming a secret** (`password`, `token`, `key`, ...): when `=`
///     or `:` follows it, perhaps after a quote or a space as in JSON, the
///     value after that goes: to its closing quote if it opened with one,
///     else up to a space, a quote, `&`, `;`, `,` or the line's end. That covers a query string (`?key=...`) as the request
///     line logs it;
///   - **`/uploads/`**: the path segment after it goes. An upload is served
///     at `.../uploads/<32 random hex>.<ext>`, and that id is what names it.
///
/// What goes is replaced by `[redacted]`, once. A word that only contains a
/// key (`passwords: 3`, `keyrevoked=5`) is left alone; one that ends in a
/// key (`monkey=3`) is redacted, which costs a log line its value and nothing
/// else.
pub const Redactor = struct {
    /// The last bytes seen, lower-cased, newest last.
    window: [longest]u8 = @splat(0),
    state: State = .plain,
    /// The quote a value opened with, which only the same quote ends: a
    /// quoted password may hold spaces. Zero for a bare value.
    quote: u8 = 0,

    const State = enum { plain, after_key, before_value, in_value, in_segment, in_line };

    pub const line_keys = [_][]const u8{ "cookie:", "authorization:" };
    pub const value_keys = [_][]const u8{ "password", "passwd", "secret", "token", "key", "session", "bcrypt" };
    pub const segment_keys = [_][]const u8{"/uploads/"};
    const longest = blk: {
        var n = 0;
        for (line_keys ++ value_keys ++ segment_keys) |k| n = @max(n, k.len);
        break :blk n;
    };
    pub const mark = "[redacted]";

    pub fn feed(self: *Redactor, b: u8, sink: anytype, comptime put: fn (@TypeOf(sink), u8) void) void {
        switch (self.state) {
            .plain => {},
            .after_key => switch (b) {
                '"', '\'', ' ' => return put(sink, b),
                ':', '=' => {
                    self.state = .before_value;
                    return put(sink, b);
                },
                else => self.state = .plain,
            },
            .before_value => switch (b) {
                ' ' => return put(sink, b),
                '"', '\'' => {
                    if (self.quote != 0) {
                        // An empty quoted value: `""`.
                        self.quote = 0;
                        self.state = .plain;
                    } else {
                        self.quote = b;
                        return put(sink, b);
                    }
                },
                '\n', '\r' => {
                    self.quote = 0;
                    self.state = .plain;
                },
                else => {
                    for (mark) |m| put(sink, m);
                    self.state = .in_value;
                    return;
                },
            },
            .in_value => if (self.quote != 0) {
                if (b != self.quote and b != '\n' and b != '\r') return;
                self.quote = 0;
                self.state = .plain;
            } else switch (b) {
                ' ', '\t', '"', '\'', '&', ';', ',', '\n', '\r' => self.state = .plain,
                else => return,
            },
            .in_segment => switch (b) {
                '.', '/', '?', ' ', '\t', '"', '\n', '\r' => self.state = .plain,
                else => return,
            },
            .in_line => {
                if (b != '\n') return;
                self.state = .plain;
            },
        }

        // Plain: the byte is kept, and may complete a key.
        put(sink, b);
        std.mem.copyForwards(u8, self.window[0 .. longest - 1], self.window[1..]);
        self.window[longest - 1] = std.ascii.toLower(b);
        if (b == '\n') self.window = @splat(0);
        for (line_keys) |k| {
            if (std.mem.endsWith(u8, &self.window, k)) {
                for (" " ++ mark) |m| put(sink, m);
                self.state = .in_line;
                return;
            }
        }
        for (segment_keys) |k| {
            if (std.mem.endsWith(u8, &self.window, k)) {
                for (mark) |m| put(sink, m);
                self.state = .in_segment;
                return;
            }
        }
        for (value_keys) |k| {
            if (std.mem.endsWith(u8, &self.window, k)) {
                self.state = .after_key;
                return;
            }
        }
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Both parts of what a ring holds, joined.
fn joined(r: anytype, out: []u8) []u8 {
    const p = r.parts();
    @memcpy(out[0..p[0].len], p[0]);
    @memcpy(out[p[0].len..][0..p[1].len], p[1]);
    return out[0 .. p[0].len + p[1].len];
}

test "what is written is read back, oldest first" {
    var r_buf: [16]u8 = undefined;
    var r = Ring.init(&r_buf);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("", r.read(&out));
    r.write("one\n");
    r.write("two\n");
    try testing.expectEqualStrings("one\ntwo\n", r.read(&out));
    try testing.expectEqual(@as(u64, 0), r.lost());
    // A shorter `out` gets the newest bytes.
    try testing.expectEqualStrings("two\n", r.read(out[0..4]));
}

test "once bytes are lost, a read starts at the first whole line" {
    var r_buf: [16]u8 = undefined;
    var r = Ring.init(&r_buf);
    var out: [64]u8 = undefined;
    var all: [64]u8 = undefined;
    r.write("one\ntwo\n");
    r.write("three\nfour\n"); // 19 bytes: the first three are gone
    try testing.expectEqual(@as(u64, 3), r.lost());
    try testing.expectEqualStrings("\ntwo\nthree\nfour\n", joined(&r, &all));
    try testing.expectEqualStrings("two\nthree\nfour\n", r.read(&out));
}

test "the first whole line is found across the ring's seam" {
    var r_buf: [16]u8 = undefined;
    var r = Ring.init(&r_buf);
    var out: [64]u8 = undefined;
    var all: [64]u8 = undefined;
    r.write("aaaaaaaaaa\n");
    r.write("bbbbbbbb\n"); // 20 bytes: four gone
    const p = r.parts();
    try testing.expect(p[0].len > 0 and p[1].len > 0);
    try testing.expectEqualStrings("aaaaaa\nbbbbbbbb\n", joined(&r, &all));
    try testing.expectEqualStrings("bbbbbbbb\n", r.read(&out));
    // Where the line break is in the second part.
    var s_buf: [16]u8 = undefined;
    var s = Ring.init(&s_buf);
    s.write("cccccccccccccc"); // 14
    s.write("dddd\neeee\n"); // 24: "cccccc" + "dddd\neeee\n" held
    try testing.expectEqualStrings("eeee\n", s.read(&out));
}

test "a line longer than the ring keeps its tail, and is read whole as far as it is held" {
    var r_buf: [16]u8 = undefined;
    var r = Ring.init(&r_buf);
    var out: [64]u8 = undefined;
    r.write("x" ** 40);
    // No line start is held at all: what is held is what there is.
    try testing.expectEqualStrings("x" ** 16, r.read(&out));
    r.write("\n");
    // A break as the last byte: nothing whole follows it.
    try testing.expectEqualStrings("x" ** 15 ++ "\n", r.read(&out));
    r.write("y\n");
    try testing.expectEqualStrings("y\n", r.read(&out));
    // One write longer than the ring.
    r.write("0123456789" ** 5 ++ "\n");
    // Its last 16 bytes are held, and the break that ends them is the only
    // one: read whole, as above.
    try testing.expectEqualStrings("56789" ++ "0123456789" ++ "\n", r.read(&out));
}

test "after many wraps, what is read is the end of what was written, from a line start" {
    var r_buf: [64]u8 = undefined;
    var r = Ring.init(&r_buf);
    var written: [16384]u8 = undefined;
    var n: usize = 0;
    var out: [64]u8 = undefined;
    for (0..700) |k| {
        var line: [32]u8 = undefined;
        const l = try std.fmt.bufPrint(&line, "line {d}{s}\n", .{ k, "!" ** 3 });
        r.write(l);
        @memcpy(written[n..][0..l.len], l);
        n += l.len;
        const got = r.read(&out);
        try testing.expect(std.mem.endsWith(u8, written[0..n], got));
        // From a line start: the byte before it is a break, or it is all.
        const before = n - got.len;
        try testing.expect(before == 0 or written[before - 1] == '\n');
        // And as much as the ring can hold, less at most one line.
        try testing.expect(got.len + l.len >= @min(n, 64));
        try testing.expectEqual(@as(u64, n) -| 64, r.lost());
    }
}

/// What `Redactor` makes of `pieces`, written one after another.
fn redacted(pieces: []const []const u8, out: []u8) []u8 {
    const Sink = struct {
        out: []u8,
        n: usize = 0,
        fn put(self: *@This(), b: u8) void {
            self.out[self.n] = b;
            self.n += 1;
        }
    };
    var r = Redactor{};
    var sink = Sink{ .out = out };
    for (pieces) |p| for (p) |b| r.feed(b, &sink, Sink.put);
    return out[0..sink.n];
}

fn expectRedacted(want: []const u8, pieces: []const []const u8) !void {
    var out: [512]u8 = undefined;
    try testing.expectEqualStrings(want, redacted(pieces, &out));
}

test "a value after a key naming a secret is taken out, in a query string and in JSON" {
    try expectRedacted("  request 7: GET /login/full?password=[redacted]&next=/chat -> 200\n", &.{"  request 7: GET /login/full?password=hunter2&next=/chat -> 200\n"});
    try expectRedacted("GET /x?key=[redacted] -> 404\n", &.{"GET /x?key=0123456789abcdef -> 404\n"});
    try expectRedacted("{\"user\":\"ada\",\"password\":\"[redacted]\",\"n\":1}\n", &.{"{\"user\":\"ada\",\"password\":\"correct horse\",\"n\":1}\n"});
    try expectRedacted("api-key: [redacted]\n", &.{"api-key: 0123456789abcdef\n"});
    try expectRedacted("Session=[redacted]; Path=/\n", &.{"Session=abc; Path=/\n"});
    try expectRedacted("TOKEN = [redacted]\n", &.{"TOKEN = x\n"});
    // A quoted value is taken out to its own closing quote, spaces and other
    // quotes included; an empty one stays empty.
    try expectRedacted("password='[redacted]' next\n", &.{"password='a \"b\" c' next\n"});
    try expectRedacted("{\"password\":\"\",\"n\":1}\n", &.{"{\"password\":\"\",\"n\":1}\n"});
    // An unclosed quote ends with its line.
    try expectRedacted("secret=\"[redacted]\nnext\n", &.{"secret=\"no end\nnext\n"});
}

test "a header whose value is secret loses the rest of its line, and only that" {
    try expectRedacted("Cookie: [redacted]\nnext line\n", &.{"Cookie: gopher_session=abc.def; gopher_uid=7\nnext line\n"});
    try expectRedacted("set-cookie: [redacted]\n", &.{"set-cookie: gopher_session=abc; HttpOnly\n"});
    try expectRedacted("Authorization: [redacted]\n", &.{"Authorization: Bearer 0123456789abcdef\n"});
}

test "an upload's id is taken out of its path, and its extension kept" {
    try expectRedacted("  request 9: GET /chat/1_2/plan/uploads/[redacted].png -> 200\n", &.{"  request 9: GET /chat/1_2/plan/uploads/00112233445566778899aabbccddeeff.png -> 200\n"});
    try expectRedacted("GET /x/uploads/[redacted]?v=2\n", &.{"GET /x/uploads/abc?v=2\n"});
}

test "a key or a value split across writes is still found" {
    try expectRedacted("password: [redacted]\n", &.{ "pass", "word", ": hun", "ter2", "\n" });
    try expectRedacted("Cook" ++ "ie: [redacted]\nok\n", &.{ "Cook", "ie: a=", "b\nok\n" });
    try expectRedacted("/uploads/[redacted].jpg\n", &.{ "/upl", "oads/0011", "2233", ".jpg\n" });
    // One byte at a time.
    const line = "GET /a?token=s3cret&x=1\n";
    var pieces: [line.len][]const u8 = undefined;
    for (&pieces, 0..) |*p, i| p.* = line[i..][0..1];
    try expectRedacted("GET /a?token=[redacted]&x=1\n", &pieces);
}

test "the log lines this machine writes today pass through unchanged" {
    const lines = [_][]const u8{
        "  request 12: GET /chat/1_2/sessions/plan -> 200\n",
        "  request 13: POST /login/full -> 303\n",
        "  refused: a write outside the data directories: index.html\n",
        "  sessions: 4, keyrevoked=5, passwords checked: 3\n",
        "cpu: exception 14, error 2, rip 0x1000, cr2 0xdead\n",
        "a key\nmidline: secret word\n",
    };
    for (lines) |l| try expectRedacted(l, &.{l});
}

test "redaction happens before the ring, so no secret is stored, even in part" {
    var r_buf: [64]u8 = undefined;
    var r = Ring.init(&r_buf);
    var out: [64]u8 = undefined;
    r.write("GET /login?pass");
    r.write("word=hunter2 -> 200\n");
    try testing.expectEqualStrings("GET /login?password=[redacted] -> 200\n", r.read(&out));
    try testing.expect(std.mem.indexOf(u8, r.buf, "hunter") == null);
}
