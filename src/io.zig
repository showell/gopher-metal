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
const props = @import("coverage");
const serial = @import("serial.zig");
const virtio = @import("virtio.zig");
const stack = @import("stack.zig");
const PageCache = @import("page_cache.zig").PageCache;
const fat16 = @import("fat16.zig");
const rng = @import("rng.zig");
const tsc = @import("tsc.zig");

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

/// **TWO DISKS, ONE TREE.** The site's own files (its pages, its pictures,
/// this machine's settings) come with each new image, and the application's
/// data must outlive that image. So a path is sent to a volume by its first
/// directory: one named in `data_dirs` goes to `data`, everything else to
/// `site`. The application still sees one tree and spells every path as it
/// does on Linux.
///
/// With no data volume, the data directories are on the site's volume, as
/// they were when the machine had one disk.
var site: ?fat16.Volume = null;
var data: ?fat16.Volume = null;
var data_dirs: []const []const u8 = &.{};

/// The volume every path is resolved against, until `keepData` names the
/// directories that are the application's data.
pub fn mount(v: fat16.Volume) void {
    if (page_cache) |pc| pc.clear();
    site = v;
    site_cache.clear(); // what it kept was another volume's
    // **THE FILESYSTEM GETS THIS MACHINE'S CLOCK.** FAT16 entries carry a date,
    // and the application's "recent activity" is built entirely out of file
    // modification times. fat16.zig has no clock of its own and must not invent
    // one, so it asks this — which answers null until the host has read the RTC,
    // and files written before then honestly carry no date.
    site.?.clock = realUnixOrNull;
}

/// **THE APPLICATION'S DATA: `dirs`, on `on`** (null: on the site's volume).
/// From here on nothing outside `dirs` is written: whatever is there is the
/// site's, and on a droplet the next image replaces it, so a write there would
/// be lost without anyone being told. Such a write is refused and logged.
pub fn keepData(dirs: []const []const u8, on: ?fat16.Volume) void {
    data_dirs = dirs;
    data = on;
    if (data) |*d| d.clock = realUnixOrNull;
    // Another volume, or the same one read afresh: nothing kept is known to
    // be its.
    if (page_cache) |pc| pc.clear();
}

/// **THE DATA'S FILES, KEPT AFTER THEIR FIRST READ** (`page_cache.zig`,
/// QUEUE.md item 87): from here on a data file is read from `pc` when it is
/// there, and every change io makes to a data file is told to it. Null:
/// none kept (the probes, and a host that gives it no memory).
pub fn keepPages(pc: ?*PageCache) void {
    if (page_cache) |old| old.clear();
    page_cache = pc;
}

var page_cache: ?*PageCache = null;

/// The page cache, for a host's report and the tests.
pub fn pageCache() ?*PageCache {
    return page_cache;
}

/// The page cache, if `path` is a data file it keeps.
fn pagesFor(path: []const u8) ?*PageCache {
    const pc = page_cache orelse return null;
    if (data_dirs.len == 0 or placeOf(path) != .data) return null;
    return pc;
}

/// **NOTHING LEAVES THE MACHINE AHEAD OF THE WRITES BEFORE IT.** Every
/// disk with writes it has answered but may not have kept is flushed
/// (`virtio.Block.flush`). `stream.zig` calls this before any response byte
/// joins a connection's send queue, so a 303 that says a message was saved,
/// or a chat frame that shows it to others, goes out only once the message
/// is durable. This is external synchrony (Nightingale et al., "Rethink the
/// Sync", OSDI 2006): durability matters where someone can see it, so it is
/// tied to output, not to the application's own calls. The application
/// never calls `File.sync`, on Linux either, where a write sat in the page
/// cache for up to half a minute; here every write already reaches the
/// device, and this makes it past the device's cache.
///
/// A flush that fails is logged and counted (/admin/host), and the response
/// goes out: the write itself was answered as done, and refusing every
/// response after a disk stops flushing would take the site down for what
/// may be a disk with no cache at all. The flush is tried again before the
/// next response.
pub fn durable() void {
    for ([_]?fat16.Volume{ site, data }, 0..) |maybe, k| {
        const v = maybe orelse continue;
        if (!v.blk.unflushed) continue;
        if (v.blk.flush() != virtio.blk_s_ok) {
            // Reached under metal-vmm with VOLUME_SYNC_FAIL=1 (the volume);
            // no knob fails a flush of the boot disk, which is virtio-blk
            // and writes through.
            props.reachable(@src(), "io: a flush failed, and the response goes out anyway", .{ .disk = k });
            serial.put(if (k == 0) "  a flush of the boot disk failed\n" else "  a flush of the volume failed\n");
        }
    }
}

/// The two volumes, for a host's status report: the site's, and the data's
/// when it has one of its own.
pub fn siteVolume() ?*fat16.Volume {
    return if (site) |*v| v else null;
}
pub fn dataVolume() ?*fat16.Volume {
    return if (data) |*v| v else null;
}

const Place = enum { site, data };

/// **THE DISK IS CHOSEN THE WAY FAT16 WILL RESOLVE THE PATH**, or the path is
/// refused. fat16 matches names ignoring case, so the first directory is
/// compared the same way; and it resolves `.` and `..` as real entries, so a
/// path holding either could be routed by its first directory and land
/// somewhere else — `data/../x` at the volume's root, past the refusal in
/// `writing`. The application never spells a path that way, so such a path is
/// refused (null) rather than interpreted.
fn placeOf(path: []const u8) ?Place {
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
    }
    parts.reset();
    const first = parts.next() orelse return .site;
    for (data_dirs) |dir| {
        if (std.ascii.eqlIgnoreCase(dir, first)) return .data;
    }
    return .site;
}

fn volumeAt(place: Place) Error!*fat16.Volume {
    if (place == .data) {
        if (data) |*d| return d;
    }
    return &(site orelse return Error.FileNotFound);
}

/// **THE SITE'S OWN FILES, KEPT AFTER THEIR FIRST READ** (QUEUE.md item 61).
/// A page read from a file (the home page's text, the resume, a picture) cost
/// four disk requests every time: under QEMU about 0.4 ms of each answer,
/// where an embedded page costs none. Once `keepData` has named the data
/// directories, nothing outside them is written (`writing` refuses it), so a
/// site file read once is the same file until the next image, and keeping it
/// can never go stale. Data files are never kept.
///
/// Bounded and fixed: `capacity` bytes in all, files of up to `largest`, and
/// `slots` of them, first come; past that a file is read from the disk as
/// before. No allocator, so it is here from the boot, in `.bss`.
pub const SiteCache = struct {
    pub const capacity = 4 << 20;
    pub const largest = 512 << 10;
    pub const slots = 64;

    bytes: [capacity]u8 = undefined,
    used: usize = 0,
    names: [slots][max_path]u8 = undefined,
    name_lens: [slots]u16 = undefined,
    starts: [slots]usize = undefined,
    sizes: [slots]usize = undefined,
    count: usize = 0,
    /// Reads answered from here, for a host's report and the tests.
    hits: u64 = 0,

    /// The kept bytes for `path`, matched as FAT matches names: ignoring case.
    fn find(self: *SiteCache, path: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.ascii.eqlIgnoreCase(self.names[i][0..self.name_lens[i]], path))
                return self.bytes[self.starts[i]..][0..self.sizes[i]];
        }
        return null;
    }

    /// Keeps `bytes` as `path`'s, if they fit.
    fn keep(self: *SiteCache, path: []const u8, bytes: []const u8) void {
        if (self.count >= slots or path.len > max_path or bytes.len > largest) return;
        if (self.used + bytes.len > capacity) return;
        @memcpy(self.names[self.count][0..path.len], path);
        self.name_lens[self.count] = @intCast(path.len);
        self.starts[self.count] = self.used;
        self.sizes[self.count] = bytes.len;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
        self.count += 1;
    }

    fn clear(self: *SiteCache) void {
        self.used = 0;
        self.count = 0;
    }
};

var site_cache: SiteCache = .{};

test "the site cache keeps what fits, up to its capacity, and not a byte past it" {
    const c = try std.testing.allocator.create(SiteCache);
    defer std.testing.allocator.destroy(c);
    c.* = .{};
    var file: [SiteCache.largest]u8 = undefined;
    var name: [16]u8 = undefined;
    // Eight of the largest file it keeps are exactly its capacity.
    const fill = SiteCache.capacity / SiteCache.largest;
    for (0..fill) |k| {
        @memset(&file, @truncate(k));
        c.keep(try std.fmt.bufPrint(&name, "gallery/{d}", .{k}), &file);
    }
    try std.testing.expectEqual(@as(usize, SiteCache.capacity), c.used);
    try std.testing.expectEqual(fill, c.count);
    // One byte more is not kept, and what is kept is untouched.
    c.keep("pages/one-more", "x");
    try std.testing.expectEqual(fill, c.count);
    try std.testing.expect(c.find("pages/one-more") == null);
    for (0..fill) |k| {
        const got = c.find(try std.fmt.bufPrint(&name, "gallery/{d}", .{k})).?;
        try std.testing.expectEqual(SiteCache.largest, got.len);
        try std.testing.expectEqual(@as(u8, @truncate(k)), got[got.len - 1]);
    }
}

/// The site cache, for a host's report and the tests.
pub fn siteCache() *SiteCache {
    return &site_cache;
}

/// Whether `path` is a site file that cannot change: one outside the data
/// directories, once there are data directories to be outside of.
fn cacheable(path: []const u8) bool {
    return data_dirs.len != 0 and placeOf(path) == .site;
}

/// **ABSENT, OR A DISK THAT WOULD NOT SAY: NOT THE SAME ANSWER.** fat16's
/// `open`, its errors as the application's: NotFound is FileNotFound, and a
/// read that failed is ReadFailed. Every failure was FileNotFound, so a disk
/// error read as "no such file": `createFile` then made the file afresh,
/// emptying one that was there, and the admin's reset took the admin for
/// absent (QUEUE.md item 89).
fn openEntry(v: *fat16.Volume, path: []const u8) Error!fat16.Entry {
    return v.open(path) catch |e| switch (e) {
        error.NotFound => if (throughFile(v, path)) Error.NotDir else Error.FileNotFound,
        else => Error.ReadFailed,
    };
}

/// **A PATH THROUGH A FILE IS `NotDir`, AS std.Io ANSWERS ON LINUX.** fat16
/// refuses `a/b` with `a` a file as a name that is not there, and this
/// answered FileNotFound, where Linux says NotDir: so the same store.zig call
/// read as an absent file on metal and as an error on Linux (the store judge,
/// 2026-10-07: `readOrEmpty` gave "" on one host and failed on the other).
/// Asked only after a miss, so a found path costs nothing more.
fn throughFile(v: *fat16.Volume, path: []const u8) bool {
    var end: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, end, '/')) |slash| : (end = slash + 1) {
        if (slash == 0) continue;
        const e = v.open(path[0..slash]) catch return false;
        if (!e.isDirectory()) return true;
    }
    return false;
}

/// The volume to read `path` from.
fn reading(path: []const u8) Error!*fat16.Volume {
    return volumeAt(placeOf(path) orelse return Error.FileNotFound);
}

/// The volume to change `path` on, or a refusal: see `keepData`.
fn writing(path: []const u8) Error!*fat16.Volume {
    const place = placeOf(path) orelse {
        serial.put("  refused: a write to a path with . or ..: ");
        serial.put(path);
        serial.put("\n");
        return Error.WriteFailed;
    };
    if (place == .site and data_dirs.len != 0) {
        serial.put("  refused: a write outside the data directories: ");
        serial.put(path);
        serial.put("\n");
        return Error.WriteFailed;
    }
    return volumeAt(place);
}

/// The wall clock in whole seconds, or null if nothing has set it yet. Unlike
/// `Clock.now(.real)` this does not panic: a file write is not a session check,
/// and a probe kernel with no clock still writes files.
fn realUnixOrNull() ?i64 {
    if (!realTimeIsSet()) return null;
    return @intCast(@divFloor(Clock.now(.real, io()).nanoseconds, 1_000_000_000));
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

/// Kind is std's `File.Kind`, ALL of it, though this machine only ever answers
/// `.file` or `.directory`. The application switches over it with an
/// `else => {}` prong — correct against std's eleven members — and against a
/// two-member enum that prong is unreachable, which zig refuses to compile.
pub const Kind = enum {
    block_device,
    character_device,
    directory,
    named_pipe,
    sym_link,
    file,
    unix_domain_socket,
    whiteout,
    door,
    event_port,
    unknown,
};

pub const Stat = struct {
    size: u64,
    kind: Kind,

    /// **FAT16 HAS NO NANOSECONDS, BUT IT HAS A DATE, AND THIS MACHINE WRITES
    /// IT.** A directory entry carries a DOS timestamp with two-second
    /// resolution and nothing finer, so this is always a whole even number of
    /// seconds in nanoseconds. Two things read it: reading_list's cache, which
    /// re-parses a document when its mtime has ADVANCED, and chat's "recent
    /// activity", whose whole model is which files were written last. An entry
    /// that nothing with a clock ever wrote reads as zero.
    mtime: Timestamp = .{ .nanoseconds = 0 },
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

/// max_path bounds the path a File remembers. The application's deepest is a
/// game session's action log — `{data_root}/{id}/lynrummy-elm/sessions/{n}/
/// actions.dsl` — and a data root is an absolute path on the host it came from,
/// so this is generous rather than tight. There is no allocator here to make it
/// dynamic.
pub const max_path: usize = 256;

pub const File = struct {
    entry: fat16.Entry,

    /// **A FILE REMEMBERS ITS PATH**, because a write here names a path rather
    /// than holding a descriptor: there are no open files on this machine, only
    /// a volume and a directory walk.
    path: [max_path]u8 = undefined,
    path_len: usize = 0,

    /// at is the ONLY way a File is made, so none can exist without its path.
    /// openFile once built one without it, and every positional read through
    /// that handle would have looked up the empty path.
    fn at(entry: fat16.Entry, path: []const u8) Error!File {
        if (path.len > max_path) return Error.NameTooLong;
        var f = File{ .entry = entry, .path_len = path.len };
        @memcpy(f.path[0..path.len], path);
        return f;
    }

    pub fn close(_: File, _: Self) void {}

    pub fn stat(self: File, _: Self) Error!Stat {
        return .{
            .size = self.entry.size,
            .kind = if (self.entry.isDirectory()) .directory else .file,
            .mtime = .{ .nanoseconds = @as(i96, self.entry.mtime_unix) * 1_000_000_000 },
        };
    }

    /// Reads until `buffer` is full or the file ends, starting at `offset`, and
    /// answers how many bytes that was — std's `File.readPositionalAll`, which
    /// chat_upload calls to serve a picture whole (a plain GET) or a slice of a
    /// video (a Range request).
    ///
    /// It re-opens by PATH rather than trusting the entry captured at open: an
    /// append since then has moved the size, and a read must see it.
    ///
    /// **A WHOLE-FILE READ BRINGS THE FILE IN** (QUEUE.md item 102, picture
    /// lever 1), exactly as `readFileAlloc` does: a picture served by a plain
    /// GET (offset 0, the buffer holding all of it) is kept, so the next GET of
    /// it is served from memory, not read whole from the disk again — the one
    /// stall item 90 left (a big picture at 30-39 MB/s on each request). A Range
    /// read does not keep the file: it is a seek into a video (offset past the
    /// start, or a buffer too small to have held the whole file), and a video is
    /// past `largest` anyway. Keeping obeys `largest`, so a picture over the cap
    /// is read from the disk as before.
    pub fn readPositionalAll(self: File, _: Self, buffer: []u8, offset: u64) Error!usize {
        const path = self.path[0..self.path_len];
        const pc = pagesFor(path);
        if (pc) |c| if (c.get(path)) |kept| {
            if (offset >= kept.len) return 0;
            const n = @min(buffer.len, kept.len - @as(usize, @intCast(offset)));
            @memcpy(buffer[0..n], kept[@intCast(offset)..][0..n]);
            return n;
        };
        const v = try reading(path);
        const e = try openEntry(v, path);
        if (e.isDirectory()) return Error.IsDir;
        if (offset >= e.size) return 0;
        const n = v.readAt(e, @intCast(offset), buffer) catch return Error.ReadFailed;
        if (pc) |c| if (offset == 0 and n == e.size) c.put(path, buffer[0..n]);
        return n;
    }

    /// **THE APPEND.** Every write the application makes that is not a whole
    /// file is this, and always at the end:
    ///
    ///     var file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    ///     const st = try file.stat(io);
    ///     try file.writePositionalAll(io, bytes, st.size);
    ///
    /// — a chat message, a game action, an uploaded chunk. `offset` may also be
    /// inside the file (an overwrite); it may not be past the end, because FAT
    /// has no sparse files and the hole would be whatever those clusters last
    /// held. See fat16.writeInto.
    pub fn writePositionalAll(self: File, _: Self, bytes: []const u8, offset: u64) Error!void {
        if (offset > 0xFFFF_FFFF) return Error.NoSpaceLeft;
        const path = self.path[0..self.path_len];
        const v = try writing(path);
        const pc = pagesFor(path);
        v.writeInto(path, @intCast(offset), bytes) catch |e| {
            if (throughFile(v, path)) return Error.NotDir;
            if (pc) |c| c.forget(path);
            return switch (e) {
                error.NotFound => Error.FileNotFound,
                error.BadName => Error.NameTooLong,
                error.Full, error.DirectoryFull, error.TooBig => Error.NoSpaceLeft,
                else => Error.WriteFailed,
            };
        };
        if (pc) |c| c.wrote(path, @intCast(offset), bytes);
    }
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

/// Walking a directory. The names it hands out point into the iterator, so a
/// caller that wants to keep one copies it -- which is what
/// `std.Io.Dir.Iterator` also requires.
///
/// **A CURSOR, WITH NO CEILING.** This decoded the whole directory up front
/// into 256 slots and stopped the machine past them, which the application
/// reaches: a player may keep 500 game sessions in one folder, and nothing
/// bounds the players (QUEUE.md item 50). It now reads the directory as it is
/// asked (fat16's `Lister`), so its size is one sector and one name whatever
/// the directory holds, and a directory that will not read says so at the
/// entry it fails on.
pub const Iterator = struct {
    lister: ?fat16.Volume.Lister = null,
    /// **A DIRECTORY THAT CANNOT BE LISTED IS NOT AN EMPTY ONE** (metal-vmm
    /// QUEUE 104). `iterate` cannot answer an error (its shape is std's), so
    /// a volume that is not there, or a directory fat16 will not walk (an
    /// entry naming a cluster outside the data), is kept here and is what
    /// the first `next` answers.
    failed: ?Error = null,
    /// **THE LONG NAME, NOT THE 8.3 ALIAS.** This stored `e.name` -- the alias
    /// -- and the application read its own directories back in upper case:
    /// chat's topic list came out `GENERAL` instead of `general`, so /chat
    /// resumed to a conversation that does not exist. The alias is an artifact
    /// of how FAT16 stores a name; `text()` is the name the file was created
    /// with, and the name every other operation here matches on.
    name: [fat16.max_name]u8 = undefined,

    pub fn next(self: *Iterator, _: Self) Error!?Entry {
        if (self.failed) |e| return e;
        const l = if (self.lister) |*l| l else return null;
        while (true) {
            const e = (l.next() catch return Error.ReadFailed) orelse return null;
            // **"." AND ".." ARE NOT ENTRIES A DIRECTORY ITERATOR RETURNS.**
            // Every FAT16 subdirectory holds them, and `std.Io.Dir.Iterator` on
            // Linux does not report them -- so the application, which recurses
            // into every directory a listing hands it, recursed into "."
            // forever. That is not a hang: it walks the stack past its end,
            // through `.bss` and into the page tables, and the machine
            // triple-faults with nothing in the log. fat16.zig's own removeTree
            // already knew this; the knowledge just did not reach the layer
            // that hands names to the application.
            const name = e.text();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            @memcpy(self.name[0..name.len], name);
            return .{ .name = self.name[0..name.len], .kind = if (e.isDirectory()) .directory else .file };
        }
    }
};

/// **THE OPTION STRUCTS ARE std's, FIELD FOR FIELD, FOR THE FIELDS THE
/// APPLICATION WRITES** — with std's defaults. They were `anytype` until the
/// route table was compiled against them, and `anytype` fails twice over:
///
///   - a literal with no result type cannot hold `@enumFromInt(0o600)` or a
///     decl literal, so `users.zig`'s api-key write did not compile; and
///   - a default has to be CHOSEN, and this file chose wrong: createFile
///     treated a missing `.truncate` as false, where std's default is true. No
///     call in the application omits it today, so nothing was corrupted — but
///     `createFile(io, p, .{})` would have kept old bytes here and emptied the
///     file on Linux.
///
/// A field the application does not use is left out on purpose: writing one is
/// then a compile error here, rather than an option quietly ignored.
pub const OpenOptions = struct {
    iterate: bool = false,
};

pub const Mode = enum { read_only, write_only, read_write };

pub const OpenFileOptions = struct {
    mode: Mode = .read_only,
};

/// FAT16 has no permission bits. The value is accepted so the application's
/// `@enumFromInt(0o600)` on the password and api-key files compiles, and it is
/// IGNORED — there is no other process here to read those files.
pub const Permissions = enum(u32) {
    default_file = 0o666,
    _,
};

pub const CreateFileOptions = struct {
    truncate: bool = true,
    permissions: Permissions = .default_file,
};

pub const WriteFileOptions = struct {
    sub_path: []const u8,
    data: []const u8,
    flags: CreateFileOptions = .{},
};

pub const StatFileOptions = struct {};
pub const AccessOptions = struct {};

pub const Dir = struct {
    /// The cluster this directory starts at; zero is the root.
    cluster: fat16.Cluster = 0,
    /// The volume it is on, which is where `iterate` lists it.
    place: Place = .site,

    pub fn cwd() Dir {
        return .{ .cluster = 0 };
    }

    pub fn close(_: Dir, _: Self) void {}

    /// **EVERY PATH HERE IS FROM THE ROOT**, whatever `Dir` it is asked of:
    /// the application spells every call `Io.Dir.cwd().…`, and uses a `Dir`
    /// it opened only to `iterate` it. A path asked of any other `Dir` would
    /// be resolved from the root of whichever disk its first directory names
    /// — the wrong file, perhaps on the wrong disk — so it stops the machine
    /// instead, saying why.
    fn fromRoot(self: Dir) void {
        if (self.cluster != 0 or self.place != .site)
            @panic("a path was asked of a Dir opened below the root; on this machine only cwd() resolves paths");
    }

    pub fn openDir(self: Dir, _: Self, sub_path: []const u8, _: OpenOptions) Error!Dir {
        self.fromRoot();
        const place = placeOf(sub_path) orelse return Error.FileNotFound;
        const v = try volumeAt(place);
        const e = try openEntry(v, sub_path);
        if (!e.isDirectory()) return Error.NotDir;
        return .{ .cluster = e.first_cluster, .place = place };
    }

    pub fn openFile(self: Dir, _: Self, sub_path: []const u8, _: OpenFileOptions) Error!File {
        self.fromRoot();
        const v = try reading(sub_path);
        const e = try openEntry(v, sub_path);
        if (e.isDirectory()) return Error.IsDir;
        return File.at(e, sub_path);
    }

    pub fn statFile(self: Dir, _: Self, sub_path: []const u8, _: StatFileOptions) Error!Stat {
        self.fromRoot();
        const v = try reading(sub_path);
        const e = try openEntry(v, sub_path);
        return .{
            .size = e.size,
            .kind = if (e.isDirectory()) .directory else .file,
            .mtime = .{ .nanoseconds = @as(i96, e.mtime_unix) * 1_000_000_000 },
        };
    }

    pub fn access(self: Dir, ignored: Self, sub_path: []const u8, _: AccessOptions) Error!void {
        _ = try self.statFile(ignored, sub_path, .{});
    }

    /// The call the application makes 42 times. The bytes are allocated from
    /// `gpa` and the caller owns them.
    pub fn readFileAlloc(self: Dir, ignored: Self, sub_path: []const u8, gpa: std.mem.Allocator, limit: Limit) Error![]u8 {
        self.fromRoot();
        _ = ignored;
        const pc = pagesFor(sub_path);
        if (pc) |c| if (c.get(sub_path)) |kept| {
            if (kept.len > @intFromEnum(limit)) return Error.StreamTooLong;
            const out = gpa.alloc(u8, kept.len) catch return Error.OutOfMemory;
            @memcpy(out, kept);
            return out;
        };
        const keepable = cacheable(sub_path);
        if (keepable) if (site_cache.find(sub_path)) |kept| {
            if (kept.len > @intFromEnum(limit)) return Error.StreamTooLong;
            const out = gpa.alloc(u8, kept.len) catch return Error.OutOfMemory;
            @memcpy(out, kept);
            site_cache.hits += 1;
            return out;
        };
        const v = try reading(sub_path);
        const e = try openEntry(v, sub_path);
        if (e.isDirectory()) return Error.IsDir;
        if (e.size > @intFromEnum(limit)) return Error.StreamTooLong;

        const out = gpa.alloc(u8, e.size) catch return Error.OutOfMemory;
        const n = v.readFile(e, out) catch return Error.ReadFailed;
        if (keepable) site_cache.keep(sub_path, out[0..n]);
        if (pc) |c| if (n == e.size) c.put(sub_path, out[0..n]);
        return out[0..n];
    }

    /// The other half: a whole file, written at once. FAT16 has no journal, so
    /// the directory entry is written after the data -- a machine that stops
    /// mid-write has lost a file rather than corrupted one.
    ///
    /// **THE OPTIONS STRUCT IS THE APPLICATION'S SPELLING**, and std's:
    /// `writeFile(io, .{ .sub_path = p, .data = b })`. This took
    /// `(io, sub_path, bytes)` until the route table was compiled against it,
    /// because the only callers until then were this machine's own probes,
    /// which pass whatever the declaration asks for. That is the same way the
    /// `Io` value, `Limit.limited`, `Clock.now` and `Mutex.lockUncancelable`
    /// were all wrong: self-consistent, and answering a question the
    /// application does not ask.
    ///
    /// `.flags.permissions` is accepted and IGNORED. FAT16 has no permission
    /// bits at all, so a 0o600 on the password file cannot be honoured here —
    /// and the caller must not be told it was. What protects that file on this
    /// machine is that there is no other process to read it.
    pub fn writeFile(self: Dir, _: Self, options: WriteFileOptions) Error!void {
        self.fromRoot();
        // A whole-file write that keeps the old tail is a different operation,
        // and nothing in the application asks for it. Refuse rather than
        // quietly replacing the file anyway.
        if (!options.flags.truncate) @panic("writeFile with .flags.truncate = false is not implemented on this machine");
        const v = try writing(options.sub_path);
        const pc = pagesFor(options.sub_path);
        v.writeFile(options.sub_path, options.data) catch |e| {
            if (throughFile(v, options.sub_path)) return Error.NotDir;
            if (pc) |c| c.forget(options.sub_path);
            return switch (e) {
                error.BadName => Error.NameTooLong,
                error.IsDirectory => Error.IsDir,
                error.Full, error.DirectoryFull => Error.NoSpaceLeft,
                else => Error.WriteFailed,
            };
        };
        if (pc) |c| c.replaced(options.sub_path, options.data);
    }

    /// mkdir -p. The application calls it before nearly every write, because
    /// its stores are directory trees keyed by id and the parent usually does
    /// not exist yet. fat16.makePath already walks and creates, so this is a
    /// rename with error translation.
    pub fn createDirPath(self: Dir, _: Self, sub_path: []const u8) Error!void {
        self.fromRoot();
        const v = try writing(sub_path);
        _ = v.makePath(sub_path) catch |e| {
            // A folder path that runs through a file, or is one, is NotDir,
            // as std.Io's createDirPath answers it on Linux.
            const is_file = if (v.open(sub_path)) |found| !found.isDirectory() else |_| false;
            if (is_file or throughFile(v, sub_path)) return Error.NotDir;
            switch (e) {
                error.BadName => return Error.NameTooLong,
                error.Full, error.DirectoryFull => return Error.NoSpaceLeft,
                else => return Error.WriteFailed,
            }
        };
    }

    /// Open-or-create, for the append pattern documented on
    /// `File.writePositionalAll`. `.truncate` is honoured: false keeps what is
    /// there (the only way the application calls it), true empties the file
    /// first.
    ///
    /// The returned File carries the PATH, not a descriptor — see File.
    pub fn createFile(self: Dir, ignored: Self, sub_path: []const u8, opts: CreateFileOptions) Error!File {
        // Checked HERE as well as in File.at: this call has a side effect, and a
        // path too long for a handle must be refused before the file is made.
        if (sub_path.len > max_path) return Error.NameTooLong;
        const v = try writing(sub_path);
        const truncate = opts.truncate;

        // Absent: made. A disk that would not say is an error, never taken
        // for absent: that emptied a file that was there (QUEUE.md item 89).
        const existing: ?fat16.Entry = openEntry(v, sub_path) catch |e| switch (e) {
            Error.FileNotFound => null,
            else => return e,
        };
        if (existing) |e| {
            if (e.isDirectory()) return Error.IsDir;
        }
        // Create it, or empty it, when there is nothing to keep. An empty file
        // holds no chain at all; the first append is also its allocation.
        if (existing == null or truncate) {
            try self.writeFile(ignored, .{ .sub_path = sub_path, .data = "" });
        }

        const e = try openEntry(v, sub_path);
        return File.at(e, sub_path);
    }

    /// deleteFile removes one file. The application spells every call
    /// `catch {}` — it is clearing a bookmark or an api-key, and a file that is
    /// already gone is the outcome it wanted.
    pub fn deleteFile(self: Dir, _: Self, sub_path: []const u8) Error!void {
        self.fromRoot();
        const v = try writing(sub_path);
        if (pagesFor(sub_path)) |c| c.forget(sub_path);
        v.remove(sub_path) catch |e| {
            if (throughFile(v, sub_path)) return Error.NotDir;
            switch (e) {
                error.NotFound => return Error.FileNotFound,
                // As std.Io answers a directory given to deleteFile.
                error.IsDirectory => return Error.IsDir,
                else => return Error.WriteFailed,
            }
        };
    }

    /// rename moves a file to another name in the same directory, over any
    /// file of that name: how angry-gopher's `store.replace` makes a rewrite
    /// survive a stop (fat16.rename says what each stop leaves). std.Io's
    /// shape, `io` last; both paths from the root, on one volume, in one
    /// directory.
    pub fn rename(self: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8, _: Self) Error!void {
        self.fromRoot();
        new_dir.fromRoot();
        const v = try writing(old_sub_path);
        if (try writing(new_sub_path) != v) return Error.WriteFailed;
        const pc = pagesFor(old_sub_path) orelse pagesFor(new_sub_path);
        v.rename(old_sub_path, new_sub_path) catch |e| {
            if (pc) |c| {
                c.forget(old_sub_path);
                c.forget(new_sub_path);
            }
            return switch (e) {
                error.NotFound => Error.FileNotFound,
                error.IsDirectory => Error.IsDir,
                error.BadName => Error.NameTooLong,
                error.Full, error.DirectoryFull => Error.NoSpaceLeft,
                else => Error.WriteFailed,
            };
        };
        if (pc) |c| c.renamed(old_sub_path, new_sub_path);
    }

    /// deleteTree removes a directory and everything under it — a released
    /// account's game data, a deleted player. See fat16.removeTree for why it
    /// re-lists each round instead of walking a snapshot.
    pub fn deleteTree(self: Dir, _: Self, sub_path: []const u8) Error!void {
        self.fromRoot();
        const v = try writing(sub_path);
        if (pagesFor(sub_path)) |c| c.forgetTree(sub_path);
        // A tree that is not there is gone already; one through a file is
        // NotDir, as std.Io's deleteTree answers on Linux.
        if (throughFile(v, sub_path)) return Error.NotDir;
        v.removeTree(sub_path) catch return Error.WriteFailed;
    }

    /// This directory, a cursor over it: see `Iterator`. A directory whose
    /// first sector cannot be found answers empty, which is what `list`
    /// always did for a cluster it cannot follow; one that fails later says
    /// so at that entry.
    ///
    /// **NO `io` HERE**, because std's `Dir.iterate()` takes none and the
    /// application calls it bare: `var it = dir.iterate();`. The io arrives one
    /// level down, at `it.next(io)`. This took one until the route table was
    /// compiled against it — the same way `writeFile`'s options struct and the
    /// four shapes in a1c2492 were all wrong, and for the same reason: the only
    /// callers were this machine's own probes.
    ///
    /// `cwd().iterate()` lists the boot disk's root, so with a volume attached
    /// `data` and `auth` are not in it. The application never lists the root.
    ///
    /// **EVERY DIRECTORY WALK CHECKS THAT THERE IS STACK LEFT.** The
    /// application recurses through the trees it lists -- the admin roster sums
    /// a player's disk usage that way -- and how deep a tree goes is data, not
    /// code. On Linux a guard page turns that into a clean SIGSEGV; here there
    /// is no guard page and no fault handler, so the alternative to saying so
    /// is a silent reset. This is the chokepoint because every level of every
    /// such walk passes through it, and the check costs one comparison.
    pub fn iterate(self: Dir) Iterator {
        if (stack.nearTheEnd())
            serial.fail("a directory walk has recursed to within the stack's guard: the tree is deeper than this machine can walk");
        const v = volumeAt(self.place) catch |e| return .{ .failed = e };
        return .{ .lister = v.lister(self.cluster) catch return .{ .failed = Error.ReadFailed } };
    }
};

// ---- time ----------------------------------------------------------------

/// **THE RATE IS MEASURED, AND THERE IS NO DEFAULT.** The timestamp counter
/// moves forward and never goes back, which is what a timeout needs; its rate
/// is the CPU's and has to be measured against something whose rate is known
/// (pit.zig). This used to ASSUME two gigahertz. On this box the TSC runs at
/// 2,494 MHz, so every duration ran 25% fast. A host now passes the measured
/// rate, and asking for any clock before it has panics.
var tsc_hz: u64 = 0;
var tsc_base: u64 = 0;

const clock_unset_msg = "Io.Clock.now before startClock(tsc_hz): this machine does not know how fast its timestamp counter runs";

pub fn startClock(measured_tsc_hz: u64) void {
    tsc_hz = measured_tsc_hz;
    tsc_base = tsc.read();
}

pub fn clockIsStarted() bool {
    return tsc_hz != 0;
}

/// Nanoseconds since `startClock`, or null if this machine has not measured its
/// timestamp counter yet.
///
/// **UNLIKE `Clock.now`, THIS DOES NOT PANIC.** A deadline is something code
/// may reasonably ask about before deciding whether it can have one — and the
/// answer "this machine cannot measure a duration yet" is a fact, not a fault.
/// Session expiry is a different matter, which is why `.real` still panics.
pub fn awakeNs() ?i96 {
    if (tsc_hz == 0) return null;
    return sinceBoot();
}

/// Nanoseconds between two TSC readings, at the measured rate. Public so a host
/// can turn a tick count it kept — the block device's, say — into a duration.
pub fn ticksToNs(ticks: u64) i96 {
    if (tsc_hz == 0) @panic(clock_unset_msg);
    return @intCast(@divTrunc(@as(i128, ticks) * 1_000_000_000, @as(i128, tsc_hz)));
}

/// sinceBoot is nanoseconds since startClock().
fn sinceBoot() i96 {
    return ticksToNs(tsc.read() -% tsc_base);
}

/// **THE WALL CLOCK IS NOT SINCE-BOOT, AND IT REFUSES TO PRETEND.**
///
/// Nine places in the application ask for `Clock.now(.real, io)` — creation
/// times, last-seen, presence, and `users.zig`'s SESSION EXPIRY, which checks
/// `now - issued > max_age`. This clock used to answer every clock with time
/// since boot. With `now` a few seconds and `issued` a Unix time near 1.8e9,
/// that difference is enormously negative, so every session cookie — however
/// old — would have been accepted forever.
///
/// So `.real` needs to be TOLD: a host calls `setRealTime` once, with Unix
/// seconds from somewhere that knows them, and `.real` is that plus the time
/// since. Asking before anyone has told it panics, naming the fix, for the same
/// reason mem_meter does: a wrong answer here is silent and a panic is not.
var real_base_ns: ?i96 = null;
var real_set_at: i96 = 0;

const real_unset_msg = "Io.Clock.now(.real) before setRealTime(): this machine does not know the wall-clock time, and answering with time-since-boot would silently disable session expiry";

pub fn setRealTime(unix_seconds: i64) void {
    setRealTimeAt(unix_seconds, tsc.read());
}

/// setRealTimeAt says the wall clock read `unix_seconds` at the moment the TSC
/// read `at_tsc`. A host that waited for the RTC's seconds to tick over passes
/// the TSC it captured AT that edge, so the anchor is as exact as the polling
/// rather than up to a second late.
pub fn setRealTimeAt(unix_seconds: i64, at_tsc: u64) void {
    real_set_at = ticksToNs(at_tsc -% tsc_base);
    real_base_ns = @as(i96, unix_seconds) * 1_000_000_000;
}

pub fn realTimeIsSet() bool {
    return real_base_ns != null;
}

/// Timestamp is std's `Io.Timestamp`: what `Clock.now` answers and what
/// `Stat.mtime` holds. A struct, because the application reads
/// `.now(.real, io).nanoseconds`.
pub const Timestamp = struct { nanoseconds: i96 };

/// Duration is std's `Io.Duration`, with the one constructor the application
/// uses (chat's bus: a keepalive in seconds).
pub const Duration = struct {
    nanoseconds: i96,

    pub fn fromSeconds(s: i64) Duration {
        return .{ .nanoseconds = @as(i96, s) * 1_000_000_000 };
    }
};

/// Clock is std's `Io.Clock`: an ENUM, so `Io.Clock.now(.real, io)` passes the
/// clock as a value. It was a struct with a `now(anytype, …)` until the route
/// table was compiled against it, and a struct cannot give `.fromSeconds(…)`
/// inside a timeout literal a type to resolve against.
///
/// One core and one process: `.awake`, `.boot`, `.cpu_process` and
/// `.cpu_thread` are all time since startClock(). Only `.real` differs.
pub const Clock = enum {
    real,
    awake,
    boot,
    cpu_process,
    cpu_thread,

    pub fn now(clock: Clock, _: Self) Self.Timestamp {
        return switch (clock) {
            .real => .{ .nanoseconds = (real_base_ns orelse @panic(real_unset_msg)) + (sinceBoot() - real_set_at) },
            .awake, .boot, .cpu_process, .cpu_thread => .{ .nanoseconds = sinceBoot() },
        };
    }

    pub const Duration = struct { raw: Self.Duration, clock: Clock };
    pub const Timestamp = struct { raw: Self.Timestamp, clock: Clock };
};

/// Timeout is std's `Io.Timeout`, so the application's literal
/// `.{ .duration = .{ .raw = .fromSeconds(n), .clock = .awake } }` has a type.
pub const Timeout = union(enum) {
    none,
    duration: Clock.Duration,
    deadline: Clock.Timestamp,
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

/// **THE FUTEX IS THE WAKEUP EDGE, AND THERE IS NOTHING TO WAKE.**
///
/// chat's bus (bus.zig) publishes to subscribers and wakes them through a futex
/// on a sequence counter. One core with no preemption has no other task blocked
/// on that counter: whatever would have been woken is the very code that called
/// wake, further down its own stack. So the wake is a no-op and the wait returns
/// at once — which is the honest answer, not a shortcut. A wait that actually
/// blocked here would block the machine.
///
/// When SSE arrives this is the first thing that has to change, and it changes
/// into an event loop rather than a thread.
pub fn futexWake(_: Self, comptime T: type, ptr: *align(@alignOf(u32)) const T, max_waiters: u32) void {
    _ = ptr;
    _ = max_waiters;
}

/// Answers at once, with std's error set so the caller's `catch {}` compiles.
/// It never reports Canceled: nothing here cancels.
pub fn futexWaitTimeout(_: Self, comptime T: type, ptr: *align(@alignOf(u32)) const T, expected: T, timeout: Timeout) error{Canceled}!void {
    _ = ptr;
    _ = expected;
    _ = timeout;
}

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
