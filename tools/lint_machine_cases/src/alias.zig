const tcp = @import("tcp.zig");
const FM = tcp.FinMachine;
const Holder = struct { held: FM = .{} };
fn f(h: *Holder) void {
    h.held = .{}; // refused
}
