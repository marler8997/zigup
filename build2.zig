const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

// TODO: make this work with "GitRepoStep.zig", there is a
//       problem with the -Dfetch option
const GitRepoStep = @import("dep/ziget/GitRepoStep.zig");

const zigetbuild = @import("dep/ziget/build.zig");
const SslBackend = zigetbuild.SslBackend;

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

    const target = if (b.option([]const u8, "ci_target", "the CI target being built")) |ci_target|
        try std.zig.CrossTarget.parse(.{ .arch_os_abi = ci_target_map.get(ci_target) orelse {
            std.log.err("unknown ci_target '{s}'", .{ci_target});
            std.os.exit(1);
        } })
    else
        b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const zigup_build_options = b.addOptions();
    const win32exelink: ?*std.build.LibExeObjStep = blk: {
        if (target.getOs().tag == .windows) {
            const exe = b.addExecutable(.{
                .name = "win32exelink",
                .root_source_file = .{ .path = "win32exelink.zig" },
                .target = target,
                .optimize = optimize,
            });
            // workaround @embedFile not working with absolute paths, see https://github.com/ziglang/zig/issues/14551
            //zigup_build_options.addOptionFileSource("win32exelink_filename", .{ .generated = &exe.output_path_source });
            const update_step = RelativeOutputPathSourceStep.create(exe);
            zigup_build_options.addOptionFileSource("win32exelink_filename", .{ .generated = &update_step.output_path_source });
            break :blk exe;
        }
        break :blk null;
    };

    // TODO: Maybe add more executables with different ssl backends
    const exe = try addZigupExe(b, ziget_repo, target, optimize, zigup_build_options, win32exelink, .iguana);
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

// This whole step is a workaround to @embedFile not working with absolute paths, see https://github.com/ziglang/zig/issues/14551
const RelativeOutputPathSourceStep = struct {
    step: std.build.Step,
    exe: *std.build.LibExeObjStep,
    output_path_source: std.build.GeneratedFile,
    pub fn create(exe: *std.build.LibExeObjStep) *RelativeOutputPathSourceStep {
        const s = exe.step.owner.allocator.create(RelativeOutputPathSourceStep) catch unreachable;
        s.* = .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "relative output path",
                .owner = exe.step.owner,
                .makeFn = make,
            }),
            .exe = exe,
            .output_path_source = .{
                .step = &s.step,
            },
        };
        s.step.dependOn(&exe.step);
        return s;
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(RelativeOutputPathSourceStep, "step", step);
        const b = self.exe.step.owner;
        //std.log.info("output path is '{s}'", .{self.exe.output_path_source.path.?});
        const abs_path = self.exe.output_path_source.path.?;
        const build_root_path = b.build_root.path orelse @panic("todo");
        std.debug.assert(std.mem.startsWith(u8, abs_path, build_root_path));
        self.output_path_source.path = std.mem.trimLeft(u8, abs_path[build_root_path.len..], "\\/");
    }
};

fn addTest(b: *Builder, exe: *std.build.LibExeObjStep, target: std.zig.CrossTarget, optimize: std.builtin.Mode) void {
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
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    zigup_build_options: *std.build.OptionsStep,
    optional_win32exelink: ?*std.build.LibExeObjStep,
    ssl_backend: ?SslBackend
) !*std.build.LibExeObjStep {
    const require_ssl_backend = b.allocator.create(RequireSslBackendStep) catch unreachable;
    require_ssl_backend.* = RequireSslBackendStep.init(b, "the zigup exe", ssl_backend);

    const exe = b.addExecutable(.{
        .name = "zigup",
        .root_source_file = .{ .path = "zigup.zig" },
        .target = target,
        .optimize = optimize,
    });

    if (optional_win32exelink) |win32exelink| {
        exe.step.dependOn(&win32exelink.step);
    }
    exe.addOptions("build_options", zigup_build_options);

    exe.step.dependOn(&ziget_repo.step);
    zigetbuild.addZigetModule(exe, ssl_backend, ziget_repo.getPath(&exe.step));

    if (targetIsWindows(target)) {
        const zarc_repo = GitRepoStep.create(b, .{
            .url = "https://github.com/marler8997/zarc",
            .branch = "protected",
            .sha = "2e5256624d7871180badc9784b96dd66d927d604",
        });
        exe.step.dependOn(&zarc_repo.step);
        const zarc_repo_path = zarc_repo.getPath(&exe.step);
        const zarc_mod = b.addModule("zarc", .{
            .source_file = .{ .path = b.pathJoin(&.{ zarc_repo_path, "src", "main.zig" }) },
        });
        exe.addModule("zarc", zarc_mod);
    }

    exe.step.dependOn(&require_ssl_backend.step);
    return exe;
}

fn targetIsWindows(target: std.zig.CrossTarget) bool {
    if (target.os_tag) |tag|
        return tag == .windows;
    return builtin.target.os.tag == .windows;
}

const SslBackendFailedStep = struct {
    step: std.build.Step,
    context: []const u8,
    backend: SslBackend,
    pub fn init(b: *Builder, context: []const u8, backend: SslBackend) SslBackendFailedStep {
        return .{
            .step = std.build.Step.init(.custom, "SslBackendFailedStep", b.allocator, make),
            .context = context,
            .backend = backend,
        };
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(RequireSslBackendStep, "step", step);
        std.debug.print("error: the {s} failed to add the {s} SSL backend\n", .{self.context, self.backend});
        std.os.exit(1);
    }
};

const RequireSslBackendStep = struct {
    step: std.build.Step,
    context: []const u8,
    backend: ?SslBackend,
    pub fn init(b: *Builder, context: []const u8, backend: ?SslBackend) RequireSslBackendStep {
        return .{
            .step = std.build.Step.init(.{
                .id = .custom,
                .name = "RequireSslBackend",
                .owner = b,
                .makeFn = make,
            }),
            .context = context,
            .backend = backend,
        };
    }
    fn make(step: *std.build.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(RequireSslBackendStep, "step", step);
        if (self.backend) |_| { } else {
            std.debug.print("error: {s} requires an SSL backend:\n", .{self.context});
            inline for (zigetbuild.ssl_backends) |field| {
                std.debug.print("    -D{s}\n", .{field.name});
            }
            std.os.exit(1);
        }
    }
};

fn addGithubReleaseExe(b: *Builder, github_release_step: *std.build.Step, ziget_repo: []const u8, comptime target_triple: []const u8, comptime ssl_backend: SslBackend) !void {

    const small_release = true;

    const target = try std.zig.CrossTarget.parse(.{ .arch_os_abi = target_triple });
    const mode = if (small_release) .ReleaseSafe else .Debug;
    const exe = try addZigupExe(b, ziget_repo, target, mode, ssl_backend);
    if (small_release) {
       exe.strip = true;
    }
    exe.setOutputDir("github-release" ++ std.fs.path.sep_str ++ target_triple ++ std.fs.path.sep_str ++ @tagName(ssl_backend));
    github_release_step.dependOn(&exe.step);
}

const ci_target_map = std.ComptimeStringMap([]const u8, .{
    .{ "ubuntu-latest-x86_64", "x86_64-linux" },
    .{ "macos-latest-x86_64", "x86_64-macos" },
    .{ "windows-latest-x86_64", "x86_64-windows" },
    .{ "ubuntu-latest-aarch64", "aarch64-linux" },
    .{ "macos-latest-aarch64", "aarch64-macos" },
});
