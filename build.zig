const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *Builder) !void {
    const target = if (b.option([]const u8, "ci_target", "the CI target being built")) |ci_target|
        try std.zig.CrossTarget.parse(.{ .arch_os_abi = ci_target_map.get(ci_target) orelse {
            std.log.err("unknown ci_target '{s}'", .{ci_target});
            std.os.exit(1);
        } })
    else
        b.standardTargetOptions(.{});

    const mode = b.standardReleaseOptions();

    const zigup_build_options = b.addOptions();
    const win32exelink: ?*std.build.LibExeObjStep = blk: {
        if (target.getOs().tag == .windows) {
            const exe = b.addExecutable("win32exelink", "win32exelink.zig");
            exe.setTarget(target);
            exe.setBuildMode(mode);
            zigup_build_options.addOptionFileSource("win32exelink_filename", .{ .generated = &exe.output_path_source });
            break :blk exe;
        }
        break :blk null;
    };

    // TODO: Maybe add more executables with different ssl backends
    const exe = try addZigupExe(b, target, mode, zigup_build_options, win32exelink);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    addTest(b, exe, target, mode);
}

fn addTest(b: *Builder, exe: *std.build.LibExeObjStep, target: std.zig.CrossTarget, mode: std.builtin.Mode) void {
    const test_exe = b.addExecutable("test", "test.zig");
    test_exe.setTarget(target);
    test_exe.setBuildMode(mode);
    const run_cmd = test_exe.run();

    // TODO: make this work, add exe install path as argument to test
    //run_cmd.addArg(exe.getInstallPath());
    _ = exe;
    run_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "test the executable");
    test_step.dependOn(&run_cmd.step);
}

fn addZigupExe(
    b: *Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
    zigup_build_options: *std.build.OptionsStep,
    optional_win32exelink: ?*std.build.LibExeObjStep,
) !*std.build.LibExeObjStep {
    const exe = b.addExecutable("zigup", "zigup.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    if (optional_win32exelink) |win32exelink| {
        exe.step.dependOn(&win32exelink.step);
    }
    exe.addOptions("build_options", zigup_build_options);

    const zarc_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zarc",
        .branch = "protected",
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: merge this branch
        .sha = "abc4b7ee82eba97e6959d7784d3fcc68d0fd31bf",
    });
    if (targetIsWindows(target)) {
        exe.step.dependOn(&zarc_repo.step);
        const zarc_repo_path = zarc_repo.getPath(&exe.step);
        exe.addPackage(Pkg {
            .name = "zarc",
            .source = .{ .path = try join(b, &[_][]const u8 { zarc_repo_path, "src", "main.zig" }) },
        });
    }
    return exe;
}

fn targetIsWindows(target: std.zig.CrossTarget) bool {
    if (target.os_tag) |tag|
        return tag == .windows;
    return builtin.target.os.tag == .windows;
}

fn addGithubReleaseExe(b: *Builder, github_release_step: *std.build.Step, comptime target_triple: []const u8) !void {

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

fn join(b: *Builder, parts: []const []const u8) ![]const u8 {
    return try std.fs.path.join(b.allocator, parts);
}

const ci_target_map = std.ComptimeStringMap([]const u8, .{
    .{ "ubuntu-latest-x86_64", "x86_64-linux" },
    .{ "macos-latest-x86_64", "x86_64-macos" },
    .{ "windows-latest-x86_64", "x86_64-windows" },
    .{ "ubuntu-latest-aarch64", "aarch64-linux" },
    .{ "macos-latest-aarch64", "aarch64-macos" },
});
