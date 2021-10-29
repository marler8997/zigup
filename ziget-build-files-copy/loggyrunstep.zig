const std = @import("std");
const RunStep = std.build.RunStep;
const print = std.debug.print;

// This saves the RunStep.make function pointer because it is private
var global_run_step_make: ?fn(step: *std.build.Step) anyerror!void = null;
    
pub fn enable(run_step: *RunStep) void {
    // TODO: use an atomic operation
    if (global_run_step_make) |make| {
        std.debug.assert(run_step.step.makeFn == make);
    } else {
        global_run_step_make = run_step.step.makeFn;
    }
    run_step.step.makeFn = loggyRunStepMake;
}

fn printCmd(cwd: ?[]const u8, argv: []const []const u8) void {
    if (cwd) |yes_cwd| print("cd {s} && ", .{yes_cwd});
    for (argv) |arg| {
        print("{s} ", .{arg});
    }
    print("\n", .{});
}

fn loggyRunStepMake(step: *std.build.Step) !void {
    const self = @fieldParentPtr(RunStep, "step", step);

    const cwd = if (self.cwd) |cwd| self.builder.pathFromRoot(cwd) else self.builder.build_root;

    var argv_list = std.ArrayList([]const u8).init(self.builder.allocator);
    for (self.argv.items) |arg| {
        switch (arg) {
            .bytes => |bytes| try argv_list.append(bytes),
            .file_source => |file| try argv_list.append(file.getPath(self.builder)),
            .artifact => |artifact| {
                const executable_path = artifact.installed_path orelse artifact.getOutputSource().getPath(self.builder);
                try argv_list.append(executable_path);
            },
        }
    }
    printCmd(cwd, argv_list.items);
    return global_run_step_make.?(step);
}
