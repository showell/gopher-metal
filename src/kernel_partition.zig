//! **THE KERNEL'S OWN PARTITION, BY TYPE.** A droplet's disk carries the
//! kernel in a GPT partition of this type (droplet/image.zig writes it, the
//! boot loader reads it), and chat's files in another partition. gpt.zig
//! mounts the first partition that is NOT this type, so the data is found by
//! what it is rather than where it sits.
//!
//! The kernel is in partition entry 1, because DigitalOcean's import took a
//! disk whose entry 1 was empty for a bare filesystem and wrapped it inside a
//! new disk of its own, boot code and all (2026-10-01).
//!
//! A made-up GUID, as a type only our loader reads should be:
//! 503d64ca-6a8a-48a9-b509-a23323b6de20, stored the way GPT stores it (the
//! first three fields little-endian).
pub const type_guid = [16]u8{ 0xca, 0x64, 0x3d, 0x50, 0x8a, 0x6a, 0xa9, 0x48, 0xb5, 0x09, 0xa2, 0x33, 0x23, 0xb6, 0xde, 0x20 };
