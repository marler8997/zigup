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
    // TODO: need to implement some interesting logic to make this work without
    //       having the iguana repo copied into this one
    //try addGithubReleaseExe(b, github_release_step, ziget_repo, "x86_64-linux", SslBackend.iguana);

    const target = b.standardTargetOptions(.{});
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
    const exe = try addZigupExe(b, ziget_repo, target, mode, zigup_build_options, win32exelink, zigetbuild.SslBackend.iguana);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

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
    ziget_repo: *GitRepoStep,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
    zigup_build_options: *std.build.OptionsStep,
    optional_win32exelink: ?*std.build.LibExeObjStep,
    ssl_backend: ?SslBackend
) !*std.build.LibExeObjStep {
    const require_ssl_backend = b.allocator.create(RequireSslBackendStep) catch unreachable;
    require_ssl_backend.* = RequireSslBackendStep.init(b, "the zigup exe", ssl_backend);

    const exe = b.addExecutable("zigup", "zigup.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    if (optional_win32exelink) |win32exelink| {
        exe.step.dependOn(&win32exelink.step);
    }
    exe.addOptions("build_options", zigup_build_options);

    exe.step.dependOn(&ziget_repo.step);
    zigetbuild.addZigetPkg(exe, ssl_backend, ziget_repo.getPath(&exe.step));

    if (targetIsWindows(target)) {
        const zarc_repo = GitRepoStep.create(b, .{
            .url = "https://github.com/marler8997/zarc",
            .branch = "protected",
            .sha = "f66a05a50c71e17ee74fa13047f84002fb5cd6a0",
        });
        exe.step.dependOn(&zarc_repo.step);
        const zarc_repo_path = zarc_repo.getPath(&exe.step);
        exe.addPackage(Pkg {
            .name = "zarc",
            .path = .{ .path = try join(b, &[_][]const u8 { zarc_repo_path, "src", "main.zig" }) },
        });
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
            .step = std.build.Step.init(.custom, "RequireSslBackend", b.allocator, make),
            .context = context,
            .backend = backend,
        };
    }
    fn make(step: *std.build.Step) !void {
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

fn join(b: *Builder, parts: []const []const u8) ![]const u8 {
    return try std.fs.path.join(b.allocator, parts);
}
