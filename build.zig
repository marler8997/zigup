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

fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub fn build(b: *Builder) void {
    const zigetRepo = "../ziget";
    const iguanaRepo = "../iguanaTLS";

    //
    // TODO: figure out how to use ziget's build.zig file
    //
    const zigetIndexFile = zigetRepo ++ "/ziget.zig";
    const openSslIndexFile = zigetRepo ++ "/openssl/ssl.zig";
    const iguanaSslIndexFile = zigetRepo ++ "/iguana/ssl.zig";
    const iguanaIndexFile = iguanaRepo ++ "/src/main.zig";
    const openssl = unwrapOptionalBool(b.option(bool, "openssl", "enable OpenSSL ssl backend"));
    const iguana = unwrapOptionalBool(b.option(bool, "iguana", "enable IguanaTLS ssl backend")) or !openssl;
    if (openssl and iguana) {
        std.log.err("both '-Dopenssl' and '-Diguana' cannot be enabled at the same time", .{});
        std.os.exit(1);
    }
    const sslIndexFile = if (iguana) iguanaSslIndexFile else openSslIndexFile;
    //const sslIndexFile = zigetRepo ++ "/nossl/ssl.zig";
    if (iguana)
        checkPackage(zigetIndexFile, "https://github.com/marler8997/ziget")
    else
        checkPackage(iguanaIndexFile, "https://github.com/alexnask/iguanaTLS");

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const sslPkg = if (iguana) blk: {
        const iguanaPkg = Pkg { .name= "iguana", .path = iguanaIndexFile };
        break :blk Pkg { .name = "ssl", .path = sslIndexFile, .dependencies = &.{ iguanaPkg } };
    } else  Pkg { .name = "ssl", .path = sslIndexFile};
    
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

