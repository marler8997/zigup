const builtin = @import("builtin");
const std = @import("std");

const fixdeletetree = @import("fixdeletetree.zig");

const exe_ext = builtin.os.tag.exeFileExt(builtin.cpu.arch);

fn compilersArg(arg: []const u8) []const u8 {
    return if (std.mem.eql(u8, arg, "--no-compilers")) "" else arg;
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const all_args = try std.process.argsAlloc(arena);
    if (all_args.len < 7) @panic("not enough cmdline args");

    const test_name = all_args[1];
    const add_path_option = all_args[2];
    const in_env_dir = all_args[3];
    const with_compilers = compilersArg(all_args[4]);
    const keep_compilers = compilersArg(all_args[5]);
    const out_env_dir = all_args[6];
    const setup_option = all_args[7];
    const zigup_exe = all_args[8];
    const zigup_args = all_args[9..];

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

    const appdata = try std.fs.path.join(arena, &.{ out_env_dir, "appdata" });
    const path_link = try std.fs.path.join(arena, &.{ out_env_dir, "zig" ++ exe_ext });
    const install_dir = try std.fs.path.join(arena, &.{ out_env_dir, "install" });
    const install_dir_parsed = switch (parseInstallDir(install_dir)) {
        .good => |p| p,
        .bad => |reason| std.debug.panic("failed to parse install dir '{s}': {s}", .{ install_dir, reason }),
    };

    const install_dir_setting_path = try std.fs.path.join(arena, &.{ appdata, "install-dir" });
    defer arena.free(install_dir_setting_path);

    if (std.mem.eql(u8, in_env_dir, "--no-input-environment")) {
        try std.fs.cwd().makeDir(install_dir);
        try std.fs.cwd().makeDir(appdata);
        var file = try std.fs.cwd().createFile(install_dir_setting_path, .{});
        defer file.close();
        try file.writer().writeAll(install_dir);
    } else {
        var shared_sibling_state: SharedSiblingState = .{};
        try copyEnvDir(
            arena,
            in_env_dir,
            out_env_dir,
            in_env_dir,
            out_env_dir,
            .{ .with_compilers = with_compilers },
            &shared_sibling_state,
        );

        const input_install_dir = blk: {
            var file = try std.fs.cwd().openFile(install_dir_setting_path, .{});
            defer file.close();
            break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
        };
        defer arena.free(input_install_dir);
        switch (parseInstallDir(input_install_dir)) {
            .good => |input_install_dir_parsed| {
                std.debug.assert(std.mem.eql(u8, install_dir_parsed.cache_o, input_install_dir_parsed.cache_o));
                var file = try std.fs.cwd().createFile(install_dir_setting_path, .{});
                defer file.close();
                try file.writer().writeAll(install_dir);
            },
            .bad => {
                // the install dir must have been customized, keep it
            },
        }
    }

    var maybe_second_bin_dir: ?[]const u8 = null;

    if (std.mem.eql(u8, setup_option, "no-extra-setup")) {
        // nothing extra to setup
    } else if (std.mem.eql(u8, setup_option, "path-link-is-directory")) {
        std.fs.cwd().deleteFile(path_link) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
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
    try argv.append("--appdata");
    try argv.append(appdata);
    try argv.append("--path-link");
    try argv.append(path_link);
    try argv.appendSlice(zigup_args);

    if (true) {
        try std.io.getStdErr().writer().writeAll("runtest exec: ");
        for (argv.items) |arg| {
            try std.io.getStdErr().writer().print(" {s}", .{arg});
        }
        try std.io.getStdErr().writer().writeAll("\n");
    }

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
        .Exited => |c| if (c != 0) std.process.exit(c),
        else => |sig| {
            std.log.err("zigup terminated from '{s}' with {}", .{ @tagName(result), sig });
            std.process.exit(0xff);
        },
    }

    {
        var dir = try std.fs.cwd().openDir(install_dir, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |install_entry| {
            switch (install_entry.kind) {
                .directory => {},
                else => continue,
            }
            if (containsCompiler(keep_compilers, install_entry.name)) {
                std.log.info("keeping compiler '{s}'", .{install_entry.name});
                continue;
            }
            const files_path = try std.fs.path.join(arena, &.{ install_entry.name, "files" });
            var files_dir = try dir.openDir(files_path, .{ .iterate = true });
            defer files_dir.close();
            var files_it = files_dir.iterate();
            var is_first = true;
            while (try files_it.next()) |files_entry| {
                if (is_first) {
                    std.log.info("cleaning compiler '{s}'", .{install_entry.name});
                    is_first = false;
                }
                try fixdeletetree.deleteTree(files_dir, files_entry.name);
            }
        }
    }
}

const ParsedInstallDir = struct {
    test_name: []const u8,
    hash: []const u8,
    cache_o: []const u8,
};
fn parseInstallDir(install_dir: []const u8) union(enum) {
    good: ParsedInstallDir,
    bad: []const u8,
} {
    {
        const name = std.fs.path.basename(install_dir);
        if (!std.mem.eql(u8, name, "install")) return .{ .bad = "did not end with 'install'" };
    }
    const test_dir = std.fs.path.dirname(install_dir) orelse return .{ .bad = "missing test dir" };
    const test_name = std.fs.path.basename(test_dir);
    const cache_dir = std.fs.path.dirname(test_dir) orelse return .{ .bad = "missing cache/hash dir" };
    const hash = std.fs.path.basename(cache_dir);
    return .{ .good = .{
        .test_name = test_name,
        .hash = hash,
        .cache_o = std.fs.path.dirname(cache_dir) orelse return .{ .bad = "missing cache o dir" },
    } };
}

fn containsCompiler(compilers: []const u8, compiler: []const u8) bool {
    var it = std.mem.splitScalar(u8, compilers, ',');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, compiler)) return true;
    }
    return false;
}

fn isCompilerFilesEntry(path: []const u8) ?[]const u8 {
    var it = std.fs.path.NativeComponentIterator.init(path) catch std.debug.panic("invalid path '{s}'", .{path});
    {
        const name = (it.next() orelse return null).name;
        if (!std.mem.eql(u8, name, "install")) return null;
    }
    const compiler = it.next() orelse return null;
    const leaf = (it.next() orelse return null).name;
    if (!std.mem.eql(u8, leaf, "files")) return null;
    _ = it.next() orelse return null;
    if (null != it.next()) return null;
    return compiler.name;
}

const SharedSiblingState = struct {
    logged: bool = false,
};
fn copyEnvDir(
    allocator: std.mem.Allocator,
    in_root: []const u8,
    out_root: []const u8,
    in_path: []const u8,
    out_path: []const u8,
    opt: struct { with_compilers: []const u8 },
    shared_sibling_state: *SharedSiblingState,
) !void {
    std.debug.assert(std.mem.startsWith(u8, in_path, in_root));
    std.debug.assert(std.mem.startsWith(u8, out_path, out_root));

    {
        const separators = switch (builtin.os.tag) {
            .windows => "\\/",
            else => "/",
        };
        const relative = std.mem.trimLeft(u8, in_path[in_root.len..], separators);
        if (isCompilerFilesEntry(relative)) |compiler| {
            const exclude = !containsCompiler(opt.with_compilers, compiler);
            if (!shared_sibling_state.logged) {
                shared_sibling_state.logged = true;
                std.log.info("{s} compiler '{s}'", .{ if (exclude) "excluding" else "including", compiler });
            }
            if (exclude) return;
        }
    }

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
                var shared_child_state: SharedSiblingState = .{};
                try copyEnvDir(allocator, in_root, out_root, in_sub_path, out_sub_path, opt, &shared_child_state);
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
