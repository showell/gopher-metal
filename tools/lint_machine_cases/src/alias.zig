const tcp = @import("tcp.zig");
const FM = tcp.FinMachine;
const Holder = struct { held: FM = .{} };
fn f(h: *Holder) void {
    h.held = .{}; // refused
}
const FM2 = @import("tcp.zig").FinMachine;
const Other = struct { kept: FM2 = .{} };
fn g(o: *Other) void {
    o.kept = .{}; // refused
}
