// gopher-metal's kernels. Everything here targets x86_64-freestanding: no OS,
// no libc, no syscalls. A kernel is one root file over src/, linked with
// probe/link.ld and booted by QEMU through the PVH note it carries.
//
//   zig build probe     the virtio probe kernel  ->  probe/probe.elf
const std = @import("std");
const assets = @import("gen/assets.zig");

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
    //
    // **`-Ddev` IS FOR ITERATING.** Debug with the C sanitizer off — nothing
    // here is C — builds in a fraction of ReleaseSafe's time, with Debug's
    // safety checks. Commits are judged on ReleaseSafe.
    const dev = b.option(bool, "dev", "Debug kernels, for a fast rebuild while iterating") orelse false;
    const optimize: std.builtin.OptimizeMode = if (dev) .Debug else .ReleaseSafe;
    const copy = b.addUpdateSourceFiles();

    // One module for everything under src/, so a type from virtio.zig is the
    // same type wherever it is used.
    const metal = b.createModule(.{ .root_source_file = b.path("src/metal.zig") });

    // `cache_fat` builds the same probe with the FAT held in memory, so one
    // source judges both paths — and run.sh can require the two to leave
    // byte-identical volumes.
    const kernels = [_]struct { name: []const u8, root: []const u8, step: []const u8, help: []const u8, cache_fat: bool = false }{
        .{ .name = "block.elf", .root = "probe/block.zig", .step = "block", .help = "the virtio-blk probe kernel" },
        .{ .name = "fat16.elf", .root = "probe/fat16.zig", .step = "fat16", .help = "the FAT16 probe kernel" },
        .{ .name = "fat16write.elf", .root = "probe/fat16write.zig", .step = "fat16write", .help = "fat16-write, reproducing the ladder verdict" },
        .{ .name = "stdio.elf", .root = "probe/stdio.zig", .step = "stdio", .help = "std.Io.Dir over FAT16" },
        .{ .name = "vfat.elf", .root = "probe/vfat.zig", .step = "vfat", .help = "long names and subdirectories, judged by fsck.vfat" },
        .{ .name = "append.elf", .root = "probe/append.zig", .step = "append", .help = "the append the application makes, judged by fsck.vfat and Linux" },
        .{ .name = "replace.elf", .root = "probe/replace.zig", .step = "replace", .help = "replace, delete and delete-tree, in a fragmented directory" },
        .{ .name = "replace_cached.elf", .root = "probe/replace.zig", .step = "replace_cached", .help = "the same, with the FAT held in memory", .cache_fat = true },
        .{ .name = "restore.elf", .root = "probe/restore.zig", .step = "restore", .help = "reading a volume Linux wrote" },
        .{ .name = "clock.elf", .root = "probe/clock.zig", .step = "clock", .help = "the clocks, and .real once it is told" },
        .{ .name = "realunset.elf", .root = "probe/realunset.zig", .step = "realunset", .help = "MUST PANIC: .real before anyone set it" },
        .{ .name = "memory.elf", .root = "probe/memory.zig", .step = "memory", .help = "the machine's RAM, discovered and handed out" },
        .{ .name = "rng.elf", .root = "probe/rng.zig", .step = "rng", .help = "entropy from virtio-rng and RDRAND" },
        .{ .name = "net.elf", .root = "probe/net.zig", .step = "net", .help = "the virtio-net and DHCP probe kernel" },
        .{ .name = "http.elf", .root = "probe/http.zig", .step = "http", .help = "the one-request web server probe kernel" },
        .{ .name = "stdhttp.elf", .root = "probe/stdhttp.zig", .step = "stdhttp", .help = "the same, but with zig's own std.http.Server" },
    };

    // **THE REAL SERVER**, built only when port.sh has prepared it: this repo
    // holds the change, not the code it is applied to.
    // port.sh writes here by default; -Dgopher=<dir> points elsewhere.
    const gopher_port = b.option([]const u8, "gopher", "angry-gopher's ported sources") orelse
        b.pathFromRoot("../../build/gopher-metal/port");

    const all = b.step("kernels", "every kernel");
    for (kernels) |k| {
        const probe_opts = b.addOptions();
        probe_opts.addOption(bool, "cache_fat", k.cache_fat);
        const exe = b.addExecutable(.{
            .name = k.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(k.root),
                .target = bareTarget(b),
                .optimize = optimize,
                .sanitize_c = .off,
                .pic = false,
                .code_model = .kernel,
                // **THERE IS ONE THREAD AND THERE WILL NOT BE ANOTHER.** A
                // freestanding target is not single-threaded by default, so
                // without this std keeps the threaded lowerings -- real atomic
                // instructions, thread-local storage -- for a machine that has
                // one core, no preemption and no scheduler. Saying so is what
                // entitles src/io.zig to stub the whole concurrency family.
                .single_threaded = true,
                .imports = &.{
                    .{ .name = "metal", .module = metal },
                    .{ .name = "probe_options", .module = probe_opts.createModule() },
                },
            }),
        });
        exe.use_llvm = true;
        exe.setLinkerScript(b.path("probe/link.ld"));
        exe.entry = .{ .symbol_name = "_start" };

        const one = b.addUpdateSourceFiles();
        one.addCopyFileToSource(exe.getEmittedBin(), b.fmt("probe/{s}", .{k.name}));
        b.step(k.step, k.help).dependOn(&one.step);
        all.dependOn(&one.step);
        copy.addCopyFileToSource(exe.getEmittedBin(), b.fmt("probe/{s}", .{k.name}));
    }

    // The application's own modules, each importing `metal` for its Io.
    //
    // **NOT part of `kernels`**, and not depended on by the install step: this
    // needs `port.sh` to have prepared the sources, and a checkout without
    // angry-gopher beside it should still build everything else. `zig build
    // gopher` says plainly what is missing when it is missing.
    // What the application's own build.zig supplies and this one must too: a
    // `build_options` module, and the front-end artifacts each page embeds by
    // name. That table lives in angry-gopher/zig-server/build.zig; only the
    // two /driving needs are mirrored here, because only /driving is served.
    //
    // **THIS IS THE PART OF THE PORT THAT IS NOT ABOUT THE MACHINE.** The 61
    // modules compile freestanding with one line changed each; what is left is
    // build-graph plumbing, and it is the same plumbing on Linux.
    const gopher_root = b.option([]const u8, "gopher-root", "the angry-gopher checkout") orelse
        b.pathFromRoot("../angry-gopher");

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "commit", "bare-metal");
    build_opts.addOption(bool, "fake_leak", false);

    const app = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/router.zig", .{gopher_port}) },
        .imports = &.{
            .{ .name = "metal", .module = metal },
            .{ .name = "build_options", .module = build_opts.createModule() },
        },
    });
    // Every asset the application's own build.zig declares, read out of it by
    // port.sh rather than copied here. A page embeds these by name, and a name
    // that no build graph declared is a compile error with a confusing message.
    for (assets.assets) |a| {
        // Their paths are relative to zig-server/, which is one level in.
        app.addAnonymousImport(a.name, .{
            .root_source_file = .{ .cwd_relative = b.fmt("{s}/zig-server/{s}", .{ gopher_root, a.path }) },
        });
    }
    const gopher = b.addExecutable(.{
        .name = "gopher.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("probe/gopher.zig"),
            .target = bareTarget(b),
            .optimize = optimize,
            .sanitize_c = .off,
            .pic = false,
            .code_model = .kernel,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "metal", .module = metal },
                .{ .name = "router.zig", .module = app },
            },
        }),
    });
    // Zig's own x86 backend, which Debug would otherwise pick, cannot yet
    // assemble this kernel's AT&T or its soft-float.
    gopher.use_llvm = true;
    gopher.setLinkerScript(b.path("probe/link.ld"));
    gopher.entry = .{ .symbol_name = "_start" };
    const gopher_copy = b.addUpdateSourceFiles();
    gopher_copy.addCopyFileToSource(gopher.getEmittedBin(), "probe/gopher.elf");
    b.step("gopher", "the real server, once port.sh has prepared it").dependOn(&gopher_copy.step);

    b.getInstallStep().dependOn(&copy.step);

    // **HOST TESTS** for the parts of src/ that are pure — no ports, no
    // virtqueues — and so can run here rather than in a guest. Every mode a
    // device can report in is a way to be silently wrong, and those modes are
    // cheaper to enumerate on the host than to provoke in QEMU.
    const test_step = b.step("test", "host unit tests for the pure parts of src/");
    for ([_][]const u8{ "src/rtc.zig", "src/stack.zig", "src/civil.zig", "src/fat16.zig", "src/pvh.zig", "src/pages.zig", "src/tcp.zig", "src/tcp_test.zig", "src/ready.zig" }) |path| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}
