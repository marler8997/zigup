const std = @import("std");
const builtin = std.builtin;
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const ziget = @import("ziget");

var global_optional_install_dir: ?[]const u8 = null;
var global_optional_path_link: ?[]const u8 = null;

fn find_zigs(allocator: *Allocator) !?[][]u8 {
    const ziglist = std.ArrayList([]u8).init(allocator);
    // don't worry about free for now, this is a short lived program

    if (builtin.os.tag == .windows) {
        @panic("windows not implemented");
        //const result = try runGetOutput(allocator, .{"where", "-a", "zig"});
    } else {
        const which_result = try cmdlinetool.runGetOutput(allocator, .{ "which", "zig" });
        if (runutil.runFailed(&which_result)) {
            return null;
        }
        if (which_result.stderr.len > 0) {
            std.debug.warn("which command failed with:\n{}\n", .{which_result.stderr});
            std.os.exit(1);
        }
        std.debug.warn("which output:\n{}\n", .{which_result.stdout});
        {
            var i = std.mem.split(which_result.stdout, "\n");
            while (i.next()) |dir| {
                std.debug.warn("path '{}'\n", .{dir});
            }
        }
    }
    @panic("not impl");
}

fn download(allocator: *Allocator, url: []const u8, writer: anytype) !void {
    var download_options = ziget.request.DownloadOptions{
        .flags = 0,
        .allocator = allocator,
        .maxRedirects = 10,
        .forwardBufferSize = 4096,
        .maxHttpResponseHeaders = 8192,
        .onHttpRequest = ignoreHttpCallback,
        .onHttpResponse = ignoreHttpCallback,
    };
    var dowload_state = ziget.request.DownloadState.init();
    try ziget.request.download(
        ziget.url.parseUrl(url) catch unreachable,
        writer,
        download_options,
        &dowload_state,
    );
}

fn downloadToFileAbsolute(allocator: *Allocator, url: []const u8, file_absolute: []const u8) !void {
    const file = try std.fs.createFileAbsolute(file_absolute, .{});
    defer file.close();
    try download(allocator, url, file.outStream());
}

fn downloadToString(allocator: *Allocator, url: []const u8) ![]u8 {
    var response_array_list = try ArrayList(u8).initCapacity(allocator, 20 * 1024); // 20 KB (modify if response is expected to be bigger)
    errdefer response_array_list.deinit();
    try download(allocator, url, response_array_list.outStream());
    return response_array_list.toOwnedSlice();
}

fn ignoreHttpCallback(request: []const u8) void {}

fn getHomeDir() ![]const u8 {
    return std.os.getenv("HOME") orelse {
        std.debug.warn("Error: cannot find install directory, $HOME environment variable is not set\n", .{});
        return error.MissingHomeEnvironmentVariable;
    };
}

fn allocInstallDirString(allocator: *Allocator) ![]const u8 {
    // TODO: maybe support ZIG_INSTALL_DIR environment variable?
    // TODO: maybe support a file on the filesystem to configure install dir?
    const home = try getHomeDir();
    if (!std.fs.path.isAbsolute(home)) {
        std.debug.warn("Error: $HOME environment variable '{}' is not an absolute path\n", .{home});
        return error.BadHomeEnvironmentVariable;
    }
    return std.fs.path.join(allocator, &[_][]const u8{ home, "zig" });
}
const GetInstallDirOptions = struct {
    create: bool,
};
fn getInstallDir(allocator: *Allocator, options: GetInstallDirOptions) ![]const u8 {
    var optional_dir_to_free_on_error: ?[]const u8 = null;
    errdefer if (optional_dir_to_free_on_error) |dir| allocator.free(dir);

    const install_dir = init: {
        if (global_optional_install_dir) |dir| break :init dir;
        optional_dir_to_free_on_error = try allocInstallDirString(allocator);
        break :init optional_dir_to_free_on_error.?;
    };
    std.debug.assert(std.fs.path.isAbsolute(install_dir));
    std.debug.warn("install directory '{}'\n", .{install_dir});
    if (options.create) {
        loggyMakeDirAbsolute(install_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
    return install_dir;
}

fn makeZigPathLinkString(allocator: *Allocator) ![]const u8 {
    if (global_optional_path_link) |path| return path;

    // for now we're just going to hardcode the path to $HOME/bin/zig
    const home = try getHomeDir();
    return try std.fs.path.join(allocator, &[_][]const u8{ home, "bin", "zig" });
}

// TODO: this should be in standard lib
fn toAbsolute(allocator: *Allocator, path: []const u8) ![]u8 {
    std.debug.assert(!std.fs.path.isAbsolute(path));
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &[_][]const u8{ cwd, path });
}

fn help() void {
    std.io.getStdErr().writeAll(
        \\Download and manage zig compilers.
        \\
        \\Common Usage:
        \\
        \\  zigup VERSION                 download and set VERSION compiler as default
        \\  zigup fetch VERSION           download VERSION compiler
        \\  zigup default [VERSION]       get or set the default compiler
        \\  zigup clean   [VERSION]       clean the installed compilers that are not marked as keep or master. if a version is specified, it will clean that version
        \\  zigup keep VERSION            mark a compiler to be kept during clean
        \\
        \\Uncommon Usage:
        \\
        \\  zigup fetch-index             download and print the download index json
        \\
        \\Common Options:
        \\  --install-dir DIR             override the default install location
        \\  --path-link PATH              path to the `zig` symlink that points to the default compiler
        \\                                this will typically be a file path within a PATH directory so
        \\                                that the user can just run `zig`
        \\
    ) catch unreachable;
}

fn getCmdOpt(args: [][]const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* == args.len) {
        std.debug.warn("Error: option '{}' requires an argument\n", .{args[i.* - 1]});
        return error.AlreadyReported;
    }
    return args[i.*];
}

pub fn main() !u8 {
    return main2() catch |e| switch (e) {
        error.AlreadyReported => return 1,
        else => return e,
    };
}
pub fn main2() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena.allocator;

    const args_array = try std.process.argsAlloc(allocator);
    // no need to free, os will do it
    //defer std.process.argsFree(allocator, argsArray);

    var args = if (args_array.len == 0) args_array else args_array[1..];
    // parse common options
    //
    {
        var i: usize = 0;
        var newlen: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "--install-dir", arg)) {
                global_optional_install_dir = try getCmdOpt(args, &i);
                if (!std.fs.path.isAbsolute(global_optional_install_dir.?)) {
                    global_optional_install_dir = try toAbsolute(allocator, global_optional_install_dir.?);
                }
            } else if (std.mem.eql(u8, "--path-link", arg)) {
                global_optional_path_link = try getCmdOpt(args, &i);
                if (!std.fs.path.isAbsolute(global_optional_path_link.?)) {
                    global_optional_path_link = try toAbsolute(allocator, global_optional_path_link.?);
                }
            } else if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
                help();
                return 1;
            } else {
                args[newlen] = args[i];
                newlen += 1;
            }
        }
        args = args[0..newlen];
    }
    if (args.len == 0) {
        help();
        return 1;
    }
    if (std.mem.eql(u8, "fetch-index", args[0])) {
        if (args.len != 1) {
            std.debug.warn("Error: 'index' command requires 0 arguments but got {}\n", .{args.len - 1});
            return 1;
        }
        var download_index = try fetchDownloadIndex(allocator);
        defer download_index.deinit(allocator);
        try std.io.getStdOut().writeAll(download_index.text);
        return 0;
    }
    if (std.mem.eql(u8, "fetch", args[0])) {
        if (args.len != 2) {
            std.debug.warn("Error: 'fetch' command requires 1 argument but got {}\n", .{args.len - 1});
            return 1;
        }
        try fetchCompiler(allocator, args[1], .leave_default);
        return 0;
    }
    if (std.mem.eql(u8, "clean", args[0])) {
        if (args.len == 1) {
            try cleanCompilers(allocator, null);
        } else if (args.len == 2) {
            try cleanCompilers(allocator, args[1]);
        } else {
            std.debug.warn("Error: 'clean' command requires 0 or 1 arguments but got {}\n", .{args.len - 1});
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, "keep", args[0])) {
        if (args.len != 2) {
            std.debug.warn("Error: 'keep' command requires 1 argument but got {}\n", .{args.len - 1});
            return 1;
        }
        try keepCompiler(allocator, args[1]);
        return 0;
    }
    if (std.mem.eql(u8, "list", args[0])) {
        if (args.len != 1) {
            std.debug.warn("Error: 'list' command requires 0 arguments but got {}\n", .{args.len - 1});
            return 1;
        }
        try listCompilers(allocator);
        return 0;
    }
    if (std.mem.eql(u8, "default", args[0])) {
        if (args.len == 1) {
            try printDefaultCompiler(allocator);
            return 0;
        }
        if (args.len == 2) {
            const version_string = args[1];
            const install_dir = try getInstallDir(allocator, .{ .create = true });
            defer allocator.free(install_dir);
            const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, version_string });
            defer allocator.free(compiler_dir);
            if (std.mem.eql(u8, version_string, "master")) {
                @panic("set default to master not implemented");
            } else {
                try setDefaultCompiler(allocator, compiler_dir);
            }
            return 0;
        }
        std.debug.warn("Error: 'default' command requires 1 or 2 arguments but got {}\n", .{args.len - 1});
        return 1;
    }
    if (args.len == 1) {
        try fetchCompiler(allocator, args[0], .set_default);
        return 0;
    }
    const command = args[0];
    args = args[1..];
    std.debug.warn("command not impl '{}'\n", .{command});
    return 1;

    //const optionalInstallPath = try find_zigs(allocator);
}

const SetDefault = enum { set_default, leave_default };

fn fetchCompiler(allocator: *Allocator, version_arg: []const u8, set_default: SetDefault) !void {
    const install_dir = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir);

    var optional_download_index: ?DownloadIndex = null;
    // This is causing an LLVM error
    //defer if (optionalDownloadIndex) |_| optionalDownloadIndex.?.deinit(allocator);
    // Also I would rather do this, but it doesn't work because of const issues
    //defer if (optionalDownloadIndex) |downloadIndex| downloadIndex.deinit(allocator);

    const VersionUrl = struct { version: []const u8, url: []const u8 };

    // NOTE: we only fetch the download index if the user wants to download 'master', we can skip
    //       this step for all other versions because the version to URL mapping is fixed (see getDefaultUrl)
    const is_master = std.mem.eql(u8, version_arg, "master");
    const version_url = blk: {
        if (!is_master)
            break :blk VersionUrl{ .version = version_arg, .url = try getDefaultUrl(allocator, version_arg) };
        optional_download_index = try fetchDownloadIndex(allocator);
        const master = optional_download_index.?.json.root.Object.get("master").?;
        const compiler_version = master.Object.get("version").?.String;
        const master_linux = master.Object.get("x86_64-linux").?;
        const master_linux_tarball = master_linux.Object.get("tarball").?.String;
        break :blk VersionUrl{ .version = compiler_version, .url = master_linux_tarball };
    };
    const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, version_url.version });
    defer allocator.free(compiler_dir);
    try installCompiler(allocator, compiler_dir, version_url.url);
    if (is_master) {
        const master_symlink = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "master" });
        defer allocator.free(master_symlink);
        _ = try loggyUpdateSymlink(version_url.version, master_symlink, .{ .is_directory = true });
    }
    if (set_default == .set_default) {
        try setDefaultCompiler(allocator, compiler_dir);
    }
}

const download_index_url = "https://ziglang.org/download/index.json";

const DownloadIndex = struct {
    text: []u8,
    json: std.json.ValueTree,
    pub fn deinit(self: *DownloadIndex, allocator: *Allocator) void {
        self.json.deinit();
        allocator.free(self.text);
    }
};

fn fetchDownloadIndex(allocator: *Allocator) !DownloadIndex {
    const text = downloadToString(allocator, download_index_url) catch |e| switch (e) {
        else => {
            std.debug.warn("failed to download '{}': {}\n", .{ download_index_url, e });
            return e;
        },
    };
    errdefer allocator.free(text);
    var json = init: {
        var parser = std.json.Parser.init(allocator, false);
        defer parser.deinit();
        break :init try parser.parse(text);
    };
    errdefer json.deinit();
    return DownloadIndex{ .text = text, .json = json };
}

fn loggyMakeDirAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        std.debug.warn("mkdir \"{}\"\n", .{dir_absolute});
    } else {
        std.debug.warn("mkdir '{}'\n", .{dir_absolute});
    }
    try std.fs.makeDirAbsolute(dir_absolute);
}

fn loggyDeleteTreeAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        std.debug.warn("rd /s /q \"{}\"\n", .{dir_absolute});
    } else {
        std.debug.warn("rm -rf '{}'\n", .{dir_absolute});
    }
    try std.fs.deleteTreeAbsolute(dir_absolute);
}

pub fn loggyRenameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    std.debug.warn("mv '{}' '{}'\n", .{ old_path, new_path });
    try std.fs.renameAbsolute(old_path, new_path);
}

pub fn loggySymlinkAbsolute(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.SymLinkFlags) !void {
    std.debug.warn("ln -s '{}' '{}'\n", .{ target_path, sym_link_path });
    // NOTE: can't use symLinkAbsolute because it requires target_path to be absolute but we don't want that
    //       not sure if it is a bug in the standard lib or not
    //try std.fs.symLinkAbsolute(target_path, sym_link_path, flags);
    try std.os.symlink(target_path, sym_link_path);
}

/// returns: true if the symlink was updated, false if it was already set to the given `target_path`
pub fn loggyUpdateSymlink(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.SymLinkFlags) !bool {
    var current_target_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    if (std.fs.readLinkAbsolute(sym_link_path, &current_target_path_buffer)) |current_target_path| {
        if (std.mem.eql(u8, target_path, current_target_path)) {
            std.debug.warn("symlink '{}' already points to '{}'\n", .{ sym_link_path, target_path });
            return false; // already up-to-date
        }
        try std.os.unlink(sym_link_path);
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    try loggySymlinkAbsolute(target_path, sym_link_path, flags);
    return true; // updated
}

// TODO: this should be in std lib somewhere
fn existsAbsolute(absolutePath: []const u8) !bool {
    std.fs.cwd().access(absolutePath, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        error.PermissionDenied => return e,
        error.InputOutput => return e,
        error.SystemResources => return e,
        error.SymLinkLoop => return e,
        error.FileBusy => return e,
        error.Unexpected => unreachable,
        error.InvalidUtf8 => unreachable,
        error.ReadOnlyFileSystem => unreachable,
        error.NameTooLong => unreachable,
        error.BadPathName => unreachable,
    };
    return true;
}

fn listCompilers(allocator: *Allocator) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = false });
    defer allocator.free(install_dir_string);

    var install_dir = std.fs.cwd().openDir(install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();

    const stdout = std.io.getStdOut().writer();
    {
        var it = install_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .Directory)
                continue;
            if (std.mem.endsWith(u8, entry.name, ".installing"))
                continue;
            try stdout.print("{}\n", .{entry.name});
        }
    }
}

fn keepCompiler(allocator: *Allocator, compiler_version: []const u8) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);

    // TODO openDirAbsolute in stdlib
    var install_dir = try std.fs.cwd().openDir(install_dir_string, .{ .iterate = true });
    defer install_dir.close();

    var compiler_dir = install_dir.openDir(compiler_version, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.warn("Error: compiler not found: {}\n", .{compiler_version});
            return;
        },
        else => return e,
    };
    var keep_fd = try compiler_dir.createFile("keep", .{});
    keep_fd.close();
    std.debug.warn("created '{}{c}{}{c}{}'\n", .{ install_dir_string, std.fs.path.sep, compiler_version, std.fs.path.sep, "keep" });
}

fn cleanCompilers(allocator: *Allocator, compiler_name_opt: ?[]const u8) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);
    // getting the current compiler
    const default_comp_opt = try getDefaultCompiler(allocator);
    defer if (default_comp_opt) |default_compiler| allocator.free(default_compiler);

    // TODO openDirAbsolute in stdlib
    var install_dir = std.fs.cwd().openDir(install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();
    const master_points_to_opt = try getMasterDir(allocator, &install_dir);
    defer if (master_points_to_opt) |master_points_to| allocator.free(master_points_to);
    if (compiler_name_opt) |compiler_name| {
        switch (shouldDeleteCompiler(master_points_to_opt, default_comp_opt, compiler_name)) {
            .yes => {},
            .no_is_default => {
                std.debug.warn("Error: not deleting '{}' (is default compiler)\n", .{compiler_name});
                return;
            },
            .no_is_master => {
                std.debug.warn("Error: not deleting '{}' (because it is master)\n", .{compiler_name});
                return;
            },
        }
        std.debug.warn("deleting '{}{c}{}'\n", .{ install_dir_string, std.fs.path.sep, compiler_name });
        try install_dir.deleteTree(compiler_name);
    } else {
        var it = install_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .Directory)
                continue;
            switch (shouldDeleteCompiler(master_points_to_opt, default_comp_opt, entry.name)) {
                .yes => {},
                .no_is_default => {
                    std.debug.warn("keeping '{}' (is default commpiler)\n", .{entry.name});
                    continue;
                },
                .no_is_master => {
                    std.debug.warn("keeping '{}' (because it is master)\n", .{entry.name});
                    continue;
                },
            }

            var compiler_dir = try install_dir.openDir(entry.name, .{});
            defer compiler_dir.close();
            if (compiler_dir.access("keep", .{})) |_| {
                std.debug.warn("keeping '{}' (has keep file)\n", .{entry.name});
                continue;
            } else |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            }
            std.debug.warn("deleting '{}{c}{}'\n", .{ install_dir_string, std.fs.path.sep, entry.name });
            try install_dir.deleteTree(entry.name);
        }
    }
}
fn readDefaultCompiler(allocator: *Allocator, buffer: *[std.fs.MAX_PATH_BYTES]u8) !?[]const u8 {
    const path_link = try makeZigPathLinkString(allocator);
    defer allocator.free(path_link);
    if (std.fs.readLinkAbsolute(path_link, buffer)) |targetPath| {
        return std.fs.path.basename(std.fs.path.dirname(std.fs.path.dirname(targetPath).?).?);
    } else |e| switch (e) {
        error.FileNotFound => {
            return null;
        },
        else => return e,
    }
}

fn readMasterDir(allocator: *Allocator, buffer: *[std.fs.MAX_PATH_BYTES]u8, install_dir: *std.fs.Dir) !?[]const u8 {
    return install_dir.readLink("master", buffer) catch |e| switch (e) {
        error.FileNotFound => {
            return null;
        },
        else => return e,
    };
}

fn getDefaultCompiler(allocator: *Allocator) !?[]const u8 {
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const slice_path = (try readDefaultCompiler(allocator, &buffer)) orelse return null;
    var path_to_return = try allocator.alloc(u8, slice_path.len);
    std.mem.copy(u8, path_to_return, slice_path);
    return path_to_return;
}

fn getMasterDir(allocator: *Allocator, install_dir: *std.fs.Dir) !?[]const u8 {
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const slice_path = (try readMasterDir(allocator, &buffer, install_dir)) orelse return null;
    var path_to_return = try allocator.alloc(u8, slice_path.len);
    std.mem.copy(u8, path_to_return, slice_path);
    return path_to_return;
}

fn printDefaultCompiler(allocator: *Allocator) !void {
    const default_compiler_opt = try getDefaultCompiler(allocator);
    defer if (default_compiler_opt) |default_compiler| allocator.free(default_compiler);
    if (default_compiler_opt) |default_compiler| {
        std.debug.warn("{}\n", .{default_compiler});
    } else {
        std.debug.warn("<no-default>\n", .{});
    }
}

fn setDefaultCompiler(allocator: *Allocator, compiler_dir: []const u8) !void {
    const path_link = try makeZigPathLinkString(allocator);
    defer allocator.free(path_link);
    const link_target = try std.fs.path.join(allocator, &[_][]const u8{ compiler_dir, "files", "zig" });
    defer allocator.free(link_target);
    if (builtin.os.tag == .windows) {
        // TODO: create zig.bat file
        @panic("setDefaultCompiler not implemented in Windows");
    } else {
        _ = try loggyUpdateSymlink(link_target, path_link, .{});
    }
}

fn getDefaultUrl(allocator: *Allocator, compiler_version: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{}/zig-linux-x86_64-{}.tar.xz", .{ compiler_version, compiler_version });
}

fn installCompiler(allocator: *Allocator, compiler_dir: []const u8, url: []const u8) !void {
    if (try existsAbsolute(compiler_dir)) {
        std.debug.warn("compiler '{}' already installed\n", .{compiler_dir});
        return;
    }

    const installing_dir = try std.mem.concat(allocator, u8, &[_][]const u8{ compiler_dir, ".installing" });
    defer allocator.free(installing_dir);
    try loggyDeleteTreeAbsolute(installing_dir);
    try loggyMakeDirAbsolute(installing_dir);

    const archive_basename = std.fs.path.basename(url);
    var archive_root_dir: []const u8 = undefined;

    // download and extract archive
    {
        const archive_absolute = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_basename });
        defer allocator.free(archive_absolute);
        std.debug.warn("downloading '{}' to '{}'\n", .{ url, archive_absolute });
        downloadToFileAbsolute(allocator, url, archive_absolute) catch |e| switch (e) {
            error.HttpNon200StatusCode => {
                // TODO: more information would be good
                std.debug.warn("HTTP request failed (TODO: improve ziget library to get better error)\n", .{});
                // this removes the installing dir if the http request fails so we dont have random directories
                try loggyDeleteTreeAbsolute(installing_dir);
                return error.AlreadyReported;
            },
            else => return e,
        };

        if (std.mem.endsWith(u8, archive_basename, ".tar.xz")) {
            archive_root_dir = archive_basename[0 .. archive_basename.len - ".tar.xz".len];
            _ = try run(allocator, &[_][]const u8{ "tar", "xf", archive_absolute, "-C", installing_dir });
        } else {
            std.debug.warn("Error: unknown archive extension '{}'\n", .{archive_basename});
            return error.UnknownArchiveExtension;
        }
        try loggyDeleteTreeAbsolute(archive_absolute);
    }

    {
        const extracted_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_root_dir });
        defer allocator.free(extracted_dir);
        const normalized_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, "files" });
        defer allocator.free(normalized_dir);
        try loggyRenameAbsolute(extracted_dir, normalized_dir);
    }

    // TODO: write date information (so users can sort compilers by date)

    // finish installation by renaming the install dir
    try loggyRenameAbsolute(installing_dir, compiler_dir);
}

pub fn run(allocator: *std.mem.Allocator, argv: []const []const u8) !std.ChildProcess.Term {
    try logRun(allocator, argv);
    var proc = try std.ChildProcess.init(argv, allocator);
    defer proc.deinit();
    return proc.spawnAndWait();
}
fn logRun(allocator: *std.mem.Allocator, argv: []const []const u8) !void {
    var buffer = try allocator.alloc(u8, getCommandStringLength(argv));
    defer allocator.free(buffer);

    var prefix = false;
    var offset: usize = 0;
    for (argv) |arg| {
        if (prefix) {
            buffer[offset] = ' ';
            offset += 1;
        } else {
            prefix = true;
        }
        std.mem.copy(u8, buffer[offset .. offset + arg.len], arg);
        offset += arg.len;
    }
    std.debug.assert(offset == buffer.len);
    std.debug.warn("[RUN] {}\n", .{buffer});
}
pub fn getCommandStringLength(argv: []const []const u8) usize {
    var len: usize = 0;
    var prefix_length: u8 = 0;
    for (argv) |arg| {
        len += prefix_length + arg.len;
        prefix_length = 1;
    }
    return len;
}
pub fn appendCommandString(appender: *appendlib.Appender(u8), argv: []const []const u8) void {
    var prefix: []const u8 = "";
    for (argv) |arg| {
        appender.appendSlice(prefix);
        appender.appendSlice(arg);
        prefix = " ";
    }
}
pub fn shouldDeleteCompiler(master_points_to_opt: ?[]const u8, default_compiler_opt: ?[]const u8, name: []const u8) enum { yes, no_is_default, no_is_master } {
    if (default_compiler_opt) |default_comp| {
        if (mem.eql(u8, default_comp, name)) {
            return .no_is_default;
        }
    }
    if (master_points_to_opt) |master_points_to| {
        if (mem.eql(u8, master_points_to, name)) {
            return .no_is_master;
        }
    }
    return .yes;
}
