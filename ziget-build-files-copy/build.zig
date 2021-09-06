const std = @import("std");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;

pub fn build(b: *Builder) !void {
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

    addTests(b, target, mode);
}

fn addTests(b: *Builder, target: std.zig.CrossTarget, mode: std.builtin.Mode) void {
    const test_exe = b.addExecutable("test", "test.zig");
    test_exe.setTarget(target);
    test_exe.setBuildMode(mode);

    const test_step = b.step("test", "Run all the 'Enabled' tests");
    inline for (ssl_backends) |field| {
        const enum_value = @field(SslBackend, field.name);
        const enabled_by_default =
            if (enum_value == .wolfssl) false
            else if (enum_value == .schannel and std.builtin.os.tag != .windows) false
            else true;
        addTest(test_step, test_exe, field.name, enabled_by_default);
    }
    addTest(test_step, test_exe, "nossl", true);
}

fn addTest(test_step: *std.build.Step, test_exe: *std.build.LibExeObjStep, comptime backend_name: []const u8, comptime enabled_by_default: bool) void {
    const b = test_exe.builder;
    const run_cmd = test_exe.run();
    run_cmd.addArg(backend_name);
    run_cmd.step.dependOn(b.getInstallStep());

    const enabled_prefix = if (enabled_by_default) "Enabled " else "Disabled";
    const test_backend_step = b.step("test-" ++ backend_name,
        enabled_prefix ++ ": test ziget with the '" ++ backend_name ++ "' ssl backend");
    test_backend_step.dependOn(&run_cmd.step);

    if (enabled_by_default) {
        test_step.dependOn(&run_cmd.step);
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
            if (std.builtin.os.tag == .windows) {
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
            const openssl_repo = try (GitRepo {
                .url = "https://github.com/openssl/openssl",
                .branch = "OpenSSL_1_1_1j",
                .sha = "52c587d60be67c337364b830dd3fdc15404a2f04",
            }).resolve(b.allocator);

            // TODO: should we implement something to cache the configuration?
            //       can the configure output be in a different directory?
            {
                const configure_openssl = std.build.RunStep.create(b, "configure openssl");
                configure_openssl.cwd = openssl_repo;
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
                make_openssl.cwd = openssl_repo;
                make_openssl.addArgs(&[_][]const u8 {
                    "make",
                    "include/openssl/opensslconf.h",
                    "include/crypto/bn_conf.h",
                    "include/crypto/dso_conf.h",
                });
                make_openssl.step.dependOn(&configure_openssl.step);
                step.step.dependOn(&make_openssl.step);
            }
            step.addIncludeDir(openssl_repo);
            step.addIncludeDir(try std.fs.path.join(b.allocator, &[_][]const u8 { openssl_repo, "include" }));
            step.addIncludeDir(try std.fs.path.join(b.allocator, &[_][]const u8 { openssl_repo, "crypto", "modes" }));
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
                    step.addCSourceFile(try std.fs.path.join(b.allocator, &[_][]const u8 { openssl_repo, src }), cflags);
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
            const iguana_index_file = try (GitRepo {
                .url = "https://github.com/marler8997/iguanaTLS",
                .branch = null,
                .sha = @embedFile("iguanasha"),
            }).resolveOneFile(b.allocator, "src" ++ std.fs.path.sep_str ++ "main.zig");
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
                const msspi_repo = try (GitRepo {
                    .url = "https://github.com/deemru/msspi",
                    .branch = "0.1.42",
                    .sha = "7338760a4a2c6fb80c47b24a2abba32d5fc40635"
                }).resolve(b.allocator);
                const msspi_src_dir = try std.fs.path.join(b.allocator, &[_][]const u8 { msspi_repo, "src" });
                const msspi_main_cpp = try std.fs.path.join(b.allocator, &[_][]const u8 { msspi_src_dir, "msspi.cpp" });
                const msspi_third_party_include = try std.fs.path.join(b.allocator, &[_][]const u8 { msspi_repo, "third_party", "cprocsp", "include" });
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

pub fn setupOpensslWindows(step: *std.build.LibExeObjStep) !void {
    const b = step.builder;
    const openssl_path = b.option([]const u8, "openssl-path", "path to openssl (for Windows)") orelse {
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
        errdefer allocator.free(path);

        std.fs.accessAbsolute(path, std.fs.File.OpenFlags { .read = true }) catch {
            std.debug.print("Error: repository '{s}' does not exist\n", .{path});
            std.debug.print("       Run the following to clone it:\n", .{});
            const branch_args = if (self.branch) |b| &[2][]const u8 {" -b ", b} else &[2][]const u8 {"", ""};
            std.debug.print("       git clone {s}{s}{s} {s} && git -C {3s} checkout {s} -b for_ziget\n",
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
