const std = @import("std");
const builtin = @import("builtin");
const Pkg = std.build.Pkg;

fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub fn build(b: *std.Build) !void {
    //var github_release_step = b.step("github-release", "Build the github-release binaries");
    //try addGithubReleaseExe(b, github_release_step, ziget_repo, "x86_64-linux", .std);

    const target = if (b.option([]const u8, "ci_target", "the CI target being built")) |ci_target|
        b.resolveTargetQuery(try std.zig.CrossTarget.parse(.{ .arch_os_abi = ci_target_map.get(ci_target) orelse {
            std.log.err("unknown ci_target '{s}'", .{ci_target});
            std.process.exit(1);
        } }))
    else
        b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const win32exelink_mod: ?*std.Build.Module = blk: {
        if (target.result.os.tag == .windows) {
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

    {
        const unzip = b.addExecutable(.{
            .name = "unzip",
            .root_source_file = b.path("unzip.zig"),
            .target = target,
            .optimize = optimize,
        });
        const install = b.addInstallArtifact(unzip, .{});
        b.step("unzip", "Build/install the unzip cmdline tool").dependOn(&install.step);
    }
}

fn addTest(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
) void {
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
    b: *std.Build,
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

    if (target.result.os.tag == .windows) {
        exe.root_module.addImport("win32exelink", win32exelink_mod.?);
    }

    return exe;
}

fn addGithubReleaseExe(
    b: *std.Build,
    github_release_step: *std.build.Step,
    comptime target_triple: []const u8,
) !void {
    const small_release = true;

    const target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = target_triple });
    const mode = if (small_release) .ReleaseSafe else .Debug;
    const exe = try addZigupExe(b, target, mode);
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
    .{ "ubuntu-latest-armv7a", "arm-linux" },
    .{ "ubuntu-latest-riscv64", "riscv64-linux" },
    .{ "ubuntu-latest-powerpc64le", "powerpc64le-linux" },
    .{ "ubuntu-latest-powerpc", "powerpc-linux" },
    .{ "macos-latest-aarch64", "aarch64-macos" },
});
