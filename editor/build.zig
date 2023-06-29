const std = @import("std");
const LipoStep = @import("lipostep.zig");
const XCFrameworkStep = @import("xcframeworkstep.zig");
const LibtoolStep = @import("libtoolstep.zig");

const alloc = std.heap.c_allocator;

/// From https://mitchellh.com/writing/zig-and-swiftui#merging-all-dependencies
pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigobjc = b.createModule(.{
        .source_file = .{ .path = "lib/zig-objc/src/main.zig" },
    });
    const modules = [_]*std.build.Module{zigobjc};

    build_tests(b, target, optimize);

    // Make static libraries for aarch64 and x86_64
    var static_lib_aarch64 = build_static_lib(b, target, optimize, "editor_aarch64", .aarch64, &modules);
    var static_lib_x86_64 = build_static_lib(b, target, optimize, "editor_x86_64", .x86_64, &modules);

    // // Merge all non-zig dependencies
    // var lib_list = std.ArrayList(std.build.FileSource).init(alloc);
    // try lib_list.append(.{.path = "lib/zig-objc"});
    // const libtool = LibtoolStep.create(b, .{
    // });
    // try lib_list.append(.{ .generated = &static_lib_aarch64.output_path_source });

    // Make a universal static library
    const static_lib_universal = LipoStep.create(b, .{
        .name = "editor",
        .out_name = "libeditor.a",
        .input_a = static_lib_aarch64.getOutputLibSource(),
        .input_b = static_lib_x86_64.getOutputLibSource(),
    });
    static_lib_universal.step.dependOn(&static_lib_aarch64.step);
    static_lib_universal.step.dependOn(&static_lib_x86_64.step);

    b.installArtifact(static_lib_aarch64);
    b.installArtifact(static_lib_x86_64);

    // Create XCFramework so the lib can be used from swift
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "EditorKit",
        .out_path = "macos/EditorKit.xcframework",
        .library = static_lib_universal.output,
        .headers = .{ .path = "include" },
    });

    xcframework.step.dependOn(static_lib_universal.step);
    b.default_step.dependOn(xcframework.step);
}

fn build_static_lib(b: *std.build.Builder, target: std.zig.CrossTarget, optimize: std.builtin.Mode, name: []const u8, cpu_arch: std.Target.Cpu.Arch, modules: []const *std.build.Module) *std.build.Step.Compile {
    // Make static libraries for aarch64 and x86_64
    var static_lib = b.addStaticLibrary(.{
        .name = name,
        .root_source_file = .{ .path = "src/main_c.zig" },
        .target = .{
            .cpu_arch = cpu_arch,
            .os_tag = .macos,
            .os_version_min = target.os_version_min,
        },
        .optimize = optimize,
    });
    static_lib.addFrameworkPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks");
    static_lib.addSystemIncludePath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include");
    static_lib.addLibraryPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Devseloper/SDKs/MacOSX.sdk/usr/lib");
    static_lib.linkFramework("CoreText");
    static_lib.linkFramework("MetalKit");
    static_lib.linkFramework("Foundation");
    static_lib.linkFramework("AppKit");
    static_lib.linkFramework("CoreGraphics");

    static_lib.bundle_compiler_rt = true;
    for (modules) |module| {
        static_lib.addModule("zig-objc", module);
    }
    static_lib.linkLibC();
    b.default_step.dependOn(&static_lib.step);
    return static_lib;
}

fn build_tests(b: *std.build.Builder, target: std.zig.CrossTarget, optimize: std.builtin.Mode) void {
    const tests = b.addTest(.{
        .name = "rope_tests",
        .root_source_file = .{ .path = "src/rope.zig" },
        .target = target,
        .optimize = optimize,
        // .filter = "deletion multiline",
    });
    tests.linkLibC();
    b.default_step.dependOn(&tests.step);
    const run: *std.build.Step.Run = b.addRunArtifact(tests);
    b.installArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
    test_step.dependOn(&run.step);
}
