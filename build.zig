//! This build.zig file boostraps the real build in build2.zig

// NOTE: need to wait on https://github.com/ziglang/zig/pull/9989 before doing this
//       to make build errors reasonable
const std = @import("std");
const Builder = std.build.Builder;

const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *Builder) !void {
    buildNoreturn(b);
}
fn buildNoreturn(b: *Builder) noreturn {
    const err = buildOrFail(b);
    std.log.err("{s}", .{@errorName(err)});
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace.*);
    }
    std.os.exit(0xff);
}
fn buildOrFail(b: *Builder) anyerror {
    const ziget_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/ziget",
        .sha = @embedFile("zigetsha"),
        .fetch_enabled = true,
    });
    const build2 = addBuild(b, .{ .path = "build2.zig" }, .{});
    build2.addArgs(try getBuildArgs(b));

    var progress = std.Progress{};
    {
        var prog_node = progress.start("clone ziget", 1);
        ziget_repo.step.make(prog_node) catch |e| return e;
        prog_node.end();
    }
    {
        var prog_node = progress.start("run build2.zig", 1);
        build2.step.make(prog_node) catch |err| switch (err) {
            error.MakeFailed => std.os.exit(0xff), // error already printed by subprocess, hopefully?
            error.MakeSkipped => @panic("impossible?"),
        };
        prog_node.end();
    }
    std.os.exit(0);
}

// TODO: remove the following if https://github.com/ziglang/zig/pull/9987 is integrated
fn getBuildArgs(self: *Builder) ![]const [:0]const u8 {
    const args = try std.process.argsAlloc(self.allocator);
    return args[5..];
}
pub fn addBuild(self: *Builder, build_file: std.build.FileSource, _: struct {}) *std.build.RunStep {
    const run_step = std.build.RunStep.create(
        self,
        self.fmt("zig build {s}", .{build_file.getDisplayName()}),
    );
    run_step.addArg(self.zig_exe);
    run_step.addArg("build");
    run_step.addArg("--build-file");
    run_step.addFileSourceArg(build_file);
    run_step.addArg("--cache-dir");
    const cache_root_path = self.cache_root.path orelse @panic("todo");
    run_step.addArg(self.pathFromRoot(cache_root_path));
    return run_step;
}
