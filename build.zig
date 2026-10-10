// gopher-metal's kernels. Everything here targets x86_64-freestanding: no OS,
// no libc, no syscalls. A kernel is one root file over src/, linked with
// probe/link.ld and booted by QEMU through the PVH note it carries.
//
//   zig build kernels   every probe kernel into probe/ (`zig build --help` lists each)
//   zig build gopher    the real server, after ./port.sh
const std = @import("std");
const assets = @import("gen/assets.zig");

/// A kernel's root module: bare metal, no red zone, and **ONE THREAD, AND
/// THERE WILL NOT BE ANOTHER.** A freestanding target is not single-threaded
/// by default, so without it std keeps the threaded lowerings (real atomic
/// instructions, thread-local storage) for a machine that has one core, no
/// preemption and no scheduler. Saying so is what entitles src/io.zig to
/// stub the whole concurrency family. The built kernels and `check`'s
/// type-checked ones are made here, so the two cannot drift.
fn kernelModule(b: *std.Build, root: std.Build.LazyPath, optimize: std.builtin.OptimizeMode, imports: []const std.Build.Module.Import) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = root,
        .target = bareTarget(b),
        .optimize = optimize,
        .sanitize_c = .off,
        .pic = false,
        .code_model = .kernel,
        .red_zone = false,
        .single_threaded = true,
        .imports = imports,
    });
}

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

/// The plants (src/plant.zig): one at most, by `-Dplant=<name>`.
const Plant = enum { none, disk_write_swallowed, net_goback_byte, counted_leak_short };

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
    pinnedSdk(b, sdk.builder.build_root.path orelse ".");
    const coverage = sdk.module("coverage");
    coverage.red_zone = false;
    // The seed explorer (zig-coverage-sdk's explore.zig): simulators only.
    const explore = sdk.module("explore");
    const coverage_catalog = @import("zig_coverage_sdk").addCatalog(b, sdk.artifact("coverage-scan"), coverage, b.path("src"), catalogFiles(b));
    // **ONE PLANT AT MOST** (src/plant.zig): every compilation that holds
    // disk_fat.zig or tcp.zig takes it beside the coverage SDK.
    const plant_opts = b.addOptions();
    const plant = b.option(Plant, "plant", "a deliberate bug the judge must catch, for metal-vmm's plants.sh (src/plant.zig); needs -Dcoverage in gopher.elf") orelse .none;
    plant_opts.addOption(Plant, "plant", plant);
    const plant_options = plant_opts.createModule();
    const with_coverage = [_]std.Build.Module.Import{
        .{ .name = "coverage", .module = coverage },
        .{ .name = "plant_options", .module = plant_options },
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
        const exe = b.addExecutable(.{ .name = k.name, .root_module = kernelModule(b, b.path(k.root), optimize, &.{
            .{ .name = "metal", .module = metal },
            .{ .name = "probe_options", .module = probe_opts.createModule() },
        }) });
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
    const gopher_imports = [_]std.Build.Module.Import{
        .{ .name = "metal", .module = metal },
        .{ .name = "router.zig", .module = app },
        .{ .name = "gm_build", .module = gm_opts.createModule() },
    };
    const gopher = b.addExecutable(.{ .name = "gopher.elf", .root_module = kernelModule(b, b.path("probe/gopher.zig"), optimize, &gopher_imports) });
    // Zig's own x86 backend, which Debug would otherwise pick, cannot yet
    // assemble this kernel's AT&T or its soft-float.
    gopher.use_llvm = true;
    gopher.setLinkerScript(b.path("probe/link.ld"));
    gopher.entry = .{ .symbol_name = "_start" };
    const gopher_copy = b.addUpdateSourceFiles();
    gopher_copy.addCopyFileToSource(gopher.getEmittedBin(), "probe/gopher.elf");
    b.step("gopher", "the real server, once port.sh has prepared it").dependOn(&gopher_copy.step);

    // **EVERY KERNEL TYPE-CHECKED, ON EVERY `zig build test`** (metal-vmm
    // B34): a field renamed in src/ broke gopher.elf (b4463a9) and native
    // (140's Fin) with every unit test green, since no test compiles a
    // kernel. Debug, and no binary asked for, so nothing is generated: only
    // analysis.
    //
    // **ANALYSIS, NOT CODEGEN OR THE LINK.** What only LLVM or the linker
    // sees passes here and fails `zig build kernels`: a symbol named only in
    // an asm string or link.ld (a rename of `pvh_start_info`), a bad
    // mnemonic, an extern nothing defines (a cold review found each). Code
    // behind `builtin.mode != .Debug` is not analyzed either. native and
    // droplet are host programs, and are built and linked whole.
    //
    // gopher.elf needs angry-gopher's port (port.sh) and its checkout, for
    // the assets; without either it is not checked, and the step says so
    // rather than pass in silence.
    const check_step = b.step("check", "type-check every kernel (analysis only, not codegen or link), and build native and droplet (part of `test`)");
    // **EVERY PLANT TYPE-CHECKED** (src/plant.zig): a plant's code is
    // analysed only when it is on, so each is checked by a `check` of its
    // own, with -Dcoverage as gopher.elf requires. Run it after touching a
    // plant's lines, and before plants.sh, which does not run it itself.
    const check_plants = b.step("check-plants", "type-check every kernel once with each plant on (src/plant.zig)");
    for (std.enums.values(Plant)) |p| {
        if (p == .none) continue;
        // The same port and checkout as this build's, or gopher.elf is
        // checked against the defaults' (or not at all) for every plant.
        const one = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "check", "-Dcoverage", b.fmt("-Dplant={s}", .{@tagName(p)}), b.fmt("-Dgopher={s}", .{gopher_port}), b.fmt("-Dgopher-root={s}", .{gopher_root}) });
        one.setCwd(b.path("."));
        check_plants.dependOn(&one.step);
    }
    for (kernels) |k| {
        const probe_opts = b.addOptions();
        probe_opts.addOption(bool, "cache_fat", k.cache_fat);
        const exe = b.addExecutable(.{ .name = k.name, .root_module = kernelModule(b, b.path(k.root), .Debug, &.{
            .{ .name = "metal", .module = metal },
            .{ .name = "probe_options", .module = probe_opts.createModule() },
        }) });
        check_step.dependOn(&exe.step);
    }
    var port_code: u8 = 0;
    // **ONLY A PORT OF THE CHECKOUT AS IT IS NOW** (metal-vmm 146(a)): the
    // asset list is the port's, the files the checkout's, so a stale port
    // would fail the build for no fault of this repo's. tools/verdicts.py
    // says whether it is fresh, as gates.sh asks it, and a port not fresh
    // fails the check.
    const port_state: []const u8 = blk: {
        const out = b.runAllowFail(&.{ "env", b.fmt("GOPHER_PORT={s}", .{gopher_port}), b.fmt("GOPHER_ROOT={s}", .{gopher_root}), "python3", b.pathFromRoot("tools/verdicts.py"), "fresh" }, &port_code, .ignore) catch break :blk "tools/verdicts.py could not be run";
        break :blk std.mem.trim(u8, out, " \t\r\n");
    };
    if (std.mem.eql(u8, port_state, "fresh")) {
        const exe = b.addExecutable(.{ .name = "gopher.elf", .root_module = kernelModule(b, b.path("probe/gopher.zig"), .Debug, &gopher_imports) });
        check_step.dependOn(&exe.step);
    } else {
        // **A KERNEL NOT CHECKED FAILS THE CHECK** (Steve, 2026-10-10: fail,
        // never warn). It printed and passed; a stale port then hid a kernel
        // that did not build (48a167f).
        const fail = b.addFail(b.fmt("check: gopher.elf NOT type-checked: {s} (port {s}, checkout {s}): run ./port.sh, or -Dgopher=<dir> and -Dgopher-root=<dir> for others", .{ port_state, gopher_port, gopher_root }));
        check_step.dependOn(&fail.step);
    }

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
    check_step.dependOn(&serve.step);
    check_step.dependOn(&image.step);

    // **HOST TESTS** for the parts of src/ that are pure — no ports, no
    // virtqueues — and so can run here rather than in a guest. Every mode a
    // device can report in is a way to be silently wrong, and those modes are
    // cheaper to enumerate on the host than to provoke in QEMU.
    const test_step = b.step("test", "host unit tests for the pure parts of src/");
    // One file's tests in seconds, while working on it: the whole step takes
    // minutes. A name that matches none of the files is an error.
    const test_file = b.option([]const u8, "test-file", "run only this file's unit tests (src/io_test.zig)");
    // **THE WHOLE-TREE CHECKS ARE THE WHOLE STEP'S** (metal-vmm 146(b),(c)):
    // every kernel analyzed, the formatter and the machine lint. One file's
    // run (-Dtest-file) skips them, so it is seconds again; -Dcheck=false
    // skips the kernels, for the mutation tools, which judge a mutant by the
    // tests and rebuild every one from nothing.
    const with_check = b.option(bool, "check", "zig build test analyzes every kernel too (default; -Dcheck=false for mutation runs)") orelse true;
    if (test_file == null) {
        if (with_check) test_step.dependOn(check_step);
        // **`zig fmt --check src` IS PART OF THE TESTS**, so src/ stays the
        // way the formatter writes it. It was let slip once (three files,
        // QUEUE.md item 10), and a separate step nobody runs would let it
        // slip again.
        test_step.dependOn(&b.addFmt(.{ .paths = &.{"src"}, .check = true }).step);
        // **ONLY `fire` CHANGES A MACHINE'S STATE** (src/machine.zig): Zig
        // has no private fields, so tools/lint_machine.py is the guard.
        const lint_machine = b.addSystemCommand(&.{ "python3", "tools/lint_machine.py" });
        lint_machine.has_side_effects = true;
        test_step.dependOn(&lint_machine.step);
        // And its own cases: each write it must refuse, refused (147(f)).
        const lint_cases = b.addSystemCommand(&.{ "python3", "tools/lint_machine.py", "--self-test" });
        lint_cases.has_side_effects = true;
        test_step.dependOn(&lint_cases.step);
    }
    var test_file_found = test_file == null;
    // **WHICH LINES OF tcp.zig ITS UNIT TESTS RUN** (`zig build tcp-coverage`):
    // tcp_test.zig at every start below, each run once under
    // tools/linecov.py; the lines with code that none of them ran are listed.
    const tcp_coverage = b.addSystemCommand(&.{ "python3", "tools/linecov.py", "src/tcp.zig" });
    b.step("tcp-coverage", "the lines of tcp.zig its unit tests never run").dependOn(&tcp_coverage.step);
    // The same for the FAT: disk_fat.zig and disk_fat_dirent.zig, over the
    // merged unit binary (which also runs the simulators and store tests that
    // reach the FAT, so a line only a simulator runs counts as run) and
    // disk_fat_test and the faults and lies binaries.
    const fat_coverage = b.addSystemCommand(&.{ "python3", "tools/linecov.py", "src/disk_fat.zig" });
    const dirent_coverage = b.addSystemCommand(&.{ "python3", "tools/linecov.py", "src/disk_fat_dirent.zig" });
    const fat_coverage_step = b.step("fat-coverage", "the lines of disk_fat.zig and disk_fat_dirent.zig no host test runs (the unit binary, simulators included, and the FAT test binaries)");
    fat_coverage_step.dependOn(&fat_coverage.step);
    fat_coverage_step.dependOn(&dirent_coverage.step);
    // **ONE BINARY FOR THE FILES' OWN TESTS** (src/unit_tests.zig, metal-vmm
    // QUEUE 142): one compile of the runner, std and the shared imports,
    // and each file's tests run once, not in every binary that imports it.
    // This list is the authority; unit_tests.zig must import exactly it.
    const unit_files = [_][]const u8{ "src/rtc.zig", "src/pit.zig", "src/stack.zig", "src/civil.zig", "src/disk_fat.zig", "src/disk_fat_dirent.zig", "src/machine.zig", "src/seq.zig", "src/ring_pieces.zig", "src/pvh.zig", "src/pages.zig", "src/tcp.zig", "src/tcp_check.zig", "src/tcp_sim.zig", "src/fat_sim.zig", "src/page_sim.zig", "src/pure_sim.zig", "src/ready_sim.zig", "src/durable_sim.zig", "src/durable.zig", "src/scsi_mode.zig", "src/floor_sim.zig", "src/store.zig", "src/store_model.zig", "src/store_test.zig", "src/store_linux.zig", "src/store_sim.zig", "src/scratch_dir.zig", "src/io_test.zig", "src/log_ring.zig", "src/restart.zig", "src/kept_log.zig", "src/ready.zig", "src/request_heap.zig", "src/page_cache.zig", "src/admin_reset.zig", "src/dhcp.zig", "src/screen.zig", "src/serial_gate.zig", "src/net.zig", "src/idle.zig", "src/idle_check.zig" };
    comptime {
        @setEvalBranchQuota(1_000_000);
        const root = @embedFile("src/unit_tests.zig");
        // Each import a line of its own, as `zig fmt` leaves it, so one
        // commented out (`// _ = @import(...)`) is not counted.
        if (std.mem.count(u8, root, "\n    _ = @import(") != unit_files.len) @compileError("src/unit_tests.zig imports other than build.zig's unit_files");
        for (unit_files) |path| {
            if (std.mem.indexOf(u8, root, "\n    _ = @import(\"" ++ path["src/".len..] ++ "\");") == null) @compileError("src/unit_tests.zig does not import " ++ path);
        }
    }
    // Outside src/, so not importable from unit_tests.zig: its own binary.
    const own_binary = [_][]const u8{"droplet/image.zig"};
    const unit_imports = [_]std.Build.Module.Import{
        .{ .name = "kernel_partition", .module = kernel_partition },
        .{ .name = "coverage", .module = coverage },
        .{ .name = "plant_options", .module = plant_options },
        .{ .name = "coverage_catalog", .module = coverage_catalog },
        .{ .name = "explore", .module = explore },
    };
    const unit_roots: []const []const u8 = if (test_file) |only| blk: {
        for (unit_files ++ own_binary) |path| if (std.mem.eql(u8, only, path)) break :blk &.{path};
        break :blk &.{};
    } else &(.{"src/unit_tests.zig"} ++ own_binary);
    for (unit_roots) |path| {
        test_file_found = true;
        const unit = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = b.graph.host,
            .imports = &unit_imports,
        }) });
        test_step.dependOn(&b.addRunArtifact(unit).step);
        // disk_fat's lines run in the merged binary, or in its own.
        if (std.mem.eql(u8, path, "src/unit_tests.zig") or std.mem.eql(u8, path, "src/disk_fat.zig") or std.mem.eql(u8, path, "src/disk_fat_dirent.zig")) {
            fat_coverage.addArtifactArg(unit);
            dirent_coverage.addArtifactArg(unit);
        }
    }
    // **WHICH LINES OF THE STORE'S ORACLE ITS OWN TESTS RUN** (`zig build
    // store-model-coverage`): store_model.zig's tests alone, not the
    // simulators that lean on it, so the oracle is proven by its own tests
    // before it judges anything else.
    const model_unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/store_model.zig"),
        .target = b.graph.host,
        .imports = &unit_imports,
    }) });
    const model_coverage = b.addSystemCommand(&.{ "python3", "tools/linecov.py", "src/store_model.zig" });
    model_coverage.addArtifactArg(model_unit);
    b.step("store-model-coverage", "the lines of store_model.zig its own tests never run").dependOn(&model_coverage.step);
    // The test files built on their own, below.
    for ([_][]const u8{ "src/disk_fat_test.zig", "src/disk_fat_faults_test.zig", "src/tcp_test.zig" }) |path| {
        if (test_file) |only| if (std.mem.eql(u8, only, path)) {
            test_file_found = true;
        };
    }
    if (!test_file_found) @panic("-Dtest-file names no file the unit tests run");

    // **THE STORE PRODUCTION RUNS, JUDGED** (src/store_judge.zig):
    // angry-gopher's store.zig over Linux and, as port.sh made it
    // (`-Dgopher`), over this repo's io.zig, against the model. Needs the
    // sibling angry-gopher checkout and a port, so it is a step of its own,
    // not part of `test`, and not yet in gates.sh: its model is still
    // gopher-metal's Store, not the seam's (STORE.md).
    const ag_src = b.option([]const u8, "angry-gopher-src", "angry-gopher's zig-server/src, the Linux side of store-judge") orelse "../angry-gopher/zig-server/src";
    const judge_world = b.createModule(.{
        .root_source_file = b.path("src/judge_world.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "coverage", .module = coverage },
            .{ .name = "plant_options", .module = plant_options },
            .{ .name = "coverage_catalog", .module = coverage_catalog },
        },
    });
    const store_judge = b.addTest(.{
        .name = "store-judge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store_judge.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "judge_world", .module = judge_world },
                .{ .name = "ag_store_linux", .module = b.createModule(.{ .root_source_file = .{ .cwd_relative = b.pathFromRoot(b.fmt("{s}/store.zig", .{ag_src})) } }) },
                .{ .name = "ag_store_metal", .module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = b.fmt("{s}/store.zig", .{gopher_port}) },
                    .imports = &.{.{ .name = "metal", .module = judge_world }},
                }) },
            },
        }),
    });
    b.step("store-judge", "angry-gopher's store on Linux and on metal against the model (needs ../angry-gopher and a port)").dependOn(&b.addRunArtifact(store_judge).step);

    // **WHAT EACH STORE CALL COSTS THE DISK** (src/store_cost.zig, metal-vmm
    // 151): angry-gopher's store over io.zig, the disk requests of each call
    // and of four common requests, by kind and place. A bench, not a gate.
    const store_cost = b.addTest(.{
        .name = "store-cost",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store_cost.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "judge_world", .module = judge_world },
                .{ .name = "ag_store_metal", .module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = b.fmt("{s}/store.zig", .{gopher_port}) },
                    .imports = &.{.{ .name = "metal", .module = judge_world }},
                }) },
            },
        }),
    });
    b.step("store-cost", "the disk requests each store call and four common requests make (needs a port)").dependOn(&b.addRunArtifact(store_cost).step);

    // **THE SEED EXPLORER AGAINST BLIND SEEDS** (src/explore_bench.zig): a
    // tool, not a gate (Steve, 2026-10-07). ReleaseSafe by default: it is
    // nearly all running.
    const explore_opts = b.addOptions();
    explore_opts.addOption([]const u8, "sim", b.option([]const u8, "explore-sim", "which simulator `explore` runs: fat or store") orelse "fat");
    explore_opts.addOption([]const u8, "budgets", b.option([]const u8, "explore-budgets", "comma-separated run budgets `explore` compares at") orelse "20,100");
    explore_opts.addOption(u64, "seed", b.option(u64, "explore-seed", "the explorer's own seed") orelse 1);
    explore_opts.addOption(f32, "blind", b.option(f32, "explore-blind", "the share of the explorer's runs that are blind") orelse 0.2);
    explore_opts.addOption(bool, "list_missed", b.option(bool, "explore-list-missed", "list the properties neither reached") orelse false);
    explore_opts.addOption(f32, "flip", b.option(f32, "explore-flip", "of the rest, the share that flip a named choice") orelse 0.5);
    explore_opts.addOption(u32, "seeds", b.option(u32, "explore-seeds", "explorer seeds each column is run from (one exploration is one sample)") orelse 20);
    explore_opts.addOption(u32, "reference", b.option(u32, "explore-reference", "blind runs that decide what is counted: what they reach") orelse 300);
    const explore_bench = b.addExecutable(.{
        .name = "explore",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/explore_bench.zig"),
            .target = b.graph.host,
            .optimize = b.option(std.builtin.OptimizeMode, "explore-optimize", "how `explore` is compiled") orelse .ReleaseSafe,
            .imports = &.{
                .{ .name = "explore_options", .module = explore_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
                .{ .name = "explore", .module = explore },
            },
        }),
    });
    b.step("explore", "the seed explorer against blind seeds on fat_sim (a tool, not a gate)").dependOn(&b.addRunArtifact(explore_bench).step);

    // **THE SOAK** (src/explore_soak.zig): the explorer and blind runs on the
    // simulators, round after round; overnight, through tools/soak.sh.
    const soak_opts = b.addOptions();
    soak_opts.addOption([]const u8, "sims", b.option([]const u8, "soak-sims", "the simulators the soak runs: any of fat, store, tcp") orelse "fat,store,tcp");
    soak_opts.addOption(u32, "runs", b.option(u32, "soak-runs", "runs per exploration in the soak") orelse 1000);
    soak_opts.addOption(u32, "rounds", b.option(u32, "soak-rounds", "rounds the soak makes") orelse 1000);
    soak_opts.addOption(u32, "hours", b.option(u32, "soak-hours", "no round of the soak starts after this many hours") orelse 7);
    soak_opts.addOption(u64, "seed", b.option(u64, "soak-seed", "the explorer seed of the soak's first round") orelse 1);
    const soak = b.addExecutable(.{
        .name = "soak",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/explore_soak.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "soak_options", .module = soak_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
                .{ .name = "explore", .module = explore },
                .{ .name = "kernel_partition", .module = kernel_partition },
            },
        }),
    });
    b.step("soak", "the seed explorer and blind runs on fat, store and tcp, round after round (overnight; tools/soak.sh)").dependOn(&b.addRunArtifact(soak).step);
    // **THE SOAK'S BINARY, NOT RUN** (zig-out/bin/soak), for tools/soak.sh
    // to run detached. An ordinary program since metal-vmm QUEUE 106: as a
    // test, `zig build soak` held everything it printed until it exited.
    b.step("soak-build", "build the soak's binary into zig-out/bin, for tools/soak.sh to run").dependOn(&b.addInstallArtifact(soak, .{}).step);

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
    props_opts.addOption(u64, "store_seeds", b.option(u64, "store-seeds", "how many store_sim seeds `properties` sweeps") orelse 1000);
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
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
                .{ .name = "explore", .module = explore },
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
    const disk_fat_opts = b.addOptions();
    disk_fat_opts.addOption([]const u8, "images_dir", b.option([]const u8, "fat16-images", "where disk_fat_test writes its disk images") orelse "");
    disk_fat_opts.addOption([]const u8, "foreign_dir", b.option([]const u8, "fat16-foreign", "volumes other tools made, for disk_fat_test's check to judge") orelse "");
    // **Debug, like every other test** (metal-vmm QUEUE 136): these were
    // ReleaseSafe for a run a third as long (12.5 s, not 33 s), but its
    // compiles cost 72 s of a 2-core box's time for the three binaries, to
    // save 20 s of running. Debug: 1-2 s of compiling each, 37 s of running.
    const disk_fat_unit = b.addTest(.{
        .name = "disk_fat_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/disk_fat_test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "disk_fat_test_options", .module = disk_fat_opts.createModule() },
                .{ .name = "coverage", .module = coverage },
                .{ .name = "plant_options", .module = plant_options },
                .{ .name = "coverage_catalog", .module = coverage_catalog },
            },
        }),
    });
    if (wanted(test_file, "src/disk_fat_test.zig")) test_step.dependOn(&b.addRunArtifact(disk_fat_unit).step);
    fat_coverage.addArtifactArg(disk_fat_unit);
    dirent_coverage.addArtifactArg(disk_fat_unit);
    // The stops and the lying disk (QUEUE.md items 79-80): hundreds of runs
    // each, so binaries of their own, run beside disk_fat_test's: one for the
    // stops and the failed requests, one for the lies. Every test in the file
    // is named by one filter or the other.
    const disk_fat_faults_opts = disk_fat_opts.createModule();
    // **EVERY TEST IN THE FILE RUNS UNDER ONE FILTER OR THE OTHER**, or the
    // build stops: a test named outside them would never run, and say nothing.
    const faults_filters = [_][]const u8{ "every operation stopped after every write", "a request that fails is an error", "a request that fails before a write's commit", "a request that fails or lies leaves no cluster lost" };
    const lies_filters = [_][]const u8{ "a disk that lies", "a write that lands and answers failure" };
    everyTestFiltered(b, "src/disk_fat_faults_test.zig", &(faults_filters ++ lies_filters));
    for ([_][]const []const u8{
        faults_filters[0..],
        lies_filters[0..],
    }, [_][]const u8{ "disk_fat_faults_test", "disk_fat_lies_test" }) |filters, name| {
        const unit = b.addTest(.{
            .name = name,
            .filters = filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/disk_fat_faults_test.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "disk_fat_test_options", .module = disk_fat_faults_opts },
                    .{ .name = "coverage", .module = coverage },
                    .{ .name = "plant_options", .module = plant_options },
                    .{ .name = "coverage_catalog", .module = coverage_catalog },
                },
            }),
        });
        if (wanted(test_file, "src/disk_fat_faults_test.zig")) test_step.dependOn(&b.addRunArtifact(unit).step);
        fat_coverage.addArtifactArg(unit);
        dirent_coverage.addArtifactArg(unit);
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
                    .{ .name = "plant_options", .module = plant_options },
                    .{ .name = "coverage_catalog", .module = coverage_catalog },
                },
            }),
        });
        if (wanted(test_file, "src/tcp_test.zig")) test_step.dependOn(&b.addRunArtifact(unit).step);
        tcp_coverage.addArtifactArg(unit);
    }
}

/// Whether `zig build test` runs `path`'s tests: all of them, or only
/// `-Dtest-file`'s.
fn wanted(test_file: ?[]const u8, path: []const u8) bool {
    const only = test_file orelse return true;
    return std.mem.eql(u8, only, path);
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

/// **THE COVERAGE SDK IS PINNED** (Steve, 2026-10-10): build.zig.zon names
/// it by path, a sibling checkout, so a build used whatever commit that
/// checkout held. A cloud session ran a day of tests against one from
/// before `on_broken`, which fails a unit test at a property it breaks,
/// and nothing said so. The checkout's HEAD must be this commit, or the
/// build stops and names both. Moving the SDK is moving this line, in the
/// same commit as whatever needed the move.
/// `-Dcoverage-sdk-unpinned` builds against any commit, and says so.
const coverage_sdk_pin = "c7baca92b046b2afb0ea059ef2662096871a2f66";

fn pinnedSdk(b: *std.Build, sdk_path: []const u8) void {
    const unpinned = b.option(bool, "coverage-sdk-unpinned", "build against whatever commit ../zig-coverage-sdk holds, not the one build.zig pins") orelse false;
    var code: u8 = undefined;
    const out = b.runAllowFail(&.{ "git", "-C", sdk_path, "rev-parse", "HEAD" }, &code, .ignore) catch |e| {
        if (unpinned) return;
        std.process.fatal("the coverage SDK at {s}: its commit cannot be read ({t}); build.zig pins {s} (-Dcoverage-sdk-unpinned builds without the check)", .{ sdk_path, e, coverage_sdk_pin });
    };
    const head = std.mem.trim(u8, out, " \t\r\n");
    if (std.mem.eql(u8, head, coverage_sdk_pin)) return;
    if (unpinned) {
        std.debug.print("the coverage SDK at {s} is at {s}, not the pinned {s}: building anyway (-Dcoverage-sdk-unpinned)\n", .{ sdk_path, head, coverage_sdk_pin });
        return;
    }
    std.process.fatal("the coverage SDK at {s} is at {s}, but build.zig pins {s}: `git -C {s} fetch && git -C {s} checkout {s}`, or move the pin with the change that needs it (-Dcoverage-sdk-unpinned builds anyway)", .{ sdk_path, head, coverage_sdk_pin, sdk_path, sdk_path, coverage_sdk_pin });
}

/// **THE CATALOG IS EVERY FILE IN src/ THAT DECLARES PROPERTIES** (the
/// protocols-in-prose hunt, 2026-10-10): it was a hand list of 26, and nine
/// served files had properties outside it (stream, scsi, virtio, io, pci,
/// machine, idle, idle_check, store_model), so a property there never reached
/// was never declared, and never showed as a MISS. Now every file that
/// imports the coverage SDK is cataloged, but those named here with why; a
/// name here that is not a file in src/ stops the build.
const not_cataloged = [_]struct { file: []const u8, why: []const u8 }{
    .{ .file = "metal.zig", .why = "the kernel's module root: it re-exports, it declares nothing" },
    .{ .file = "properties.zig", .why = "the properties tier's driver, host only: its own runs, not the kernel's" },
    .{ .file = "explore_bench.zig", .why = "a benchmark of the seed explorer, host only" },
    .{ .file = "explore_soak.zig", .why = "a soak of the seed explorer, host only" },
    .{ .file = "tcp_test.zig", .why = "tests: what they assert is theirs, not a site the sweeps should reach" },
    .{ .file = "disk_fat_faults_test.zig", .why = "tests, as tcp_test.zig" },
};

fn catalogFiles(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    var src = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch |e|
        std.process.fatal("src/ cannot be listed for the coverage catalog ({t})", .{e});
    defer src.close(io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = src.iterate();
    while (it.next(io) catch |e| std.process.fatal("src/ cannot be listed ({t})", .{e})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const text = src.readFileAlloc(io, entry.name, b.allocator, .limited(1 << 22)) catch |e|
            std.process.fatal("src/{s}: cannot be read for the coverage catalog ({t})", .{ entry.name, e });
        if (std.mem.indexOf(u8, text, "@import(\"coverage\")") == null) continue;
        for (not_cataloged) |n| {
            if (std.mem.eql(u8, n.file, entry.name)) break;
        } else out.append(b.allocator, b.dupe(entry.name)) catch @panic("out of memory");
    }
    for (not_cataloged) |n| {
        src.access(io, n.file, .{}) catch std.process.fatal("build.zig's not_cataloged names src/{s}, which is not there", .{n.file});
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return out.items;
}

/// Stops the build when a `test "..."` in `path` contains none of `filters`:
/// a test binary built with filters runs only the tests they name.
fn everyTestFiltered(b: *std.Build, path: []const u8, filters: []const []const u8) void {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 22)) catch |e|
        std.process.fatal("{s}: cannot be read to check its test names ({t})", .{ path, e });
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "test \"")) continue;
        for (filters) |f| {
            if (std.mem.indexOf(u8, line, f) != null) break;
        } else std.process.fatal("{s}: a test no filter in build.zig names, so it would never run: {s}", .{ path, line });
    }
}
