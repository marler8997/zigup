const builtin = @import("builtin");
const std = @import("std");

const fixdeletetree = @import("fixdeletetree.zig");

const exe_ext = builtin.os.tag.exeFileExt(builtin.cpu.arch);

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const all_args = try std.process.argsAlloc(arena);
    if (all_args.len < 7) @panic("not enough cmdline args");

    const test_name = all_args[1];
    const add_path_option = all_args[2];
    const in_env_dir = all_args[3];
    const out_env_dir = all_args[4];
    const setup_option = all_args[5];
    const zigup_exe = all_args[6];
    const zigup_args = all_args[7..];

    const add_path = blk: {
        if (std.mem.eql(u8, add_path_option, "--with-path")) break :blk true;
        if (std.mem.eql(u8, add_path_option, "--no-path")) break :blk false;
        std.log.err("expected '--with-path' or '--no-path' but got '{s}'", .{add_path_option});
        std.process.exit(0xff);
    };

    try fixdeletetree.deleteTree(std.fs.cwd(), out_env_dir);
    try std.fs.cwd().makeDir(out_env_dir);

    // make a file named after the test so we can find this directory in the cache
    _ = test_name;
    // {
    //     const test_marker_file = try std.fs.path.join(arena, &.{ out_env_dir, test_name});
    //     defer arena.free(test_marker_file);
    //     var file = try std.fs.cwd().createFile(test_marker_file, .{});
    //     defer file.close();
    //     try file.writer().print("this file marks this directory as the output for test: {s}\n", .{test_name});
    // }

    const path_link = try std.fs.path.join(arena, &.{ out_env_dir, "zig" ++ exe_ext });
    const install_dir = try std.fs.path.join(arena, &.{ out_env_dir, "install" });

    if (std.mem.eql(u8, in_env_dir, "--no-input-environment")) {
        try std.fs.cwd().makeDir(install_dir);
    } else {
        try copyEnvDir(arena, in_env_dir, out_env_dir, in_env_dir, out_env_dir);
    }

    var maybe_second_bin_dir: ?[]const u8 = null;

    if (std.mem.eql(u8, setup_option, "no-extra-setup")) {
        // nothing extra to setup
    } else if (std.mem.eql(u8, setup_option, "path-link-is-directory")) {
        if (std.fs.cwd().access(path_link, .{})) {
            try std.fs.cwd().deleteFile(path_link);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        try std.fs.cwd().makeDir(path_link);
    } else if (std.mem.eql(u8, setup_option, "another-zig")) {
        maybe_second_bin_dir = try std.fs.path.join(arena, &.{ out_env_dir, "bin2" });
        try std.fs.cwd().makeDir(maybe_second_bin_dir.?);

        const fake_zig = try std.fs.path.join(arena, &.{
            maybe_second_bin_dir.?,
            "zig" ++ comptime builtin.target.exeFileExt(),
        });
        defer arena.free(fake_zig);
        var file = try std.fs.cwd().createFile(fake_zig, .{});
        defer file.close();
        try file.writer().writeAll("a fake executable");
    } else {
        std.log.err("unknown setup option '{s}'", .{setup_option});
        std.process.exit(0xff);
    }

    var argv = std.ArrayList([]const u8).init(arena);
    try argv.append(zigup_exe);
    try argv.append("--path-link");
    try argv.append(path_link);
    try argv.append("--install-dir");
    try argv.append(install_dir);
    try argv.appendSlice(zigup_args);

    var child = std.process.Child.init(argv.items, arena);

    if (add_path) {
        var env_map = try std.process.getEnvMap(arena);
        // make sure the directory with our path-link comes first in PATH
        var new_path = std.ArrayList(u8).init(arena);
        if (maybe_second_bin_dir) |second_bin_dir| {
            try new_path.appendSlice(second_bin_dir);
            try new_path.append(std.fs.path.delimiter);
        }
        try new_path.appendSlice(out_env_dir);
        try new_path.append(std.fs.path.delimiter);
        if (env_map.get("PATH")) |path| {
            try new_path.appendSlice(path);
        }
        try env_map.put("PATH", new_path.items);
        child.env_map = &env_map;
    } else if (maybe_second_bin_dir) |_| @panic("invalid config");

    try child.spawn();
    const result = try child.wait();
    switch (result) {
        .Exited => |c| std.process.exit(c),
        else => |sig| {
            std.log.err("zigup terminated from '{s}' with {}", .{ @tagName(result), sig });
            std.process.exit(0xff);
        },
    }
}

fn copyEnvDir(
    allocator: std.mem.Allocator,
    in_root: []const u8,
    out_root: []const u8,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    var in_dir = try std.fs.cwd().openDir(in_path, .{ .iterate = true });
    defer in_dir.close();

    var it = in_dir.iterate();
    while (try it.next()) |entry| {
        const in_sub_path = try std.fs.path.join(allocator, &.{ in_path, entry.name });
        defer allocator.free(in_sub_path);
        const out_sub_path = try std.fs.path.join(allocator, &.{ out_path, entry.name });
        defer allocator.free(out_sub_path);
        switch (entry.kind) {
            .directory => {
                try std.fs.cwd().makeDir(out_sub_path);
                try copyEnvDir(allocator, in_root, out_root, in_sub_path, out_sub_path);
            },
            .file => try std.fs.cwd().copyFile(in_sub_path, std.fs.cwd(), out_sub_path, .{}),
            .sym_link => {
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const in_target = try std.fs.cwd().readLink(in_sub_path, &target_buf);
                var out_target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const out_target = blk: {
                    if (std.fs.path.isAbsolute(in_target)) {
                        if (!std.mem.startsWith(u8, in_target, in_root)) std.debug.panic(
                            "expected symlink target to start with '{s}' but got '{s}'",
                            .{ in_root, in_target },
                        );
                        break :blk try std.fmt.bufPrint(
                            &out_target_buf,
                            "{s}{s}",
                            .{ out_root, in_target[in_root.len..] },
                        );
                    }
                    break :blk in_target;
                };

                if (builtin.os.tag == .windows) @panic(
                    "we got a symlink on windows?",
                ) else try std.posix.symlink(out_target, out_sub_path);
            },
            else => std.debug.panic("copy {}", .{entry}),
        }
    }
}
