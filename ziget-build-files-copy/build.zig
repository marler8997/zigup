const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;
const GitRepoStep = @import("GitRepoStep.zig");
const loggyrunstep = @import("loggyrunstep.zig");

pub fn build(b: *Builder) !void {
    // ensure we always support -Dfetch regardless of backend
    _ = GitRepoStep.defaultFetchOption(b);

    const optional_ssl_backend = getSslBackend(b);

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("ziget", "ziget-cmdline.zig");
    exe.setTarget(target);
    exe.single_threaded = true;
    exe.setBuildMode(mode);
    exe.addPackage(
        if (optional_ssl_backend) |ssl_backend| try addSslBackend(exe, ssl_backend, ".")
        else Pkg { .name = "ssl", .path = .{ .path = "nossl/ssl.zig" } }
    );
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    addTests(b);
}

fn addTests(b: *Builder) void {
    const test_step = b.step("test", "Run all the 'Enabled' tests");
    inline for (ssl_backends) |field| {
        const enum_value = @field(SslBackend, field.name);
        const enabled_by_default = switch (enum_value) {
            .iguana => true,
            .wolfssl => false, // wolfssl not supported yet
            .schannel => false, // schannel not supported yet
            .opensslstatic => (
                   builtin.os.tag == .linux
                // or builtin.os.tag == .macos (not working yet, I think config is not working)
            ),
            .openssl => (
                   builtin.os.tag == .linux
                // or builtin.os.tag == .macos (not working yet, not sure why)
            ),
        };
        addTest(b, test_step, field.name, enabled_by_default);
    }
    addTest(b, test_step, "nossl", true);
}

fn addTest(
    b: *Builder,
    default_test_step: *std.build.Step,
    comptime backend_name: []const u8,
    enabled_by_default: bool,
) void {
    const prefix = b.pathFromRoot("zig-out" ++ std.fs.path.sep_str ++ backend_name);
    const nossl = std.mem.eql(u8, backend_name, "nossl");
    const build_backend = b.addSystemCommand(&[_][]const u8 {
        b.zig_exe,
        "build",
        "--prefix",
        prefix,
    });
    if (!nossl) {
        build_backend.addArg("-D" ++ backend_name);
    }
    if (GitRepoStep.defaultFetchOption(b)) {
        build_backend.addArg("-Dfetch");
    }
    loggyrunstep.enable(build_backend);

    const ziget_exe_basename = if (builtin.os.tag == .windows) "ziget.exe" else "ziget";
    const ziget_exe = std.fs.path.join(b.allocator, &[_][]const u8 { prefix, "bin", ziget_exe_basename }) catch unreachable;

    const test_backend_step = b.step("test-" ++ backend_name, "Test the " ++ backend_name ++ " backend");
    if (nossl) {
        const test_google = b.addSystemCommand(&[_][]const u8 {
            ziget_exe,
            "google.com",
        });
        loggyrunstep.enable(test_google);
        test_google.step.dependOn(&build_backend.step);
        test_backend_step.dependOn(&test_google.step);
    }
    {
        const test_google = b.addSystemCommand(&[_][]const u8 {
            ziget_exe,
            "http://google.com",
        });
        loggyrunstep.enable(test_google);
        test_google.step.dependOn(&build_backend.step);
        test_backend_step.dependOn(&test_google.step);
    }

    if (!nossl) {
        {
            const test_ziglang = b.addSystemCommand(&[_][]const u8 {
                ziget_exe,
                "http://ziglang.org", // NOTE: ziglang.org will redirect to HTTPS
            });
            loggyrunstep.enable(test_ziglang);
            test_ziglang.step.dependOn(&build_backend.step);
            test_backend_step.dependOn(&test_ziglang.step);
        }
        {
            const test_ziglang = b.addSystemCommand(&[_][]const u8 {
                ziget_exe,
                "https://ziglang.org",
            });
            loggyrunstep.enable(test_ziglang);
            test_ziglang.step.dependOn(&build_backend.step);
            test_backend_step.dependOn(&test_ziglang.step);
        }
    }
    if (enabled_by_default) {
        default_test_step.dependOn(test_backend_step);
    }
}

pub fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub const SslBackend = enum {
    openssl,
    opensslstatic,
    wolfssl,
    iguana,
    schannel,
};
pub const ssl_backends = @typeInfo(SslBackend).Enum.fields;

pub fn getSslBackend(b: *Builder) ?SslBackend {

    var backend: ?SslBackend = null;

    var backend_infos : [ssl_backends.len]struct {
        enabled: bool,
        name: []const u8,
    } = undefined;
    var backend_enabled_count: u32 = 0;
    inline for (ssl_backends) |field, i| {
        const enabled = unwrapOptionalBool(b.option(bool, field.name, "enable ssl backend: " ++ field.name));
        if (enabled) {
            backend = @field(SslBackend, field.name);
            backend_enabled_count += 1;
        }
        backend_infos[i] = .{
            .enabled = enabled,
            .name = field.name,
        };
    }
    if (backend_enabled_count > 1) {
        std.log.err("only one ssl backend may be enabled, can't provide these options at the same time:", .{});
        for (backend_infos) |info| {
            if (info.enabled) {
                std.log.err("    -D{s}", .{info.name});
            }
        }
        std.os.exit(1);
    }
    return backend;
}

//
// NOTE: the ziget_repo argument is here so this function can be used by other projects, not just this repo
//
pub fn addSslBackend(step: *std.build.LibExeObjStep, backend: SslBackend, ziget_repo: []const u8) !Pkg {
    const b = step.builder;
    switch (backend) {
        .openssl => {
            step.linkSystemLibrary("c");
            if (builtin.os.tag == .windows) {
                step.linkSystemLibrary("libcrypto");
                step.linkSystemLibrary("libssl");
                try setupOpensslWindows(step);
            } else {
                step.linkSystemLibrary("crypto");
                step.linkSystemLibrary("ssl");
            }
            return Pkg {
                .name = "ssl",
                .path = .{ .path = try std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "openssl/ssl.zig" }) },
            };
        },
        .opensslstatic => {
            const openssl_repo = GitRepoStep.create(step.builder, .{
                .url = "https://github.com/openssl/openssl",
                .branch = "OpenSSL_1_1_1j",
                .sha = "52c587d60be67c337364b830dd3fdc15404a2f04",
            });

            // TODO: should we implement something to cache the configuration?
            //       can the configure output be in a different directory?
            {
                const configure_openssl = std.build.RunStep.create(b, "configure openssl");
                configure_openssl.step.dependOn(&openssl_repo.step);
                configure_openssl.cwd = openssl_repo.getPath(&configure_openssl.step);
                configure_openssl.addArgs(&[_][]const u8 {
                    "./config",
                    // just a temporary path for now
                    //"--openssl",
                    //"/tmp/ziget-openssl-static-dir1",
                    "-static",
                    // just disable everything for now
                    "no-threads",
                    "no-shared",
                    "no-asm",
                    "no-sse2",
                    "no-aria",
                    "no-bf",
                    "no-camellia",
                    "no-cast",
                    "no-des",
                    "no-dh",
                    "no-dsa",
                    "no-ec",
                    "no-idea",
                    "no-md2",
                    "no-mdc2",
                    "no-rc2",
                    "no-rc4",
                    "no-rc5",
                    "no-seed",
                    "no-sm2",
                    "no-sm3",
                    "no-sm4",
                });
                configure_openssl.stdout_action = .{
                    .expect_matches = &[_][]const u8 { "OpenSSL has been successfully configured" },
                };
                const make_openssl = std.build.RunStep.create(b, "configure openssl");
                make_openssl.cwd = configure_openssl.cwd;
                make_openssl.addArgs(&[_][]const u8 {
                    "make",
                    "include/openssl/opensslconf.h",
                    "include/crypto/bn_conf.h",
                    "include/crypto/dso_conf.h",
                });
                make_openssl.step.dependOn(&configure_openssl.step);
                step.step.dependOn(&make_openssl.step);
            }

            const openssl_repo_path_for_step = openssl_repo.getPath(&step.step);
            step.addIncludeDir(openssl_repo_path_for_step);
            step.addIncludeDir(try std.fs.path.join(b.allocator, &[_][]const u8 {
                openssl_repo_path_for_step, "include" }));
            step.addIncludeDir(try std.fs.path.join(b.allocator, &[_][]const u8 {
                openssl_repo_path_for_step, "crypto", "modes" }));
            const cflags = &[_][]const u8 {
                "-Wall",
                // TODO: is this the right way to do this? is it a config option?
                "-DOPENSSL_NO_ENGINE",
                // TODO: --openssldir doesn't seem to be setting this?
                "-DOPENSSLDIR=\"/tmp/ziget-openssl-static-dir2\"",
            };
            {
                const sources = @embedFile("openssl/sources");
                var source_lines = std.mem.split(u8, sources, "\n");
                while (source_lines.next()) |src| {
                    if (src.len == 0 or src[0] == '#') continue;
                    step.addCSourceFile(try std.fs.path.join(b.allocator, &[_][]const u8 {
                        openssl_repo_path_for_step, src }), cflags);
                }
            }
            step.linkLibC();
            return Pkg {
                .name = "ssl",
                .path = .{ .path = try std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "openssl/ssl.zig" }) },
            };
        },
        .wolfssl => {
            std.log.err("-Dwolfssl is not implemented", .{});
            std.os.exit(1);
        },
        .iguana => {
            const iguana_repo = GitRepoStep.create(b, .{
                .url = "https://github.com/marler8997/iguanaTLS",
                .branch = null,
                .sha = "f997c1085470f2414a4bbc50ea170e1da82058ab",
            });
            step.step.dependOn(&iguana_repo.step);
            const iguana_repo_path = iguana_repo.getPath(&step.step);
            const iguana_index_file = try std.fs.path.join(b.allocator, &[_][]const u8 {iguana_repo_path, "src", "main.zig"});
            var p = Pkg {
                .name = "ssl",
                .path = .{ .path = try std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "iguana", "ssl.zig" }) },
                .dependencies = &[_]Pkg {
                    .{ .name = "iguana", .path = .{ .path = iguana_index_file } },
                },
            };
            // NOTE: I don't know why I need to call dupePkg, I think this is a bug
            return b.dupePkg(p);
        },
        .schannel => {
            {
                // NOTE: for now I'm using msspi from https://github.com/deemru/msspi
                //       I'll probably port this to Zig at some point
                //       Once I do remove this build config
                // NOTE: I tested using this commit: 7338760a4a2c6fb80c47b24a2abba32d5fc40635 tagged at version 0.1.42
                const msspi_repo = GitRepoStep.create(b, .{
                    .url = "https://github.com/deemru/msspi",
                    .branch = "0.1.42",
                    .sha = "7338760a4a2c6fb80c47b24a2abba32d5fc40635"
                });
                step.step.dependOn(&msspi_repo.step);
                const msspi_repo_path = msspi_repo.getPath(&step.step);

                const msspi_src_dir = try std.fs.path.join(b.allocator, &[_][]const u8 { msspi_repo_path, "src" });
                const msspi_main_cpp = try std.fs.path.join(b.allocator, &[_][]const u8 { msspi_src_dir, "msspi.cpp" });
                const msspi_third_party_include = try std.fs.path.join(b.allocator, &[_][]const u8 { msspi_repo_path, "third_party", "cprocsp", "include" });
                step.addCSourceFile(msspi_main_cpp, &[_][]const u8 { });
                step.addIncludeDir(msspi_src_dir);
                step.addIncludeDir(msspi_third_party_include);
                step.linkLibC();
                step.linkSystemLibrary("ws2_32");
                step.linkSystemLibrary("crypt32");
                step.linkSystemLibrary("advapi32");
            }
            // TODO: this will be needed if/when msspi is ported to Zig
            //const zigwin32_index_file = try getGitRepoFile(b.allocator,
            //    "https://github.com/marlersoft/zigwin32",
            //    "src" ++ std.fs.path.sep_str ++ "win32.zig");
            return Pkg {
                .name = "ssl",
                .path = .{ .path = try std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "schannel", "ssl.zig" }) },
                //.dependencies = &[_]Pkg {
                //    .{ .name = "win32", .path = .{ .path = zigwin32_index_file } },
                //},
            };
        }
    }
}

const OpensslPathOption = struct {
    // NOTE: I can't use ??[]const u8 because it exposes a bug in the compiler
    is_cached: bool = false,
    cached: ?[]const u8 = undefined,
    fn get(self: *OpensslPathOption, b: *std.build.Builder) ?[]const u8 {
        if (!self.is_cached) {
            self.cached = b.option(
                []const u8,
                "openssl-path",
                "path to openssl (for Windows)",
            );
            self.is_cached = true;
        }
        std.debug.assert(self.is_cached);
        return self.cached;
    }
};
var global_openssl_path_option = OpensslPathOption { };

pub fn setupOpensslWindows(step: *std.build.LibExeObjStep) !void {
    const b = step.builder;

    const openssl_path = global_openssl_path_option.get(b) orelse {
        std.debug.print("Error: -Dopenssl on windows requires -Dopenssl-path=DIR to be specified\n", .{});
        std.os.exit(1);
    };
    // NOTE: right now these files are hardcoded to the files expected when installing SSL via
    //       this web page: https://slproweb.com/products/Win32OpenSSL.html and installed using
    //       this exe installer: https://slproweb.com/download/Win64OpenSSL-1_1_1g.exe
    step.addIncludeDir(try std.fs.path.join(b.allocator, &[_][]const u8 {openssl_path, "include"}));
    step.addLibPath(try std.fs.path.join(b.allocator, &[_][]const u8 {openssl_path, "lib"}));
    // install dlls to the same directory as executable
    for ([_][]const u8 {"libcrypto-1_1-x64.dll", "libssl-1_1-x64.dll"}) |dll| {
        step.step.dependOn(
            &b.addInstallFileWithDir(
                .{ .path = try std.fs.path.join(b.allocator, &[_][]const u8 {openssl_path, dll}) },
                .bin,
                dll,
            ).step
        );
    }
}
