//! **THE STORE, AS PLAIN AS IT CAN BE MADE: THE ORACLE** (metal-vmm QUEUE
//! item 77). Every file and directory in a hash map, by its path folded to
//! lower case; each keeps the case it was made with. No disk, no power, no
//! size: it never answers `NoSpace`, `Damaged` or `Io`. The other stores are
//! judged by whether they answer what this answers (`store.zig` says what
//! each operation means).

const std = @import("std");
const store = @import("store.zig");
const Error = store.Error;

pub const Model = struct {
    gpa: std.mem.Allocator,
    /// Folded path -> the entry. The root is "" and always there.
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        /// The last part, as it was first written.
        name: []u8,
        kind: store.Kind,
        bytes: std.ArrayListUnmanaged(u8) = .empty,
    };

    pub fn init(gpa: std.mem.Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *Model) void {
        var it = m.entries.iterator();
        while (it.next()) |e| {
            m.gpa.free(e.key_ptr.*);
            m.gpa.free(e.value_ptr.name);
            e.value_ptr.bytes.deinit(m.gpa);
        }
        m.entries.deinit(m.gpa);
    }

    pub fn store_(m: *Model) store.Store {
        return .{ .ptr = m, .vtable = &vtable };
    }

    const vtable = store.Store.VTable{
        .read = readV,
        .write = writeV,
        .append = appendV,
        .list = listV,
        .remove = removeV,
        .replace = replaceV,
    };

    /// `parts[0..n]`, folded and joined, in `buf`.
    fn key(parts: []const []const u8, buf: []u8) []const u8 {
        var n: usize = 0;
        for (parts, 0..) |p, i| {
            if (i > 0) {
                buf[n] = '/';
                n += 1;
            }
            for (p, 0..) |c, j| buf[n + j] = std.ascii.toLower(c);
            n += p.len;
        }
        return buf[0..n];
    }

    const key_bytes = store.max_parts * (store.max_part + 1);

    fn find(m: *Model, parts: []const []const u8) ?*Entry {
        if (parts.len == 0) return null;
        var buf: [key_bytes]u8 = undefined;
        return m.entries.getPtr(key(parts, &buf));
    }

    /// What a read or remove meets on the way: a part that is a file is
    /// `NotFound`, as is one that is missing.
    fn walkTo(m: *Model, parts: []const []const u8) Error!?*Entry {
        for (1..parts.len) |n| {
            const e = m.find(parts[0..n]) orelse return Error.NotFound;
            if (e.kind != .directory) return Error.NotFound;
        }
        return m.find(parts);
    }

    /// The parents of `parts`, made where missing: a part that is a file is
    /// `BadName`.
    fn makeParents(m: *Model, parts: []const []const u8) Error!void {
        for (1..parts.len) |n| {
            if (m.find(parts[0..n])) |e| {
                if (e.kind != .directory) return Error.BadName;
                continue;
            }
            try m.put(parts[0..n], .directory);
        }
    }

    fn put(m: *Model, parts: []const []const u8, kind: store.Kind) Error!void {
        var buf: [key_bytes]u8 = undefined;
        const k = m.gpa.dupe(u8, key(parts, &buf)) catch @panic("the model ran out of memory");
        const name = m.gpa.dupe(u8, parts[parts.len - 1]) catch @panic("the model ran out of memory");
        m.entries.put(m.gpa, k, .{ .name = name, .kind = kind }) catch @panic("the model ran out of memory");
    }

    pub fn read(m: *Model, path: []const u8, out: []u8) Error!usize {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        const e = (try m.walkTo(parts)) orelse return Error.NotFound;
        if (e.kind == .directory) return Error.IsDirectory;
        if (e.bytes.items.len > out.len) return Error.TooBig;
        @memcpy(out[0..e.bytes.items.len], e.bytes.items);
        return e.bytes.items.len;
    }

    /// A file at `parts`, made (with its parents) if absent, for a write of
    /// any kind. A directory there is `IsDirectory`.
    fn fileFor(m: *Model, path: []const u8) Error!*Entry {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        try m.makeParents(parts);
        if (m.find(parts)) |e| {
            if (e.kind == .directory) return Error.IsDirectory;
            return e;
        }
        try m.put(parts, .file);
        return m.find(parts).?;
    }

    pub fn write(m: *Model, path: []const u8, bytes: []const u8) Error!void {
        const e = try m.fileFor(path);
        e.bytes.clearRetainingCapacity();
        e.bytes.appendSlice(m.gpa, bytes) catch @panic("the model ran out of memory");
    }

    pub fn append(m: *Model, path: []const u8, bytes: []const u8) Error!void {
        const e = try m.fileFor(path);
        e.bytes.appendSlice(m.gpa, bytes) catch @panic("the model ran out of memory");
    }

    /// The same as `write`: the model has no power to lose.
    pub fn replace(m: *Model, path: []const u8, bytes: []const u8) Error!void {
        return m.write(path, bytes);
    }

    pub fn remove(m: *Model, path: []const u8) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, false);
        const e = (try m.walkTo(parts)) orelse return Error.NotFound;
        if (e.kind == .directory) return Error.IsDirectory;
        var buf: [key_bytes]u8 = undefined;
        const kv = m.entries.fetchRemove(key(parts, &buf)).?;
        m.gpa.free(kv.key);
        m.gpa.free(kv.value.name);
        var bytes = kv.value.bytes;
        bytes.deinit(m.gpa);
    }

    pub fn list(m: *Model, path: []const u8, each: store.Each) Error!void {
        var pb: [store.max_parts][]const u8 = undefined;
        const parts = try store.checkPath(path, &pb, true);
        var prefix_buf: [key_bytes]u8 = undefined;
        const prefix = key(parts, &prefix_buf);
        if (parts.len > 0) {
            const e = (try m.walkTo(parts)) orelse return Error.NotFound;
            if (e.kind != .directory) return Error.NotFound;
        }
        var it = m.entries.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            const rest = if (prefix.len == 0) k else if (k.len > prefix.len and k[prefix.len] == '/' and std.mem.eql(u8, k[0..prefix.len], prefix)) k[prefix.len + 1 ..] else continue;
            if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
            const e = kv.value_ptr;
            each.call(each.context, .{ .name = e.name, .kind = e.kind, .size = e.bytes.items.len });
        }
    }

    fn self(p: *anyopaque) *Model {
        return @ptrCast(@alignCast(p));
    }
    fn readV(p: *anyopaque, path: []const u8, out: []u8) Error!usize {
        return self(p).read(path, out);
    }
    fn writeV(p: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        return self(p).write(path, bytes);
    }
    fn appendV(p: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        return self(p).append(path, bytes);
    }
    fn listV(p: *anyopaque, path: []const u8, each: store.Each) Error!void {
        return self(p).list(path, each);
    }
    fn removeV(p: *anyopaque, path: []const u8) Error!void {
        return self(p).remove(path);
    }
    fn replaceV(p: *anyopaque, path: []const u8, bytes: []const u8) Error!void {
        return self(p).replace(path, bytes);
    }
};

const testing = std.testing;

test "the model: every operation, and the errors each answers" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    var out: [64]u8 = undefined;
    try m.write("Data/Chat/a.md", "hello");
    try testing.expectEqual(@as(usize, 5), try m.read("data/chat/A.MD", &out));
    try m.append("data/chat/a.md", " world");
    try testing.expectEqualStrings("hello world", out[0..try m.read("data/chat/a.md", &out)]);
    try m.append("data/new", "x");
    try m.replace("data/new", "yz");
    try testing.expectEqualStrings("yz", out[0..try m.read("data/new", &out)]);
    try testing.expectError(Error.IsDirectory, m.read("data/chat", &out));
    try testing.expectError(Error.IsDirectory, m.write("data", "x"));
    try testing.expectError(Error.NotFound, m.read("data/none", &out));
    try testing.expectError(Error.NotFound, m.read("data/new/under", &out));
    try testing.expectError(Error.BadName, m.write("data/new/under", "x"));
    try testing.expectError(Error.TooBig, m.read("data/chat/a.md", out[0..3]));
    try testing.expectError(Error.IsDirectory, m.remove("data/chat"));
    try m.remove("DATA/NEW");
    try testing.expectError(Error.NotFound, m.remove("data/new"));
    const Count = struct {
        n: usize = 0,
        fn each(c: *anyopaque, item: store.Item) void {
            const self_: *@This() = @ptrCast(@alignCast(c));
            _ = item;
            self_.n += 1;
        }
    };
    var root = Count{};
    try m.list("", .{ .context = &root, .call = Count.each });
    try testing.expectEqual(@as(usize, 1), root.n); // Data
    var chat = Count{};
    try m.list("data/chat", .{ .context = &chat, .call = Count.each });
    try testing.expectEqual(@as(usize, 1), chat.n);
    try testing.expectError(Error.NotFound, m.list("data/chat/a.md", .{ .context = &chat, .call = Count.each }));
}
