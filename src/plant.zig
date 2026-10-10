//! **THE PLANTS** (metal-vmm `plants.sh`): deliberate bugs the judge must
//! catch, kept in the source beside the code they break, each behind
//! `if (comptime plant.on == .<name>)`. `zig build ... -Dplant=<name>` turns
//! one on; the default, `.none`, compiles every one of them away, and a
//! kernel built with one on and without `-Dcoverage` does not compile, so no
//! release image can hold one. A plant moves with its code: a refactor that
//! breaks one fails `zig build check-plants`, not the next plants run.
//!
//! Each says `PLANT: <name> fires` where it does its harm; `plants.sh`
//! fails a plant that never fires as dead, apart from one never caught.

pub const on = @import("plant_options").plant;
pub const Plant = @TypeOf(on);
