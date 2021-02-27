const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

const zigetbuild = @import("ziget-build-files-copy/build.zig");
// TODO: use this if/when we get @tryImport
//const SslBackend = if (zigetbuild) zigetbuild.SslBackend else enum {};
const SslBackend = zigetbuild.SslBackend;

fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub fn build(b: *Builder) !void {
    const ziget_repo = try (GitRepo {
        .url = "https://github.com/marler8997/ziget",
        .branch = null,
        .sha = "2b25f39471760e12709ca80daf59c72e5f51a4dd",
    }).resolve(b.allocator);

    // TODO: implement this if/when we get @tryImport
    //if (zigetbuild) |_| { } else {
    //    std.log.err("TODO: add zigetbuild package and recompile/reinvoke build.d", .{});
    //    return;
    //}

    var github_release_step = b.step("github-release", "Build the github-release binaries");
    // TODO: need to implement some interesting logic to make this work without
    //       having the iguana repo copied into this one
    //try addGithubReleaseExe(b, github_release_step, ziget_repo, "x86_64-linux", SslBackend.iguana);

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

    const ziget_ssl_pkg = blk: {
        if (ssl_backend) |backend| {
            break :blk zigetbuild.addSslBackend(exe, backend, ziget_repo) catch |err| {
                const ssl_backend_failed = b.allocator.create(SslBackendFailedStep) catch unreachable;
                ssl_backend_failed.* = SslBackendFailedStep.init(b, "the zigup exe", backend);
                break :blk Pkg {
                    .name = "missing-ssl-backend-files",
                    .path = "missing-ssl-backend-files.zig"
                };
            };
        }
        break :blk Pkg {
            .name = "no-ssl-backend-configured",
            .path = "no-ssl-backend-configured.zig"
        };
    };
    exe.addPackage(Pkg {
        .name = "ziget",
        .path = try join(b, &[_][]const u8 { ziget_repo, "ziget.zig" }),
        .dependencies = &[_]Pkg {ziget_ssl_pkg},
    });
    exe.step.dependOn(&require_ssl_backend.step);
    return exe;
}

const SslBackendFailedStep = struct {
    step: std.build.Step,
    context: []const u8,
    backend: SslBackend,
    pub fn init(b: *Builder, context: []const u8, backend: SslBackend) SslBackendFailedStep {
        return .{
            .step = std.build.Step.init(.Custom, "SslBackendFailedStep", b.allocator, make),
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

pub const GitRepo = struct {
    url: []const u8,
    branch: ?[]const u8,
    sha: []const u8,
    path: ?[]const u8 = null,

    pub fn defaultReposDir(allocator: *std.mem.Allocator) ![]const u8 {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        return try std.fs.path.join(allocator, &[_][]const u8 { cwd, "dep" });
    }

    pub fn resolve(self: GitRepo, allocator: *std.mem.Allocator) ![]const u8 {
        var optional_repos_dir_to_clean: ?[]const u8 = null;
        defer {
            if (optional_repos_dir_to_clean) |p| {
                allocator.free(p);
            }
        }

        const path = if (self.path) |p| try allocator.dupe(u8, p) else blk: {
            const repos_dir = try defaultReposDir(allocator);
            optional_repos_dir_to_clean = repos_dir;
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ repos_dir, std.fs.path.basename(self.url) });
        };
        errdefer self.allocator.free(path);

        std.fs.accessAbsolute(path, std.fs.File.OpenFlags { .read = true }) catch |err| {
            std.debug.print("Error: repository '{s}' does not exist\n", .{path});
            std.debug.print("       Run the following to clone it:\n", .{});
            const branch_args = if (self.branch) |b| &[2][]const u8 {" -b ", b} else &[2][]const u8 {"", ""};
            std.debug.print("       git clone {s}{s}{s} {s} && git -C {3s} checkout {s} -b for_zigup\n",
                .{self.url, branch_args[0], branch_args[1], path, self.sha});
            std.os.exit(1);
        };

        // TODO: check if the SHA matches an print a message and/or warning if it is different

        return path;
    }

    pub fn resolveOneFile(self: GitRepo, allocator: *std.mem.Allocator, index_sub_path: []const u8) ![]const u8 {
        const repo_path = try self.resolve(allocator);
        defer allocator.free(repo_path);
        return try std.fs.path.join(allocator, &[_][]const u8 { repo_path, index_sub_path });
    }
};
