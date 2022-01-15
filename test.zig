const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const sep = std.fs.path.sep_str;
const path_env_sep = if (builtin.os.tag == .windows) ";" else ":";

const fixdeletetree = @import("fixdeletetree.zig");

var child_env_map: std.BufMap = undefined;
var path_env_ptr: *[]const u8 = undefined;
fn setPathEnv(new_path: []const u8) void {
    path_env_ptr.* = new_path;
    std.log.info("PATH={s}", .{new_path});
}

pub fn main() !u8 {
    std.log.info("running test!", .{});
    try fixdeletetree.deleteTree(std.fs.cwd(), "scratch");
    try std.fs.cwd().makeDir("scratch");
    const bin_dir = "scratch" ++ sep ++ "bin";
    try std.fs.cwd().makeDir(bin_dir);
    const install_dir = if (builtin.os.tag == .windows) (bin_dir ++ "\\zig") else ("scratch/install");
    try std.fs.cwd().makeDir(install_dir);

    // NOTE: for now we are incorrectly assuming the install dir is CWD/zig-out
    const zigup = "." ++ sep ++ bin_dir ++ sep ++ "zigup" ++ builtin.target.exeFileExt();
    try std.fs.cwd().copyFile(
        "zig-out" ++ sep ++ "bin" ++ sep ++ "zigup" ++ builtin.target.exeFileExt(),
        std.fs.cwd(),
        zigup,
        .{},
    );

    const zigup_args = &[_][]const u8 { zigup } ++ (
        if (builtin.os.tag == .windows) &[_][]const u8 { } else &[_][]const u8 { "--install-dir", install_dir }
    );

    var allocator_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator_store.deinit();
    const allocator = allocator_store.allocator();

    // add our scratch/bin directory to PATH
    child_env_map = try std.process.getEnvMap(allocator);
    path_env_ptr = bufMapGetEnvPtr(child_env_map, "PATH") orelse {
        std.log.err("the PATH environment variable does not exist?", .{});
        return 1;
    };
    const cwd = try std.process.getCwdAlloc(allocator);

    const original_path_env = path_env_ptr.*;
    {
        const scratch_bin_path = try std.fs.path.join(allocator, &.{ cwd, bin_dir });
        defer allocator.free(scratch_bin_path);
        setPathEnv(try std.mem.concat(allocator, u8, &.{ scratch_bin_path, path_env_sep, original_path_env}));
    }

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"default", "master"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "master has not been fetched"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"-h"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Usage"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"--help"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Usage"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"default"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.eql(u8, result.stdout, "<no-default>\n"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"fetch-index"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "master"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"default", "0.5.0"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        dumpExecResult(result);
        switch (result.term) {
            .Exited => |code| try testing.expectEqual(@as(u8, 1), code),
            else => |term| std.debug.panic("unexpected exit {}", .{term}),
        }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "error: compiler '0.5.0' is not installed\n"));
    }
    try runNoCapture(zigup_args ++ &[_][]const u8 {"0.5.0"});
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"default"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        dumpExecResult(result);
        try testing.expect(std.mem.eql(u8, result.stdout, "0.5.0\n"));
    }
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"fetch", "0.5.0"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "already installed"));
    }
    try runNoCapture(zigup_args ++ &[_][]const u8 {"master"});
    try runNoCapture(zigup_args ++ &[_][]const u8 {"0.6.0"});
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"default"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        dumpExecResult(result);
        try testing.expect(std.mem.eql(u8, result.stdout, "0.6.0\n"));
    }
    {
        const save_path_env = path_env_ptr.*;
        defer setPathEnv(save_path_env);
        setPathEnv("");
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"default", "master"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, " is not in PATH"));
    }
    try runNoCapture(zigup_args ++ &[_][]const u8 {"default", "master"});
    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"list"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "0.5.0"));
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "0.6.0"));
    }
    try runNoCapture(zigup_args ++ &[_][]const u8 {"default", "0.5.0"});
    try testing.expectEqual(@as(u32, 3), try getCompilerCount(install_dir));

    try runNoCapture(zigup_args ++ &[_][]const u8 {"keep", "0.6.0"});
    // doesn't delete anything because we have keepfile and master doens't get deleted
    try runNoCapture(zigup_args ++ &[_][]const u8 {"clean"});
    try testing.expectEqual(@as(u32, 3), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"clean", "0.6.0"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "deleting "));
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "0.6.0"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"clean"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "it is master"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    try runNoCapture(zigup_args ++ &[_][]const u8 {"master"});
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"DOESNOTEXST"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
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
            var file = try std.fs.cwd().createFile(bin2_dir ++ sep ++ "zig" ++ builtin.target.exeFileExt(), .{});
            defer file.close();
            try file.writer().writeAll("a fake executable");
        }

        setPathEnv(try std.mem.concat(allocator, u8, &.{ scratch_bin2_path, path_env_sep, previous_path}));
        defer setPathEnv(previous_path);

        {
            const result = try runCaptureOuts(allocator, zigup_args ++ &[_][]const u8 {"default", "0.5.0"});
            defer { allocator.free(result.stdout); allocator.free(result.stderr); }
            try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, " is lower priority in PATH than "));
        }
    }

    std.log.info("Success", .{});
    return 0;
}

fn getCompilerCount(install_dir: []const u8) !u32 {
    var dir = try std.fs.cwd().openDir(install_dir, .{.iterate=true});
    defer dir.close();
    var it = dir.iterate();
    var count: u32 = 0;
    while (try it.next()) |entry| {
        if (entry.kind == .Directory) {
            count += 1;
        } else {
            if (builtin.os.tag == .windows) {
                try testing.expect(entry.kind == .File);
            } else {
                try testing.expect(entry.kind == .SymLink);
            }
        }
    }
    return count;
}


fn trailNl(s: []const u8) []const u8 {
    return if (s.len == 0 or s[s.len-1] != '\n') "\n" else "";
}

fn dumpExecResult(result: std.ChildProcess.ExecResult) void {
    if (result.stdout.len > 0) {
        std.debug.print("--- STDOUT ---\n{s}{s}--------------\n", .{result.stdout, trailNl(result.stdout)});
    }
    if (result.stderr.len > 0) {
        std.debug.print("--- STDERR ---\n{s}{s}--------------\n", .{result.stderr, trailNl(result.stderr)});
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
    return try std.ChildProcess.exec(.{.allocator = allocator, .argv = argv, .env_map = &child_env_map});
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

fn bufMapGetEnvPtr(buf_map: std.BufMap, env_name: []const u8) ?*[]const u8 {
    if (builtin.os.tag == .windows) {
        var it = buf_map.iterator();
        while (it.next()) |kv| {
            if (std.ascii.eqlIgnoreCase(env_name, kv.key_ptr.*)) {
                return kv.value_ptr;
            }
        }
    }
    return buf_map.getPtr(env_name);
}
