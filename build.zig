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
        .url = "https://github.com/hazeycode/ziget",
        .branch = null,
        .sha = "37f8b6b16e2f724a16d2150f4501b742aaf09390",
    });
    const build2 = addBuild(b, .{ .path = "build2.zig" }, .{});
    build2.addArgs(try getBuildArgs(b));
    ziget_repo.step.make() catch |e| return e;
    build2.step.make() catch |err| switch (err) {
        error.UnexpectedExitCode => std.os.exit(0xff), // error already printed by subprocess
        else => |e| return e,
    };
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
    run_step.addArg(self.pathFromRoot(self.cache_root));
    return run_step;
}
