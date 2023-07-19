const TreeSitterHighlightStep = @This();

const std = @import("std");
const Step = std.build.Step;
const RunStep = std.build.RunStep;
const FileSource = std.build.FileSource;

pub const Options = struct {
    treesitter_dir: []const u8,
};

step: *Step,
output: FileSource,

pub fn create(b: *std.Build, opts: Options) *TreeSitterHighlightStep {
    const self = b.allocator.create(TreeSitterHighlightStep) catch @panic("OOM");

    var run_step = RunStep.create(
        b,
        b.fmt("build tree-sitter-highlight", .{}),
    );
    run_step.cwd = b.fmt("{s}/highlight", .{opts.treesitter_dir});

    run_step.addArgs(&.{ "cargo", "build", "--release", "--lib" });

    const output_str = b.fmt("{s}/target/release/libtree_sitter_highlight.a", .{opts.treesitter_dir});

    self.* = .{
        .step = &run_step.step,
        .output = .{ .path = output_str },
    };

    return self;
}
