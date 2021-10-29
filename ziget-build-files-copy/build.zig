const std = @import("std");
const builtin = @import("builtin");
const Builder = std.build.Builder;
const Pkg = std.build.Pkg;
const GitRepoStep = @import("GitRepoStep.zig");
const loggyrunstep = @import("loggyrunstep.zig");

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const build_all_step = b.step("all", "Build ziget with all the 'enabled' backends");
    const nossl_exe = addExe(b, target, mode, null, build_all_step);
    var ssl_exes: [ssl_backends.len]*std.build.LibExeObjStep = undefined;
    inline for (ssl_backends) |field, i| {
        const enum_value = @field(SslBackend, field.name);
        ssl_exes[i] = addExe(b, target, mode, enum_value, build_all_step);
    }

    const test_all_step = b.step("test", "Run all the 'Enabled' tests");
    addTest(b, test_all_step, "nossl", nossl_exe, null);
    inline for (ssl_backends) |field, i| {
        const enum_value = @field(SslBackend, field.name);
        addTest(b, test_all_step, field.name, ssl_exes[i], enum_value);
    }

    // by default, install zig-iguana
    const default_exe = ssl_exes[@enumToInt(SslBackend.iguana)];
    b.getInstallStep().dependOn(&default_exe.install_step.?.step);
    const run_cmd = default_exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ziget with the iguana backend");
    run_step.dependOn(&run_cmd.step);
}

fn getEnabledByDefault(optional_ssl_backend: ?SslBackend) bool {
    return if (optional_ssl_backend) |backend| switch (backend) {
        .iguana => true,
        .schannel => false, // schannel not supported yet
        .opensslstatic => (
               builtin.os.tag == .linux
            // or builtin.os.tag == .macos (not working yet, I think config is not working)
        ),
        .openssl => (
               builtin.os.tag == .linux
            // or builtin.os.tag == .macos (not working yet, not sure why)
        ),
    } else true;
}

fn addExe(
    b: *Builder,
    target: std.build.Target,
    mode: std.builtin.Mode,
    comptime optional_ssl_backend: ?SslBackend,
    build_all_step: *std.build.Step,
) *std.build.LibExeObjStep {
    const info: struct { name: []const u8, exe_suffix: []const u8 } = if (optional_ssl_backend) |backend| .{
        .name = @tagName(backend),
        .exe_suffix = if (backend == .iguana) "" else ("-" ++ @tagName(backend)),
    } else .{
        .name = "nossl",
        .exe_suffix = "-nossl",
    };

    const exe = b.addExecutable("ziget" ++ info.exe_suffix, "ziget-cmdline.zig");
    exe.setTarget(target);
    exe.single_threaded = true;
    exe.setBuildMode(mode);
    addZigetPkg(exe, optional_ssl_backend, ".");
    const install = b.addInstallArtifact(exe);
    const enabled_by_default = getEnabledByDefault(optional_ssl_backend);
    if (enabled_by_default) {
        build_all_step.dependOn(&install.step);
    }
    const abled_suffix: []const u8 = if (enabled_by_default) "" else " (DISABLED BY DEFAULT)";
    b.step(info.name, b.fmt("Build ziget with the {s} backend{s}", .{
        info.name,
        abled_suffix,
    })).dependOn(
        &install.step
    );
    return exe;
}

fn addTest(
    b: *Builder,
    test_all_step: *std.build.Step,
    comptime backend_name: []const u8,
    exe: *std.build.LibExeObjStep,
    optional_ssl_backend: ?SslBackend,
) void {
    const enabled_by_default = getEnabledByDefault(optional_ssl_backend);
    const abled_suffix: []const u8 = if (enabled_by_default) "" else " (DISABLED BY DEFAULT)";
    const test_backend_step = b.step(
        "test-" ++ backend_name,
        b.fmt("Test the {s} backend{s}", .{backend_name, abled_suffix})
    );
    {
        const run = exe.run();
        run.addArg("http://google.com");
        loggyrunstep.enable(run);
        test_backend_step.dependOn(&run.step);
    }
    if (optional_ssl_backend) |_| {
        {
            const run = exe.run();
            run.addArg("http://ziglang.org"); // NOTE: ziglang.org will redirect to HTTPS
            loggyrunstep.enable(run);
            test_backend_step.dependOn(&run.step);
        }
        {
            const run = exe.run();
            run.addArg("https://ziglang.org");
            loggyrunstep.enable(run);
            test_backend_step.dependOn(&run.step);
        }
    } else {
        const run = exe.run();
        run.addArg("google.com");
        loggyrunstep.enable(run);
        test_backend_step.dependOn(&run.step);
    }
    if (getEnabledByDefault(optional_ssl_backend)) {
        test_all_step.dependOn(test_backend_step);
    }
}

pub const SslBackend = enum {
    openssl,
    opensslstatic,
    iguana,
    schannel,
};
pub const ssl_backends = @typeInfo(SslBackend).Enum.fields;

///! Adds the ziget package to the given lib_exe_obj.
///! This function will add the necessary include directories, libraries, etc to be able to
///! include ziget and it's SSL backend dependencies into the given lib_exe_obj.
pub fn addZigetPkg(
    lib_exe_obj: *std.build.LibExeObjStep,
    optional_ssl_backend: ?SslBackend,
    ziget_repo: []const u8,
) void {
    const b = lib_exe_obj.builder;
    const ziget_index = std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "ziget.zig" }) catch unreachable;
    const ssl_pkg = if (optional_ssl_backend) |backend| addSslBackend(lib_exe_obj, backend, ziget_repo)
        else Pkg{ .name = "ssl", .path = .{ .path = "nossl/ssl.zig" } };
    lib_exe_obj.addPackage(Pkg {
        .name = "ziget",
        .path = .{ .path = ziget_index },
        .dependencies = &[_]Pkg {ssl_pkg},
    });
}

fn addSslBackend(lib_exe_obj: *std.build.LibExeObjStep, backend: SslBackend, ziget_repo: []const u8) Pkg {
    const b = lib_exe_obj.builder;
    switch (backend) {
        .openssl => {
            lib_exe_obj.linkSystemLibrary("c");
            if (builtin.os.tag == .windows) {
                lib_exe_obj.linkSystemLibrary("libcrypto");
                lib_exe_obj.linkSystemLibrary("libssl");
                setupOpensslWindows(lib_exe_obj);
            } else {
                lib_exe_obj.linkSystemLibrary("crypto");
                lib_exe_obj.linkSystemLibrary("ssl");
            }
            return Pkg{
                .name = "ssl",
                .path = .{ .path = std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "openssl", "ssl.zig" }) catch unreachable}
            };
        },
        .opensslstatic => {
            const openssl_repo = GitRepoStep.create(b, .{
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
                lib_exe_obj.step.dependOn(&make_openssl.step);
            }

            const openssl_repo_path_for_step = openssl_repo.getPath(&lib_exe_obj.step);
            lib_exe_obj.addIncludeDir(openssl_repo_path_for_step);
            lib_exe_obj.addIncludeDir(std.fs.path.join(b.allocator, &[_][]const u8 {
                openssl_repo_path_for_step, "include" }) catch unreachable);
            lib_exe_obj.addIncludeDir(std.fs.path.join(b.allocator, &[_][]const u8 {
                openssl_repo_path_for_step, "crypto", "modes" }) catch unreachable);
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
                    lib_exe_obj.addCSourceFile(std.fs.path.join(b.allocator, &[_][]const u8 {
                        openssl_repo_path_for_step, src }) catch unreachable, cflags);
                }
            }
            lib_exe_obj.linkLibC();
            return Pkg{
                .name = "ssl",
                .path = .{ .path = std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "openssl", "ssl.zig" }) catch unreachable},
            };
        },
        .iguana => {
            const iguana_repo = GitRepoStep.create(b, .{
                .url = "https://github.com/marler8997/iguanaTLS",
                .branch = null,
                .sha = "f997c1085470f2414a4bbc50ea170e1da82058ab",
            });
            lib_exe_obj.step.dependOn(&iguana_repo.step);
            const iguana_repo_path = iguana_repo.getPath(&lib_exe_obj.step);
            const iguana_index_file = std.fs.path.join(b.allocator, &[_][]const u8 {iguana_repo_path, "src", "main.zig"}) catch unreachable;
            return b.dupePkg(Pkg{
                .name = "ssl",
                .path = .{ .path = std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "iguana", "ssl.zig" }) catch unreachable },
                .dependencies = &[_]Pkg {
                    .{ .name = "iguana", .path = .{ .path = iguana_index_file } },
                },
            });
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
                lib_exe_obj.step.dependOn(&msspi_repo.step);
                const msspi_repo_path = msspi_repo.getPath(&lib_exe_obj.step);

                const msspi_src_dir = std.fs.path.join(b.allocator, &[_][]const u8 { msspi_repo_path, "src" }) catch unreachable;
                const msspi_main_cpp = std.fs.path.join(b.allocator, &[_][]const u8 { msspi_src_dir, "msspi.cpp" }) catch unreachable;
                const msspi_third_party_include = std.fs.path.join(b.allocator, &[_][]const u8 { msspi_repo_path, "third_party", "cprocsp", "include" }) catch unreachable;
                lib_exe_obj.addCSourceFile(msspi_main_cpp, &[_][]const u8 { });
                lib_exe_obj.addIncludeDir(msspi_src_dir);
                lib_exe_obj.addIncludeDir(msspi_third_party_include);
                lib_exe_obj.linkLibC();
                lib_exe_obj.linkSystemLibrary("ws2_32");
                lib_exe_obj.linkSystemLibrary("crypt32");
                lib_exe_obj.linkSystemLibrary("advapi32");
            }
            // TODO: this will be needed if/when msspi is ported to Zig
            //const zigwin32_index_file = try getGitRepoFile(b.allocator,
            //    "https://github.com/marlersoft/zigwin32",
            //    "src" ++ std.fs.path.sep_str ++ "win32.zig");
            return b.dupePkg(.{
                .name = "ssl",
                .path = .{ .path = std.fs.path.join(b.allocator, &[_][]const u8 { ziget_repo, "schannel", "ssl.zig" }) catch unreachable },
                //.dependencies = &[_]Pkg {
                //    .{ .name = "win32", .path = .{ .path = zigwin32_index_file } },
                //},
            });
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

pub fn setupOpensslWindows(lib_exe_obj: *std.build.LibExeObjStep) void {
    const b = lib_exe_obj.builder;

    const openssl_path = global_openssl_path_option.get(b) orelse {
        lib_exe_obj.step.dependOn(&FailStep.create(b, "missing openssl-path",
            "-Dopenssl on windows requires -Dopenssl-path=DIR to be specified").step);
        return;
    };
    // NOTE: right now these files are hardcoded to the files expected when installing SSL via
    //       this web page: https://slproweb.com/products/Win32OpenSSL.html and installed using
    //       this exe installer: https://slproweb.com/download/Win64OpenSSL-1_1_1g.exe
    lib_exe_obj.addIncludeDir(std.fs.path.join(b.allocator, &[_][]const u8 {openssl_path, "include"}) catch unreachable);
    lib_exe_obj.addLibPath(std.fs.path.join(b.allocator, &[_][]const u8 {openssl_path, "lib"}) catch unreachable);
    // install dlls to the same directory as executable
    for ([_][]const u8 {"libcrypto-1_1-x64.dll", "libssl-1_1-x64.dll"}) |dll| {
        lib_exe_obj.step.dependOn(
            &b.addInstallFileWithDir(
                .{ .path = std.fs.path.join(b.allocator, &[_][]const u8 {openssl_path, dll}) catch unreachable },
                .bin,
                dll,
            ).step
        );
    }
}

const FailStep = struct {
    step: std.build.Step,
    fail_msg: []const u8,
    pub fn create(b: *Builder, name: []const u8, fail_msg: []const u8) *FailStep {
        var result = b.allocator.create(FailStep) catch unreachable;
        result.* = .{
            .step = std.build.Step.init(.custom, name, b.allocator, make),
            .fail_msg = fail_msg,
        };
        return result;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(FailStep, "step", step);
        std.log.err("{s}", .{self.fail_msg});
        std.os.exit(0xff);
    }
};
