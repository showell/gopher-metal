//! **A SIMULATOR'S EVENTS** (metal-vmm QUEUE 224.1): each simulator counts
//! its natural unit here, and `zig build properties` reads the count around
//! each run, for its `ns/event` against the floor of about 1 µs an event.
//! The units, as each simulator counts them:
//!
//! - tcp_sim: a tick of the world's clock, and a segment delivered;
//! - fat_sim, page_sim, store_sim, durable_sim, drain_sim: an operation (a
//!   step of the run);
//! - ready_sim: a request generated and read;
//! - pure_sim: a step of one module's run (a line, a boot, a restart, a
//!   request);
//! - floor_sim: one of its malformed-input cases (fourteen a seed).
//!
//! Only counted, never read by the simulators: it changes no run.
pub var count: u64 = 0;
