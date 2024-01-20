const std = @import("std");
const builtin = @import("builtin");
const Builder = std.Build;
const Pkg = std.Build.Pkg;

// TODO: make this work with "GitRepoStep.zig", there is a
//       problem with the -Dfetch option
const GitRepoStep = @import("GitRepoStep.zig");

fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub fn build(b: *Builder) !void {
    const ziget_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/ziget",
        .branch = null,
        .sha = @embedFile("zigetsha"),
    });

    // TODO: implement this if/when we get @tryImport
    //if (zigetbuild) |_| { } else {
    //    std.log.err("TODO: add zigetbuild package and recompile/reinvoke build.d", .{});
    //    return;
    //}

    //var github_release_step = b.step("github-release", "Build the github-release binaries");
    //try addGithubReleaseExe(b, github_release_step, ziget_repo, "x86_64-linux", .std);

    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const win32exelink_mod: ?*std.Build.Module = blk: {
        if (target.query.os_tag == .windows) {
            const exe = b.addExecutable(.{
                .name = "win32exelink",
                .root_source_file = .{ .path = "win32exelink.zig" },
                .target = target,
                .optimize = optimize,
            });
            break :blk b.createModule(.{
                .root_source_file = exe.getEmittedBin(),
            });
        }
        break :blk null;
    };

    // TODO: Maybe add more executables with different ssl backends
    const exe = try addZigupExe(
        b,
        ziget_repo,
        target,
        optimize,
        win32exelink_mod,
    );
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    addTest(b, exe, target, optimize);
}

fn addTest(b: *Builder, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.Mode) void {
    const test_exe = b.addExecutable(.{
        .name = "test",
        .root_source_file = .{ .path = "test.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_cmd = b.addRunArtifact(test_exe);

    // TODO: make this work, add exe install path as argument to test
    //run_cmd.addArg(exe.getInstallPath());
    _ = exe;
    run_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "test the executable");
    test_step.dependOn(&run_cmd.step);
}

fn addZigupExe(
    b: *Builder,
    ziget_repo: *GitRepoStep,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    win32exelink_mod: ?*std.Build.Module,
) !*std.Build.Step.Compile {

    const exe = b.addExecutable(.{
        .name = "zigup",
        .root_source_file = .{ .path = "zigup.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.step.dependOn(&ziget_repo.step);
    // zigetbuild.addZigetModule(exe, ssl_backend, ziget_repo.getPath(&exe.step));

    if (target.result.os.tag == .windows) {
        exe.root_module.addImport("win32exelink", win32exelink_mod.?);
        const zarc_repo = GitRepoStep.create(b, .{
            .url = "https://github.com/marler8997/zarc",
            .branch = "protected",
            .sha = "2e5256624d7871180badc9784b96dd66d927d604",
            .fetch_enabled = true,
        });
        exe.step.dependOn(&zarc_repo.step);
        const zarc_repo_path = zarc_repo.getPath(&exe.step);
        const zarc_mod = b.addModule("zarc", .{
            .root_source_file = .{ .path = b.pathJoin(&.{ zarc_repo_path, "src", "main.zig" }) },
        });
        exe.root_module.addImport("zarc", zarc_mod);
    }
    return exe;
}

fn addGithubReleaseExe(b: *Builder, github_release_step: *std.Build.Step, ziget_repo: []const u8, comptime target_triple: []const u8) !void {
    const small_release = true;

    const target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = target_triple });
    const mode = if (small_release) .ReleaseSafe else .Debug;
    const exe = try addZigupExe(b, ziget_repo, target, mode);
    if (small_release) {
        exe.strip = true;
    }
    exe.setOutputDir("github-release" ++ std.fs.path.sep_str ++ target_triple);
    github_release_step.dependOn(&exe.step);
}

const ci_target_map = std.ComptimeStringMap([]const u8, .{
    .{ "ubuntu-latest-x86_64", "x86_64-linux" },
    .{ "macos-latest-x86_64", "x86_64-macos" },
    .{ "windows-latest-x86_64", "x86_64-windows" },
    .{ "ubuntu-latest-aarch64", "aarch64-linux" },
    .{ "macos-latest-aarch64", "aarch64-macos" },
});
