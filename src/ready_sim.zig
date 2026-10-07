//! **WHEN A CONNECTION IS READY, UNDER A SEED** (metal-vmm QUEUE.md item 51).
//! `ready.zig` imports only `std` and `tcp.zig`, so it can be driven as the
//! table drives it: the bytes of a request arriving in pieces of any size,
//! and after each piece the question asked again of everything pending.
//!
//! Each run is one seed. The seed chooses a connection's receive buffer (a
//! few hundred bytes to 64 KiB), and then requests: a method with a body or
//! without, a target and headers of any length (sometimes past the buffer,
//! the 431 path), a Content-Length, an `Expect: 100-continue`, a chunked
//! body, or a head that is not HTTP at all; bytes after it (a second
//! request); the pieces they arrive in; and whether the client closes, and
//! when.
//!
//! **THE REFERENCE IS THE GENERATOR'S**: it wrote the request, so it knows
//! where the head ends, what the method is and what the body's length is,
//! without parsing anything. `ready.zig`'s answer after each piece must be
//! what its own comments promise for those facts:
//!
//! - **a head not ended** waits, unless the buffer is too full for another
//!   segment (`tcp.zig`'s `tight`), which is served as it is; a client that
//!   closed is abandoned;
//! - **a head ended** is ready when its method takes no body, it expects
//!   100-continue, its body is chunked, its body is here, its body cannot
//!   fit the buffer, or std cannot parse it; else it waits, or is abandoned;
//! - **once ready, ready**: more bytes never make a ready connection wait,
//!   but for a head served by the shut window before it ends: when it ends,
//!   its body may be waited for. Harmless in the table, which serves a
//!   connection at its first ready; counted, not failed.
//!
//! Heads end with CRLF but for one request in eight, whose lines end with
//! bare LF: std's HeadParser finds their end and its Head.parse refuses
//! them, so an ended one is served for the handler to refuse. There std's
//! whole-buffer parse can also miss the end (the bug pinned in `ready.zig`,
//! HEAD-PARSER-BUG.md); a disagreement of that shape is counted, not
//! failed.

const std = @import("std");
const ready = @import("ready.zig");
const tcp = @import("tcp.zig");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}

const testing = std.testing;

const Kind = enum { plain, body, expect, chunked, not_http };

/// What the generator knows of the request it wrote.
const Truth = struct {
    /// Bytes up to and including the empty line, or null if it never ends
    /// (the head is cut short, or the bytes are not HTTP and never end one).
    head_len: ?usize,
    has_body_method: bool,
    kind: Kind,
    content_length: usize,
    bare_lf: bool,
};

const Request = struct {
    bytes: std.ArrayList(u8) = .empty,
    truth: Truth = undefined,
};

fn appendRandom(r: std.Random, out: *std.ArrayList(u8), n: usize, alphabet: []const u8) !void {
    for (0..n) |_| try out.append(testing.allocator, alphabet[r.uintLessThan(usize, alphabet.len)]);
}

/// One request's bytes and what they are.
fn generate(r: std.Random, cap: usize) !Request {
    const gpa = testing.allocator;
    var q: Request = .{};
    const bare_lf = r.uintLessThan(u8, 8) == 0;
    const eol: []const u8 = if (bare_lf) "\n" else "\r\n";
    const kind: Kind = switch (r.uintLessThan(u8, 10)) {
        0, 1, 2 => .plain,
        3, 4, 5 => .body,
        6 => .expect,
        7 => .chunked,
        8 => .not_http,
        else => .plain,
    };
    const body_methods = [_][]const u8{ "POST", "PUT", "PATCH" };
    const plain_methods = [_][]const u8{ "GET", "HEAD", "DELETE", "OPTIONS" };
    var has_body_method = false;
    if (kind == .not_http) {
        // Words, then an empty line: it ends like a head, and is not one.
        try appendRandom(r, &q.bytes, r.intRangeAtMost(usize, 1, 40), "abcdefghij klmnop");
        try q.bytes.appendSlice(gpa, eol);
        try q.bytes.appendSlice(gpa, eol);
    } else {
        const with_body = kind != .plain or r.boolean();
        const method = if (with_body) body_methods[r.uintLessThan(usize, body_methods.len)] else plain_methods[r.uintLessThan(usize, plain_methods.len)];
        has_body_method = with_body;
        try q.bytes.appendSlice(gpa, method);
        try q.bytes.append(gpa, ' ');
        try q.bytes.append(gpa, '/');
        // A target of any length: now and then past the buffer.
        const target = if (r.uintLessThan(u8, 10) == 0) r.intRangeAtMost(usize, cap / 2, cap + 2000) else r.uintLessThan(usize, 80);
        try appendRandom(r, &q.bytes, target, "abcdefghijklmnopqrstuvwxyz0123456789/_-.");
        try q.bytes.appendSlice(gpa, " HTTP/1.1");
        try q.bytes.appendSlice(gpa, eol);
        try q.bytes.appendSlice(gpa, "Host: metal.lynrummy.com");
        try q.bytes.appendSlice(gpa, eol);
        for (0..r.uintLessThan(usize, 6)) |_| {
            try q.bytes.appendSlice(gpa, "X-Thing: ");
            try appendRandom(r, &q.bytes, r.uintLessThan(usize, 200), "abcdefghijklmnopqrstuvwxyz=; ");
            try q.bytes.appendSlice(gpa, eol);
        }
    }
    var length: usize = 0;
    switch (kind) {
        .body, .expect => {
            length = if (r.uintLessThan(u8, 6) == 0) r.intRangeAtMost(usize, cap / 2, cap * 2) else r.uintLessThan(usize, 3000);
            var line: [64]u8 = undefined;
            try q.bytes.appendSlice(gpa, std.fmt.bufPrint(&line, "Content-Length: {d}", .{length}) catch unreachable);
            try q.bytes.appendSlice(gpa, eol);
            if (kind == .expect) {
                try q.bytes.appendSlice(gpa, "Expect: 100-continue");
                try q.bytes.appendSlice(gpa, eol);
            }
        },
        .chunked => {
            // Now and then a length as well, which the chunks override
            // (RFC 9112 §6.3), and which std's parser keeps beside them
            // (metal-vmm QUEUE 93, mutant R6).
            if (r.uintLessThan(u8, 3) == 0) {
                var line: [64]u8 = undefined;
                try q.bytes.appendSlice(gpa, std.fmt.bufPrint(&line, "Content-Length: {d}", .{r.intRangeAtMost(usize, 1, 3000)}) catch unreachable);
                try q.bytes.appendSlice(gpa, eol);
                props.reachable(@src(), "ready_sim: a chunked body also says a length, which the chunks override", null);
            }
            try q.bytes.appendSlice(gpa, "Transfer-Encoding: chunked");
            try q.bytes.appendSlice(gpa, eol);
        },
        else => {},
    }
    var head_len: ?usize = null;
    if (kind != .not_http) {
        try q.bytes.appendSlice(gpa, eol);
        head_len = q.bytes.items.len;
    } else head_len = q.bytes.items.len;
    // The body, as much of it as the client sends, and now and then the
    // next request behind it.
    try appendRandom(r, &q.bytes, if (kind == .chunked) r.uintLessThan(usize, 300) else length, "0123456789abcdef");
    if (r.uintLessThan(u8, 5) == 0) try q.bytes.appendSlice(gpa, "GET /next HTTP/1.1\r\nHost: x\r\n\r\n");
    q.truth = .{ .head_len = head_len, .has_body_method = has_body_method, .kind = kind, .content_length = length, .bare_lf = bare_lf };
    return q;
}

/// What `ready.zig` promises for `n` bytes of the request pending, from
/// the generator's facts and its own comments, not from parsing.
fn promised(t: Truth, n: usize, peer_done: bool, cap: usize) ready.Readiness {
    const ended = if (t.head_len) |h| n >= h else false;
    if (!ended) {
        const left = cap - @min(n, cap);
        if (left < @min(@as(usize, tcp.our_mss), cap / 2)) return .ready;
        return if (peer_done) .abandoned else .waiting;
    }
    const h = t.head_len.?;
    // Not HTTP, a head past the buffer, or one whose lines end in bare LF
    // (which std's HeadParser finds the end of and its Head.parse refuses):
    // served, and std refuses it in the handler.
    if (t.kind == .not_http or h > cap or t.bare_lf) return .ready;
    if (!t.has_body_method) return .ready;
    if (t.kind == .expect or t.kind == .chunked) return .ready;
    if (n - h >= t.content_length) return .ready;
    if (t.content_length > cap - h) return .ready;
    return if (peer_done) .abandoned else .waiting;
}

pub fn runSeed(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const caps = [_]usize{ 600, 2048, 4096, 16 * 1024, 64 * 1024 };
    const cap = caps[r.uintLessThan(usize, caps.len)];
    for (0..r.intRangeAtMost(usize, 1, 20)) |q_i| {
        var q = try generate(r, cap);
        defer q.bytes.deinit(testing.allocator);
        const bytes = q.bytes.items;
        // The client may close after some piece, or never.
        const closes_at: ?usize = if (r.uintLessThan(u8, 4) == 0) r.uintAtMost(usize, bytes.len) else null;
        var n: usize = 0;
        var was_ready = false;
        var seen_unended_ready = false;
        while (true) {
            // What is pending is at most the buffer: the window holds the
            // rest back, as the table does.
            const pending = bytes[0..@min(n, cap)];
            const done = if (closes_at) |c| n >= c else false;
            const got = ready.check(pending, done, cap);
            const want = promised(q.truth, pending.len, done, cap);
            if (got != want) {
                // std's whole-buffer parse missing a bare-LF end is the known
                // bug (ready.zig pins it): counted, not failed.
                if (q.truth.bare_lf and (got == .waiting or got == .abandoned)) {
                    props.reachable(@src(), "ready_sim: std misses a bare-LF head end, the pinned bug", .{ .seed = seed });
                } else {
                    std.debug.print("ready_sim seed {d} request {d}: {d} of {d} bytes pending (buffer {d}, closed {any}, {s}, head {?d}, body {d}): ready.check said {s}, its comments promise {s}\n", .{
                        seed, q_i, pending.len, bytes.len, cap, done, @tagName(q.truth.kind), q.truth.head_len, q.truth.content_length, @tagName(got), @tagName(want),
                    });
                    return error.SimulationFailed;
                }
            }
            if (was_ready and got == .waiting and !q.truth.bare_lf) {
                std.debug.print("ready_sim seed {d} request {d}: ready at fewer bytes, waiting at {d}\n", .{ seed, q_i, pending.len });
                return error.SimulationFailed;
            }
            // Ready by the shut window, before the head ends, is the one
            // ready a later byte can undo: the head ends, and its body is
            // waited for. Harmless in the table, which serves a connection
            // at its first ready and lets the handler read the rest.
            const ended = if (q.truth.head_len) |h| pending.len >= h else false;
            if (got == .ready and !ended) {
                props.reachable(@src(), "ready_sim: a shut window serves a head before it ends", null);
            } else if (got == .ready) was_ready = true;
            if (got == .waiting and !ended) {} else if (got == .waiting and seen_unended_ready) {
                props.reachable(@src(), "ready_sim: a head served by the shut window waits once it ends", null);
            }
            if (got == .ready and !ended) seen_unended_ready = true;
            if (got == .ready and q.truth.head_len != null and pending.len < q.truth.head_len.? and q.truth.head_len.? > cap)
                props.reachable(@src(), "ready_sim: a head past the buffer is served unended (the 431 path)", null);
            if (got == .ready and q.truth.kind == .body and q.truth.content_length > cap -| (q.truth.head_len orelse 0) and q.truth.head_len.? <= pending.len)
                props.reachable(@src(), "ready_sim: a body too big for the buffer is served at its head", null);
            if (got == .waiting and q.truth.head_len != null and pending.len >= q.truth.head_len.?)
                props.reachable(@src(), "ready_sim: a head whose body is still coming waits", null);
            if (got == .abandoned) props.reachable(@src(), "ready_sim: a client that closed part-way is abandoned", null);
            if (n >= bytes.len or (done and n >= closes_at.?)) break;
            // The next piece: a byte, a segment, or anything between.
            n += switch (r.uintLessThan(u8, 4)) {
                0 => 1,
                1 => tcp.our_mss,
                else => r.intRangeAtMost(usize, 1, 3000),
            };
            n = @min(n, bytes.len);
        }
    }
}

test "ready.zig under a seed, a handful of seeds" {
    for (1..41) |seed| try runSeed(seed);
}
