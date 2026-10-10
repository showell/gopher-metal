const machine = @import("machine.zig");
pub const FinMachine = machine.Machine(.{ .name = "x" });
const Conn = struct { fin: FinMachine = .{}, fins: [2]FinMachine = .{ .{}, .{} } };
fn capture(c: *Conn) void {
    for (&c.fins) |*m| m.* = .{}; // refused
}
fn bareIndex() void {
    var fins: [2]FinMachine = .{ .{}, .{} };
    fins[1] = .{}; // refused
    _ = &fins;
}
fn older(c: *Conn, p: *FinMachine) void {
    c.fin = .{}; // refused
    c.fins[0] = .{}; // refused
    p.* = .{}; // refused
    var q = &c.fin;
    q.* = .{}; // refused
    const lit = .{ .fin = 1 };
    _ = lit;
}
test "a test may build a case" {
    var c: Conn = .{};
    c.fin = FinMachine.startingAt(.x);
}
