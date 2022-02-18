const std = @import("std");
const assert = std.debug.assert;
const builtin = std.builtin;
const tests = @import("test/tests.zig");
const mem = std.mem;
const io = std.io;
const fs = std.fs;

const InstallDirectoryOptions = std.build.InstallDirectoryOptions;
const LibExeObjStep = std.build.LibExeObjStep;
const CrossTarget = std.zig.CrossTarget;
const Builder = std.build.Builder;
const ArrayList = std.ArrayList;
const BufMap = std.BufMap;
const Step = std.build.Step;
const Pkg = std.build.Pkg;

pub const zig_version = std.builtin.Version{ .major = 0, .minor = 10, .patch = 0 };

pub const ZigBuildOptions = struct {
    // zig fmt: off
    version_string: ?[]const u8 = null,   // Override Zig version string. Default is to find out with git.

    // Enable/disable build components
    skip_non_native: bool = false,        // Skip non-native components during build
    is_stage1: bool = false,              // Build the stage 1 compiler, put stage2 behind a feature flag
    omit_stage2: bool = false,            // Do not include stage2 behind a feature flag inside stage1
    enable_logging: ?bool = false,        // Whether to enable logging
    enable_link_snapshots: bool = false,  // Whether to enable linker state snapshots

    // Use system-installed libraries, or not
    use_zig_libcxx: bool = false,         // If libc++ is needed, use zig's bundled version, don't try to integrate with the system
    link_libc: bool = false,              // Force self-hosted compiler to link libc (will be linked anyway if LLVM is enabled)
    link_libcxx: bool = false,            // Force self-hosted compiler to link libc++ (will be linked anyway if LLVM is enabled)
    static_llvm: bool = false,            // Disable integration with system-installed LLVM, Clang, LLD, and lib++
    config_h_path_option: ?[]const u8 = null, // Path to the generated config.h

    // LLVM-related flags
    enable_llvm: bool = false,            // Build self-hosted compiler with LLVM backend enabled
    llvm_has_m68k: bool = false,          // Whether LLVM has the experimental target m68k enabled
    llvm_has_csky: bool = false,          // Whether LLVM has the experimental target csky enabled
    llvm_has_ve: bool = false,            // Whether LLVM has the experimental target ve enabled
    llvm_has_arc: bool = false,           // Whether LLVM has the experimental target arc enabled

    // Debug, traceback, and performance tracing
    tracy: ?[]const u8 = null,            // Enable Tracy integration. Supply path to Tracy source
    tracy_callstack: bool = false,        // Include callstack information with Tracy Data. Does nothing if -Dtracy is not provided
    tracy_allocation: bool = false,       // Include allocation information with Tracy Data. Does nothing if -Dtracy is not provided
    mem_leak_frames: ?u32 = null,         // How many stack frames to print when a memory leak occurs. Texts get 2x this amount
    force_gpa: bool = false,              // Force the compiler to use GeneralPurposeAllocator
    // zig fmt: on
};

pub const ZigTestOptions = struct {
    // zig fmt: off
    test_filter: ?[]const u8 = null,      // Skip tests that do not match filter
    modes: []const builtin.Mode = &[_]builtin.Mode{.Debug}, // Only execute tests matching these modes

    skip_non_native: bool = false,        // Main test suite skips non-native builds
    skip_stage2_tests: bool = false,      // Main test suite skips self-hosted compiler tests
    skip_compile_errors: bool = false,    // Main test suite skips compile error tests
    skip_run_translated_c: bool = false,  // Main test suite skips run-translated-c tests
    skip_libc: bool = false,              // Main test suite skips tests that link libc

    enable_macos_sdk: bool = false,       // Run tests requiring presence of macOS SDK and frameworks
    // zig fmt: on
};

pub fn git_version_string(b: *Builder) ?[]const u8 {
    const version_string = b.fmt("{d}.{d}.{d}", .{ zig_version.major, zig_version.minor, zig_version.patch });

    var code: u8 = undefined;
    const git_describe_untrimmed = b.execAllowFail(&[_][]const u8{
        "git", "-C", b.build_root, "describe", "--match", "*.*.*", "--tags",
    }, &code, .Ignore) catch {
        return null;
    };
    const git_describe = mem.trim(u8, git_describe_untrimmed, " \n\r");

    switch (mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.9.0).
            if (!mem.eql(u8, git_describe, version_string)) {
                std.debug.print("Zig version '{s}' does not match Git tag '{s}'\n", .{ version_string, git_describe });
                return null;
            }
            return version_string;
        },
        2 => {
            // Untagged development build (e.g. 0.9.0-dev.2025+ecf0050a9).
            var it = mem.split(u8, git_describe, "-");
            const tagged_ancestor = it.next() orelse unreachable;
            const commit_height = it.next() orelse unreachable;
            const commit_id = it.next() orelse unreachable;

            const ancestor_ver = std.builtin.Version.parse(tagged_ancestor) catch return null;
            if (zig_version.order(ancestor_ver) != .gt) {
                std.debug.print("Zig version '{}' must be greater than tagged ancestor '{}'\n", .{ zig_version, ancestor_ver });
                return null;
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                return null;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            return version_string;
        },
    }
}

pub fn addSoftFloatLib(b: *Builder, obj: *LibExeObjStep) !void {
    const CacheLib = struct {
        var softfloat: ?*LibExeObjStep = null;
    };
    if (CacheLib.softfloat == null) {
        const softfloat = b.addStaticLibrary("softfloat", null);
        softfloat.setBuildMode(.ReleaseFast);
        softfloat.setTarget(obj.target);
        softfloat.addIncludeDir("deps/SoftFloat-3e-prebuilt");
        softfloat.addIncludeDir("deps/SoftFloat-3e/source/8086");
        softfloat.addIncludeDir("deps/SoftFloat-3e/source/include");
        softfloat.addCSourceFiles(&softfloat_sources, &[_][]const u8{ "-std=c99", "-O3" });
        softfloat.single_threaded = obj.single_threaded;
        CacheLib.softfloat = softfloat;
    }
    obj.linkLibrary(CacheLib.softfloat.?);
}

pub fn installLibFiles(b: *Builder) !void {
    b.installDirectory(InstallDirectoryOptions{
        .source_dir = "lib",
        .install_dir = .lib,
        .install_subdir = "zig",
        .exclude_extensions = &[_][]const u8{
            "README.md",
            ".z.0",
            ".z.9",
            ".gz",
            "rfc1951.txt",
            ".tzif",
        },
        .blank_extensions = &[_][]const u8{
            "test.zig",
        },
    });
}

fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const root_path = root() ++ "/";
const package_path = root_path ++ "src/lib.zig";

pub fn link(b: *Builder, obj: *LibExeObjStep, cfg: *ZigBuildOptions, test_cfg: ?*ZigTestOptions) !Pkg {
    var pkg = Pkg{ 
        .name = "zig", 
        .path = .{ .path = package_path }, 
    };

    // Step 1: Normalize configs
    if (cfg.is_stage1 or cfg.static_llvm) {
        cfg.enable_llvm = true;
    }
    if (cfg.enable_llvm or (cfg.tracy != null)) {
        cfg.link_libc = true;
        cfg.link_libcxx = true;
    }
    if (cfg.mem_leak_frames == null) {
        cfg.mem_leak_frames = blk: {
            if (obj.strip) break :blk @as(u32, 0);
            if (obj.build_mode != .Debug) break :blk 0;
            break :blk 4;
        };
    }
    if (cfg.enable_logging == null) {
        cfg.enable_logging = (obj.build_mode == .Debug);
    }

    // Step 2: Add build_options
    const options = b.addOptions();
    pkg.dependencies = &[_]Pkg{options.getPackage("build_options")};

    const version = if (cfg.version_string) |version| version else blk: {
        if (git_version_string(b)) |v| {
            break :blk v;
        } else {
            std.debug.print("error: version info cannot be retrieved from git. Zig version must be provided using -Dversion-string\n", .{});
            std.process.exit(1);
        }
    };
    const semver = try std.SemanticVersion.parse(version);

    options.addOption(u32, "mem_leak_frames", cfg.mem_leak_frames.?);
    options.addOption(bool, "skip_non_native", cfg.skip_non_native);
    options.addOption(bool, "have_llvm", cfg.enable_llvm);
    options.addOption(bool, "llvm_has_m68k", cfg.llvm_has_m68k);
    options.addOption(bool, "llvm_has_csky", cfg.llvm_has_csky);
    options.addOption(bool, "llvm_has_ve", cfg.llvm_has_ve);
    options.addOption(bool, "llvm_has_arc", cfg.llvm_has_arc);
    options.addOption(bool, "force_gpa", cfg.force_gpa);

    options.addOption([:0]const u8, "version", try b.allocator.dupeZ(u8, version));
    options.addOption(std.SemanticVersion, "semver", semver);
    options.addOption(bool, "enable_logging", cfg.enable_logging.?);
    options.addOption(bool, "enable_link_snapshots", cfg.enable_link_snapshots);
    options.addOption(bool, "enable_tracy", cfg.tracy != null);
    options.addOption(bool, "enable_tracy_callstack", cfg.tracy_callstack);
    options.addOption(bool, "enable_tracy_allocation", cfg.tracy_allocation);
    options.addOption(bool, "is_stage1", cfg.is_stage1);
    options.addOption(bool, "omit_stage2", cfg.omit_stage2);

    if (test_cfg) |c| {
        options.addOption(bool, "skip_compile_errors", c.skip_compile_errors);
        options.addOption(bool, "enable_qemu", b.enable_qemu);
        options.addOption(bool, "enable_wine", b.enable_wine);
        options.addOption(bool, "enable_wasmtime", b.enable_wasmtime);
        options.addOption(bool, "enable_rosetta", b.enable_rosetta);
        options.addOption(bool, "enable_darling", b.enable_darling);
        options.addOption(?[]const u8, "glibc_runtimes_dir", b.glibc_runtimes_dir);
    }

    // Step 3: Add C/C++ sources and libraries
    if (cfg.is_stage1) { // Stage 1 C/C++
        obj.addIncludeDir("src");
        obj.addIncludeDir("deps/SoftFloat-3e/source/include");
        obj.defineCMacro("ZIG_LINK_MODE", "Static");
        try addSoftFloatLib(b, obj);
        obj.addCSourceFiles(&stage1_sources, &exe_cflags);
        obj.addCSourceFiles(&optimized_c_sources, &[_][]const u8{ "-std=c99", "-O3" });
    }

    if (cfg.enable_llvm) { // LLVM
        const maybe_cmake_cfg = if (cfg.static_llvm) null else findAndParseConfigH(b, cfg.config_h_path_option);
        if (maybe_cmake_cfg) |cmake_cfg| {
            // Inside this code path, we have to coordinate with system packaged LLVM, Clang, and LLD.
            // That means we also have to rely on stage1 compiled c++ files. We parse config.h to find
            // the information passed on to us from cmake.
            if (cmake_cfg.cmake_prefix_path.len > 0) {
                b.addSearchPrefix(cmake_cfg.cmake_prefix_path);
            }

            // This attempts to link with whatever libcxx is used
            // by the system c++ compiler
            try addCmakeCfgOptionsToExe(b, cmake_cfg, obj, cfg.use_zig_libcxx);
        } else {
            // Here we are -Denable-llvm but no cmake integration.
            try addStaticLlvmOptionsToExe(obj);
        }
    }

    if (cfg.tracy) |tracy_path| { // Tracy
        const client_cpp = try fs.path.join(
            b.allocator,
            &[_][]const u8{ tracy_path, "TracyClient.cpp" },
        );

        // On mingw, we need to opt into windows 7+ to get some features required by tracy.
        const tracy_c_flags: []const []const u8 = if (obj.target.isWindows() and obj.target.getAbi() == .gnu)
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
        else
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        obj.addIncludeDir(tracy_path);
        obj.addCSourceFile(client_cpp, tracy_c_flags);

        if (obj.target.isWindows()) {
            obj.linkSystemLibrary("dbghelp");
            obj.linkSystemLibrary("ws2_32");
        }
    }

    // Step 4: Link libc and libc++, if necessary
    if (cfg.link_libc) {
        obj.linkLibC();
    }
    if (cfg.link_libcxx and !cfg.enable_llvm) {
        // TODO: Clean up the cxx mess (maybe remove the flag entirely)
        // (Zig-compiled c++ requires -lc++, but linking pre-existing modules may want system libc++)
        obj.linkLibCpp();
    }

    return pkg;
}

pub fn process_docs(b: *Builder, obj: *LibExeObjStep) !*Step {
    const rel_zig_exe = try fs.path.relative(b.allocator, b.build_root, b.zig_exe);
    const langref_out_path = fs.path.join(
        b.allocator,
        &[_][]const u8{ b.cache_root, "langref.html" },
    ) catch unreachable;
    const docgen_cmd = obj.run();
    docgen_cmd.addArgs(&[_][]const u8{
        rel_zig_exe,
        "doc" ++ fs.path.sep_str ++ "langref.html.in",
        langref_out_path,
    });
    docgen_cmd.step.dependOn(&obj.step);

    const docs_step = b.step("docs", "Build documentation");
    docs_step.dependOn(&docgen_cmd.step);

    return docs_step;
}

pub fn get_test_modes(b: *Builder) ![]const builtin.Mode {
    const skip_debug = b.option(bool, "skip-debug", "Main test suite skips debug builds") orelse false;
    const skip_release = b.option(bool, "skip-release", "Main test suite skips release builds") orelse false;
    const skip_release_small = b.option(bool, "skip-release-small", "Main test suite skips release-small builds") orelse skip_release;
    const skip_release_fast = b.option(bool, "skip-release-fast", "Main test suite skips release-fast builds") orelse skip_release;
    const skip_release_safe = b.option(bool, "skip-release-safe", "Main test suite skips release-safe builds") orelse skip_release;

    // Tests
    var chosen_modes: [4]builtin.Mode = undefined;
    var chosen_mode_index: usize = 0;
    if (!skip_debug) {
        chosen_modes[chosen_mode_index] = builtin.Mode.Debug;
        chosen_mode_index += 1;
    }
    if (!skip_release_safe) {
        chosen_modes[chosen_mode_index] = builtin.Mode.ReleaseSafe;
        chosen_mode_index += 1;
    }
    if (!skip_release_fast) {
        chosen_modes[chosen_mode_index] = builtin.Mode.ReleaseFast;
        chosen_mode_index += 1;
    }
    if (!skip_release_small) {
        chosen_modes[chosen_mode_index] = builtin.Mode.ReleaseSmall;
        chosen_mode_index += 1;
    }
    return chosen_modes[0..chosen_mode_index];
}

pub fn build(b: *Builder) !void {
    b.setPreferredReleaseMode(.ReleaseFast);
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    // Top-level build options (for executable)
    const single_threaded = b.option(bool, "single-threaded", "Build artifacts that run in single threaded mode");
    const strip = b.option(bool, "strip", "Omit debug information") orelse false;

    var cfg = ZigBuildOptions{
        .version_string = b.option([]const u8, "version-string", "Override Zig version string. Default is to find out with git."),

        .skip_non_native = b.option(bool, "skip-non-native", "Skip non-native components during build") orelse false,
        .is_stage1 = b.option(bool, "stage1", "Build the stage1 compiler, put stage2 behind a feature flag") orelse false,
        .omit_stage2 = b.option(bool, "omit-stage2", "Do not include stage2 behind a feature flag inside stage1") orelse false,
        .enable_llvm = b.option(bool, "enable-llvm", "Build self-hosted compiler with LLVM backend enabled") orelse false,
        .enable_logging = b.option(bool, "log", "Enable debug logging with --debug-log"),
        .enable_link_snapshots = b.option(bool, "link-snapshot", "Whether to enable linker state snapshots") orelse false,

        .llvm_has_m68k = b.option(bool, "llvm-has-m68k", "Whether LLVM has the experimental target m68k enabled") orelse false,
        .llvm_has_csky = b.option(bool, "llvm-has-csky", "Whether LLVM has the experimental target csky enabled") orelse false,
        .llvm_has_ve = b.option(bool, "llvm-has-ve", "Whether LLVM has the experimental target ve enabled") orelse false,
        .llvm_has_arc = b.option(bool, "llvm-has-arc", "Whether LLVM has the experimental target arc enabled") orelse false,

        .use_zig_libcxx = b.option(bool, "use-zig-libcxx", "If libc++ is needed, use zig's bundled version, don't try to integrate with the system") orelse false,
        .link_libc = b.option(bool, "force-link-libc", "Force self-hosted compiler to link libc") orelse false,
        .link_libcxx = b.option(bool, "force-link-libcxx", "Force self-hosted compiler to link libc++") orelse false,
        .static_llvm = b.option(bool, "static-llvm", "Disable integration with system-installed LLVM, Clang, LLD, and libc++") orelse false,
        .config_h_path_option = b.option([]const u8, "config_h", "Path to the generated config.h"),

        .tracy = b.option([]const u8, "tracy", "Enable Tracy integration. Supply path to Tracy source"),
        .tracy_callstack = b.option(bool, "tracy-callstack", "Include callstack information with Tracy data. Does nothing if -Dtracy is not provided") orelse false,
        .tracy_allocation = b.option(bool, "tracy-allocation", "Include allocation information with Tracy data. Does nothing if -Dtracy is not provided") orelse false,
        .mem_leak_frames = b.option(u32, "mem-leak-frames", "How many stack frames to print when a memory leak occurs. Tests get 2x this amount."),
        .force_gpa = b.option(bool, "force-gpa", "Force the compiler to use GeneralPurposeAllocator") orelse false,
    };

    var test_cfg = ZigTestOptions{
        .test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter"),

        .skip_non_native = b.option(bool, "test-skip-non-native", "Main test suite skips non-native builds") orelse false,
        .skip_stage2_tests = b.option(bool, "test-skip-stage2", "Main test suite skips self-hosted compiler tests") orelse false,
        .skip_compile_errors = b.option(bool, "test-skip-compile-errors", "Main test suite skips compile error tests") orelse false,
        .skip_run_translated_c = b.option(bool, "test-skip-run-translated-c", "Main test suite skips run-translated-c tests") orelse false,
        .skip_libc = b.option(bool, "test-skip-libc", "Main test suite skips tests that link libc") orelse false,

        .enable_macos_sdk = b.option(bool, "test-enable-macos-sdk", "Run tests requiring presence of macOS SDK and frameworks") orelse false,
    };

    // Lib files
    const skip_install_lib_files = b.option(bool, "skip-install-lib-files", "Do not copy lib/ files to installation prefix") orelse false;
    const only_install_lib_files = b.option(bool, "lib-files-only", "Only install library files") orelse false;

    if (!skip_install_lib_files) {
        try installLibFiles(b);
    }
    if (only_install_lib_files)
        return;

    // Actual exe
    const main_file = if (cfg.is_stage1) "src/stage1.zig" else "src/main.zig";
    var exe = b.addExecutable("zig", main_file);
    exe.strip = strip;
    exe.install();
    exe.setBuildMode(mode);
    exe.setTarget(target);
    b.default_step.dependOn(&exe.step);
    exe.single_threaded = single_threaded;

    // Test exe
    var test_stage2 = b.addTest("src/test.zig");
    test_stage2.setBuildMode(mode);
    test_stage2.addPackagePath("test_cases", "test/cases.zig");
    test_stage2.single_threaded = single_threaded;
    const test_stage2_step = b.step("test-stage2", "Run the stage2 compiler tests");
    test_stage2_step.dependOn(&test_stage2.step);

    if (target.isWindows() and target.getAbi() == .gnu) {
        // LTO is currently broken on mingw, this can be removed when it's fixed.
        exe.want_lto = false;
        test_stage2.want_lto = false;
    }

    // This is intentionally a dummy path. stage1.zig tries to @import("compiler_rt") in case
    // of being built by cmake. But when built by zig it's gonna get a compiler_rt so that
    // is pointless.
    if (cfg.enable_llvm and cfg.is_stage1) {
        exe.addPackagePath("compiler_rt", "src/empty.zig");
    }

    // Link in Zig dependencies
    const pkg_exe = try link(b, exe, &cfg, null);
    exe.addPackage(pkg_exe.dependencies.?[0]); // We ignore the package, since we are already its root
    const pkg_test_stage2 = try link(b, test_stage2, &cfg, &test_cfg);
    test_stage2.addPackage(pkg_test_stage2.dependencies.?[0]);

    // Generate Docs
    const docgen_exe = b.addExecutable("docgen", "doc/docgen.zig");
    docgen_exe.single_threaded = exe.single_threaded;
    const docs_step = try process_docs(b, docgen_exe);

    // run stage1 `zig fmt` on this build.zig file just to make sure it works
    const fmt_build_zig = b.addFmt(&[_][]const u8{"build.zig"});
    const fmt_step = b.step("test-fmt", "Run zig fmt against build.zig to make sure it works");
    fmt_step.dependOn(&fmt_build_zig.step);

    // Create "toolchain" for main binary + all non-stdlib tests
    const toolchain_step = b.step("test-toolchain", "Run the tests for the toolchain");
    toolchain_step.dependOn(&fmt_build_zig.step);
    if (!test_cfg.skip_stage2_tests) {
        toolchain_step.dependOn(&exe.step);
        toolchain_step.dependOn(test_stage2_step);
    }

    // Main standalone test sequence
    test_cfg.modes = try get_test_modes(b);
    try addTests(b, toolchain_step, test_cfg, exe.target);

    // stdlib tests
    const std_step = tests.addPkgTests(
        b,
        test_cfg.test_filter,
        "lib/std/std.zig",
        "std",
        "Run the standard library tests",
        test_cfg.modes,
        false,
        test_cfg.skip_non_native,
        test_cfg.skip_libc,
    );

    // Full sequence: Docs + Zig tests + stdlib tests
    const test_step = b.step("test", "Run all the tests");
    test_step.dependOn(toolchain_step);
    test_step.dependOn(std_step);
    test_step.dependOn(docs_step);
}

pub fn addTests(b: *Builder, step: *Step, cfg: ZigTestOptions, target: CrossTarget) !void {
    step.dependOn(tests.addPkgTests(
        b,
        cfg.test_filter,
        "test/behavior.zig",
        "behavior",
        "Run the behavior tests",
        cfg.modes,
        false, // skip_single_threaded
        cfg.skip_non_native,
        cfg.skip_libc,
    ));

    step.dependOn(tests.addPkgTests(
        b,
        cfg.test_filter,
        "lib/std/special/compiler_rt.zig",
        "compiler-rt",
        "Run the compiler_rt tests",
        cfg.modes,
        true, // skip_single_threaded
        cfg.skip_non_native,
        true, // skip_libc
    ));

    step.dependOn(tests.addPkgTests(
        b,
        cfg.test_filter,
        "lib/std/special/c.zig",
        "minilibc",
        "Run the mini libc tests",
        cfg.modes,
        true, // skip_single_threaded
        cfg.skip_non_native,
        true, // skip_libc
    ));

    step.dependOn(tests.addCompareOutputTests(b, cfg.test_filter, cfg.modes));
    step.dependOn(tests.addStandaloneTests(b, cfg.test_filter, cfg.modes, cfg.skip_non_native, cfg.enable_macos_sdk, target));
    step.dependOn(tests.addStackTraceTests(b, cfg.test_filter, cfg.modes));
    step.dependOn(tests.addCliTests(b, cfg.test_filter, cfg.modes));
    step.dependOn(tests.addAssembleAndLinkTests(b, cfg.test_filter, cfg.modes));
    step.dependOn(tests.addRuntimeSafetyTests(b, cfg.test_filter, cfg.modes));
    step.dependOn(tests.addTranslateCTests(b, cfg.test_filter));
    if (!cfg.skip_run_translated_c) {
        step.dependOn(tests.addRunTranslatedCTests(b, cfg.test_filter, target));
    }
    // tests for this feature are disabled until we have the self-hosted compiler available
    // step.dependOn(tests.addGenHTests(b, cfg.test_filter));
}

const exe_cflags = [_][]const u8{
    "-std=c++14",
    "-D__STDC_CONSTANT_MACROS",
    "-D__STDC_FORMAT_MACROS",
    "-D__STDC_LIMIT_MACROS",
    "-D_GNU_SOURCE",
    "-fvisibility-inlines-hidden",
    "-fno-exceptions",
    "-fno-rtti",
    "-Werror=type-limits",
    "-Wno-missing-braces",
    "-Wno-comment",
};

fn addCmakeCfgOptionsToExe(
    b: *Builder,
    cfg: CMakeConfig,
    exe: *std.build.LibExeObjStep,
    use_zig_libcxx: bool,
) !void {
    exe.addObjectFile(fs.path.join(b.allocator, &[_][]const u8{
        cfg.cmake_binary_dir,
        "zigcpp",
        b.fmt("{s}{s}{s}", .{ exe.target.libPrefix(), "zigcpp", exe.target.staticLibSuffix() }),
    }) catch unreachable);
    assert(cfg.lld_include_dir.len != 0);
    exe.addIncludeDir(cfg.lld_include_dir);
    addCMakeLibraryList(exe, cfg.clang_libraries);
    addCMakeLibraryList(exe, cfg.lld_libraries);
    addCMakeLibraryList(exe, cfg.llvm_libraries);

    if (use_zig_libcxx) {
        exe.linkLibCpp();
    } else {
        const need_cpp_includes = true;

        // System -lc++ must be used because in this code path we are attempting to link
        // against system-provided LLVM, Clang, LLD.
        if (exe.target.getOsTag() == .linux) {
            // First we try to static link against gcc libstdc++. If that doesn't work,
            // we fall back to -lc++ and cross our fingers.
            addCxxKnownPath(b, cfg, exe, "libstdc++.a", "", need_cpp_includes) catch |err| switch (err) {
                error.RequiredLibraryNotFound => {
                    exe.linkSystemLibrary("c++");
                },
                else => |e| return e,
            };
            exe.linkSystemLibrary("unwind");
        } else if (exe.target.isFreeBSD()) {
            try addCxxKnownPath(b, cfg, exe, "libc++.a", null, need_cpp_includes);
            exe.linkSystemLibrary("pthread");
        } else if (exe.target.getOsTag() == .openbsd) {
            try addCxxKnownPath(b, cfg, exe, "libc++.a", null, need_cpp_includes);
            try addCxxKnownPath(b, cfg, exe, "libc++abi.a", null, need_cpp_includes);
        } else if (exe.target.isDarwin()) {
            exe.linkSystemLibrary("c++");
        }
    }

    if (cfg.dia_guids_lib.len != 0) {
        exe.addObjectFile(cfg.dia_guids_lib);
    }
}

fn addStaticLlvmOptionsToExe(
    exe: *std.build.LibExeObjStep,
) !void {
    // Adds the Zig C++ sources which both stage1 and stage2 need.
    //
    // We need this because otherwise zig_clang_cc1_main.cpp ends up pulling
    // in a dependency on llvm::cfg::Update<llvm::BasicBlock*>::dump() which is
    // unavailable when LLVM is compiled in Release mode.
    const zig_cpp_cflags = exe_cflags ++ [_][]const u8{"-DNDEBUG=1"};
    exe.addCSourceFiles(&zig_cpp_sources, &zig_cpp_cflags);

    for (clang_libs) |lib_name| {
        exe.linkSystemLibrary(lib_name);
    }

    for (lld_libs) |lib_name| {
        exe.linkSystemLibrary(lib_name);
    }

    for (llvm_libs) |lib_name| {
        exe.linkSystemLibrary(lib_name);
    }

    exe.linkSystemLibrary("z");

    // This means we rely on clang-or-zig-built LLVM, Clang, LLD libraries.
    exe.linkSystemLibrary("c++");

    if (exe.target.getOs().tag == .windows) {
        exe.linkSystemLibrary("version");
        exe.linkSystemLibrary("uuid");
        exe.linkSystemLibrary("ole32");
    }
}

fn addCxxKnownPath(
    b: *Builder,
    ctx: CMakeConfig,
    exe: *std.build.LibExeObjStep,
    objname: []const u8,
    errtxt: ?[]const u8,
    need_cpp_includes: bool,
) !void {
    if (!std.process.can_spawn)
        return error.RequiredLibraryNotFound;

    const path_padded = try b.exec(&[_][]const u8{
        ctx.cxx_compiler,
        b.fmt("-print-file-name={s}", .{objname}),
    });
    const path_unpadded = mem.tokenize(u8, path_padded, "\r\n").next().?;
    if (mem.eql(u8, path_unpadded, objname)) {
        if (errtxt) |msg| {
            std.debug.print("{s}", .{msg});
        } else {
            std.debug.print("Unable to determine path to {s}\n", .{objname});
        }
        return error.RequiredLibraryNotFound;
    }
    exe.addObjectFile(path_unpadded);

    // TODO a way to integrate with system c++ include files here
    // cc -E -Wp,-v -xc++ /dev/null
    if (need_cpp_includes) {
        // I used these temporarily for testing something but we obviously need a
        // more general purpose solution here.
        //exe.addIncludeDir("/nix/store/fvf3qjqa5qpcjjkq37pb6ypnk1mzhf5h-gcc-9.3.0/lib/gcc/x86_64-unknown-linux-gnu/9.3.0/../../../../include/c++/9.3.0");
        //exe.addIncludeDir("/nix/store/fvf3qjqa5qpcjjkq37pb6ypnk1mzhf5h-gcc-9.3.0/lib/gcc/x86_64-unknown-linux-gnu/9.3.0/../../../../include/c++/9.3.0/x86_64-unknown-linux-gnu");
        //exe.addIncludeDir("/nix/store/fvf3qjqa5qpcjjkq37pb6ypnk1mzhf5h-gcc-9.3.0/lib/gcc/x86_64-unknown-linux-gnu/9.3.0/../../../../include/c++/9.3.0/backward");
    }
}

fn addCMakeLibraryList(exe: *std.build.LibExeObjStep, list: []const u8) void {
    var it = mem.tokenize(u8, list, ";");
    while (it.next()) |lib| {
        if (mem.startsWith(u8, lib, "-l")) {
            exe.linkSystemLibrary(lib["-l".len..]);
        } else {
            exe.addObjectFile(lib);
        }
    }
}

const CMakeConfig = struct {
    cmake_binary_dir: []const u8,
    cmake_prefix_path: []const u8,
    cxx_compiler: []const u8,
    lld_include_dir: []const u8,
    lld_libraries: []const u8,
    clang_libraries: []const u8,
    llvm_libraries: []const u8,
    dia_guids_lib: []const u8,
};

const max_config_h_bytes = 1 * 1024 * 1024;

fn findAndParseConfigH(b: *Builder, config_h_path_option: ?[]const u8) ?CMakeConfig {
    const config_h_text: []const u8 = if (config_h_path_option) |config_h_path| blk: {
        break :blk fs.cwd().readFileAlloc(b.allocator, config_h_path, max_config_h_bytes) catch unreachable;
    } else blk: {
        // TODO this should stop looking for config.h once it detects we hit the
        // zig source root directory.
        var check_dir = fs.path.dirname(b.zig_exe).?;
        while (true) {
            var dir = fs.cwd().openDir(check_dir, .{}) catch unreachable;
            defer dir.close();

            break :blk dir.readFileAlloc(b.allocator, "config.h", max_config_h_bytes) catch |err| switch (err) {
                error.FileNotFound => {
                    const new_check_dir = fs.path.dirname(check_dir);
                    if (new_check_dir == null or mem.eql(u8, new_check_dir.?, check_dir)) {
                        return null;
                    }
                    check_dir = new_check_dir.?;
                    continue;
                },
                else => unreachable,
            };
        } else unreachable; // TODO should not need `else unreachable`.
    };

    var ctx: CMakeConfig = .{
        .cmake_binary_dir = undefined,
        .cmake_prefix_path = undefined,
        .cxx_compiler = undefined,
        .lld_include_dir = undefined,
        .lld_libraries = undefined,
        .clang_libraries = undefined,
        .llvm_libraries = undefined,
        .dia_guids_lib = undefined,
    };

    const mappings = [_]struct { prefix: []const u8, field: []const u8 }{
        .{
            .prefix = "#define ZIG_CMAKE_BINARY_DIR ",
            .field = "cmake_binary_dir",
        },
        .{
            .prefix = "#define ZIG_CMAKE_PREFIX_PATH ",
            .field = "cmake_prefix_path",
        },
        .{
            .prefix = "#define ZIG_CXX_COMPILER ",
            .field = "cxx_compiler",
        },
        .{
            .prefix = "#define ZIG_LLD_INCLUDE_PATH ",
            .field = "lld_include_dir",
        },
        .{
            .prefix = "#define ZIG_LLD_LIBRARIES ",
            .field = "lld_libraries",
        },
        .{
            .prefix = "#define ZIG_CLANG_LIBRARIES ",
            .field = "clang_libraries",
        },
        .{
            .prefix = "#define ZIG_LLVM_LIBRARIES ",
            .field = "llvm_libraries",
        },
        .{
            .prefix = "#define ZIG_DIA_GUIDS_LIB ",
            .field = "dia_guids_lib",
        },
    };

    var lines_it = mem.tokenize(u8, config_h_text, "\r\n");
    while (lines_it.next()) |line| {
        inline for (mappings) |mapping| {
            if (mem.startsWith(u8, line, mapping.prefix)) {
                var it = mem.split(u8, line, "\"");
                _ = it.next().?; // skip the stuff before the quote
                const quoted = it.next().?; // the stuff inside the quote
                @field(ctx, mapping.field) = toNativePathSep(b, quoted);
            }
        }
    }
    return ctx;
}

fn toNativePathSep(b: *Builder, s: []const u8) []u8 {
    const duplicated = b.allocator.dupe(u8, s) catch unreachable;
    for (duplicated) |*byte| switch (byte.*) {
        '/' => byte.* = fs.path.sep,
        else => {},
    };
    return duplicated;
}

const softfloat_sources = [_][]const u8{
    "deps/SoftFloat-3e/source/8086/f128M_isSignalingNaN.c",
    "deps/SoftFloat-3e/source/8086/extF80M_isSignalingNaN.c",
    "deps/SoftFloat-3e/source/8086/s_commonNaNToF128M.c",
    "deps/SoftFloat-3e/source/8086/s_commonNaNToExtF80M.c",
    "deps/SoftFloat-3e/source/8086/s_commonNaNToF16UI.c",
    "deps/SoftFloat-3e/source/8086/s_commonNaNToF32UI.c",
    "deps/SoftFloat-3e/source/8086/s_commonNaNToF64UI.c",
    "deps/SoftFloat-3e/source/8086/s_f128MToCommonNaN.c",
    "deps/SoftFloat-3e/source/8086/s_extF80MToCommonNaN.c",
    "deps/SoftFloat-3e/source/8086/s_f16UIToCommonNaN.c",
    "deps/SoftFloat-3e/source/8086/s_f32UIToCommonNaN.c",
    "deps/SoftFloat-3e/source/8086/s_f64UIToCommonNaN.c",
    "deps/SoftFloat-3e/source/8086/s_propagateNaNF128M.c",
    "deps/SoftFloat-3e/source/8086/s_propagateNaNExtF80M.c",
    "deps/SoftFloat-3e/source/8086/s_propagateNaNF16UI.c",
    "deps/SoftFloat-3e/source/8086/softfloat_raiseFlags.c",
    "deps/SoftFloat-3e/source/f128M_add.c",
    "deps/SoftFloat-3e/source/f128M_div.c",
    "deps/SoftFloat-3e/source/f128M_eq.c",
    "deps/SoftFloat-3e/source/f128M_eq_signaling.c",
    "deps/SoftFloat-3e/source/f128M_le.c",
    "deps/SoftFloat-3e/source/f128M_le_quiet.c",
    "deps/SoftFloat-3e/source/f128M_lt.c",
    "deps/SoftFloat-3e/source/f128M_lt_quiet.c",
    "deps/SoftFloat-3e/source/f128M_mul.c",
    "deps/SoftFloat-3e/source/f128M_mulAdd.c",
    "deps/SoftFloat-3e/source/f128M_rem.c",
    "deps/SoftFloat-3e/source/f128M_roundToInt.c",
    "deps/SoftFloat-3e/source/f128M_sqrt.c",
    "deps/SoftFloat-3e/source/f128M_sub.c",
    "deps/SoftFloat-3e/source/f128M_to_f16.c",
    "deps/SoftFloat-3e/source/f128M_to_f32.c",
    "deps/SoftFloat-3e/source/f128M_to_f64.c",
    "deps/SoftFloat-3e/source/f128M_to_extF80M.c",
    "deps/SoftFloat-3e/source/f128M_to_i32.c",
    "deps/SoftFloat-3e/source/f128M_to_i32_r_minMag.c",
    "deps/SoftFloat-3e/source/f128M_to_i64.c",
    "deps/SoftFloat-3e/source/f128M_to_i64_r_minMag.c",
    "deps/SoftFloat-3e/source/f128M_to_ui32.c",
    "deps/SoftFloat-3e/source/f128M_to_ui32_r_minMag.c",
    "deps/SoftFloat-3e/source/f128M_to_ui64.c",
    "deps/SoftFloat-3e/source/f128M_to_ui64_r_minMag.c",
    "deps/SoftFloat-3e/source/extF80M_add.c",
    "deps/SoftFloat-3e/source/extF80M_div.c",
    "deps/SoftFloat-3e/source/extF80M_eq.c",
    "deps/SoftFloat-3e/source/extF80M_le.c",
    "deps/SoftFloat-3e/source/extF80M_lt.c",
    "deps/SoftFloat-3e/source/extF80M_mul.c",
    "deps/SoftFloat-3e/source/extF80M_rem.c",
    "deps/SoftFloat-3e/source/extF80M_roundToInt.c",
    "deps/SoftFloat-3e/source/extF80M_sqrt.c",
    "deps/SoftFloat-3e/source/extF80M_sub.c",
    "deps/SoftFloat-3e/source/extF80M_to_f16.c",
    "deps/SoftFloat-3e/source/extF80M_to_f32.c",
    "deps/SoftFloat-3e/source/extF80M_to_f64.c",
    "deps/SoftFloat-3e/source/extF80M_to_f128M.c",
    "deps/SoftFloat-3e/source/f16_add.c",
    "deps/SoftFloat-3e/source/f16_div.c",
    "deps/SoftFloat-3e/source/f16_eq.c",
    "deps/SoftFloat-3e/source/f16_isSignalingNaN.c",
    "deps/SoftFloat-3e/source/f16_lt.c",
    "deps/SoftFloat-3e/source/f16_mul.c",
    "deps/SoftFloat-3e/source/f16_mulAdd.c",
    "deps/SoftFloat-3e/source/f16_rem.c",
    "deps/SoftFloat-3e/source/f16_roundToInt.c",
    "deps/SoftFloat-3e/source/f16_sqrt.c",
    "deps/SoftFloat-3e/source/f16_sub.c",
    "deps/SoftFloat-3e/source/f16_to_extF80M.c",
    "deps/SoftFloat-3e/source/f16_to_f128M.c",
    "deps/SoftFloat-3e/source/f16_to_f64.c",
    "deps/SoftFloat-3e/source/f32_to_f128M.c",
    "deps/SoftFloat-3e/source/f32_to_extF80M.c",
    "deps/SoftFloat-3e/source/f64_to_f128M.c",
    "deps/SoftFloat-3e/source/f64_to_extF80M.c",
    "deps/SoftFloat-3e/source/f64_to_f16.c",
    "deps/SoftFloat-3e/source/i32_to_f128M.c",
    "deps/SoftFloat-3e/source/s_add256M.c",
    "deps/SoftFloat-3e/source/s_addCarryM.c",
    "deps/SoftFloat-3e/source/s_addComplCarryM.c",
    "deps/SoftFloat-3e/source/s_addF128M.c",
    "deps/SoftFloat-3e/source/s_addExtF80M.c",
    "deps/SoftFloat-3e/source/s_addM.c",
    "deps/SoftFloat-3e/source/s_addMagsF16.c",
    "deps/SoftFloat-3e/source/s_addMagsF32.c",
    "deps/SoftFloat-3e/source/s_addMagsF64.c",
    "deps/SoftFloat-3e/source/s_approxRecip32_1.c",
    "deps/SoftFloat-3e/source/s_approxRecipSqrt32_1.c",
    "deps/SoftFloat-3e/source/s_approxRecipSqrt_1Ks.c",
    "deps/SoftFloat-3e/source/s_approxRecip_1Ks.c",
    "deps/SoftFloat-3e/source/s_compare128M.c",
    "deps/SoftFloat-3e/source/s_compare96M.c",
    "deps/SoftFloat-3e/source/s_compareNonnormExtF80M.c",
    "deps/SoftFloat-3e/source/s_countLeadingZeros16.c",
    "deps/SoftFloat-3e/source/s_countLeadingZeros32.c",
    "deps/SoftFloat-3e/source/s_countLeadingZeros64.c",
    "deps/SoftFloat-3e/source/s_countLeadingZeros8.c",
    "deps/SoftFloat-3e/source/s_eq128.c",
    "deps/SoftFloat-3e/source/s_invalidF128M.c",
    "deps/SoftFloat-3e/source/s_invalidExtF80M.c",
    "deps/SoftFloat-3e/source/s_isNaNF128M.c",
    "deps/SoftFloat-3e/source/s_le128.c",
    "deps/SoftFloat-3e/source/s_lt128.c",
    "deps/SoftFloat-3e/source/s_mul128MTo256M.c",
    "deps/SoftFloat-3e/source/s_mul64To128M.c",
    "deps/SoftFloat-3e/source/s_mulAddF128M.c",
    "deps/SoftFloat-3e/source/s_mulAddF16.c",
    "deps/SoftFloat-3e/source/s_mulAddF32.c",
    "deps/SoftFloat-3e/source/s_mulAddF64.c",
    "deps/SoftFloat-3e/source/s_negXM.c",
    "deps/SoftFloat-3e/source/s_normExtF80SigM.c",
    "deps/SoftFloat-3e/source/s_normRoundPackMToF128M.c",
    "deps/SoftFloat-3e/source/s_normRoundPackMToExtF80M.c",
    "deps/SoftFloat-3e/source/s_normRoundPackToF16.c",
    "deps/SoftFloat-3e/source/s_normRoundPackToF32.c",
    "deps/SoftFloat-3e/source/s_normRoundPackToF64.c",
    "deps/SoftFloat-3e/source/s_normSubnormalF128SigM.c",
    "deps/SoftFloat-3e/source/s_normSubnormalF16Sig.c",
    "deps/SoftFloat-3e/source/s_normSubnormalF32Sig.c",
    "deps/SoftFloat-3e/source/s_normSubnormalF64Sig.c",
    "deps/SoftFloat-3e/source/s_remStepMBy32.c",
    "deps/SoftFloat-3e/source/s_roundMToI64.c",
    "deps/SoftFloat-3e/source/s_roundMToUI64.c",
    "deps/SoftFloat-3e/source/s_roundPackMToExtF80M.c",
    "deps/SoftFloat-3e/source/s_roundPackMToF128M.c",
    "deps/SoftFloat-3e/source/s_roundPackToF16.c",
    "deps/SoftFloat-3e/source/s_roundPackToF32.c",
    "deps/SoftFloat-3e/source/s_roundPackToF64.c",
    "deps/SoftFloat-3e/source/s_roundToI32.c",
    "deps/SoftFloat-3e/source/s_roundToI64.c",
    "deps/SoftFloat-3e/source/s_roundToUI32.c",
    "deps/SoftFloat-3e/source/s_roundToUI64.c",
    "deps/SoftFloat-3e/source/s_shiftLeftM.c",
    "deps/SoftFloat-3e/source/s_shiftNormSigF128M.c",
    "deps/SoftFloat-3e/source/s_shiftRightJam256M.c",
    "deps/SoftFloat-3e/source/s_shiftRightJam32.c",
    "deps/SoftFloat-3e/source/s_shiftRightJam64.c",
    "deps/SoftFloat-3e/source/s_shiftRightJamM.c",
    "deps/SoftFloat-3e/source/s_shiftRightM.c",
    "deps/SoftFloat-3e/source/s_shortShiftLeft64To96M.c",
    "deps/SoftFloat-3e/source/s_shortShiftLeftM.c",
    "deps/SoftFloat-3e/source/s_shortShiftRightExtendM.c",
    "deps/SoftFloat-3e/source/s_shortShiftRightJam64.c",
    "deps/SoftFloat-3e/source/s_shortShiftRightJamM.c",
    "deps/SoftFloat-3e/source/s_shortShiftRightM.c",
    "deps/SoftFloat-3e/source/s_sub1XM.c",
    "deps/SoftFloat-3e/source/s_sub256M.c",
    "deps/SoftFloat-3e/source/s_subM.c",
    "deps/SoftFloat-3e/source/s_subMagsF16.c",
    "deps/SoftFloat-3e/source/s_subMagsF32.c",
    "deps/SoftFloat-3e/source/s_subMagsF64.c",
    "deps/SoftFloat-3e/source/s_tryPropagateNaNF128M.c",
    "deps/SoftFloat-3e/source/s_tryPropagateNaNExtF80M.c",
    "deps/SoftFloat-3e/source/softfloat_state.c",
    "deps/SoftFloat-3e/source/ui32_to_f128M.c",
    "deps/SoftFloat-3e/source/ui64_to_f128M.c",
    "deps/SoftFloat-3e/source/ui32_to_extF80M.c",
    "deps/SoftFloat-3e/source/ui64_to_extF80M.c",
};

const stage1_sources = [_][]const u8{
    "src/stage1/analyze.cpp",
    "src/stage1/astgen.cpp",
    "src/stage1/bigfloat.cpp",
    "src/stage1/bigint.cpp",
    "src/stage1/buffer.cpp",
    "src/stage1/codegen.cpp",
    "src/stage1/dump_analysis.cpp",
    "src/stage1/errmsg.cpp",
    "src/stage1/error.cpp",
    "src/stage1/heap.cpp",
    "src/stage1/ir.cpp",
    "src/stage1/ir_print.cpp",
    "src/stage1/mem.cpp",
    "src/stage1/os.cpp",
    "src/stage1/parser.cpp",
    "src/stage1/range_set.cpp",
    "src/stage1/stage1.cpp",
    "src/stage1/target.cpp",
    "src/stage1/tokenizer.cpp",
    "src/stage1/util.cpp",
    "src/stage1/softfloat_ext.cpp",
};
const optimized_c_sources = [_][]const u8{
    "src/stage1/parse_f128.c",
};
const zig_cpp_sources = [_][]const u8{
    // These are planned to stay even when we are self-hosted.
    "src/zig_llvm.cpp",
    "src/zig_clang.cpp",
    "src/zig_llvm-ar.cpp",
    "src/zig_clang_driver.cpp",
    "src/zig_clang_cc1_main.cpp",
    "src/zig_clang_cc1as_main.cpp",
    // https://github.com/ziglang/zig/issues/6363
    "src/windows_sdk.cpp",
};

const clang_libs = [_][]const u8{
    "clangFrontendTool",
    "clangCodeGen",
    "clangFrontend",
    "clangDriver",
    "clangSerialization",
    "clangSema",
    "clangStaticAnalyzerFrontend",
    "clangStaticAnalyzerCheckers",
    "clangStaticAnalyzerCore",
    "clangAnalysis",
    "clangASTMatchers",
    "clangAST",
    "clangParse",
    "clangSema",
    "clangBasic",
    "clangEdit",
    "clangLex",
    "clangARCMigrate",
    "clangRewriteFrontend",
    "clangRewrite",
    "clangCrossTU",
    "clangIndex",
    "clangToolingCore",
};
const lld_libs = [_][]const u8{
    "lldDriver",
    "lldMinGW",
    "lldELF",
    "lldCOFF",
    "lldMachO",
    "lldWasm",
    "lldReaderWriter",
    "lldCore",
    "lldYAML",
    "lldCommon",
};
// This list can be re-generated with `llvm-config --libfiles` and then
// reformatting using your favorite text editor. Note we do not execute
// `llvm-config` here because we are cross compiling. Also omit LLVMTableGen
// from these libs.
const llvm_libs = [_][]const u8{
    "LLVMWindowsManifest",
    "LLVMXRay",
    "LLVMLibDriver",
    "LLVMDlltoolDriver",
    "LLVMCoverage",
    "LLVMLineEditor",
    "LLVMXCoreDisassembler",
    "LLVMXCoreCodeGen",
    "LLVMXCoreDesc",
    "LLVMXCoreInfo",
    "LLVMX86Disassembler",
    "LLVMX86AsmParser",
    "LLVMX86CodeGen",
    "LLVMX86Desc",
    "LLVMX86Info",
    "LLVMWebAssemblyDisassembler",
    "LLVMWebAssemblyAsmParser",
    "LLVMWebAssemblyCodeGen",
    "LLVMWebAssemblyDesc",
    "LLVMWebAssemblyUtils",
    "LLVMWebAssemblyInfo",
    "LLVMSystemZDisassembler",
    "LLVMSystemZAsmParser",
    "LLVMSystemZCodeGen",
    "LLVMSystemZDesc",
    "LLVMSystemZInfo",
    "LLVMSparcDisassembler",
    "LLVMSparcAsmParser",
    "LLVMSparcCodeGen",
    "LLVMSparcDesc",
    "LLVMSparcInfo",
    "LLVMRISCVDisassembler",
    "LLVMRISCVAsmParser",
    "LLVMRISCVCodeGen",
    "LLVMRISCVDesc",
    "LLVMRISCVInfo",
    "LLVMPowerPCDisassembler",
    "LLVMPowerPCAsmParser",
    "LLVMPowerPCCodeGen",
    "LLVMPowerPCDesc",
    "LLVMPowerPCInfo",
    "LLVMNVPTXCodeGen",
    "LLVMNVPTXDesc",
    "LLVMNVPTXInfo",
    "LLVMMSP430Disassembler",
    "LLVMMSP430AsmParser",
    "LLVMMSP430CodeGen",
    "LLVMMSP430Desc",
    "LLVMMSP430Info",
    "LLVMMipsDisassembler",
    "LLVMMipsAsmParser",
    "LLVMMipsCodeGen",
    "LLVMMipsDesc",
    "LLVMMipsInfo",
    "LLVMLanaiDisassembler",
    "LLVMLanaiCodeGen",
    "LLVMLanaiAsmParser",
    "LLVMLanaiDesc",
    "LLVMLanaiInfo",
    "LLVMHexagonDisassembler",
    "LLVMHexagonCodeGen",
    "LLVMHexagonAsmParser",
    "LLVMHexagonDesc",
    "LLVMHexagonInfo",
    "LLVMBPFDisassembler",
    "LLVMBPFAsmParser",
    "LLVMBPFCodeGen",
    "LLVMBPFDesc",
    "LLVMBPFInfo",
    "LLVMAVRDisassembler",
    "LLVMAVRAsmParser",
    "LLVMAVRCodeGen",
    "LLVMAVRDesc",
    "LLVMAVRInfo",
    "LLVMARMDisassembler",
    "LLVMARMAsmParser",
    "LLVMARMCodeGen",
    "LLVMARMDesc",
    "LLVMARMUtils",
    "LLVMARMInfo",
    "LLVMAMDGPUDisassembler",
    "LLVMAMDGPUAsmParser",
    "LLVMAMDGPUCodeGen",
    "LLVMAMDGPUDesc",
    "LLVMAMDGPUUtils",
    "LLVMAMDGPUInfo",
    "LLVMAArch64Disassembler",
    "LLVMAArch64AsmParser",
    "LLVMAArch64CodeGen",
    "LLVMAArch64Desc",
    "LLVMAArch64Utils",
    "LLVMAArch64Info",
    "LLVMOrcJIT",
    "LLVMMCJIT",
    "LLVMJITLink",
    "LLVMInterpreter",
    "LLVMExecutionEngine",
    "LLVMRuntimeDyld",
    "LLVMOrcTargetProcess",
    "LLVMOrcShared",
    "LLVMDWP",
    "LLVMSymbolize",
    "LLVMDebugInfoPDB",
    "LLVMDebugInfoGSYM",
    "LLVMOption",
    "LLVMObjectYAML",
    "LLVMMCA",
    "LLVMMCDisassembler",
    "LLVMLTO",
    "LLVMPasses",
    "LLVMCFGuard",
    "LLVMCoroutines",
    "LLVMObjCARCOpts",
    "LLVMipo",
    "LLVMVectorize",
    "LLVMLinker",
    "LLVMInstrumentation",
    "LLVMFrontendOpenMP",
    "LLVMFrontendOpenACC",
    "LLVMExtensions",
    "LLVMDWARFLinker",
    "LLVMGlobalISel",
    "LLVMMIRParser",
    "LLVMAsmPrinter",
    "LLVMDebugInfoMSF",
    "LLVMDebugInfoDWARF",
    "LLVMSelectionDAG",
    "LLVMCodeGen",
    "LLVMIRReader",
    "LLVMAsmParser",
    "LLVMInterfaceStub",
    "LLVMFileCheck",
    "LLVMFuzzMutate",
    "LLVMTarget",
    "LLVMScalarOpts",
    "LLVMInstCombine",
    "LLVMAggressiveInstCombine",
    "LLVMTransformUtils",
    "LLVMBitWriter",
    "LLVMAnalysis",
    "LLVMProfileData",
    "LLVMObject",
    "LLVMTextAPI",
    "LLVMMCParser",
    "LLVMMC",
    "LLVMDebugInfoCodeView",
    "LLVMBitReader",
    "LLVMCore",
    "LLVMRemarks",
    "LLVMBitstreamReader",
    "LLVMBinaryFormat",
    "LLVMSupport",
    "LLVMDemangle",
};
