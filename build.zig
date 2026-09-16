// gopher-metal's kernels. Everything here targets x86_64-freestanding: no OS,
// no libc, no syscalls. A kernel is one root file over src/, linked with
// probe/link.ld and booted by QEMU through the PVH note it carries.
//
//   zig build probe     the virtio probe kernel  ->  probe/probe.elf
const std = @import("std");

/// The one target: a 64-bit machine with no operating system, and no SSE,
/// because a kernel that has not enabled it faults on the first xmm register
/// the compiler reaches for -- and it reaches for them in memcpy unless told
/// not to.
fn bareTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = std.Target.x86.featureSet(&.{ .sse, .sse2, .avx, .avx2 }),
        .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
    });
}

pub fn build(b: *std.Build) void {
    // **NOT Debug.** A Debug build pulls in zig's UBSan runtime, which wants
    // 128-bit float conversions and therefore the SSE registers this target has
    // switched off. ReleaseSafe keeps the bounds checks and leaves that out.
    const optimize: std.builtin.OptimizeMode = .ReleaseSafe;
    const copy = b.addUpdateSourceFiles();

    // One module for everything under src/, so a type from virtio.zig is the
    // same type wherever it is used.
    const metal = b.createModule(.{ .root_source_file = b.path("src/metal.zig") });

    const kernels = [_]struct { name: []const u8, root: []const u8, step: []const u8, help: []const u8 }{
        .{ .name = "block.elf", .root = "probe/block.zig", .step = "block", .help = "the virtio-blk probe kernel" },
        .{ .name = "net.elf", .root = "probe/net.zig", .step = "net", .help = "the virtio-net and DHCP probe kernel" },
    };

    const all = b.step("kernels", "every kernel");
    for (kernels) |k| {
        const exe = b.addExecutable(.{
            .name = k.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(k.root),
                .target = bareTarget(b),
                .optimize = optimize,
                .pic = false,
                .code_model = .kernel,
                .imports = &.{.{ .name = "metal", .module = metal }},
            }),
        });
        exe.setLinkerScript(b.path("probe/link.ld"));
        exe.entry = .{ .symbol_name = "_start" };

        const one = b.addUpdateSourceFiles();
        one.addCopyFileToSource(exe.getEmittedBin(), b.fmt("probe/{s}", .{k.name}));
        b.step(k.step, k.help).dependOn(&one.step);
        all.dependOn(&one.step);
        copy.addCopyFileToSource(exe.getEmittedBin(), b.fmt("probe/{s}", .{k.name}));
    }

    b.getInstallStep().dependOn(&copy.step);
}
