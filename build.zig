const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub fn build(b: *Builder) !void {
    const ssl_backend: enum { openssl, iguana } = init: {
        const openssl = unwrapOptionalBool(b.option(bool, "openssl", "enable OpenSSL backend"));
        const iguana = unwrapOptionalBool(b.option(bool, "iguana", "enable IguanaTLS backend"));
        if (openssl and iguana) {
            std.log.err("both '-Dopenssl' and '-Diguana' cannot be enabled at the same time", .{});
            std.os.exit(1);
        }
        if (openssl) break :init .openssl;
        if (iguana) break :init .iguana;

        std.log.err("please enable an ssl backend with either '-Dopenssl' or '-Diguana'", .{});
        std.os.exit(1);
    };

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zigup", "zigup.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    //
    // TODO: figure out how to use ziget's build.zig file
    //
    const ziget_repo = try getGitRepo(b.allocator, "https://github.com/marler8997/ziget");
    const ssl_pkg = init: { switch (ssl_backend) {
        .openssl => {
            // these libraries are required for openssl
            exe.linkSystemLibrary("c");
            exe.linkSystemLibrary("ssl");
            exe.linkSystemLibrary("crypto");
            break :init Pkg {
                .name = "ssl",
                .path = try join(b, &[_][]const u8 {ziget_repo, "openssl", "ssl.zig"}),
            };
        },
        .iguana => {
            const iguana_repo = try getGitRepo(b.allocator, "https://github.com/alexnask/iguanaTLS");
            const iguana_index_file = try join(b, &[_][]const u8 {iguana_repo, "src", "main.zig"});
            break :init Pkg {
                .name = "ssl",
                .path = try join(b, &[_][]const u8 {ziget_repo, "iguana", "ssl.zig"}),
                .dependencies = &[_]Pkg {
                    .{ .name = "iguana", .path = iguana_index_file },
                },
            };
        }
    }};
    exe.addPackage(.{
        .name = "ziget",
        .path = try join(b, &[_][]const u8 {ziget_repo, "ziget.zig"}),
        .dependencies = &[_]Pkg { ssl_pkg },
    });
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn join(b: *Builder, parts: []const []const u8) ![]const u8 {
    return try std.fs.path.join(b.allocator, parts);
}

fn getGitRepo(allocator: *std.mem.Allocator, url: []const u8) ![]const u8 {
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
