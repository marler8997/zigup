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
    std.log.info("running test!", .{});
    try fixdeletetree.deleteTree(std.fs.cwd(), "scratch");
    try std.fs.cwd().makeDir("scratch");
    const bin_dir = "scratch" ++ sep ++ "bin";
    try std.fs.cwd().makeDir(bin_dir);
    const install_dir = if (builtin.os.tag == .windows) (bin_dir ++ "\\zig") else ("scratch/install");
    try std.fs.cwd().makeDir(install_dir);

    // NOTE: for now we are incorrectly assuming the install dir is CWD/zig-out
    const zigup = comptime "." ++ sep ++ bin_dir ++ sep ++ "zigup" ++ builtin.target.exeFileExt();
    try std.fs.cwd().copyFile(
        comptime "zig-out" ++ sep ++ "bin" ++ sep ++ "zigup" ++ builtin.target.exeFileExt(),
        std.fs.cwd(),
        zigup,
        .{},
    );

    const install_args = if (builtin.os.tag == .windows) [_][]const u8{} else [_][]const u8{ "--install-dir", install_dir };
    const zigup_args = &[_][]const u8{zigup} ++ install_args;

    var allocator_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator_store.deinit();
    const allocator = allocator_store.allocator();

    const path_link = try std.fs.path.join(allocator, &.{ bin_dir, comptime "zig" ++ builtin.target.exeFileExt() });
    defer allocator.free(path_link);

    // add our scratch/bin directory to PATH
    child_env_map = try std.process.getEnvMap(allocator);
    path_env_ptr = child_env_map.getPtr("PATH") orelse {
        std.log.err("the PATH environment variable does not exist?", .{});
        return 1;
    };
    const cwd = try std.process.getCwdAlloc(allocator);

    const original_path_env = path_env_ptr.*;
    {
        const scratch_bin_path = try std.fs.path.join(allocator, &.{ cwd, bin_dir });
        defer allocator.free(scratch_bin_path);
        setPathEnv(try std.mem.concat(allocator, u8, &.{ scratch_bin_path, path_env_sep, original_path_env }));
    }

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
        const zig_exe_link = comptime "scratch" ++ sep ++ "bin" ++ sep ++ "zig" ++ builtin.target.exeFileExt();

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
    try std.fs.cwd().makeDir(install_dir ++ sep ++ "0.9.0");
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
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "HTTP request failed"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    // verify that we get an error if there is another compiler in the path
    {
        const bin2_dir = "scratch" ++ sep ++ "bin2";
        try std.fs.cwd().makeDir(bin2_dir);

        const previous_path = path_env_ptr.*;
        const scratch_bin2_path = try std.fs.path.join(allocator, &.{ cwd, bin2_dir });
        defer allocator.free(scratch_bin2_path);

        {
            var file = try std.fs.cwd().createFile(comptime bin2_dir ++ sep ++ "zig" ++ builtin.target.exeFileExt(), .{});
            defer file.close();
            try file.writer().writeAll("a fake executable");
        }

        setPathEnv(try std.mem.concat(allocator, u8, &.{ scratch_bin2_path, path_env_sep, previous_path }));
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
    try runNoCapture(zigup_args ++ &[_][]const u8{"0.11.0-dev.4263+f821543e4"});

    std.log.info("Success", .{});
    return 0;
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
    var dir = try std.fs.cwd().openIterableDir(install_dir, .{});
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

fn dumpExecResult(result: std.ChildProcess.ExecResult) void {
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
fn runCaptureOuts(allocator: std.mem.Allocator, argv: []const []const u8) !std.ChildProcess.ExecResult {
    {
        const cmd = try std.mem.join(allocator, " ", argv);
        defer allocator.free(cmd);
        std.log.info("RUN: {s}", .{cmd});
    }
    return try std.ChildProcess.exec(.{ .allocator = allocator, .argv = argv, .env_map = &child_env_map });
}
fn passOrThrow(term: std.ChildProcess.Term) error{ChildProcessFailed}!void {
    if (!execResultPassed(term)) {
        std.log.err("child process failed with {}", .{term});
        return error.ChildProcessFailed;
    }
}
fn passOrDumpAndThrow(result: std.ChildProcess.ExecResult) error{ChildProcessFailed}!void {
    if (!execResultPassed(result.term)) {
        dumpExecResult(result);
        std.log.err("child process failed with {}", .{result.term});
        return error.ChildProcessFailed;
    }
}
fn execResultPassed(term: std.ChildProcess.Term) bool {
    switch (term) {
        .Exited => |code| return code == 0,
        else => return false,
    }
}
