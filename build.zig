const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const zigup_exe_native = blk: {
        const exe = addZigupExe(b, target, optimize);
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        break :blk exe;
    };

    const test_step = b.step("test", "test the executable");

    addTests(b, target, zigup_exe_native, test_step, .{
        .make_build_steps = true,
    });

    const unzip_step = b.step(
        "unzip",
        "Build/install the unzip cmdline tool",
    );

    {
        const unzip = b.addExecutable(.{
            .name = "unzip",
            .root_source_file = b.path("unzip.zig"),
            .target = target,
            .optimize = optimize,
        });
        const install = b.addInstallArtifact(unzip, .{});
        unzip_step.dependOn(&install.step);
    }

    const zip_step = b.step(
        "zip",
        "Build/install the zip cmdline tool",
    );
    {
        const zip = b.addExecutable(.{
            .name = "zip",
            .root_source_file = b.path("zip.zig"),
            .target = target,
            .optimize = optimize,
        });
        const install = b.addInstallArtifact(zip, .{});
        zip_step.dependOn(&install.step);
    }

    const host_zip_exe = b.addExecutable(.{
        .name = "zip",
        .root_source_file = b.path("zip.zig"),
        .target = b.graph.host,
    });

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    ci_step.dependOn(test_step);
    ci_step.dependOn(unzip_step);
    ci_step.dependOn(zip_step);
    try ci(b, ci_step, host_zip_exe);
}

fn addZigupExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
) *std.Build.Step.Compile {
    const win32exelink_mod: ?*std.Build.Module = blk: {
        if (target.result.os.tag == .windows) {
            const exe = b.addExecutable(.{
                .name = "win32exelink",
                .root_source_file = b.path("win32exelink.zig"),
                .target = target,
                .optimize = optimize,
            });
            break :blk b.createModule(.{
                .root_source_file = exe.getEmittedBin(),
            });
        }
        break :blk null;
    };

    const exe = b.addExecutable(.{
        .name = "zigup",
        .root_source_file = b.path("zigup.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });

    if (target.result.os.tag == .windows) {
        exe.root_module.addImport("win32exelink", win32exelink_mod.?);
    }
    return exe;
}

fn ci(
    b: *std.Build,
    ci_step: *std.Build.Step,
    host_zip_exe: *std.Build.Step.Compile,
) !void {
    const ci_targets = [_][]const u8{
        "aarch64-linux",
        "aarch64-macos",
        "aarch64-windows",
        "arm-linux",
        "powerpc64le-linux",
        "riscv64-linux",
        "s390x-linux",
        "x86-linux",
        "x86-windows",
        "x86_64-linux",
        "x86_64-macos",
        "x86_64-windows",
    };

    const make_archive_step = b.step("archive", "Create CI archives");
    ci_step.dependOn(make_archive_step);

    for (ci_targets) |ci_target_str| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target_str },
        ));
        const optimize: std.builtin.OptimizeMode =
            // Compile in ReleaseSafe on Windows for faster extraction
            if (target.result.os.tag == .windows) .ReleaseSafe else .Debug;
        const zigup_exe = addZigupExe(b, target, optimize);
        const zigup_exe_install = b.addInstallArtifact(zigup_exe, .{
            .dest_dir = .{ .override = .{ .custom = ci_target_str } },
        });
        ci_step.dependOn(&zigup_exe_install.step);

        const target_test_step = b.step(b.fmt("test-{s}", .{ci_target_str}), "");
        addTests(b, target, zigup_exe, target_test_step, .{
            .make_build_steps = false,
            // This doesn't seem to be working, so we're only adding these tests
            // as a dependency if we see the arch is compatible beforehand
            .failing_to_execute_foreign_is_an_error = false,
        });
        const os_compatible = (builtin.os.tag == target.result.os.tag);
        const arch_compatible = (builtin.cpu.arch == target.result.cpu.arch);
        if (os_compatible and arch_compatible) {
            ci_step.dependOn(target_test_step);
        }

        if (builtin.os.tag == .linux) {
            make_archive_step.dependOn(makeCiArchiveStep(b, ci_target_str, target.result, zigup_exe_install, host_zip_exe));
        }
    }
}

fn makeCiArchiveStep(
    b: *std.Build,
    ci_target_str: []const u8,
    target: std.Target,
    exe_install: *std.Build.Step.InstallArtifact,
    host_zip_exe: *std.Build.Step.Compile,
) *std.Build.Step {
    const install_path = b.getInstallPath(.prefix, ".");

    if (target.os.tag == .windows) {
        const out_zip_file = b.pathJoin(&.{
            install_path,
            b.fmt("zigup-{s}.zip", .{ci_target_str}),
        });
        const zip = b.addRunArtifact(host_zip_exe);
        zip.addArg(out_zip_file);
        zip.addArg("zigup.exe");
        zip.cwd = .{ .cwd_relative = b.getInstallPath(
            exe_install.dest_dir.?,
            ".",
        ) };
        zip.step.dependOn(&exe_install.step);
        return &zip.step;
    }

    const targz = b.pathJoin(&.{
        install_path,
        b.fmt("zigup-{s}.tar.gz", .{ci_target_str}),
    });
    const tar = b.addSystemCommand(&.{
        "tar",
        "-czf",
        targz,
        "zigup",
    });
    tar.cwd = .{ .cwd_relative = b.getInstallPath(
        exe_install.dest_dir.?,
        ".",
    ) };
    tar.step.dependOn(&exe_install.step);
    return &tar.step;
}

const SharedTestOptions = struct {
    make_build_steps: bool,
    failing_to_execute_foreign_is_an_error: bool = true,
};
fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    zigup_exe: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    shared_options: SharedTestOptions,
) void {
    const runtest_exe = b.addExecutable(.{
        .name = "runtest",
        .root_source_file = b.path("runtest.zig"),
        .target = target,
    });
    const tests: Tests = .{
        .b = b,
        .test_step = test_step,
        .zigup_exe = zigup_exe,
        .runtest_exe = runtest_exe,
        .shared_options = shared_options,
    };

    tests.addWithClean(.{
        .name = "test-usage-h",
        .argv = &.{"-h"},
        .check = .{ .expect_stderr_match = "Usage" },
    });
    tests.addWithClean(.{
        .name = "test-usage-help",
        .argv = &.{"--help"},
        .check = .{ .expect_stderr_match = "Usage" },
    });

    tests.addWithClean(.{
        .name = "test-fetch-index",
        .argv = &.{"fetch-index"},
        .checks = &.{
            .{ .expect_stdout_match = "master" },
            .{ .expect_stdout_match = "version" },
            .{ .expect_stdout_match = "0.13.0" },
        },
    });

    tests.addWithClean(.{
        .name = "test-invalid-index-url",
        .argv = &.{ "fetch-index", "--index", "this-is-not-a-valid-url" },
        .checks = &.{
            .{ .expect_stderr_match = "error: could not download 'this-is-not-a-valid-url': the URL is invalid (InvalidFormat)" },
        },
    });

    tests.addWithClean(.{
        .name = "test-invalid-index-content",
        .argv = &.{ "fetch-index", "--index", "https://ziglang.org" },
        .checks = &.{
            .{ .expect_stderr_match = "failed to parse JSON content from index url 'https://ziglang.org' with " },
        },
    });

    tests.addWithClean(.{
        .name = "test-get-install-dir",
        .argv = &.{"get-install-dir"},
    });
    tests.addWithClean(.{
        .name = "test-get-install-dir2",
        .argv = &.{ "--install-dir", "/a/fake/install/dir", "get-install-dir" },
        .checks = &.{
            .{ .expect_stdout_exact = "/a/fake/install/dir\n" },
        },
    });
    tests.addWithClean(.{
        .name = "test-set-install-dir-relative",
        .argv = &.{ "set-install-dir", "foo/bar" },
        .checks = &.{
            .{ .expect_stderr_match = "error: set-install-dir requires an absolute path" },
        },
    });

    {
        // just has to be an absolute path that exists
        const install_dir = b.build_root.path.?;
        const with_install_dir = tests.add(.{
            .name = "test-set-install-dir",
            .argv = &.{ "set-install-dir", install_dir },
        });
        tests.addWithClean(.{
            .name = "test-get-install-dir3",
            .argv = &.{"get-install-dir"},
            .env = .{ .dir = with_install_dir },
            .checks = &.{
                .{ .expect_stdout_exact = b.fmt("{s}\n", .{install_dir}) },
            },
        });
        tests.addWithClean(.{
            .name = "test-revert-install-dir",
            .argv = &.{"set-install-dir"},
            .env = .{ .dir = with_install_dir },
        });
    }

    tests.addWithClean(.{
        .name = "test-no-default",
        .argv = &.{"default"},
        .check = .{ .expect_stdout_exact = "<no-default>\n" },
    });
    tests.addWithClean(.{
        .name = "test-default-master-not-fetched",
        .argv = &.{ "default", "master" },
        .check = .{ .expect_stderr_match = "master has not been fetched" },
    });
    tests.addWithClean(.{
        .name = "test-default-0.7.0-not-fetched",
        .argv = &.{ "default", "0.7.0" },
        .check = .{ .expect_stderr_match = "error: compiler '0.7.0' is not installed\n" },
    });

    const non_existent_version = "0.0.99";
    tests.addWithClean(.{
        .name = "test-bad-version",
        .argv = &.{non_existent_version},
        .checks = &.{
            .{ .expect_stderr_match = "error: could not download '" },
        },
    });

    // NOTE: this test will eventually break when these builds are cleaned up,
    //       we should support downloading from bazel and use that instead since
    //       it should be more permanent
    if (false) tests.addWithClean(.{
        .name = "test-dev-version",
        .argv = &.{"0.15.0-dev.621+a63f7875f"},
        .check = .{ .expect_stdout_exact = "" },
    });

    const _7 = tests.add(.{
        .name = "test-7",
        .argv = &.{"0.7.0"},
        .check = .{ .expect_stdout_match = "" },
    });
    tests.addWithClean(.{
        .name = "test-already-fetched-7",
        .env = .{ .dir = _7 },
        .argv = &.{ "fetch", "0.7.0" },
        .check = .{ .expect_stderr_match = "already installed" },
    });
    tests.addWithClean(.{
        .name = "test-get-default-7",
        .env = .{ .dir = _7 },
        .argv = &.{"default"},
        .check = .{ .expect_stdout_exact = "0.7.0\n" },
    });
    tests.addWithClean(.{
        .name = "test-get-default-7-no-path",
        .env = .{ .dir = _7 },
        .add_path = false,
        .argv = &.{ "default", "0.7.0" },
        .check = .{ .expect_stderr_match = " is not in PATH" },
    });

    // verify we print a nice error message if we can't update the symlink
    // because it's a directory
    tests.addWithClean(.{
        .name = "test-get-default-7-path-link-is-directory",
        .env = .{ .dir = _7 },
        .setup_option = "path-link-is-directory",
        .argv = &.{ "default", "0.7.0" },
        .checks = switch (builtin.os.tag) {
            .windows => &.{
                .{ .expect_stderr_match = "unable to create the exe link, the path '" },
                .{ .expect_stderr_match = "' is a directory" },
            },
            else => &.{
                .{ .expect_stderr_match = "unable to update/overwrite the 'zig' PATH symlink, the file '" },
                .{ .expect_stderr_match = "' already exists and is not a symlink" },
            },
        },
    });

    const _7_and_8 = tests.add(.{
        .name = "test-fetch-8",
        .env = .{ .dir = _7 },
        .keep_compilers = "0.8.0",
        .argv = &.{ "fetch", "0.8.0" },
    });
    tests.addWithClean(.{
        .name = "test-get-default-7-after-fetch-8",
        .env = .{ .dir = _7_and_8 },
        .argv = &.{"default"},
        .check = .{ .expect_stdout_exact = "0.7.0\n" },
    });
    tests.addWithClean(.{
        .name = "test-already-fetched-8",
        .env = .{ .dir = _7_and_8 },
        .argv = &.{ "fetch", "0.8.0" },
        .check = .{ .expect_stderr_match = "already installed" },
    });
    const _7_and_default_8 = tests.add(.{
        .name = "test-set-default-8",
        .env = .{ .dir = _7_and_8 },
        .argv = &.{ "default", "0.8.0" },
        .check = .{ .expect_stdout_exact = "" },
    });
    tests.addWithClean(.{
        .name = "test-7-after-default-8",
        .env = .{ .dir = _7_and_default_8 },
        .argv = &.{"0.7.0"},
        .check = .{ .expect_stdout_exact = "" },
    });

    const master_7_and_8 = tests.add(.{
        .name = "test-master",
        .env = .{ .dir = _7_and_8, .with_compilers = "0.8.0" },
        .keep_compilers = "0.8.0",
        .argv = &.{"master"},
        .check = .{ .expect_stdout_exact = "" },
    });
    tests.addWithClean(.{
        .name = "test-already-fetched-master",
        .env = .{ .dir = master_7_and_8 },
        .argv = &.{ "fetch", "master" },
        .check = .{ .expect_stderr_match = "already installed" },
    });

    tests.addWithClean(.{
        .name = "test-default-after-master",
        .env = .{ .dir = master_7_and_8 },
        .argv = &.{"default"},
        // master version could be anything so we won't check
    });
    tests.addWithClean(.{
        .name = "test-default-master",
        .env = .{ .dir = master_7_and_8 },
        .argv = &.{ "default", "master" },
    });
    tests.addWithClean(.{
        .name = "test-default-not-in-path",
        .add_path = false,
        .env = .{ .dir = master_7_and_8 },
        .argv = &.{ "default", "master" },
        .check = .{ .expect_stderr_match = " is not in PATH" },
    });

    // verify that we get an error if there is another compiler in the path
    tests.addWithClean(.{
        .name = "test-default-master-with-another-zig",
        .setup_option = "another-zig",
        .env = .{ .dir = master_7_and_8 },
        .argv = &.{ "default", "master" },
        .checks = &.{
            .{ .expect_stderr_match = "error: zig compiler '" },
            .{ .expect_stderr_match = "' is higher priority in PATH than the path-link '" },
        },
    });

    {
        const default8 = tests.add(.{
            .name = "test-default8-with-another-zig",
            .setup_option = "another-zig",
            .env = .{ .dir = master_7_and_8 },
            .argv = &.{ "default", "0.8.0" },
            .checks = &.{
                .{ .expect_stderr_match = "error: zig compiler '" },
                .{ .expect_stderr_match = "' is higher priority in PATH than the path-link '" },
            },
        });
        // default compiler should still be set
        tests.addWithClean(.{
            .name = "test-default8-even-with-another-zig",
            .env = .{ .dir = default8 },
            .argv = &.{"default"},
            .check = .{ .expect_stdout_exact = "0.8.0\n" },
        });
    }

    tests.addWithClean(.{
        .name = "test-list",
        .env = .{ .dir = master_7_and_8 },
        .argv = &.{"list"},
        .checks = &.{
            .{ .expect_stdout_match = "0.7.0\n" },
            .{ .expect_stdout_match = "0.8.0\n" },
        },
    });

    {
        const default_8 = tests.add(.{
            .name = "test-8-with-master",
            .env = .{ .dir = master_7_and_8 },
            .argv = &.{"0.8.0"},
            .check = .{ .expect_stdout_exact = "" },
        });
        tests.addWithClean(.{
            .name = "test-default-8",
            .env = .{ .dir = default_8 },
            .argv = &.{"default"},
            .check = .{ .expect_stdout_exact = "0.8.0\n" },
        });
    }

    tests.addWithClean(.{
        .name = "test-run-8",
        .env = .{ .dir = master_7_and_8, .with_compilers = "0.8.0" },
        .argv = &.{ "run", "0.8.0", "version" },
        .check = .{ .expect_stdout_match = "0.8.0\n" },
    });
    tests.addWithClean(.{
        .name = "test-run-doesnotexist",
        .env = .{ .dir = master_7_and_8 },
        .argv = &.{ "run", "doesnotexist", "version" },
        .check = .{ .expect_stderr_match = "error: compiler 'doesnotexist' does not exist, fetch it first with: zigup fetch doesnotexist\n" },
    });

    tests.addWithClean(.{
        .name = "test-clean-default-master",
        .env = .{ .dir = master_7_and_8 },
        .argv = &.{"clean"},
        .checks = &.{
            .{ .expect_stderr_match = "keeping '" },
            .{ .expect_stderr_match = "' (is default compiler)\n" },
            .{ .expect_stderr_match = "deleting '" },
            .{ .expect_stderr_match = "0.7.0'\n" },
            .{ .expect_stderr_match = "0.8.0'\n" },
            .{ .expect_stdout_exact = "" },
        },
    });

    {
        const default7 = tests.add(.{
            .name = "test-set-default-7",
            .env = .{ .dir = master_7_and_8 },
            .argv = &.{ "default", "0.7.0" },
            .checks = &.{
                .{ .expect_stdout_exact = "" },
            },
        });
        tests.addWithClean(.{
            .name = "test-clean-default-7",
            .env = .{ .dir = default7 },
            .argv = &.{"clean"},
            .checks = &.{
                .{ .expect_stderr_match = "keeping '" },
                .{ .expect_stderr_match = "' (it is master)\n" },
                .{ .expect_stderr_match = "keeping '0.7.0' (is default compiler)\n" },
                .{ .expect_stderr_match = "deleting '" },
                .{ .expect_stderr_match = "0.8.0'\n" },
                .{ .expect_stdout_exact = "" },
            },
        });
    }

    {
        const keep8 = tests.add(.{
            .name = "test-keep8",
            .env = .{ .dir = master_7_and_8 },
            .argv = &.{ "keep", "0.8.0" },
            .check = .{ .expect_stdout_exact = "" },
        });

        {
            const keep8_default_7 = tests.add(.{
                .name = "test-set-default-7-keep8",
                .env = .{ .dir = keep8 },
                .argv = &.{ "default", "0.7.0" },
                .checks = &.{
                    .{ .expect_stdout_exact = "" },
                },
            });
            tests.addWithClean(.{
                .name = "test-clean-default-7-keep8",
                .env = .{ .dir = keep8_default_7 },
                .argv = &.{"clean"},
                .checks = &.{
                    .{ .expect_stderr_match = "keeping '" },
                    .{ .expect_stderr_match = "' (it is master)\n" },
                    .{ .expect_stderr_match = "keeping '0.7.0' (is default compiler)\n" },
                    .{ .expect_stderr_match = "keeping '0.8.0' (has keep file)\n" },
                    .{ .expect_stdout_exact = "" },
                },
            });
            tests.addWithClean(.{
                .name = "test-clean-master",
                .env = .{ .dir = keep8_default_7 },
                .argv = &.{ "clean", "master" },
                .checks = &.{
                    .{ .expect_stderr_match = "deleting '" },
                    .{ .expect_stderr_match = "master'\n" },
                    .{ .expect_stdout_exact = "" },
                },
            });
        }

        const after_clean = tests.add(.{
            .name = "test-clean-keep8",
            .env = .{ .dir = keep8 },
            .argv = &.{"clean"},
            .checks = &.{
                .{ .expect_stderr_match = "keeping '" },
                .{ .expect_stderr_match = "' (is default compiler)\n" },
                .{ .expect_stderr_match = "keeping '0.8.0' (has keep file)\n" },
                .{ .expect_stderr_match = "deleting '" },
                .{ .expect_stderr_match = "0.7.0'\n" },
            },
        });

        tests.addWithClean(.{
            .name = "test-set-default-7-after-clean",
            .env = .{ .dir = after_clean },
            .argv = &.{ "default", "0.7.0" },
            .checks = &.{
                .{ .expect_stderr_match = "error: compiler '0.7.0' is not installed\n" },
            },
        });

        const default8 = tests.add(.{
            .name = "test-set-default-8-after-clean",
            .env = .{ .dir = after_clean },
            .argv = &.{ "default", "0.8.0" },
            .checks = &.{
                .{ .expect_stdout_exact = "" },
            },
        });

        tests.addWithClean(.{
            .name = "test-clean8-as-default",
            .env = .{ .dir = default8 },
            .argv = &.{ "clean", "0.8.0" },
            .checks = &.{
                .{ .expect_stderr_match = "error: cannot clean '0.8.0' (is default compiler)\n" },
            },
        });

        const after_clean8 = tests.add(.{
            .name = "test-clean8",
            .env = .{ .dir = after_clean },
            .argv = &.{ "clean", "0.8.0" },
            .checks = &.{
                .{ .expect_stderr_match = "deleting '" },
                .{ .expect_stderr_match = "0.8.0'\n" },
                .{ .expect_stdout_exact = "" },
            },
        });
        tests.addWithClean(.{
            .name = "test-clean-after-clean8",
            .env = .{ .dir = after_clean8 },
            .argv = &.{"clean"},
            .checks = &.{
                .{ .expect_stderr_match = "keeping '" },
                .{ .expect_stderr_match = "' (is default compiler)\n" },
                .{ .expect_stdout_exact = "" },
            },
        });
    }
}

const native_exe_ext = builtin.os.tag.exeFileExt(builtin.cpu.arch);

const TestOptions = struct {
    name: []const u8,
    add_path: bool = true,
    env: ?struct { dir: std.Build.LazyPath, with_compilers: []const u8 = "" } = null,
    keep_compilers: []const u8 = "",
    setup_option: []const u8 = "no-extra-setup",
    argv: []const []const u8,
    check: ?std.Build.Step.Run.StdIo.Check = null,
    checks: []const std.Build.Step.Run.StdIo.Check = &.{},
};

const Tests = struct {
    b: *std.Build,
    test_step: *std.Build.Step,
    zigup_exe: *std.Build.Step.Compile,
    runtest_exe: *std.Build.Step.Compile,
    shared_options: SharedTestOptions,

    fn addWithClean(tests: Tests, opt: TestOptions) void {
        _ = tests.addCommon(opt, .yes_clean);
    }
    fn add(tests: Tests, opt: TestOptions) std.Build.LazyPath {
        return tests.addCommon(opt, .no_clean);
    }

    fn compilersArg(arg: []const u8) []const u8 {
        return if (arg.len == 0) "--no-compilers" else arg;
    }

    fn addCommon(tests: Tests, opt: TestOptions, clean_opt: enum { no_clean, yes_clean }) std.Build.LazyPath {
        const b = tests.b;
        const run = std.Build.Step.Run.create(b, b.fmt("run {s}", .{opt.name}));
        run.failing_to_execute_foreign_is_an_error = tests.shared_options.failing_to_execute_foreign_is_an_error;
        run.addArtifactArg(tests.runtest_exe);
        run.addArg(opt.name);
        run.addArg(if (opt.add_path) "--with-path" else "--no-path");
        if (opt.env) |env| {
            run.addDirectoryArg(env.dir);
        } else {
            run.addArg("--no-input-environment");
        }
        run.addArg(compilersArg(if (opt.env) |env| env.with_compilers else ""));
        run.addArg(compilersArg(opt.keep_compilers));
        const out_env = run.addOutputDirectoryArg(opt.name);
        run.addArg(opt.setup_option);
        run.addFileArg(tests.zigup_exe.getEmittedBin());
        run.addArgs(opt.argv);
        if (opt.check) |check| {
            run.addCheck(check);
        }
        for (opt.checks) |check| {
            run.addCheck(check);
        }

        const test_step: *std.Build.Step = switch (clean_opt) {
            .no_clean => &run.step,
            .yes_clean => &CleanDir.create(tests.b, out_env).step,
        };

        if (tests.shared_options.make_build_steps) {
            b.step(opt.name, "").dependOn(test_step);
        }
        tests.test_step.dependOn(test_step);

        return out_env;
    }
};

const CleanDir = struct {
    step: std.Build.Step,
    dir_path: std.Build.LazyPath,
    pub fn create(owner: *std.Build, path: std.Build.LazyPath) *CleanDir {
        const clean_dir = owner.allocator.create(CleanDir) catch @panic("OOM");
        clean_dir.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = owner.fmt("CleanDir {s}", .{path.getDisplayName()}),
                .owner = owner,
                .makeFn = &make,
            }),
            .dir_path = path.dupe(owner),
        };
        path.addStepDependencies(&clean_dir.step);
        return clean_dir;
    }
    fn make(step: *std.Build.Step, opts: std.Build.Step.MakeOptions) !void {
        _ = opts;
        const b = step.owner;
        const clean_dir: *CleanDir = @fieldParentPtr("step", step);
        try b.build_root.handle.deleteTree(clean_dir.dir_path.getPath(b));
    }
};
