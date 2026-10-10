//! **THE HOST UNIT TESTS, ONE BINARY** (metal-vmm QUEUE 142): every file
//! below, its tests and the tests of what it imports, each compiled and
//! run once. Built as one binary, the step paid one compile of the test
//! runner, std and the shared imports, not one per file; and a file's
//! tests ran in every binary that imported it (machine.zig's in nine).
//!
//! **build.zig's `unit_files` IS THE LIST**: it refuses to build when this
//! file imports other than exactly those, so one cannot drift from the
//! other. `-Dtest-file=src/x.zig` still builds one file alone. A crash in
//! one test does not stop the rest: the build runner starts the binary
//! again past it.

test {
    _ = @import("rtc.zig");
    _ = @import("pit.zig");
    _ = @import("stack.zig");
    _ = @import("civil.zig");
    _ = @import("disk_fat.zig");
    _ = @import("disk_fat_dirent.zig");
    _ = @import("machine.zig");
    _ = @import("seq.zig");
    _ = @import("ring_pieces.zig");
    _ = @import("pvh.zig");
    _ = @import("pages.zig");
    _ = @import("tcp.zig");
    _ = @import("tcp_check.zig");
    _ = @import("tcp_sim.zig");
    _ = @import("fat_sim.zig");
    _ = @import("page_sim.zig");
    _ = @import("pure_sim.zig");
    _ = @import("ready_sim.zig");
    _ = @import("durable_sim.zig");
    _ = @import("durable.zig");
    _ = @import("scsi_mode.zig");
    _ = @import("floor_sim.zig");
    _ = @import("store.zig");
    _ = @import("store_model.zig");
    _ = @import("store_test.zig");
    _ = @import("store_linux.zig");
    _ = @import("store_sim.zig");
    _ = @import("scratch_dir.zig");
    _ = @import("io_test.zig");
    _ = @import("log_ring.zig");
    _ = @import("restart.zig");
    _ = @import("kept_log.zig");
    _ = @import("ready.zig");
    _ = @import("request_heap.zig");
    _ = @import("page_cache.zig");
    _ = @import("admin_reset.zig");
    _ = @import("dhcp.zig");
    _ = @import("screen.zig");
    _ = @import("serial_gate.zig");
    _ = @import("net.zig");
    _ = @import("idle.zig");
    _ = @import("idle_check.zig");
}
