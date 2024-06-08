const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const sep = std.fs.path.sep_str;
const path_env_sep = if (builtin.os.tag == .windows) ";" else ":";

const fixdeletetree = @import("fixdeletetree.zig");

var child_env_map: std.process.EnvMap = undefined;
var path_env_ptr: *[]const u8 = undefined;
fn setPathEnv(new_path: []const u8) void {
    path_env_ptr.* = new_path;
    std.log.info("PATH={s}", .{new_path});
}

// For some odd reason, the "zig version" output is different on macos
const expected_zig_version_0_7_0 = if (builtin.os.tag == .macos) "0.7.0+9af53f8e0" else "0.7.0";

pub fn main() !u8 {
    var allocator_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    //defer allocator_instance.deinit();
    const allocator = allocator_instance.allocator();

    const all_cmdline_args = try std.process.argsAlloc(allocator);
    if (all_cmdline_args.len <= 1) {
        try std.io.getStdErr().writer().print("Usage: test ZIGUP_EXE TEST_DIR\n", .{});
        return 0xff;
    }
    const cmdline_args = all_cmdline_args[1..];
    if (cmdline_args.len != 2) {
        std.log.err("expected 1 cmdline arg but got {}", .{cmdline_args.len});
        return 0xff;
    }

    const zigup_src_exe = cmdline_args[0];
    const test_dir = cmdline_args[1];
    std.log.info("run zigup tests", .{});
    std.log.info("zigup exe '{s}'", .{zigup_src_exe});
    std.log.info("test directory '{s}'", .{test_dir});

    if (!std.fs.path.isAbsolute(test_dir)) {
        std.log.err("currently the test requires an absolute test directory path", .{});
        return 0xff;
    }

    try fixdeletetree.deleteTree(std.fs.cwd(), test_dir);
    try std.fs.cwd().makePath(test_dir);
    const bin_dir = try std.fs.path.join(allocator, &.{ test_dir, "bin" });
    try std.fs.cwd().makeDir(bin_dir);
    const install_sub_path = if (builtin.os.tag == .windows) "bin\\zig" else "install";
    const install_dir = try std.fs.path.join(allocator, &.{test_dir, install_sub_path });
    try std.fs.cwd().makeDir(install_dir);

    const zigup = try std.fs.path.join(allocator, &.{
        test_dir,
        "bin",
        "zigup" ++ comptime builtin.target.exeFileExt()
    });
    try std.fs.cwd().copyFile(
        zigup_src_exe,
        std.fs.cwd(),
        zigup,
        .{},
    );
    if (builtin.os.tag == .windows) {
        const zigup_src_pdb = try std.mem.concat(
            allocator, u8, &.{ zigup_src_exe[0 .. zigup_src_exe.len-4], ".pdb" }
        );
        defer allocator.free(zigup_src_pdb);
        const zigup_pdb = try std.fs.path.join(allocator, &.{ test_dir, "bin\\zigup.pdb" });
        defer allocator.free(zigup_pdb);
        try std.fs.cwd().copyFile(zigup_src_pdb, std.fs.cwd(), zigup_pdb, .{});
    }

    const install_args = if (builtin.os.tag == .windows) [_][]const u8{
    } else [_][]const u8{
        "--install-dir", install_dir,
    };
    const zigup_args = &[_][]const u8{zigup} ++ install_args;

    const path_link = try std.fs.path.join(allocator, &.{ bin_dir, comptime "zig" ++ builtin.target.exeFileExt() });
    defer allocator.free(path_link);

    // add our scratch/bin directory to PATH
    child_env_map = try std.process.getEnvMap(allocator);
    path_env_ptr = child_env_map.getPtr("PATH") orelse {
        std.log.err("the PATH environment variable does not exist?", .{});
        return 1;
    };

    const original_path_env = path_env_ptr.*;
    setPathEnv(try std.mem.concat(allocator, u8, &.{ bin_dir, path_env_sep, original_path_env }));

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "default", "master" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "master has not been fetched"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"-h"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Usage"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"--help"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Usage"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"default"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.eql(u8, result.stdout, "<no-default>\n"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"fetch-index"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "master"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "default", "0.7.0" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        dumpExecResult(result);
        switch (result.term) {
            .Exited => |code| try testing.expectEqual(@as(u8, 1), code),
            else => |term| std.debug.panic("unexpected exit {}", .{term}),
        }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "error: compiler '0.7.0' is not installed\n"));
    }
    try runNoCapture(zigup_args ++ &[_][]const u8{"0.7.0"});
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"default"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try passOrDumpAndThrow(result);
        dumpExecResult(result);
        try testing.expect(std.mem.eql(u8, result.stdout, "0.7.0\n"));
    }

    // verify we print a nice error message if we can't update the symlink
    // because it's a directory
    {
        const zig_exe_link = try std.fs.path.join(allocator, &.{ bin_dir, "zig" ++ comptime builtin.target.exeFileExt() });
        defer allocator.free(zig_exe_link);

        if (std.fs.cwd().access(zig_exe_link, .{})) {
            try std.fs.cwd().deleteFile(zig_exe_link);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        try std.fs.cwd().makeDir(zig_exe_link);

        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "default", "0.7.0" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        dumpExecResult(result);
        switch (result.term) {
            .Exited => |code| try testing.expectEqual(@as(u8, 1), code),
            else => |term| std.debug.panic("unexpected exit {}", .{term}),
        }
        if (builtin.os.tag == .windows) {
            try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "unable to create the exe link, the path '"));
            try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "' is a directory"));
        } else {
            try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "unable to update/overwrite the 'zig' PATH symlink, the file '"));
            try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "' already exists and is not a symlink"));
        }

        try std.fs.cwd().deleteDir(zig_exe_link);
    }

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "fetch", "0.7.0" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "already installed"));
    }
    try runNoCapture(zigup_args ++ &[_][]const u8{"master"});
    try runNoCapture(zigup_args ++ &[_][]const u8{"0.8.0"});
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"default"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try passOrDumpAndThrow(result);
        dumpExecResult(result);
        try testing.expect(std.mem.eql(u8, result.stdout, "0.8.0\n"));
    }
    {
        const save_path_env = path_env_ptr.*;
        defer setPathEnv(save_path_env);
        setPathEnv("");
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "default", "master" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, " is not in PATH"));
    }
    try runNoCapture(zigup_args ++ &[_][]const u8{ "default", "master" });
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"list"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "0.7.0"));
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "0.8.0"));
    }
    try runNoCapture(zigup_args ++ &[_][]const u8{ "default", "0.7.0" });
    try testing.expectEqual(@as(u32, 3), try getCompilerCount(install_dir));
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "run", "0.8.0", "version" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try testing.expectEqualSlices(u8, "0.8.0\n", result.stdout);
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "run", "doesnotexist", "version" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try testing.expectEqualSlices(u8, "error: compiler 'doesnotexist' does not exist, fetch it first with: zigup fetch doesnotexist\n", result.stderr);
    }
    try runNoCapture(zigup_args ++ &[_][]const u8{ "keep", "0.8.0" });
    // doesn't delete anything because we have keepfile and master doens't get deleted
    try runNoCapture(zigup_args ++ &[_][]const u8{"clean"});
    try testing.expectEqual(@as(u32, 3), try getCompilerCount(install_dir));

    // Just make a directory to trick zigup into thinking there is another compiler so we don't have to wait for it to download/install
    try makeDir(test_dir, install_sub_path ++ sep ++ "0.9.0");
    try testing.expectEqual(@as(u32, 4), try getCompilerCount(install_dir));
    try runNoCapture(zigup_args ++ &[_][]const u8{"clean"});
    try testing.expectEqual(@as(u32, 3), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "clean", "0.8.0" });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "deleting "));
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "0.8.0"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"clean"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "it is master"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    try runNoCapture(zigup_args ++ &[_][]const u8{"master"});
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{"DOESNOTEXST"});
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "download"));
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "failed"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    // verify that we get an error if there is another compiler in the path
    {
        const bin2_dir = try std.fs.path.join(allocator, &.{ test_dir, "bin2" });
        defer allocator.free(bin2_dir);
        try std.fs.cwd().makeDir(bin2_dir);

        const previous_path = path_env_ptr.*;

        {
            const fake_zig = try std.fs.path.join(allocator, &.{
                bin2_dir,
                "zig" ++ comptime builtin.target.exeFileExt()
            });
            defer allocator.free(fake_zig);
            var file = try std.fs.cwd().createFile(fake_zig, .{});
            defer file.close();
            try file.writer().writeAll("a fake executable");
        }

        setPathEnv(try std.mem.concat(allocator, u8, &.{ bin2_dir, path_env_sep, previous_path }));
        defer setPathEnv(previous_path);

        // verify zig isn't currently on 0.7.0 before we set it as the default
        try checkZigVersion(allocator, path_link, expected_zig_version_0_7_0, .not_equal);

        {
            const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8{ "default", "0.7.0" });
            defer {
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
            std.log.info("output: {s}", .{result.stderr});
            try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "error: zig compiler '"));
            try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "' is higher priority in PATH than the path-link '"));
        }

        // the path link should still be updated even though it's in a lower path priority.
        // Verify zig points to the new defult version we just set.
        try checkZigVersion(allocator, path_link, expected_zig_version_0_7_0, .equal);
    }

    // verify a dev build
    // NOTE: this test will eventually break when these builds are cleaned up,
    //       we should support downloading from bazel and use that instead since
    //       it should be more permanent
    try runNoCapture(zigup_args ++ &[_][]const u8{ "0.14.0-dev.14+ec337051a" });

    std.log.info("Success", .{});
    return 0;
}

fn makeDir(dir_path: []const u8, sub_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    try dir.makeDir(sub_path);
}

fn checkZigVersion(allocator: std.mem.Allocator, zig: []const u8, compare: []const u8, want_equal: enum { not_equal, equal }) !void {
    const result = try runCaptureOuts(allocator, &[_][]const u8{ zig, "version" });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try passOrDumpAndThrow(result);

    const actual_version = std.mem.trimRight(u8, result.stdout, "\r\n");
    const actual_equal = std.mem.eql(u8, compare, actual_version);
    const expected_equal = switch (want_equal) {
        .not_equal => false,
        .equal => true,
    };
    if (expected_equal != actual_equal) {
        const prefix: []const u8 = if (expected_equal) "" else " NOT";
        std.log.info("expected zig version to{s} be '{s}', but is '{s}'", .{ prefix, compare, actual_version });
        return error.TestUnexpectedResult;
    }
}

fn getCompilerCount(install_dir: []const u8) !u32 {
    var dir = try std.fs.cwd().openDir(install_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var count: u32 = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            count += 1;
        } else {
            if (builtin.os.tag == .windows) {
                try testing.expect(entry.kind == .file);
            } else {
                try testing.expect(entry.kind == .sym_link);
            }
        }
    }
    return count;
}

fn trailNl(s: []const u8) []const u8 {
    return if (s.len == 0 or s[s.len - 1] != '\n') "\n" else "";
}

fn dumpExecResult(result: std.process.Child.RunResult) void {
    if (result.stdout.len > 0) {
        std.debug.print("--- STDOUT ---\n{s}{s}--------------\n", .{ result.stdout, trailNl(result.stdout) });
    }
    if (result.stderr.len > 0) {
        std.debug.print("--- STDERR ---\n{s}{s}--------------\n", .{ result.stderr, trailNl(result.stderr) });
    }
}

fn runNoCapture(argv: []const []const u8) !void {
    var arena_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_store.deinit();
    const result = try runCaptureOuts(arena_store.allocator(), argv);
    dumpExecResult(result);
    try passOrThrow(result.term);
}
fn runCaptureOuts(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    {
        const cmd = try std.mem.join(allocator, " ", argv);
        defer allocator.free(cmd);
        std.log.info("RUN: {s}", .{cmd});
    }
    return try std.process.Child.run(.{ .allocator = allocator, .argv = argv, .env_map = &child_env_map });
}
fn passOrThrow(term: std.process.Child.Term) error{ChildProcessFailed}!void {
    if (!execResultPassed(term)) {
        std.log.err("child process failed with {}", .{term});
        return error.ChildProcessFailed;
    }
}
fn passOrDumpAndThrow(result: std.process.Child.RunResult) error{ChildProcessFailed}!void {
    if (!execResultPassed(result.term)) {
        dumpExecResult(result);
        std.log.err("child process failed with {}", .{result.term});
        return error.ChildProcessFailed;
    }
}
fn execResultPassed(term: std.process.Child.Term) bool {
    switch (term) {
        .Exited => |code| return code == 0,
        else => return false,
    }
}
