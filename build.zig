const std = @import("std");
const sokol = @import("sokol");
const cimgui = @import("cimgui");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // Get the matching Zig module name, C header search path and C library for
    // vanilla imgui vs the imgui docking branch.
    const cimgui_conf = cimgui.getConfig(false); // no docking

    // note that the sokol dependency is built with `.with_sokol_imgui = true`
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
        .with_tracing = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    // inject the cimgui header search path into the sokol C library compile step
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zffe", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zffe",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zffe" is the name you will use in your source code to
                // import this module (e.g. `@import("zffe")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zffe", .module = mod },
                .{ .name = "sokol", .module = dep_sokol.module("sokol") },
                .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // ---- FFE image pipeline: ffed3d asm -> ffe.elf -> ffe.bin + ffe.map ----
    // `zig build` assembles, links, generates the map, compiles the shim +
    // Zig code, and installs zffe + ffe-info + data/ffe.{bin,map,elf}.
    // Inspect with:
    //   zig build info -- zig-out/data/ffe.bin zig-out/data/ffe.map --lift
    const ffed3d_dir = b.option(
        []const u8,
        "ffed3d",
        "Path to ffed3d checkout, relative to CWD (default: ../ffed3d)",
    ) orelse "../ffed3d";
    const want_asm = b.option(
        bool,
        "ffe-asm",
        "Assemble ffe.bin/ffe.map from ffed3d (needs nasm, ld.lld, llvm-objcopy)",
    ) orelse true;
    const nasm_exe = b.option([]const u8, "nasm", "nasm executable") orelse "nasm";
    const ffe_ld = b.option([]const u8, "ffe-ld", "ELF linker for the ffe image") orelse "ld.lld";
    const objcopy_exe = b.option([]const u8, "llvm-objcopy", "llvm-objcopy executable") orelse "llvm-objcopy";
    const have_remill = b.option(bool, "have-remill", "Link real Remill/LLVM into the shim") orelse false;
    const remill_prefix = b.option([]const u8, "remill-prefix", "Remill install prefix (with -Dhave-remill)");
    const llvm_config_exe = b.option([]const u8, "llvm-config", "llvm-config executable (with -Dhave-remill)") orelse "llvm-config";

    // Remill/LLVM link inputs, filled only when have_remill is set.
    var remill_libpaths: std.ArrayList([]const u8) = .empty;
    var remill_syslibs: std.ArrayList([]const u8) = .empty;
    var remill_frameworks: std.ArrayList([]const u8) = .empty;

    // Shim as a static lib so the exe, ffe-info, and both test binaries share it.
    const shim_mod = b.createModule(.{ .target = target, .optimize = optimize });
    const shim_lib = b.addLibrary(.{
        .name = "zffe_shim",
        .linkage = .static,
        .root_module = shim_mod,
    });
    var shim_cflags: std.ArrayList([]const u8) = .empty;
    shim_cflags.append(b.allocator, "-std=c++17") catch @panic("OOM");
    if (have_remill) {
        const rp = remill_prefix orelse {
            std.debug.print("error: -Dhave-remill requires -Dremill-prefix\n", .{});
            std.process.exit(1);
        };
        shim_cflags.append(b.allocator, "-DZFFE_HAVE_REMILL=1") catch @panic("OOM");
        shim_mod.addIncludePath(b.graph.cwdRelativePath(b.pathJoin(&.{ rp, "include" })));
        remill_libpaths.append(b.allocator, b.pathJoin(&.{ rp, "lib" })) catch @panic("OOM");
        remill_syslibs.append(b.allocator, "remill") catch @panic("OOM");
        const cxxflags = b.run(&.{ llvm_config_exe, "--cxxflags" });
        var cit = std.mem.splitScalar(u8, cxxflags, ' ');
        while (cit.next()) |flag| {
            if (flag.len == 0 or flag[flag.len - 1] == '\n') {
                const trimmed = std.mem.trim(u8, flag, " \t\r\n");
                if (trimmed.len == 0) continue;
                shim_cflags.append(b.allocator, trimmed) catch @panic("OOM");
                continue;
            }
            shim_cflags.append(b.allocator, flag) catch @panic("OOM");
        }
        const ldflags = b.run(&.{ llvm_config_exe, "--ldflags", "--libs", "core", "--system-libs" });
        var lit = std.mem.splitScalar(u8, ldflags, ' ');
        while (lit.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t\r\n");
            if (tok.len == 0) continue;
            if (std.mem.startsWith(u8, tok, "-L")) {
                remill_libpaths.append(b.allocator, tok[2..]) catch @panic("OOM");
            } else if (std.mem.startsWith(u8, tok, "-l")) {
                remill_syslibs.append(b.allocator, tok[2..]) catch @panic("OOM");
            } else if (std.mem.eql(u8, tok, "-framework")) {
                const fw = std.mem.trim(u8, lit.next() orelse break, " \t\r\n");
                remill_frameworks.append(b.allocator, fw) catch @panic("OOM");
            }
        }
    }
    shim_mod.addCSourceFile(.{ .file = b.path("src/shim.cpp"), .flags = shim_cflags.items });
    shim_mod.addCSourceFile(.{ .file = b.path("src/guest_mem.cpp"), .flags = shim_cflags.items });
    shim_mod.link_libcpp = true;

    // Host tools. Built always so their tests run standalone.
    const elf2map_exe = b.addExecutable(.{
        .name = "elf2map",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/elf2map.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const elf2map_tests = b.addTest(.{ .root_module = elf2map_exe.root_module });
    const run_elf2map_tests = b.addRunArtifact(elf2map_tests);
    const sentinel_exe = b.addExecutable(.{
        .name = "sentinel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sentinel.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const sentinel_tests = b.addTest(.{ .root_module = sentinel_exe.root_module });
    const run_sentinel_tests = b.addRunArtifact(sentinel_tests);

    if (want_asm) {
        // -I needs a trailing slash for %include "ffedat.asm" resolution.
        const nasm_inc = std.fmt.allocPrint(b.allocator, "{s}/", .{ffed3d_dir}) catch @panic("OOM");
        const nasm_ffe = b.addSystemCommand(&.{nasm_exe});
        nasm_ffe.addArgs(&.{ "-f", "elf32", "-I", nasm_inc });
        const ffe_obj = nasm_ffe.addPrefixedOutputFileArg("-o", "ffe.o");
        nasm_ffe.addFileArg(b.graph.cwdRelativePath(b.pathJoin(&.{ ffed3d_dir, "ffe.asm" })));

        const nasm_bmp = b.addSystemCommand(&.{nasm_exe});
        nasm_bmp.addArgs(&.{ "-f", "elf32", "-I", nasm_inc });
        const bmp_obj = nasm_bmp.addPrefixedOutputFileArg("-o", "ffebmp.o");
        nasm_bmp.addFileArg(b.graph.cwdRelativePath(b.pathJoin(&.{ ffed3d_dir, "ffebmp.asm" })));

        const link = b.addSystemCommand(&.{ffe_ld});
        link.addArg("-T");
        link.addFileArg(b.path("tools/ffe.ld"));
        link.addArgs(&.{ "--unresolved-symbols=ignore-all", "--emit-relocs" });
        const elf = link.addPrefixedOutputFileArg("-o", "ffe.elf");
        link.addFileArg(ffe_obj);
        link.addFileArg(bmp_obj);

        const copy = b.addSystemCommand(&.{objcopy_exe});
        copy.addArgs(&.{ "-O", "binary" });
        copy.addFileArg(elf);
        const bin_raw = copy.addOutputFileArg("ffe.raw.bin");

        const gen_map = b.addRunArtifact(elf2map_exe);
        gen_map.addFileArg(elf);
        const map_raw = gen_map.addOutputFileArg("ffe.raw.map");

        const patch = b.addRunArtifact(sentinel_exe);
        patch.addFileArg(elf);
        patch.addFileArg(bin_raw);
        patch.addFileArg(map_raw);
        const bin = patch.addOutputFileArg("ffe.bin");
        const map = patch.addOutputFileArg("ffe.map");

        const install_bin = b.addInstallFile(bin, "data/ffe.bin");
        const install_map = b.addInstallFile(map, "data/ffe.map");
        const install_elf = b.addInstallFile(elf, "data/ffe.elf");
        b.getInstallStep().dependOn(&install_bin.step);
        b.getInstallStep().dependOn(&install_map.step);
        b.getInstallStep().dependOn(&install_elf.step);

        const ffe_step = b.step("ffe", "Assemble ffe.bin/ffe.map/ffe.elf from ffed3d sources");
        ffe_step.dependOn(&install_bin.step);
        ffe_step.dependOn(&install_map.step);
        ffe_step.dependOn(&install_elf.step);
    }

    // ffe-info inspector tool.
    const info_exe = b.addExecutable(.{
        .name = "ffe-info",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffe_info.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(info_exe);
    const info_cmd = b.addRunArtifact(info_exe);
    info_cmd.addPassthruArgs();
    const info_step = b.step("info", "Run ffe-info (pass: <ffe.bin> <ffe.map> [--lift])");
    info_step.dependOn(&info_cmd.step);

    // Link the shim (+ Remill/LLVM when enabled) into every module using it.
    // Note: exe_tests shares exe.root_module and mod_tests shares mod, so
    // three calls cover all five artifacts.
    linkFfeDeps(b, exe.root_module, shim_lib, remill_libpaths.items, remill_syslibs.items, remill_frameworks.items);
    linkFfeDeps(b, info_exe.root_module, shim_lib, remill_libpaths.items, remill_syslibs.items, remill_frameworks.items);
    linkFfeDeps(b, mod, shim_lib, remill_libpaths.items, remill_syslibs.items, remill_frameworks.items);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_elf2map_tests.step);
    test_step.dependOn(&run_sentinel_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

fn linkFfeDeps(
    b: *std.Build,
    mod: *std.Build.Module,
    shim_lib: *std.Build.Step.Compile,
    libpaths: []const []const u8,
    syslibs: []const []const u8,
    frameworks: []const []const u8,
) void {
    mod.linkLibrary(shim_lib);
    mod.link_libcpp = true;
    for (libpaths) |p| mod.addLibraryPath(b.graph.cwdRelativePath(p));
    for (syslibs) |l| mod.linkSystemLibrary(l, .{});
    for (frameworks) |f| mod.linkFramework(f, .{});
}
