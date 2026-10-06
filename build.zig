// gopher-metal's kernels. Everything here targets x86_64-freestanding: no OS,
// no libc, no syscalls. A kernel is one root file over src/, linked with
// probe/link.ld and booted by QEMU through the PVH note it carries.
//
//   zig build kernels   every probe kernel into probe/ (`zig build --help` lists each)
//   zig build gopher    the real server, after ./port.sh
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
    // **THE COVERAGE SDK** (github.com/showell/zig-coverage-sdk; a sibling
    // checkout, build.zig.zon): `always`/`sometimes` properties of a whole run
    // (COVERAGE.md). No red zone, as for the kernel's own code: it runs inside
    // the kernel too. **THE CATALOG** is its scanner's reading of the files
    // below, so an assertion in code nothing calls is still reported; every
    // module that compiles one of them imports both.
    const sdk = b.dependency("zig_coverage_sdk", .{});
    const coverage = sdk.module("coverage");
    coverage.red_zone = false;
    const coverage_catalog = @import("zig_coverage_sdk").addCatalog(b, sdk.artifact("coverage-scan"), coverage, b.path("src"), &.{ "tcp.zig", "tcp_sim.zig", "fat16.zig", "fat_sim.zig", "page_sim.zig", "pure_sim.zig", "ready_sim.zig", "durable_sim.zig", "durable.zig", "gpt.zig", "floor_sim.zig", "page_cache.zig", "log_ring.zig", "kept_log.zig" });
    const with_coverage = [_]std.Build.Module.Import{
        .{ .name = "coverage", .module = coverage },
        .{ .name = "coverage_catalog", .module = coverage_catalog },
    };
    const metal = b.createModule(.{
        .root_source_file = b.path("src/metal.zig"),
        .red_zone = false,
        .imports = &with_coverage,
    });

    // `cache_fat` builds the same probe with the FAT held in memory, so one
    // source judges both paths — and run.sh can require the two to leave
    // byte-identical volumes.
    const kernels = [_]struct { name: []const u8, root: []const u8, step: []const u8, help: []const u8, cache_fat: bool = false }{
        .{ .name = "block.elf", .root = "probe/block.zig", .step = "block", .help = "the virtio-blk probe kernel" },
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
        .{ .name = "backoff.elf", .root = "probe/backoff.zig", .step = "backoff", .help = "the restart end to end: four restarts, then the back-off (RESTART.md)" },
        .{ .name = "restart.elf", .root = "probe/restart.zig", .step = "restart", .help = "what each way of restarting keeps (RESTART.md)" },
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
    // name. That table lives in angry-gopher/zig-server/build.zig; port.sh
    // copies it into gen/assets.zig, so the two cannot drift.
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
    // **OFF UNTIL A DROPLET HAS BEEN MEASURED** (QUEUE.md item 16's hard
    // rule): a guest's reset must restart a real droplet, not power it off,
    // before any deployed image restarts itself. -Drestart=true builds it in.
    gm_opts.addOption(bool, "restart", b.option(bool, "restart", "gopher.elf restarts on a failure while serving (RESTART.md; measured on a real droplet 2026-10-03); -Drestart=false halts instead") orelse true);
    // **COVERAGE PROPERTIES ON THE SERIAL PORT** (COVERAGE.md): off in
    // anything deployed, where the declarations alone would fill the log
    // ring /admin/host shows. tools/coverage_jsonl.sh lifts them out.
    gm_opts.addOption(bool, "coverage", b.option(bool, "coverage", "gopher.elf writes its coverage-property lines to the serial port") orelse false);
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
    const netcore = b.createModule(.{
        .root_source_file = b.path("src/netcore.zig"),
        .target = b.graph.host,
        .imports = &with_coverage,
    });
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
    // **`zig fmt --check src` IS PART OF THE TESTS**, so src/ stays the way
    // the formatter writes it. It was let slip once (three files, QUEUE.md
    // item 10), and a separate step nobody runs would let it slip again.
    test_step.dependOn(&b.addFmt(.{ .paths = &.{"src"}, .check = true }).step);
    for ([_][]const u8{ "src/rtc.zig", "src/pit.zig", "src/stack.zig", "src/civil.zig", "src/fat16.zig", "src/pvh.zig", "src/pages.zig", "src/tcp.zig", "src/tcp_check.zig", "src/tcp_sim.zig", "src/fat_sim.zig", "src/page_sim.zig", "src/pure_sim.zig", "src/ready_sim.zig", "src/durable_sim.zig", "src/durable.zig", "src/floor_sim.zig", "src/store.zig", "src/store_model.zig", "src/store_test.zig", "src/io_test.zig", "src/log_ring.zig", "src/restart.zig", "src/kept_log.zig", "src/ready.zig", "src/request_heap.zig", "src/page_cache.zig", "src/admin_reset.zig", "droplet/image.zig", "src/dhcp.zig", "src/screen.zig", "src/serial_gate.zig", "src/net.zig" }) |path| {
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "kernel_partition", .module = kernel_partition },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
            },
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }

    // **COVERAGE PROPERTIES** (COVERAGE.md): the TCP and FAT simulators over
    // a sweep of seeds, then every assertion they reach judged. Not part of `test`: its report is read, not gated on, while it
    // is a proof of concept (a `sometimes` never met is a gap, not a bug).
    const props_opts = b.addOptions();
    props_opts.addOption(u64, "seeds", b.option(u64, "seeds", "how many tcp_sim seeds `properties` sweeps") orelse 100);
    // Every seed runs as a crowd too, unless asked for fewer: revival
    // (tcp.zig) made item 24's crowd seeds green (tcp_sim.zig, `crowd_red`).
    props_opts.addOption(u64, "crowd_seeds", b.option(u64, "crowd-seeds", "how many of the tcp_sim seeds `properties` also runs as a crowd") orelse std.math.maxInt(u64));
    props_opts.addOption(u64, "fat_seeds", b.option(u64, "fat-seeds", "how many fat_sim seeds `properties` sweeps") orelse 20);
    props_opts.addOption(u64, "page_seeds", b.option(u64, "page-seeds", "how many page_sim seeds `properties` sweeps") orelse 100);
    props_opts.addOption(u64, "pure_seeds", b.option(u64, "pure-seeds", "how many pure_sim seeds `properties` sweeps") orelse 200);
    props_opts.addOption(u64, "full_seeds", b.option(u64, "full-seeds", "how many tcp_sim seeds `properties` runs as a crowd the size of the kernel's table") orelse 20);
    props_opts.addOption(u64, "floor_seeds", b.option(u64, "floor-seeds", "how many floor_sim seeds `properties` sweeps") orelse 1000);
    props_opts.addOption(u64, "durable_seeds", b.option(u64, "durable-seeds", "how many durable_sim seeds `properties` sweeps") orelse 1000);
    props_opts.addOption(u64, "ready_seeds", b.option(u64, "ready-seeds", "how many ready_sim seeds `properties` sweeps") orelse 300);
    props_opts.addOption([]const u8, "sdk_jsonl", b.option([]const u8, "sdk-jsonl", "where `properties` writes its JSONL") orelse "");
    // The floor (coverage/floor-sim.txt, COVERAGE.md): what the long tier
    // must reach. Unset, a MISS is reported and never fails the step.
    const floor = b.option([]const u8, "floor", "a coverage floor `properties` must reach (long.sh)");
    props_opts.addOption([]const u8, "floor", if (floor) |f| b.pathFromRoot(f) else "");
    const props = b.addTest(.{
        .name = "properties",
        // Only the sweep: the files it imports carry tests of their own,
        // whose sites would join its catalog and its verdict.
        .filters = &.{"the properties over a sweep of seeds"},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/properties.zig"),
            .target = b.graph.host,
            // **DEBUG, AS EVERY HOST TEST IS** (Steve, 2026-10-05): test code
            // is iterated on, and Debug builds in a fraction of the time. A
            // sweep is nearly all running, though, about three times slower in
            // Debug: long.sh asks for ReleaseSafe for its 10,000 seeds.
            .optimize = b.option(std.builtin.OptimizeMode, "sweep-optimize", "how `properties` is built (Debug; long.sh: ReleaseSafe)") orelse .Debug,
            .imports = &.{
                .{ .name = "tcp_properties_options", .module = props_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
            },
        }),
    });
    const props_run = b.addRunArtifact(props);
    props_run.has_side_effects = true;
    b.step("properties", "the coverage properties over a sweep of tcp_sim, fat_sim, page_sim and pure_sim seeds").dependOn(&props_run.step);

    // **THE TCP TABLE'S TESTS, AT AWKWARD SEQUENCE NUMBERS** (TCP_TESTING.md
    // §6). Every number on the wire is modulo 2^32, and a `<` where `after()`
    // belongs, or a `-` where `-%` belongs, is invisible a thousand bytes from
    // zero. So the whole suite runs once per pair below: where our first
    // initial sequence number is, and where the peer's first byte is. Every
    // scenario then crosses zero, or the half-way point that decides which
    // of two numbers comes first, within its first few segments.
    // **FAT16 ON AN IN-MEMORY DISK.** With -Dfat16-images=<dir>, every image
    // the tests made is also written there, for tools/fat16_read.py to check:
    // tools/check_fat16_images.sh does both.
    const fat16_opts = b.addOptions();
    fat16_opts.addOption([]const u8, "images_dir", b.option([]const u8, "fat16-images", "where fat16_test writes its disk images") orelse "");
    fat16_opts.addOption([]const u8, "foreign_dir", b.option([]const u8, "fat16-foreign", "volumes other tools made, for fat16_test's check to judge") orelse "");
    // **ReleaseSafe, NOT Debug**: every safety check stays on, and the run is
    // a third of the time (12.5 s, not 33 s). Its tests format and check tens
    // of 35 MB FAT32 images (a rename stopped at each step, on every shape);
    // the first build after a change to fat16 costs what Debug's run did.
    const fat16_unit = b.addTest(.{
        .name = "fat16_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fat16_test.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "fat16_test_options", .module = fat16_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fat16_unit).step);
    // The stops and the lying disk (QUEUE.md items 79-80): hundreds of runs
    // each, so binaries of their own, run beside fat16_test's: one for the
    // stops and the failed requests, one for the lies. Every test in the file
    // is named by one filter or the other.
    const fat16_faults_opts = fat16_opts.createModule();
    for ([_][]const []const u8{
        &.{ "every operation stopped after every write", "a request that fails is an error" },
        &.{"a disk that lies"},
    }, [_][]const u8{ "fat16_faults_test", "fat16_lies_test" }) |filters, name| {
        const unit = b.addTest(.{
            .name = name,
            .filters = filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fat16_faults_test.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "fat16_test_options", .module = fat16_faults_opts },
                    .{ .name = "coverage", .module = coverage },
                    .{ .name = "coverage_catalog", .module = coverage_catalog },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }

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
                .imports = &.{
                    .{ .name = "tcp_test_start", .module = options.createModule() },
                    .{ .name = "coverage", .module = coverage },
                    .{ .name = "coverage_catalog", .module = coverage_catalog },
                },
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
