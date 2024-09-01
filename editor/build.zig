const std = @import("std");
const LipoStep = @import("build/lipostep.zig");
const XCFrameworkStep = @import("build/xcframeworkstep.zig");
const LibtoolStep = @import("build/libtoolstep.zig");
const MergeStaticLibsStep = @import("build/mergestaticlibstep.zig");
const TreeSitterHighlightStep = @import("build/tree_sitter_highlight_step.zig");

const alloc = std.heap.c_allocator;
const FileSource = std.Build.LazyPath;

const ModuleDef = struct {
    mod: *std.Build.Module,
    name: []const u8,
};

/// From https://mitchellh.com/writing/zig-and-swiftui#merging-all-dependencies
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    _ = target; // autofix
    const optimize = b.standardOptimizeOption(.{});

    const zigobjc = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "lib/zig-objc/src/main.zig" },
    });
    // const earcut = b.createModule(.{
    //     .source_file = .{ .path = "lib/mach-earcut/src/main.zig" },
    // });
    const modules = [_]ModuleDef{
        .{ .mod = zigobjc, .name = "zig-objc" },
        // .{ .mod = earcut, .name = "earcut" },
    };

    // build_tests(b, &modules, target, optimize);

    // Make static libraries for aarch64 and x86_64
    const static_lib_aarch64 = try build_static_lib(b, optimize, "editor_aarch64", "libeditor-aarch64-bundle.a", .aarch64, &modules);
    const static_lib_x86_64 = try build_static_lib(b, optimize, "editor_x86_64", "libeditor-x86_64-bundle.a", .x86_64, &modules);

    // Make a universal static library
    const static_lib_universal = LipoStep.create(b, .{
        .name = "editor",
        .out_name = "libeditor.a",
        .input_a = static_lib_aarch64.out,
        .input_b = static_lib_x86_64.out,
    });
    static_lib_universal.step.dependOn(static_lib_aarch64.step);
    static_lib_universal.step.dependOn(static_lib_x86_64.step);

    // Create XCFramework so the lib can be used from swift
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "EditorKit",
        .out_path = "macos/EditorKit.xcframework",
        .library = static_lib_universal.output,
        .headers = .{ .cwd_relative = "include" },
    });

    xcframework.step.dependOn(static_lib_universal.step);
    b.default_step.dependOn(xcframework.step);
    b.default_step.dependOn(static_lib_aarch64.step);
}

fn build_treesitter(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    cpu_arch: std.Target.Cpu.Arch,
) *std.Build.Step.Compile {
    var lib = b.addStaticLibrary(.{
        .name = b.fmt("tree-sitter-{s}", .{@tagName(cpu_arch)}),
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();
    lib.addCSourceFile(.{ .file = .{ .cwd_relative = "lib/tree-sitter/lib/src/lib.c" }, .flags = &.{} });
    lib.addIncludePath(.{ .cwd_relative = "lib/tree-sitter/lib/include" });
    lib.addIncludePath(.{ .cwd_relative = "lib/tree-sitter/lib/src" });

    b.installArtifact(lib);
    return lib;
}

fn build_treesitter_highlight(b: *std.Build) *TreeSitterHighlightStep {
    const step = TreeSitterHighlightStep.create(b, .{ .treesitter_dir = "lib/tree-sitter" });
    b.default_step.dependOn(step.step);
    return step;
}

fn build_static_lib(
    b: *std.Build,
    optimize: std.builtin.Mode,
    name: []const u8,
    bundle_name: []const u8,
    cpu_arch: std.Target.Cpu.Arch,
    // Zig modules
    modules: []const ModuleDef,
) !struct { out: FileSource, step: *std.Build.Step } {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = cpu_arch,
        .os_tag = .macos,
        .os_version_min = osVersionMin(.macos),
    });
    const treesitter = build_treesitter(b, target, optimize, cpu_arch);

    // Make static libraries for aarch64 and x86_64
    var static_lib = b.addStaticLibrary(.{
        .name = name,
        .root_source_file = .{ .cwd_relative = "src/main_c.zig" },
        .target = target,
        .optimize = optimize,
    });
    add_libs(b, static_lib, modules, treesitter);

    const ENABLE_DEBUG_SYMBOLS = true;
    if (comptime ENABLE_DEBUG_SYMBOLS) {
        // static_lib.dll_export_fns = true;
        // static_lib.dead_strip_dylibs = false;
        static_lib.export_table = true;
    }

    var lib_list = std.ArrayList(FileSource).init(alloc);
    try lib_list.append(static_lib.getEmittedBin());
    try lib_list.append(treesitter.getEmittedBin());
    if (cpu_arch == .aarch64) {
        // try lib_list.append(.{ .path = "/Users/zackradisic/Code/tether/editor/lib/tree-sitter/libtree-sitter.a" });
        // try lib_list.append(.{ .cwd_relative = "lib/tree-sitter/libtree-sitter.a" });
        try lib_list.append(.{ .cwd_relative = "zig-out/lib/libtree-sitter-aarch64.a" });
    } else {
        // try lib_list.append(.{ .path = "/Users/zackradisic/Code/tether/editor/lib/tree-sitter/libtree-sitter.a" });
        // try lib_list.append(.{ .cwd_relative = "zig-out/lib/libtree-sitter-x86_64.a" });
    }

    const libtool = LibtoolStep.create(b, .{
        .name = bundle_name,
        .out_name = bundle_name,
        .sources = lib_list.items,
    });
    libtool.step.dependOn(&static_lib.step);

    b.default_step.dependOn(libtool.step);
    b.installArtifact(static_lib);

    return .{ .out = libtool.output, .step = libtool.step };
    // return .{ .out = static_lib.getEmittedBin(), .step = &static_lib.step };
}

fn add_libs(b: *std.Build, compile: *std.Build.Step.Compile, modules: []const ModuleDef, treesitter: *std.Build.Step.Compile) void {
    // compile.addFrameworkPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks");
    // compile.addSystemIncludePath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include");
    // compile.addLibraryPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib");

    compile.addFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX13.3.sdk/System/Library/Frameworks" });
    compile.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX13.3.sdk/usr/include" });
    compile.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX13.3.sdk/usr/lib" });

    compile.linkFramework("CoreText");
    compile.linkFramework("MetalKit");
    compile.linkFramework("Foundation");
    compile.linkFramework("AppKit");
    compile.linkFramework("CoreGraphics");
    compile.linkSystemLibrary("System");
    compile.linkSystemLibrary("objc");
    compile.linkLibC();

    compile.bundle_compiler_rt = true;
    for (modules) |module| {
        // compile.addModule(module.name, module.mod);
        compile.root_module.addImport(module.name, module.mod);
    }

    // treesitter stuff
    // compile.addCSourceFile(.{ .file = .{ .cwd_relative = "src/syntax/tree-sitter-zig/src/parser.c" }, .flags = &.{} });
    // compile.addCSourceFile("src/syntax/tree-sitter-typescript/typescript/src/parser.c", &.{});
    // compile.addCSourceFile("src/syntax/tree-sitter-typescript/typescript/src/scanner.c", &.{});
    // compile.addCSourceFile(.{ .file = b.path("src/syntax/tree-sitter-c/src/parser.c"), .flags = &.{ "-I", "src/syntax/tree-sitter-c/src/tree_sitter" } });
    compile.addCSourceFile(.{
        .file = b.path("src/syntax/tree-sitter-c/src/parser.c"),
        .flags = &.{
            "-I", b.pathJoin(&.{ "src", "syntax", "tree-sitter-c", "src" }),
            "-I", b.pathJoin(&.{ "lib", "tree-sitter", "lib", "include" }),
        },
    });
    // compile.addCSourceFile(.{ .file = .{ .cwd_relative = "src/syntax/tree-sitter-rust/src/parser.c" }, .flags = &.{} });
    // compile.addCSourceFile(.{ .file = .{ .cwd_relative = "src/syntax/tree-sitter-rust/src/scanner.c" }, .flags = &.{} });
    compile.linkLibrary(treesitter);
    compile.addIncludePath(.{ .cwd_relative = "lib/tree-sitter/lib/include" });
    compile.addIncludePath(.{ .cwd_relative = "src/syntax/tree-sitter-c/src/tree_sitter" });
    compile.step.dependOn(&treesitter.step);
}

fn build_tests(b: *std.Build, modules: []const ModuleDef, target: std.Build.ResolvedTarget, optimize: std.builtin.Mode) void {
    const test_step = b.step("test", "Run tests");
    const treesitter = build_treesitter(b, target, optimize, .aarch64);

    const tests = [_]std.Build.TestOptions{
        .{
            .name = "main_tests",
            .root_source_file = .{ .cwd_relative = "src/main_c.zig" },
            .target = target,
            .optimize = optimize,
            // .filter = "simd rope char iter",
        },
        .{
            .name = "rope_tests",
            .root_source_file = .{ .cwd_relative = "src/rope.zig" },
            .target = target,
            .optimize = optimize,
            // .filter = "simd rope char iter",
        },
        .{
            .name = "vim_tests",
            .root_source_file = .{ .cwd_relative = "src/vim.zig" },
            .target = target,
            .optimize = optimize,
        },
        .{
            .name = "editor_tests",
            .root_source_file = .{ .cwd_relative = "src/editor.zig" },
            .target = target,
            .optimize = optimize,
            // .filter = "indentation then backspace edge case",
        },
        .{
            .name = "math_tests",
            .root_source_file = .{ .cwd_relative = "src/math.zig" },
            .target = target,
            .optimize = optimize,
        },
        .{
            .name = "highlight_tests",
            .root_source_file = .{ .cwd_relative = "src/highlight.zig" },
            .target = target,
            .optimize = optimize,
        },
        .{
            .name = "strutil_tests",
            .root_source_file = .{ .cwd_relative = "src/highlight.zig" },
            .target = target,
            .optimize = optimize,
        },
    };

    for (tests) |t| {
        build_test(b, test_step, modules, treesitter, t);
    }
}

fn build_test(b: *std.Build, test_step: *std.Build.Step, modules: []const ModuleDef, treesitter: *std.Build.Step.Compile, opts: std.Build.TestOptions) void {
    const the_test = b.addTest(opts);
    add_libs(b, the_test, modules, treesitter);
    the_test.linkLibC();
    // b.default_step.dependOn(&the_test.step);
    // b.default_step.dependOn(&treesitter.step);
    const run: *std.Build.Step.Run = b.addRunArtifact(the_test);
    b.installArtifact(the_test);
    test_step.dependOn(&the_test.step);
    test_step.dependOn(&run.step);
}

/// Returns the minimum OS version for the given OS tag. This shouldn't
/// be used generally, it should only be used for Darwin-based OS currently.
fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        // The lowest supported version of macOS is 12.x because
        // this is the first version to support Apple Silicon so it is
        // the earliest version we can virtualize to test (I only have
        // an Apple Silicon machine for macOS).
        .macos => .{ .semver = .{
            .major = 12,
            .minor = 0,
            .patch = 0,
        } },

        // iOS 17 picked arbitrarily
        .ios => .{ .semver = .{
            .major = 17,
            .minor = 0,
            .patch = 0,
        } },

        // This should never happen currently. If we add a new target then
        // we should add a new case here.
        else => null,
    };
}
