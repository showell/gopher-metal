//! **WHEN A CONNECTION IS READY TO BE SERVED** — a question about the bytes it
//! has buffered, and nothing else.
//!
//! The machine answers one request at a time, and a handler that has started
//! runs to the end. So a request is started only once everything it will read
//! is already in memory; until then its connection waits in the table and the
//! others are served. A client that connects and says nothing, or says half a
//! request line and stops, holds nobody up.
//!
//! **THE HEAD, FOR NOW.** A request is ready once its head has arrived — judged
//! by `std.http.HeadParser`, the same parser `std.http.Server.receiveHead`
//! runs, so "ready" here and "a whole head" there cannot disagree. A body that
//! is still arriving is still read by the handler as it comes; waiting for the
//! whole body (and answering `Expect: 100-continue`) is the next step.

const std = @import("std");

pub const Readiness = enum {
    /// Keep waiting.
    waiting,
    /// A whole request head is buffered.
    head,
    /// The peer has closed without sending a whole head: serve it anyway, so
    /// the host logs it and lets it go, as it always has.
    abandoned,
};

pub fn check(pending: []const u8, peer_done: bool) Readiness {
    var parser: std.http.HeadParser = .{};
    _ = parser.feed(pending);
    if (parser.state == .finished) return .head;
    if (peer_done) return .abandoned;
    return .waiting;
}

const testing = std.testing;

test "a whole head is ready" {
    try testing.expectEqual(Readiness.head, check("GET / HTTP/1.1\r\nHost: x\r\n\r\n", false));
}

test "a head with its body still to come is ready — for now" {
    try testing.expectEqual(Readiness.head, check("POST /send HTTP/1.1\r\nContent-Length: 50\r\n\r\nabc", false));
}

test "half a request is not" {
    try testing.expectEqual(Readiness.waiting, check("GET / HTTP/1.1\r\n", false));
    try testing.expectEqual(Readiness.waiting, check("GET / HTTP/1.1\r\nHost: x\r\n\r", false));
    try testing.expectEqual(Readiness.waiting, check("", false));
}

test "a head split exactly at its end is not, until the last byte arrives" {
    const head = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    for (0..head.len) |n| {
        try testing.expectEqual(Readiness.waiting, check(head[0..n], false));
    }
    try testing.expectEqual(Readiness.head, check(head, false));
}

test "bare newlines end a head too, as std's parser allows" {
    try testing.expectEqual(Readiness.head, check("GET / HTTP/1.1\nHost: x\n\n", false));
}

test "a peer that closed without a whole head is served, to be logged and let go" {
    try testing.expectEqual(Readiness.abandoned, check("GET / HTTP/1.1\r\n", true));
    try testing.expectEqual(Readiness.abandoned, check("", true));
}

test "a peer that closed after a whole head is served as a request" {
    try testing.expectEqual(Readiness.head, check("GET / HTTP/1.1\r\n\r\n", true));
}

test "garbage that happens to end like a head is served, and std rejects it there" {
    // The judge's "garbage on the wire" step: it must be answered, not held.
    try testing.expectEqual(Readiness.head, check("this is not http\r\n\r\n", false));
}
