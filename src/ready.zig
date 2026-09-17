//! **WHEN A CONNECTION IS READY TO BE SERVED** — a question about the bytes it
//! has buffered, and nothing else.
//!
//! The machine answers one request at a time, and a handler that has started
//! runs to the end. So a request is started only once everything it will read
//! is already in memory; until then its connection waits in the table and the
//! others are served. A client that connects and says nothing, or says half a
//! request line and stops, holds nobody up — and neither does one that sends a
//! header saying a hundred bytes are coming and then pauses.
//!
//! **A BODY IS WAITED FOR WHEN IT CAN BE.** Three kinds cannot be, and each is
//! started at its head, with the handler reading the rest as it arrives — which
//! is what this machine did for every body before:
//!
//!   - **`Expect: 100-continue`.** The client is waiting to be told to send it;
//!     `std.http.Server` tells it, from inside the handler. Waiting here would
//!     be both sides waiting for each other.
//!   - **A chunked body**, whose length nobody knows until it ends.
//!   - **A body too big for the connection's buffer.** Nothing drains that
//!     buffer until the handler runs, so a body that cannot fit in it would
//!     shut the window and never arrive.

const std = @import("std");

pub const Readiness = enum {
    /// Keep waiting.
    waiting,
    /// Serve it: everything the handler will read is here, or the rest cannot
    /// be waited for.
    ready,
    /// The peer has closed without finishing: serve it anyway, so the host
    /// logs it and lets it go, as it always has.
    abandoned,
};

/// `capacity` is the connection's receive buffer — the most that can ever be
/// buffered for it at once.
pub fn check(pending: []const u8, peer_done: bool, capacity: usize) Readiness {
    var parser: std.http.HeadParser = .{};
    const head_len = parser.feed(pending);
    if (parser.state != .finished) return if (peer_done) .abandoned else .waiting;

    // A head std cannot parse is served: the handler rejects it there, with
    // the same words Linux uses.
    const head = std.http.Server.Request.Head.parse(pending[0..head_len]) catch return .ready;
    // What std will read is decided by the method first: for one that takes no
    // body it reads nothing, whatever the headers say.
    if (!head.method.requestHasBody()) return .ready;
    if (head.expect != null) return .ready;
    if (head.transfer_encoding != .none) return .ready;

    const want = head.content_length orelse 0;
    const have = pending.len - head_len;
    if (have >= want) return .ready;
    if (want > capacity - @min(head_len, capacity)) return .ready;
    return if (peer_done) .abandoned else .waiting;
}

const testing = std.testing;

/// A connection's buffer, in the tests that do not care how big it is.
const room = 16 * 1024;

test "a whole head with no body is ready" {
    try testing.expectEqual(Readiness.ready, check("GET / HTTP/1.1\r\nHost: x\r\n\r\n", false, room));
}

test "half a request is not" {
    try testing.expectEqual(Readiness.waiting, check("GET / HTTP/1.1\r\n", false, room));
    try testing.expectEqual(Readiness.waiting, check("GET / HTTP/1.1\r\nHost: x\r\n\r", false, room));
    try testing.expectEqual(Readiness.waiting, check("", false, room));
}

test "a head split exactly at its end is not, until the last byte arrives" {
    const head = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    for (0..head.len) |n| {
        try testing.expectEqual(Readiness.waiting, check(head[0..n], false, room));
    }
    try testing.expectEqual(Readiness.ready, check(head, false, room));
}

test "bare newlines end a head too, as std's parser allows" {
    try testing.expectEqual(Readiness.ready, check("GET / HTTP/1.1\nHost: x\n\n", false, room));
}

test "a peer that closed without a whole head is served, to be logged and let go" {
    try testing.expectEqual(Readiness.abandoned, check("GET / HTTP/1.1\r\n", true, room));
    try testing.expectEqual(Readiness.abandoned, check("", true, room));
}

test "a peer that closed after a whole head is served as a request" {
    try testing.expectEqual(Readiness.ready, check("GET / HTTP/1.1\r\n\r\n", true, room));
}

test "garbage that happens to end like a head is served, and std rejects it there" {
    // The judge's "garbage on the wire" step: it must be answered, not held.
    try testing.expectEqual(Readiness.ready, check("this is not http\r\n\r\n", false, room));
}

const post = "POST /send HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n";

test "a body still arriving is waited for, byte by byte" {
    var buf: [post.len + 10]u8 = undefined;
    @memcpy(buf[0..post.len], post);
    @memcpy(buf[post.len..], "0123456789");
    for (0..10) |n| {
        try testing.expectEqual(Readiness.waiting, check(buf[0 .. post.len + n], false, room));
    }
    try testing.expectEqual(Readiness.ready, check(post ++ "0123456789", false, room));
}

test "more than the body says is ready, and the rest is the next request's problem" {
    try testing.expectEqual(Readiness.ready, check(post ++ "0123456789GET /", false, room));
}

test "a client that closed part-way through its body is served and let go" {
    try testing.expectEqual(Readiness.abandoned, check(post ++ "012", true, room));
}

test "a body too big for the buffer is served at its head, and read as it comes" {
    // Nothing drains the buffer until the handler runs, so waiting for a body
    // that cannot fit would be waiting for the window to open on its own.
    const big = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 40000\r\n\r\n";
    try testing.expectEqual(Readiness.ready, check(big, false, room));
    // One that just fits is still waited for.
    const fits = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 16000\r\n\r\n";
    try testing.expectEqual(Readiness.waiting, check(fits, false, room));
    // And one that fits only because the buffer is bigger.
    try testing.expectEqual(Readiness.waiting, check(big, false, 64 * 1024));
}

test "a client waiting to be told to send its body is served at once" {
    // **BOTH SIDES WOULD WAIT.** std.http.Server answers the expectation from
    // inside the handler, so the handler has to start before the body comes.
    const expects = "POST /upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 50\r\n\r\n";
    try testing.expectEqual(Readiness.ready, check(expects, false, room));
}

test "a chunked body is served at its head: nobody knows how long it is" {
    const chunked = "POST /send HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
    try testing.expectEqual(Readiness.ready, check(chunked, false, room));
}

test "a method that takes no body is ready however it is framed" {
    // std reads no body for a GET, whatever its headers claim, so waiting for
    // one would wait for a read that never happens.
    const get = "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n";
    try testing.expectEqual(Readiness.ready, check(get, false, room));
}
