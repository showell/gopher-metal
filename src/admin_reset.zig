//! **THE ADMIN'S LOST PASSWORD, RESET FROM THE BOOT DISK** (QUEUE.md item 89).
//! Fire drill 1 found the admin password lived only in a browser. Metal has
//! no shell, keeps the password only as a hash, and asks for it before a
//! backup; with the browser gone there was no way back in.
//!
//! The way back: a line in the boot disk's `gopher-metal.conf`,
//!
//!     admin_password_reset = Steve $2b$10$…
//!
//! naming the admin and a new bcrypt hash, put there by `droplet/chat.py
//! --reset-admin-password Steve` at a deploy, which asks for the password and
//! hashes it on the machine deploying (angry-gopher's hash-password). The
//! boot applies it before it serves:
//!
//! - **only to the admin**: uid 1 (angry-gopher's admin_ui.zig), a member
//!   (it has a password), named as the line says. Any other volume, or a
//!   copy whose uid 1 is someone else, is left alone, and the boot says why;
//! - **once**: the hash applied is kept beside the password
//!   (`password-reset`), and a boot that finds it there changes nothing, so
//!   a line left in an image does not undo a password changed since;
//! - **undoably**: the hash it replaces is kept as `password.before-reset`,
//!   as angry-gopher's ops/reset_admin_password keeps it on prod.
//!
//! No request can reach this: the conf is on the boot disk, and nothing
//! served writes there (io.zig refuses every write outside the data). Writes
//! are in an order a stop can repeat: the old hash aside, the new one in by a
//! rename, the marker last; stopped before the marker, the next boot does
//! it again, to the same end.

const std = @import("std");
const props = @import("coverage");

comptime {
    props.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
const io_mod = @import("io.zig");

/// What the conf line says.
pub const Reset = struct {
    name: []const u8,
    hash: []const u8,
};

/// `Steve $2b$10$…`: a name (which may hold spaces), then a hash. Null if it
/// is not that.
fn failed() Outcome {
    props.reachable(@src(), "admin reset: a step on the boot disk failed", null);
    return .failed;
}

fn noAdmin() Outcome {
    props.reachable(@src(), "admin reset: the boot disk has no admin to reset", null);
    return .no_admin;
}

pub fn parse(value: []const u8) ?Reset {
    const at = std.mem.lastIndexOfScalar(u8, value, ' ') orelse {
        props.reachable(@src(), "admin reset: a value with no space between a name and a hash", null);
        return null;
    };
    const name = std.mem.trim(u8, value[0..at], " \t");
    const hash = value[at + 1 ..];
    if (name.len == 0 or !validHash(hash)) {
        props.reachable(@src(), "admin reset: an empty name, or not a bcrypt hash this server writes", null);
        return null;
    }
    return .{ .name = name, .hash = hash };
}

/// A bcrypt hash as angry-gopher stores one: `$2a$`, `$2b$` or `$2y$`, a cost
/// of 10 to 31 (none weaker than the hashes it writes), and 53 characters of
/// bcrypt's alphabet.
pub fn validHash(h: []const u8) bool {
    if (h.len != 60) return false;
    if (h[0] != '$' or h[1] != '2' or h[3] != '$' or h[6] != '$') return false;
    if (h[2] != 'a' and h[2] != 'b' and h[2] != 'y') return false;
    if (!std.ascii.isDigit(h[4]) or !std.ascii.isDigit(h[5])) return false;
    const cost = (h[4] - '0') * 10 + (h[5] - '0');
    if (cost < 10 or cost > 31) return false;
    for (h[7..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '/') return false;
    }
    return true;
}

pub const Outcome = enum {
    /// The password is the new hash now.
    applied,
    /// This hash was applied by an earlier boot; nothing changed.
    already,
    /// There is no uid 1 with a password: no admin to give one to.
    no_admin,
    /// uid 1 is someone else than the line names.
    other_name,
    /// A read or a write failed; the next boot tries again.
    failed,
};

const name_path = "auth/1/name";
const password_path = "auth/1/password";
const new_path = "auth/1/password.new";
const before_path = "auth/1/password.before-reset";
const marker_path = "auth/1/password-reset";

pub fn apply(alloc: std.mem.Allocator, r: Reset) Outcome {
    const io = io_mod.io();
    const cwd = io_mod.Dir.cwd();
    // Absent is an answer; a read that failed is not, and is not taken for
    // one ("no admin" from a disk that would not say).
    const read = struct {
        fn f(a: std.mem.Allocator, path: []const u8) error{Failed}!?[]u8 {
            return io_mod.Dir.cwd().readFileAlloc(io_mod.io(), path, a, .limited(4096)) catch |e| switch (e) {
                error.FileNotFound => null,
                else => error.Failed,
            };
        }
    }.f;

    const name = (read(alloc, name_path) catch return failed()) orelse return noAdmin();
    defer alloc.free(name);
    const old = (read(alloc, password_path) catch return failed()) orelse return noAdmin();
    defer alloc.free(old);
    if (!std.mem.eql(u8, std.mem.trim(u8, name, " \t\r\n"), r.name)) return .other_name;

    if (read(alloc, marker_path) catch return failed()) |done| {
        defer alloc.free(done);
        if (std.mem.eql(u8, std.mem.trim(u8, done, " \t\r\n"), r.hash)) return .already;
    }

    // The hash it replaces, aside, unless that is this same hash (a stop
    // after the rename and before the marker: keep the one from before).
    if (!std.mem.eql(u8, std.mem.trim(u8, old, " \t\r\n"), r.hash)) {
        cwd.writeFile(io, .{ .sub_path = before_path, .data = old }) catch return failed();
    }
    cwd.writeFile(io, .{ .sub_path = new_path, .data = r.hash }) catch return failed();
    cwd.rename(new_path, cwd, password_path, io) catch return failed();
    cwd.writeFile(io, .{ .sub_path = marker_path, .data = r.hash }) catch return failed();
    return .applied;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const hash_a = "$2b$10$oxKybo3Oosmt0E6lXGVrnubZfb/VLlOFpGiHrMZAy0/KV3k.BbfMS";
const hash_b = "$2a$10$TC9LJ0KU0TIrFl9Hk8FCAeU1bThg2GoSYXAqsjQLdIBSHIxGVfDza";

test "the conf line: a name, which may hold spaces, then a bcrypt hash; anything else is refused" {
    const r = parse("Steve " ++ hash_a).?;
    try testing.expectEqualStrings("Steve", r.name);
    try testing.expectEqualStrings(hash_a, r.hash);
    try testing.expectEqualStrings("Steve Howell", parse("Steve Howell " ++ hash_a).?.name);
    try testing.expect(parse(hash_a) == null); // no name
    try testing.expect(parse("Steve") == null);
    try testing.expect(parse("Steve " ++ hash_a[0..59]) == null); // short
    try testing.expect(parse("Steve $2b$04" ++ hash_a[6..]) == null); // too cheap
    try testing.expect(parse("Steve $2x$10" ++ hash_a[6..]) == null); // not bcrypt
    try testing.expect(parse("Steve " ++ hash_a[0..59] ++ "!") == null); // not its alphabet
    try testing.expect(parse("Steve plaintext-password") == null);
    try testing.expect(validHash(hash_b));
}
