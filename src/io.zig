//! `Io` for this machine: the same surface `angry-gopher/zig-server` calls,
//! backed by FAT16 and the timestamp counter instead of by Linux.
//!
//! **THE FIRST ATTEMPT AT THIS WAS THE WRONG SEAM, AND IT IS WORTH SAYING WHY.**
//! `std.Io` looks like an interface — a vtable you can implement — and it is
//! not one. It has 117 function pointers and no defaults, its handles are
//! literally `std.posix.fd_t`, and `std.Io.Dir.cwd()` reaches for
//! `std.posix.AT.FDCWD`, which does not exist on a freestanding target. It does
//! not fail to work there; **it fails to compile**, whatever vtable you supply.
//! `std.Io` is a portable spelling of the POSIX syscalls, not an abstraction
//! over storage.
//!
//! The real seam is one line higher, and the application hands it to us: every
//! one of its 121 filesystem calls is spelled `Io.Dir.cwd().something(io, ...)`,
//! and 37 files open with
//!
//!     const Io = std.Io;
//!
//! Point that at this module instead and **not one call site changes**. That is
//! the port: 37 single-line edits, zero touched call sites, and a `Dir` that
//! answers the eleven operations the application actually asks for.
//!
//! Note what this does NOT change. `std.http.Server` still runs unmodified,
//! because `std.Io.Reader` and `std.Io.Writer` are genuine interfaces — one
//! required method each, defaults for the rest, no POSIX in their types. The
//! difference between those two designs is the whole lesson here.

const std = @import("std");
const serial = @import("serial.zig");
const fat16 = @import("fat16.zig");
const rng = @import("rng.zig");

/// **THE VALUE THREADED THROUGH EVERY CALL IS THIS MODULE ITSELF.** On Linux it
/// carries an event loop; here there is one machine and one disk, so it carries
/// nothing — but it is still a value, so the call sites keep their shape.
///
/// It has to be the module and not a struct inside it, and that cost a build.
/// The ported application opens with `const Io = @import("metal").io;` and then
/// spells its parameters `io: Io` — so the type it threads IS the module. A
/// separate `pub const Io = struct {}` type-checked for this machine's own
/// probes, which pass what they are given, and failed the moment the real
/// application threaded its own `io` into `Io.Dir` — which is to say, the
/// moment anything ported actually touched the filesystem.
const Self = @This();

pub fn io() Self {
    return .{};
}

/// **THE ONE FUNCTION THE PASSWORD SYSTEM NEEDS FROM THIS MACHINE.**
/// `angry-gopher/zig-server` calls it in exactly two places -- a session token
/// in `users.zig` and an upload id in `chat_upload.zig` -- and spells it the
/// same way Linux does. Everything else its identity layer uses is pure: bcrypt
/// from `std.crypto.pwhash`, HMAC-SHA256 for the cookie, and a constant-time
/// compare. Those already compile freestanding untouched.
pub fn random(_: Self, buf: []u8) void {
    rng.fill(buf);
}

/// The volume every path is resolved against. One machine, one disk.
var volume: ?fat16.Volume = null;

pub fn mount(v: fat16.Volume) void {
    volume = v;
}

pub const Limit = enum(u64) {
    unlimited = std.math.maxInt(u64),
    _,
    /// `limited` is std's spelling, and the application uses it at every capped
    /// read — `.limited(4096)` for a name, `.limited(64)` for a counter. `of` is
    /// this machine's own older name for it, kept because the probes call it.
    pub fn limited(n: u64) Limit {
        return @enumFromInt(n);
    }
    pub fn of(n: u64) Limit {
        return limited(n);
    }
};

pub const Kind = enum { file, directory };

pub const Stat = struct {
    size: u64,
    kind: Kind,
};

pub const Error = error{
    FileNotFound,
    NotDir,
    IsDir,
    OutOfMemory,
    StreamTooLong,
    ReadFailed,
    WriteFailed,
    NameTooLong,
    NoSpaceLeft,
};

pub const File = struct {
    entry: fat16.Entry,

    pub fn close(_: File, _: Self) void {}

    pub fn stat(self: File, _: Self) Error!Stat {
        return .{
            .size = self.entry.size,
            .kind = if (self.entry.isDirectory()) .directory else .file,
        };
    }
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

/// Walking a directory. The names it hands out point into the iterator, so a
/// caller that wants to keep one copies it -- which is what
/// `std.Io.Dir.Iterator` also requires.
pub const Iterator = struct {
    names: [64][12]u8 = undefined,
    lens: [64]u8 = undefined,
    kinds: [64]Kind = undefined,
    count: usize = 0,
    at: usize = 0,

    pub fn next(self: *Iterator, _: Self) Error!?Entry {
        if (self.at >= self.count) return null;
        const i = self.at;
        self.at += 1;
        return .{ .name = self.names[i][0..self.lens[i]], .kind = self.kinds[i] };
    }

    fn take(self: *Iterator, e: fat16.Entry) void {
        if (self.count >= self.names.len) return;
        self.names[self.count] = e.name;
        self.lens[self.count] = e.name_len;
        self.kinds[self.count] = if (e.isDirectory()) .directory else .file;
        self.count += 1;
    }
};

pub const Dir = struct {
    /// The cluster this directory starts at; zero is the root.
    cluster: u16 = 0,

    pub fn cwd() Dir {
        return .{ .cluster = 0 };
    }

    pub fn close(_: Dir, _: Self) void {}

    fn vol() Error!*fat16.Volume {
        return &(volume orelse return Error.FileNotFound);
    }

    pub fn openDir(self: Dir, _: Self, sub_path: []const u8, _: anytype) Error!Dir {
        _ = self;
        const v = try vol();
        const e = v.open(sub_path) catch return Error.FileNotFound;
        if (!e.isDirectory()) return Error.NotDir;
        return .{ .cluster = e.first_cluster };
    }

    pub fn openFile(self: Dir, _: Self, sub_path: []const u8, _: anytype) Error!File {
        _ = self;
        const v = try vol();
        const e = v.open(sub_path) catch return Error.FileNotFound;
        if (e.isDirectory()) return Error.IsDir;
        return .{ .entry = e };
    }

    pub fn statFile(self: Dir, _: Self, sub_path: []const u8, _: anytype) Error!Stat {
        _ = self;
        const v = try vol();
        const e = v.open(sub_path) catch return Error.FileNotFound;
        return .{ .size = e.size, .kind = if (e.isDirectory()) .directory else .file };
    }

    pub fn access(self: Dir, ignored: Self, sub_path: []const u8, opts: anytype) Error!void {
        _ = try self.statFile(ignored, sub_path, opts);
    }

    /// The call the application makes 42 times. The bytes are allocated from
    /// `gpa` and the caller owns them.
    pub fn readFileAlloc(self: Dir, ignored: Self, sub_path: []const u8, gpa: std.mem.Allocator, limit: Limit) Error![]u8 {
        _ = self;
        const v = try vol();
        const e = v.open(sub_path) catch return Error.FileNotFound;
        if (e.isDirectory()) return Error.IsDir;
        if (e.size > @intFromEnum(limit)) return Error.StreamTooLong;
        _ = ignored;

        const out = gpa.alloc(u8, e.size) catch return Error.OutOfMemory;
        const n = v.readFile(e, out) catch return Error.ReadFailed;
        return out[0..n];
    }

    /// The other half: a whole file, written at once. FAT16 has no journal, so
    /// the directory entry is written after the data -- a machine that stops
    /// mid-write has lost a file rather than corrupted one.
    pub fn writeFile(self: Dir, _: Self, sub_path: []const u8, bytes: []const u8) Error!void {
        _ = self;
        const v = try vol();
        v.writeFile(sub_path, bytes) catch |e| switch (e) {
            error.BadName => return Error.NameTooLong,
            error.Full, error.DirectoryFull => return Error.NoSpaceLeft,
            else => return Error.WriteFailed,
        };
    }

    /// Everything in this directory, read in one pass. The application lists
    /// small directories and keeps nothing open across requests, so reading
    /// them whole is simpler than a cursor and costs the same.
    pub fn iterate(self: Dir, _: Self) Error!Iterator {
        const v = try vol();
        var it = Iterator{};
        v.list(self.cluster, &it, Iterator.take) catch return Error.ReadFailed;
        return it;
    }
};

// ---- time ----------------------------------------------------------------

fn rdtsc() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// **THIS CLOCK IS MONOTONIC AND ITS UNIT IS A GUESS.** The timestamp counter
/// moves forward and never goes back, which is what a timeout needs, but its
/// rate is not known without measuring it against something that is. Two
/// gigahertz is assumed. A wall clock, which needs the CMOS or a time server,
/// is a different problem and this is not it.
const assumed_hz: u64 = 2_000_000_000;
var tsc_base: u64 = 0;

pub fn startClock() void {
    tsc_base = rdtsc();
}

/// Instant is what `Clock.now` answers, and it is a STRUCT rather than a plain
/// integer because that is what the application reads:
///
///     Io.Clock.now(.real, io).nanoseconds
///
/// Returning the number directly compiled here and failed there, which is the
/// same lesson as `Self` above — this machine's shapes are only right when the
/// application's own call sites are the thing type-checking them.
pub const Instant = struct { nanoseconds: i128 };

pub const Clock = struct {
    pub fn now(_: anytype, _: Self) Instant {
        const ticks = rdtsc() -% tsc_base;
        return .{ .nanoseconds = @divTrunc(@as(i128, ticks) * 1_000_000_000, @as(i128, assumed_hz)) };
    }
};

/// **THIS MACHINE HAS NO THREADS, AND DOES NOT WANT ANY.**
///
/// A large share of `std.Io`'s 117 entries are the concurrency family -- async,
/// concurrent, await, cancel, four more for groups, three futex operations,
/// batching, and cancellation plumbing threaded through everything else. None
/// of it applies here. One core, no preemption, one connection at a time.
///
/// So "run this concurrently" becomes "run this now", which is not a
/// compromise: on a single core with no preemption there is no overlap to
/// lose. The application is already built for it -- its accept loop is
/// single-threaded by its own comment, and it already falls back to serving
/// inline when its task pool is exhausted, so this is the path it takes on a
/// busy Linux box too.
///
/// The one thing this cannot do is hold several connections open at once,
/// which is what chat's SSE needs. That is the stage this was always going to
/// be deferred to, and it wants a scheduler rather than threads.
pub const Group = struct {
    pub const init = Group{};

    pub fn concurrent(_: *Group, ignored: Self, comptime f: anytype, args: anytype) error{}!void {
        _ = ignored;
        @call(.auto, f, args);
    }

    pub fn async(_: *Group, ignored: Self, comptime f: anytype, args: anytype) error{}!void {
        _ = ignored;
        @call(.auto, f, args);
    }

    pub fn wait(_: *Group, _: Self) void {}
    pub fn cancel(_: *Group, _: Self) void {}
};

/// **A MUTEX HERE IS FREE, AND IT CHECKS THAT IT IS ENTITLED TO BE.**
///
/// The application holds ten of these. They exist because Linux threads
/// interleave; one core with no preemption and an explicit event loop cannot
/// interleave, so every one of them costs nothing.
///
/// The temptation is to delete the calls from the application. That is worse
/// than keeping them, for two reasons.
///
/// **They carry information we would have to rediscover.** Each lock marks a
/// critical section somebody identified. When SSE arrives, concurrency comes
/// back -- not as threads, but as several connections interleaved in one event
/// loop, which is exactly when those sections matter again. Deleting the calls
/// throws away the map and leaves the territory.
///
/// **And a lock that quietly does nothing is a lie.** So this one is not
/// quiet: it records that it is held, and a second lock without an unlock is a
/// genuine re-entrancy that would deadlock on Linux. On this machine it cannot
/// happen -- so if it does, the assumption this whole design rests on is
/// wrong, and the machine says so instead of carrying on.
pub const Mutex = struct {
    held: bool = false,

    pub const init = Mutex{};

    /// lockUncancelable is std's name for "take it, and do not let a cancelled
    /// task abandon it half-held". With no threads and no cancellation there is
    /// nothing to distinguish, so it is `lock` — but the application calls it by
    /// this name at every read-add-write counter, so the name has to be here.
    pub fn lockUncancelable(self: *Mutex, io_: Self) void {
        self.lock(io_);
    }

    pub fn lock(self: *Mutex, _: Self) void {
        if (self.held) {
            serial.fail("a mutex was locked twice without being unlocked: this machine has no preemption, so that is re-entrancy, and on a threaded host it would be a deadlock");
        }
        self.held = true;
    }

    pub fn unlock(self: *Mutex, _: Self) void {
        self.held = false;
    }
};
