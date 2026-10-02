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
    // **NO RED ZONE.** x86-64 code may keep a function's scratch in the 128
    // bytes below the stack pointer, and an interrupt pushes its frame exactly
    // there. src/interrupts.zig takes interrupts only inside `rest`, but a
    // kernel that takes them at all must not be compiled to assume nothing
    // writes below its stack.
    const metal = b.createModule(.{ .root_source_file = b.path("src/metal.zig"), .red_zone = false });

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
        .{ .name = "ladder.elf", .root = "probe/ladder.zig", .step = "ladder", .help = "one operation many times, at a flat cost" },
        .{ .name = "stdhttp.elf", .root = "probe/stdhttp.zig", .step = "stdhttp", .help = "the same, but with zig's own std.http.Server" },
        .{ .name = "hello.elf", .root = "droplet/hello.zig", .step = "hello", .help = "for a real droplet: both cards, every request, forever" },
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
                .red_zone = false,
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

    // **THE COMMITS, BAKED IN**, for /version and /admin/host: angry-gopher's
    // (the application's own option, as its ops/deploy sets it on Linux) and
    // this repository's, each marked `+dirty` when its tree had uncommitted
    // changes, so a page never names a commit the machine is not running.
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "commit", commitOf(b, gopher_root));
    const gm_opts = b.addOptions();
    gm_opts.addOption([]const u8, "commit", commitOf(b, b.pathFromRoot(".")));
    build_opts.addOption(bool, "fake_leak", false);

    const app = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/router.zig", .{gopher_port}) },
        .red_zone = false,
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
            .red_zone = false,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "metal", .module = metal },
                .{ .name = "router.zig", .module = app },
                .{ .name = "gm_build", .module = gm_opts.createModule() },
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

    // **THE TCP TABLE ON LINUX.** native/serve.zig runs src/'s network code as
    // an ordinary Debug program behind a TAP device, with Linux's TCP as the
    // peer; native/judge_native.py asks it questions in seconds.
    const netcore = b.createModule(.{ .root_source_file = b.path("src/netcore.zig"), .target = b.graph.host });
    const serve = b.addExecutable(.{
        .name = "gm-serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/serve.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "netcore", .module = netcore }},
        }),
    });
    b.step("native", "the TCP table as a Linux program behind a TAP device").dependOn(&b.addInstallArtifact(serve, .{}).step);

    // **A DISK A DROPLET CAN BOOT.** droplet/image.zig puts the boot loader
    // and a kernel on a GPT disk; droplet/boot.sh assembles the loader and
    // runs the result on the droplet-shaped QEMU.
    const kernel_partition = b.createModule(.{ .root_source_file = b.path("src/kernel_partition.zig") });
    const image = b.addExecutable(.{
        .name = "gm-image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("droplet/image.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "kernel_partition", .module = kernel_partition }},
        }),
    });
    b.step("droplet", "the disk-image builder for a droplet").dependOn(&b.addInstallArtifact(image, .{}).step);

    // **HOST TESTS** for the parts of src/ that are pure — no ports, no
    // virtqueues — and so can run here rather than in a guest. Every mode a
    // device can report in is a way to be silently wrong, and those modes are
    // cheaper to enumerate on the host than to provoke in QEMU.
    const test_step = b.step("test", "host unit tests for the pure parts of src/");
    for ([_][]const u8{ "src/rtc.zig", "src/stack.zig", "src/civil.zig", "src/fat16.zig", "src/fat16_test.zig", "src/pvh.zig", "src/pages.zig", "src/tcp.zig", "src/tcp_check.zig", "src/tcp_sim.zig", "src/ready.zig", "src/request_heap.zig", "droplet/image.zig", "src/dhcp.zig", "src/screen.zig" }) |path| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
            .imports = &.{.{ .name = "kernel_partition", .module = kernel_partition }},
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }

    // **THE TCP TABLE'S TESTS, AT AWKWARD SEQUENCE NUMBERS** (TCP_TESTING.md
    // §6). Every number on the wire is modulo 2^32, and a `<` where `after()`
    // belongs, or a `-` where `-%` belongs, is invisible a thousand bytes from
    // zero. So the whole suite runs once per pair below: where our first
    // initial sequence number is, and where the peer's first byte is. Every
    // scenario then crosses zero, or the half-way point that decides which
    // of two numbers comes first, within its first few segments.
    const starts = [_]struct { isn: u32, peer: u32 }{
        .{ .isn = 2000, .peer = 5000 }, // where the tests were written
        .{ .isn = 0, .peer = 0 },
        .{ .isn = 0x7FFF_FFF0, .peer = 0x7FFF_FFF0 }, // 16 bytes before half-way
        .{ .isn = 0xFFFF_FFF0, .peer = 0xFFFF_FFF0 }, // 16 bytes before the wrap
        .{ .isn = 0xFFFF_FFF0, .peer = 0x7FFF_FFF0 }, // each side at its own edge
        .{ .isn = 0x7FFF_FFF0, .peer = 0xFFFF_FFF0 },
    };
    for (starts) |start| {
        const options = b.addOptions();
        options.addOption(u32, "isn", start.isn);
        options.addOption(u32, "peer", start.peer);
        const unit = b.addTest(.{
            .name = b.fmt("tcp_test isn={x} peer={x}", .{ start.isn, start.peer }),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tcp_test.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "tcp_test_start", .module = options.createModule() }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }
}

/// `git rev-parse --short HEAD` in `dir`, with `+dirty` when its tree has
/// uncommitted changes; `unknown` when git cannot say.
fn commitOf(b: *std.Build, dir: []const u8) []const u8 {
    var code: u8 = 0;
    const head = b.runAllowFail(&.{ "git", "-C", dir, "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const short = std.mem.trim(u8, head, " \n");
    const status = b.runAllowFail(&.{ "git", "-C", dir, "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch return short;
    return if (std.mem.trim(u8, status, " \n").len == 0) short else b.fmt("{s}+dirty", .{short});
}
