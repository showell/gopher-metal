//! **THE STORE JUDGE'S WORLD** (src/store_judge.zig): one module that owns
//! metal's io, the test disk and the model, so the ported `store.zig`
//! (imported as "metal", whose `io` this is) and the judge share one copy of
//! each.
pub const io = @import("io.zig");
pub const test_disk = @import("test_disk.zig");
pub const fat16 = @import("fat16.zig");
pub const store = @import("store.zig");
pub const store_model = @import("store_model.zig");
