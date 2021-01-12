const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

fn checkPackage(indexFile: []const u8, url: []const u8, ) void {
    std.fs.cwd().access(indexFile, std.fs.File.OpenFlags { .read = true }) catch |err| {
        std.debug.print("Error: library index file '{s}' does not exist\n", .{indexFile});
        std.debug.print("       Run the following to clone it:\n", .{});
        std.debug.print("       git clone {s} {s}\n", .{url, std.fs.path.dirname(indexFile)});
        std.os.exit(1);
    };
}

pub fn build(b: *Builder) void {
    const zigetRepo = "../ziget";

    //
    // TODO: figure out how to use ziget's build.zig file
    //
    const zigetIndexFile = zigetRepo ++ "/ziget.zig";
    const sslIndexFile = zigetRepo ++ "/openssl/ssl.zig";
    //const sslIndexFile = zigetRepo ++ "/nossl/ssl.zig";
    checkPackage(zigetIndexFile, "https://github.com/marler8997/ziget");

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const sslPkg   = Pkg { .name = "ssl", .path = sslIndexFile };
    const zigetPkg = Pkg {
        .name = "ziget",
        .path = zigetIndexFile,
        .dependencies = &[_]Pkg {sslPkg},
    };

    const exe = b.addExecutable("zigup", "zigup.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackage(zigetPkg);

    // these libraries are required for openssl
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");

    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

