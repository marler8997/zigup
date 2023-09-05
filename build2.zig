const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Pkg = std.build.Pkg;

// TODO: make this work with "GitRepoStep.zig", there is a
//       problem with the -Dfetch option
const GitRepoStep = @import("GitRepoStep.zig");

fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub fn build(b: *Build) !void {
    // var github_release_step = b.step("github-release", "Build the github-release binaries");
    // try addGithubReleaseExe(b, github_release_step, "x86_64-linux", null);

    const target = if (b.option([]const u8, "ci_target", "the CI target being built")) |ci_target|
        try std.zig.CrossTarget.parse(.{ .arch_os_abi = ci_target_map.get(ci_target) orelse {
            std.log.err("unknown ci_target '{s}'", .{ci_target});
            std.os.exit(1);
        } })
    else
        b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // NOTE: weird spoof, fixes the -Dfetch problem
    _ = b.option(bool, "fetch", "automatically fetch network resources");

    const win32exelink_mod: ?*std.Build.Module = blk: {
        if (target.getOs().tag == .windows) {
            const exe = b.addExecutable(.{
                .name = "win32exelink",
                .root_source_file = .{ .path = "win32exelink.zig" },
                .target = target,
                .optimize = optimize,
            });
            break :blk b.createModule(.{
                .source_file = exe.getEmittedBin(),
            });
        }
        break :blk null;
    };

    // TODO: Maybe add more executables with different ssl backends
    const exe = try addZigupExe(
        b,
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

fn addTest(b: *Build, exe: *std.build.LibExeObjStep, target: std.zig.CrossTarget, optimize: std.builtin.Mode) void {
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
    b: *Build,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    win32exelink_mod: ?*std.build.Module,
) !*std.build.LibExeObjStep {
    const exe = b.addExecutable(.{
        .name = "zigup",
        .root_source_file = .{ .path = "zigup.zig" },
        .target = target,
        .optimize = optimize,
    });

    if (targetIsWindows(target)) {
        exe.addModule("win32exelink", win32exelink_mod.?);
        const zarc_repo = GitRepoStep.create(b, .{
            .url = "https://github.com/marler8997/zarc",
            .branch = "protected",
            .sha = "2e5256624d7871180badc9784b96dd66d927d604",
            .fetch_enabled = true,
        });
        exe.step.dependOn(&zarc_repo.step);
        const zarc_repo_path = zarc_repo.getPath(&exe.step);
        const zarc_mod = b.addModule("zarc", .{
            .source_file = .{ .path = b.pathJoin(&.{ zarc_repo_path, "src", "main.zig" }) },
        });
        exe.addModule("zarc", zarc_mod);
    }

    return exe;
}

fn targetIsWindows(target: std.zig.CrossTarget) bool {
    if (target.os_tag) |tag|
        return tag == .windows;
    return builtin.target.os.tag == .windows;
}

fn addGithubReleaseExe(
    b: *Build,
    github_release_step: *std.build.Step,
    comptime target_triple: []const u8,
    win32exelink_mod: ?*std.build.Module,
) !void {
    const small_release = true;

    const target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = target_triple });
    const mode = if (small_release) .ReleaseSafe else .Debug;
    const exe = try addZigupExe(b, target, mode, win32exelink_mod);
    if (small_release) {
        exe.strip = true;
    }
    exe.setOutputDir("github-release" ++ std.fs.path.sep_str ++ target_triple ++ std.fs.path.sep_str);
    github_release_step.dependOn(&exe.step);
}

const ci_target_map = std.ComptimeStringMap([]const u8, .{
    .{ "ubuntu-latest-x86_64", "x86_64-linux" },
    .{ "macos-latest-x86_64", "x86_64-macos" },
    .{ "windows-latest-x86_64", "x86_64-windows" },
    .{ "ubuntu-latest-aarch64", "aarch64-linux" },
    .{ "macos-latest-aarch64", "aarch64-macos" },
});
