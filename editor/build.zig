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

    // Make static libraries for aarch64 and x86_64
    var static_lib_aarch64 = b.addStaticLibrary(.{
        .name = "editor_aarch64",
        .root_source_file = .{ .path = "src/main_c.zig" },
        .target = .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = target.os_version_min,
        },
        .optimize = optimize,
    });
    // static_lib_aarch64.addFrameworkPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks");
    // static_lib_aarch64.addSystemIncludePath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include");
    // static_lib_aarch64.addLibraryPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib");
    // static_lib_aarch64.linkSystemLibraryName("objc");
    // static_lib_aarch64.linkFramework("Foundation");
    // static_lib_aarch64.linkFramework("CoreFoundation");
    // static_lib_aarch64.linkFramework("CoreData");
    // static_lib_aarch64.linkFramework("ApplicationServices");
    // static_lib_aarch64.linkFramework("AppKit");

    static_lib_aarch64.bundle_compiler_rt = true;
    static_lib_aarch64.addModule("zig-objc", zigobjc);
    static_lib_aarch64.linkLibC();
    b.default_step.dependOn(&static_lib_aarch64.step);

    var static_lib_x86_64 = b.addStaticLibrary(.{
        .name = "editor_x86_64",
        .root_source_file = .{ .path = "src/main_c.zig" },
        .target = .{
            .cpu_arch = .x86_64,
            .os_tag = .macos,
            .os_version_min = target.os_version_min,
        },
        .optimize = optimize,
    });
    // static_lib_x86_64.addFrameworkPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks");
    // static_lib_x86_64.addSystemIncludePath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include");
    // static_lib_x86_64.addLibraryPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib");
    // static_lib_x86_64.linkSystemLibraryName("objc");
    // static_lib_x86_64.linkFramework("Foundation");
    // static_lib_x86_64.linkFramework("CoreFoundation");
    // static_lib_x86_64.linkFramework("CoreData");
    // static_lib_x86_64.linkFramework("ApplicationServices");
    // static_lib_x86_64.linkFramework("AppKit");

    static_lib_x86_64.bundle_compiler_rt = true;
    static_lib_x86_64.addModule("zig-objc", zigobjc);
    static_lib_x86_64.linkLibC();
    b.default_step.dependOn(&static_lib_x86_64.step);



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
