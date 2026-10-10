const Machine = @import("machine.zig").Machine;
const mm = @import("machine.zig");
const Door = Machine(.{ .name = "door" });
const Lamp = mm.Machine(.{ .name = "lamp" });
const H = struct { door: Door = .{}, lamp: Lamp = .{} };
fn f(h: *H) void {
    h.door = .{}; // refused
    h.lamp = .{}; // refused
}
fn fine(h: *H) void {
    const fin = 3;
    _ = fin;
    const x = .{ .door = 1 };
    _ = x;
    switch (h.door.get()) {
        .door => {},
        else => {},
    }
}
