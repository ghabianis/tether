const LibtoolStep = @import("./libtoolstep.zig");

const MergeStaticLibsStep = @This();

const std = @import("std");
const ArrayList = std.ArrayList;

const Step = std.build.Step;
const RunStep = std.build.RunStep;
const FileSource = std.build.FileSource;

pub const Options = struct {
    /// The name of this step.
    name: []const u8,

    /// The filename (not the path) of the file to create. This will
    /// be placed in a unique hashed directory. Use out_path to access.
    out_name: []const u8,

    /// Library files (.a) to combine.
    sources: []FileSource,
    steps: []*Step,
};

/// The step to depend on.
step: *Step,

/// The output file from the libtool run.
output: FileSource,

pub fn create(b: *std.Build, opts: Options) *MergeStaticLibsStep {
    const self = b.allocator.create(MergeStaticLibsStep) catch @panic("OOM");

    var ar_steps = ArrayList(*RunStep).initCapacity(b.allocator, opts.sources.len) catch @panic("OOM");
    var folders = ArrayList(FileSource).initCapacity(b.allocator, opts.sources.len) catch @panic("OOM");

    var i: usize = 0;
    for (opts.sources) |source| {
        var mkdir = RunStep.create(b, b.fmt("({s}) mkdir {d}", .{ opts.name, i }));
        mkdir.addArgs(&.{"mkdir"});
        mkdir.step.dependOn(opts.steps[i]);
        const folder = mkdir.addOutputFileArg(b.fmt("{d}", .{i}));
        std.debug.print("FOLDER: {s}\n", .{folder.getDisplayName()});
        folders.append(folder) catch @panic("OOM");

        var cd = RunStep.create(b, b.fmt("({s}) cd {d}", .{ opts.name, i }));
        cd.addArgs(&.{"cd"});
        cd.addFileSourceArg(folder);
        cd.step.dependOn(&mkdir.step);

        // ar -x lib.a
        var ar = RunStep.create(b, b.fmt("({s}) ar for {d}", .{ opts.name, i }));
        ar.addArgs(&.{ "ar", "-x" });
        ar.addFileSourceArg(source);
        ar_steps.append(ar) catch @panic("OOM");
        ar.step.dependOn(&cd.step);
        i += 1;
    }

    var glob_step = GlobsStep.create(b, "create folder globs", folders.items);
    i = 0;
    while (i < ar_steps.items.len) : (i += 1) {
        glob_step.step.dependOn(&ar_steps.items[i].step);
    }

    var libtool = LibtoolStep.create(b, .{
        .name = b.fmt("libtool {s}", .{opts.name}),
        .out_name = opts.out_name,
        .sources = glob_step.outputs,
    });
    libtool.step.dependOn(&glob_step.step);

    self.* = .{
        .step = libtool.step,
        .output = libtool.output,
    };

    return self;
}

const GlobsStep = struct {
    step: Step,
    inputs: []const FileSource,
    outputs: []FileSource,

    pub fn create(b: *std.Build, name: []const u8, inputs: []const FileSource) *GlobsStep {
        var self = b.allocator.create(GlobsStep) catch @panic("OOM");
        var step = Step.init(.{
            .id = .custom,
            .name = name,
            .owner = b,
            .makeFn = &make,
        });
        self.step = step;
        self.inputs = inputs;

        var outputs = b.allocator.alloc(FileSource, inputs.len) catch @panic("OOM");
        var i: usize = 0;
        while (i < inputs.len) : (i += 1) {
            var generated_file = b.allocator.create(std.build.GeneratedFile) catch @panic("OOM");
            generated_file.* = .{ .step = &self.step };
            outputs[i] = .{ .generated = generated_file };
        }

        self.outputs = outputs;

        return self;
    }

    pub fn make(step: *Step, prog_node: *std.Progress.Node) !void {
        const b = step.owner;
        const arena = b.allocator;
        _ = arena;
        const self = @fieldParentPtr(GlobsStep, "step", step);

        var i: usize = 0;
        for (self.inputs) |input| {
            self.outputs[i].path = b.fmt("{s}/*", .{input.path});
            i += 1;
        }
        prog_node.end();
    }
};
