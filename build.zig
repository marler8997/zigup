const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

const zigetbuild = @import("zigetbuild.zig");
// TODO: use this if/when we get @tryImport
//const SslBackend = if (zigetbuild) zigetbuild.SslBackend else enum {};
const SslBackend = zigetbuild.SslBackend;

fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub fn build(b: *Builder) !void {
    const ziget_repo = try getGitRepo(b.allocator, "https://github.com/marler8997/ziget");

    // TODO: implement this if/when we get @tryImport
    //if (zigetbuild) |_| { } else {
    //    std.log.err("TODO: add zigetbuild package and recompile/reinvoke build.d", .{});
    //    return;
    //}

    var github_release_step = b.step("github-release", "Build the github-release binaries");
    try addGithubReleaseExe(b, github_release_step, ziget_repo, "x86_64-linux", SslBackend.iguana);

    const ssl_backend = zigetbuild.getSslBackend(b);
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = try addZigupExe(b, ziget_repo, target, mode, ssl_backend);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn addZigupExe(b: *Builder, ziget_repo: []const u8, target: std.zig.CrossTarget, mode: std.builtin.Mode, ssl_backend: ?SslBackend) !*std.build.LibExeObjStep {
    const require_ssl_backend = b.allocator.create(RequireSslBackendStep) catch unreachable;
    require_ssl_backend.* = RequireSslBackendStep.init(b, "the zigup exe", ssl_backend);

    const exe = b.addExecutable("zigup", "zigup.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackage(Pkg {
        .name = "ziget",
        .path = try join(b, &[_][]const u8 { ziget_repo, "ziget.zig" }),
        .dependencies = &[_]Pkg {
            if (ssl_backend) |backend| try zigetbuild.addSslBackend(exe, backend, ziget_repo)
            else Pkg { .name = "no-ssl-backend-configured", .path = "no-ssl-backend-configured.zig" },
        },
    });
    exe.step.dependOn(&require_ssl_backend.step);
    return exe;
}

const RequireSslBackendStep = struct {
    step: std.build.Step,
    context: []const u8,
    backend: ?SslBackend,
    pub fn init(b: *Builder, context: []const u8, backend: ?SslBackend) RequireSslBackendStep {
        return .{
            .step = std.build.Step.init(.Custom, "RequireSslBackend", b.allocator, make),
            .context = context,
            .backend = backend,
        };
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(RequireSslBackendStep, "step", step);
        if (self.backend) |_| { } else {
            std.debug.print("error: {s} requires an SSL backend:\n", .{self.context});
            inline for (zigetbuild.ssl_backends) |field, i| {
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

pub fn getGitRepo(allocator: *std.mem.Allocator, url: []const u8) ![]const u8 {
    const repo_path = init: {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        break :init try std.fs.path.join(allocator,
            &[_][]const u8{ std.fs.path.dirname(cwd).?, std.fs.path.basename(url) }
        );
    };
    errdefer allocator.free(repo_path);

    std.fs.accessAbsolute(repo_path, std.fs.File.OpenFlags { .read = true }) catch |err| {
        std.debug.print("Error: repository '{s}' does not exist\n", .{repo_path});
        std.debug.print("       Run the following to clone it:\n", .{});
        std.debug.print("       git clone {s} {s}\n", .{url, repo_path});
        std.os.exit(1);
    };
    return repo_path;
}
