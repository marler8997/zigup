const std = @import("std");
const testing = std.testing;

const sep = std.fs.path.sep_str;

pub fn main() !void {
    std.log.info("running test!", .{});
    try std.fs.cwd().deleteTree("scratch");
    try std.fs.cwd().makeDir("scratch");
    const install_dir = "scratch" ++ sep ++ "install";
    const bin_dir = "scratch" ++ sep ++ "bin";
    try std.fs.cwd().makeDir(install_dir);
    try std.fs.cwd().makeDir(bin_dir);

    // NOTE: for now we are incorrectly assuming the install dir is CWD/zig-out
    const zigup = "." ++ sep ++ "zig-out" ++ sep ++ "bin" ++ sep ++ "zigup" ++ std.builtin.target.exeFileExt();
    const zigup_args = &[_][]const u8 { zigup, "--install-dir", install_dir, "--path-link", bin_dir ++ sep ++ "zig" };

    var allocator_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer allocator_store.deinit();
    const allocator = &allocator_store.allocator;

    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"-h"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Usage"));
    }
    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"--help"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Usage"));
    }

    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"default"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "<no-default>"));
    }
    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"fetch-index"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "master"));
    }
    try runNoCapture(".", zigup_args ++ &[_][]const u8 {"0.5.0"});
    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"fetch", "0.5.0"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "already installed"));
    }
    try runNoCapture(".", zigup_args ++ &[_][]const u8 {"master"});
    try runNoCapture(".", zigup_args ++ &[_][]const u8 {"0.6.0"});
    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"list"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "0.5.0"));
        try testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "0.6.0"));
    }
    try runNoCapture(".", zigup_args ++ &[_][]const u8 {"default", "0.5.0"});
    try testing.expectEqual(@as(u32, 3), try getCompilerCount(install_dir));

    try runNoCapture(".", zigup_args ++ &[_][]const u8 {"keep", "0.6.0"});
    // doesn't delete anything because we have keepfile and master doens't get deleted
    try runNoCapture(".", zigup_args ++ &[_][]const u8 {"clean"});
    try testing.expectEqual(@as(u32, 3), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"clean", "0.6.0"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "deleting "));
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "0.6.0"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"clean"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try passOrDumpAndThrow(result);
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "it is master"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    try runNoCapture(".", zigup_args ++ &[_][]const u8 {"master"});
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));

    {
        const result = try runCaptureOuts(allocator, ".", zigup_args ++ &[_][]const u8 {"DOESNOTEXST"});
        defer { allocator.free(result.stdout); allocator.free(result.stderr); }
        try testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "HTTP request failed"));
    }
    try testing.expectEqual(@as(u32, 2), try getCompilerCount(install_dir));
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
            try testing.expect(entry.kind == .SymLink);
        }
    }
    return count;
}

fn dumpExecResult(result: std.ChildProcess.ExecResult) void {
    if (result.stdout.len > 0) {
        std.log.info("STDOUT: '{s}'", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        std.log.info("STDERR: '{s}'", .{result.stderr});
    }
}

fn runNoCapture(cwd: []const u8, argv: []const []const u8) !void {
    var arena_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_store.deinit();
    const result = try runCaptureOuts(&arena_store.allocator, cwd, argv);
    dumpExecResult(result);
    try passOrThrow(result.term);
}
fn runCaptureOuts(allocator: *std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !std.ChildProcess.ExecResult {
    {
        const cmd = try std.mem.join(allocator, " ", argv);
        defer allocator.free(cmd);
        std.log.info("RUN(cwd={s}): {s}", .{cwd, cmd});
    }
    return try std.ChildProcess.exec(.{.allocator = allocator, .argv = argv, .cwd = cwd});
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
