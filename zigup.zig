const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const ziget = @import("ziget");
const zarc = @import("zarc");

const fixdeletetree = @import("fixdeletetree.zig");

const arch = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    .riscv64 => "riscv64",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (builtin.os.tag) {
    .windows => "windows",
    .linux => "linux",
    .macos => "macos",
    else => @compileError("Unsupported OS"),
};
const url_platform = os ++ "-" ++ arch;
const json_platform = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

var global_optional_install_dir: ?[]const u8 = null;
var global_optional_path_link: ?[]const u8 = null;

var global_enable_log = true;
fn loginfo(comptime fmt: []const u8, args: anytype) void {
    if (global_enable_log) {
        std.debug.print(fmt ++ "\n", args);
    }
}

fn download(allocator: Allocator, url: []const u8, writer: anytype) !void {
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

fn downloadToFileAbsolute(allocator: Allocator, url: []const u8, file_absolute: []const u8) !void {
    const file = try std.fs.createFileAbsolute(file_absolute, .{});
    defer file.close();
    try download(allocator, url, file.writer());
}

fn downloadToString(allocator: Allocator, url: []const u8) ![]u8 {
    var response_array_list = try ArrayList(u8).initCapacity(allocator, 20 * 1024); // 20 KB (modify if response is expected to be bigger)
    errdefer response_array_list.deinit();
    try download(allocator, url, response_array_list.writer());
    return response_array_list.toOwnedSlice();
}

fn ignoreHttpCallback(request: []const u8) void {
    _ = request;
}

fn getHomeDir() ![]const u8 {
    return std.os.getenv("HOME") orelse {
        std.log.err("cannot find install directory, $HOME environment variable is not set", .{});
        return error.MissingHomeEnvironmentVariable;
    };
}

fn allocInstallDirString(allocator: Allocator) ![]const u8 {
    // TODO: maybe support ZIG_INSTALL_DIR environment variable?
    // TODO: maybe support a file on the filesystem to configure install dir?
    if (builtin.os.tag == .windows) {
        const self_exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
        defer allocator.free(self_exe_dir);
        return std.fs.path.join(allocator, &.{ self_exe_dir, "zig" });
    }
    const home = try getHomeDir();
    if (!std.fs.path.isAbsolute(home)) {
        std.log.err("$HOME environment variable '{s}' is not an absolute path", .{home});
        return error.BadHomeEnvironmentVariable;
    }
    return std.fs.path.join(allocator, &[_][]const u8{ home, "zig" });
}
const GetInstallDirOptions = struct {
    create: bool,
};
fn getInstallDir(allocator: Allocator, options: GetInstallDirOptions) ![]const u8 {
    var optional_dir_to_free_on_error: ?[]const u8 = null;
    errdefer if (optional_dir_to_free_on_error) |dir| allocator.free(dir);

    const install_dir = init: {
        if (global_optional_install_dir) |dir| break :init dir;
        optional_dir_to_free_on_error = try allocInstallDirString(allocator);
        break :init optional_dir_to_free_on_error.?;
    };
    std.debug.assert(std.fs.path.isAbsolute(install_dir));
    loginfo("install directory '{s}'", .{install_dir});
    if (options.create) {
        loggyMakeDirAbsolute(install_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
    return install_dir;
}

fn makeZigPathLinkString(allocator: Allocator) ![]const u8 {
    if (global_optional_path_link) |path| return path;

    const zigup_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(zigup_dir);

    return try std.fs.path.join(allocator, &[_][]const u8{ zigup_dir, comptime "zig" ++ builtin.target.exeFileExt() });
}

// TODO: this should be in standard lib
fn toAbsolute(allocator: Allocator, path: []const u8) ![]u8 {
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
        \\  zigup list                    list installed compiler versions
        \\  zigup clean   [VERSION]       deletes the given compiler version, otherwise, cleans all compilers
        \\                                that aren't the default, master, or marked to keep.
        \\  zigup keep VERSION            mark a compiler to be kept during clean
        \\  zigup run VERSION ARGS...     run the given VERSION of the compiler with the given ARGS...
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
        std.log.err("option '{s}' requires an argument", .{args[i.* - 1]});
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
    if (builtin.os.tag == .windows) {
        _ = try std.os.windows.WSAStartup(2, 2);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

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
                return 0;
            } else {
                if (newlen == 0 and std.mem.eql(u8, "run", arg)) {
                    return try runCompiler(allocator, args[i + 1 ..]);
                }
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
            std.log.err("'index' command requires 0 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        var download_index = try fetchDownloadIndex(allocator);
        defer download_index.deinit(allocator);
        try std.io.getStdOut().writeAll(download_index.text);
        return 0;
    }
    if (std.mem.eql(u8, "fetch", args[0])) {
        if (args.len != 2) {
            std.log.err("'fetch' command requires 1 argument but got {d}", .{args.len - 1});
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
            std.log.err("'clean' command requires 0 or 1 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, "keep", args[0])) {
        if (args.len != 2) {
            std.log.err("'keep' command requires 1 argument but got {d}", .{args.len - 1});
            return 1;
        }
        try keepCompiler(allocator, args[1]);
        return 0;
    }
    if (std.mem.eql(u8, "list", args[0])) {
        if (args.len != 1) {
            std.log.err("'list' command requires 0 arguments but got {d}", .{args.len - 1});
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
            const install_dir_string = try getInstallDir(allocator, .{ .create = true });
            defer allocator.free(install_dir_string);
            const resolved_version_string = init_resolved: {
                if (!std.mem.eql(u8, version_string, "master"))
                    break :init_resolved version_string;

                var optional_master_dir: ?[]const u8 = blk: {
                    var install_dir = std.fs.openIterableDirAbsolute(install_dir_string, .{}) catch |e| switch (e) {
                        error.FileNotFound => break :blk null,
                        else => return e,
                    };
                    defer install_dir.close();
                    break :blk try getMasterDir(allocator, &install_dir.dir);
                };
                // no need to free master_dir, this is a short lived program
                break :init_resolved optional_master_dir orelse {
                    std.log.err("master has not been fetched", .{});
                    return 1;
                };
            };
            const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir_string, resolved_version_string });
            defer allocator.free(compiler_dir);
            try setDefaultCompiler(allocator, compiler_dir, .verify_existence);
            return 0;
        }
        std.log.err("'default' command requires 1 or 2 arguments but got {d}", .{args.len - 1});
        return 1;
    }
    if (args.len == 1) {
        try fetchCompiler(allocator, args[0], .set_default);
        return 0;
    }
    const command = args[0];
    args = args[1..];
    std.log.err("command not impl '{s}'", .{command});
    return 1;

    //const optionalInstallPath = try find_zigs(allocator);
}

pub fn runCompiler(allocator: Allocator, args: []const []const u8) !u8 {
    // disable log so we don't add extra output to whatever the compiler will output
    global_enable_log = false;
    if (args.len <= 1) {
        std.log.err("zigup run requires at least 2 arguments: zigup run VERSION PROG ARGS...", .{});
        return 1;
    }
    const version_string = args[0];
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);

    const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir_string, version_string });
    defer allocator.free(compiler_dir);
    if (!try existsAbsolute(compiler_dir)) {
        std.log.err("compiler '{s}' does not exist, fetch it first with: zigup fetch {0s}", .{version_string});
        return 1;
    }

    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.append(try std.fs.path.join(allocator, &.{ compiler_dir, "files", comptime "zig" ++ builtin.target.exeFileExt() }));
    try argv.appendSlice(args[1..]);

    // TODO: use "execve" if on linux
    var proc = std.ChildProcess.init(argv.items, allocator);
    const ret_val = try proc.spawnAndWait();
    switch (ret_val) {
        .Exited => |code| return code,
        else => |result| {
            std.log.err("compiler exited with {}", .{result});
            return 0xff;
        },
    }
}

const SetDefault = enum { set_default, leave_default };

fn fetchCompiler(allocator: Allocator, version_arg: []const u8, set_default: SetDefault) !void {
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
        const master = optional_download_index.?.json.value.object.get("master").?;
        const compiler_version = master.object.get("version").?.string;
        const master_linux = master.object.get(json_platform).?;
        const master_linux_tarball = master_linux.object.get("tarball").?.string;
        break :blk VersionUrl{ .version = compiler_version, .url = master_linux_tarball };
    };
    const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, version_url.version });
    defer allocator.free(compiler_dir);
    try installCompiler(allocator, compiler_dir, version_url.url);
    if (is_master) {
        const master_symlink = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "master" });
        defer allocator.free(master_symlink);
        if (builtin.os.tag == .windows) {
            var file = try std.fs.createFileAbsolute(master_symlink, .{});
            defer file.close();
            try file.writer().writeAll(version_url.version);
        } else {
            _ = try loggyUpdateSymlink(version_url.version, master_symlink, .{ .is_directory = true });
        }
    }
    if (set_default == .set_default) {
        try setDefaultCompiler(allocator, compiler_dir, .existence_verified);
    }
}

const download_index_url = "https://ziglang.org/download/index.json";

const DownloadIndex = struct {
    text: []u8,
    json: std.json.Parsed(std.json.Value),
    pub fn deinit(self: *DownloadIndex, allocator: Allocator) void {
        self.json.deinit();
        allocator.free(self.text);
    }
};

fn fetchDownloadIndex(allocator: Allocator) !DownloadIndex {
    const text = downloadToString(allocator, download_index_url) catch |e| switch (e) {
        else => {
            std.log.err("failed to download '{s}': {}", .{ download_index_url, e });
            return e;
        },
    };
    errdefer allocator.free(text);
    var json = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    errdefer json.deinit();
    return DownloadIndex{ .text = text, .json = json };
}

fn loggyMakeDirAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        loginfo("mkdir \"{s}\"", .{dir_absolute});
    } else {
        loginfo("mkdir '{s}'", .{dir_absolute});
    }
    try std.fs.makeDirAbsolute(dir_absolute);
}

fn loggyDeleteTreeAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        loginfo("rd /s /q \"{s}\"", .{dir_absolute});
    } else {
        loginfo("rm -rf '{s}'", .{dir_absolute});
    }
    try fixdeletetree.deleteTreeAbsolute(dir_absolute);
}

pub fn loggyRenameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    loginfo("mv '{s}' '{s}'", .{ old_path, new_path });
    try std.fs.renameAbsolute(old_path, new_path);
}

pub fn loggySymlinkAbsolute(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.SymLinkFlags) !void {
    loginfo("ln -s '{s}' '{s}'", .{ target_path, sym_link_path });
    // NOTE: can't use symLinkAbsolute because it requires target_path to be absolute but we don't want that
    //       not sure if it is a bug in the standard lib or not
    //try std.fs.symLinkAbsolute(target_path, sym_link_path, flags);
    _ = flags;
    try std.os.symlink(target_path, sym_link_path);
}

/// returns: true if the symlink was updated, false if it was already set to the given `target_path`
pub fn loggyUpdateSymlink(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.SymLinkFlags) !bool {
    var current_target_path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    if (std.fs.readLinkAbsolute(sym_link_path, &current_target_path_buffer)) |current_target_path| {
        if (std.mem.eql(u8, target_path, current_target_path)) {
            loginfo("symlink '{s}' already points to '{s}'", .{ sym_link_path, target_path });
            return false; // already up-to-date
        }
        try std.os.unlink(sym_link_path);
    } else |e| switch (e) {
        error.FileNotFound => {},
        error.NotLink => {
            std.debug.print(
                "unable to update/overwrite the 'zig' PATH symlink, the file '{s}' already exists and is not a symlink\n",
                .{ sym_link_path},
            );
            std.os.exit(1);
        },
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

fn listCompilers(allocator: Allocator) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = false });
    defer allocator.free(install_dir_string);

    var install_dir = std.fs.openIterableDirAbsolute(install_dir_string, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();

    const stdout = std.io.getStdOut().writer();
    {
        var it = install_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory)
                continue;
            if (std.mem.endsWith(u8, entry.name, ".installing"))
                continue;
            try stdout.print("{s}\n", .{entry.name});
        }
    }
}

fn keepCompiler(allocator: Allocator, compiler_version: []const u8) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);

    var install_dir = try std.fs.openIterableDirAbsolute(install_dir_string, .{});
    defer install_dir.close();

    var compiler_dir = install_dir.dir.openDir(compiler_version, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("compiler not found: {s}", .{compiler_version});
            return error.AlreadyReported;
        },
        else => return e,
    };
    var keep_fd = try compiler_dir.createFile("keep", .{});
    keep_fd.close();
    loginfo("created '{s}{c}{s}{c}{s}'", .{ install_dir_string, std.fs.path.sep, compiler_version, std.fs.path.sep, "keep" });
}

fn cleanCompilers(allocator: Allocator, compiler_name_opt: ?[]const u8) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);
    // getting the current compiler
    const default_comp_opt = try getDefaultCompiler(allocator);
    defer if (default_comp_opt) |default_compiler| allocator.free(default_compiler);

    var install_dir = std.fs.openIterableDirAbsolute(install_dir_string, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();
    const master_points_to_opt = try getMasterDir(allocator, &install_dir.dir);
    defer if (master_points_to_opt) |master_points_to| allocator.free(master_points_to);
    if (compiler_name_opt) |compiler_name| {
        if (getKeepReason(master_points_to_opt, default_comp_opt, compiler_name)) |reason| {
            std.log.err("cannot clean '{s}' ({s})", .{ compiler_name, reason });
            return error.AlreadyReported;
        }
        loginfo("deleting '{s}{c}{s}'", .{ install_dir_string, std.fs.path.sep, compiler_name });
        try fixdeletetree.deleteTree(install_dir.dir, compiler_name);
    } else {
        var it = install_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory)
                continue;
            if (getKeepReason(master_points_to_opt, default_comp_opt, entry.name)) |reason| {
                loginfo("keeping '{s}' ({s})", .{ entry.name, reason });
                continue;
            }

            {
                var compiler_dir = try install_dir.dir.openDir(entry.name, .{});
                defer compiler_dir.close();
                if (compiler_dir.access("keep", .{})) |_| {
                    loginfo("keeping '{s}' (has keep file)", .{entry.name});
                    continue;
                } else |e| switch (e) {
                    error.FileNotFound => {},
                    else => return e,
                }
            }
            loginfo("deleting '{s}{c}{s}'", .{ install_dir_string, std.fs.path.sep, entry.name });
            try fixdeletetree.deleteTree(install_dir.dir, entry.name);
        }
    }
}
fn readDefaultCompiler(allocator: Allocator, buffer: *[std.fs.MAX_PATH_BYTES + 1]u8) !?[]const u8 {
    const path_link = try makeZigPathLinkString(allocator);
    defer allocator.free(path_link);

    if (builtin.os.tag == .windows) {
        var file = std.fs.openFileAbsolute(path_link, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close();
        try file.seekTo(win32exelink.exe_offset);
        const len = try file.readAll(buffer);
        if (len != buffer.len) {
            std.log.err("path link file '{s}' is too small", .{path_link});
            return error.AlreadyReported;
        }
        const target_exe = std.mem.sliceTo(buffer, 0);
        return try allocator.dupe(u8, targetPathToVersion(target_exe));
    }

    const target_path = std.fs.readLinkAbsolute(path_link, buffer[0..std.fs.MAX_PATH_BYTES]) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer allocator.free(target_path);
    return try allocator.dupe(u8, targetPathToVersion(target_path));
}
fn targetPathToVersion(target_path: []const u8) []const u8 {
    return std.fs.path.basename(std.fs.path.dirname(std.fs.path.dirname(target_path).?).?);
}

fn readMasterDir(buffer: *[std.fs.MAX_PATH_BYTES]u8, install_dir: *std.fs.Dir) !?[]const u8 {
    if (builtin.os.tag == .windows) {
        var file = install_dir.openFile("master", .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close();
        return buffer[0..try file.readAll(buffer)];
    }
    return install_dir.readLink("master", buffer) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
}

fn getDefaultCompiler(allocator: Allocator) !?[]const u8 {
    var buffer: [std.fs.MAX_PATH_BYTES + 1]u8 = undefined;
    const slice_path = (try readDefaultCompiler(allocator, &buffer)) orelse return null;
    var path_to_return = try allocator.alloc(u8, slice_path.len);
    std.mem.copy(u8, path_to_return, slice_path);
    return path_to_return;
}

fn getMasterDir(allocator: Allocator, install_dir: *std.fs.Dir) !?[]const u8 {
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const slice_path = (try readMasterDir(&buffer, install_dir)) orelse return null;
    var path_to_return = try allocator.alloc(u8, slice_path.len);
    std.mem.copy(u8, path_to_return, slice_path);
    return path_to_return;
}

fn printDefaultCompiler(allocator: Allocator) !void {
    const default_compiler_opt = try getDefaultCompiler(allocator);
    defer if (default_compiler_opt) |default_compiler| allocator.free(default_compiler);
    const stdout = std.io.getStdOut().writer();
    if (default_compiler_opt) |default_compiler| {
        try stdout.print("{s}\n", .{default_compiler});
    } else {
        try stdout.writeAll("<no-default>\n");
    }
}

const ExistVerify = enum { existence_verified, verify_existence };

fn setDefaultCompiler(allocator: Allocator, compiler_dir: []const u8, exist_verify: ExistVerify) !void {
    switch (exist_verify) {
        .existence_verified => {},
        .verify_existence => {
            var dir = std.fs.openDirAbsolute(compiler_dir, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.err("compiler '{s}' is not installed", .{std.fs.path.basename(compiler_dir)});
                    return error.AlreadyReported;
                },
                else => |e| return e,
            };
            dir.close();
        },
    }

    const path_link = try makeZigPathLinkString(allocator);
    defer allocator.free(path_link);

    const link_target = try std.fs.path.join(allocator, &[_][]const u8{ compiler_dir, "files", comptime "zig" ++ builtin.target.exeFileExt() });
    defer allocator.free(link_target);
    if (builtin.os.tag == .windows) {
        try createExeLink(link_target, path_link);
    } else {
        _ = try loggyUpdateSymlink(link_target, path_link, .{});
    }

    try verifyPathLink(allocator, path_link);
}

/// Verify that path_link will work.  It verifies that `path_link` is
/// in PATH and there is no zig executable in an earlier directory in PATH.
fn verifyPathLink(allocator: Allocator, path_link: []const u8) !void {
    const path_link_dir = std.fs.path.dirname(path_link) orelse {
        std.log.err("invalid '--path-link' '{s}', it must be a file (not the root directory)", .{path_link});
        return error.AlreadyReported;
    };

    const path_link_dir_id = blk: {
        var dir = std.fs.openDirAbsolute(path_link_dir, .{}) catch |err| {
            std.log.err("unable to open the path-link directory '{s}': {s}", .{ path_link_dir, @errorName(err) });
            return error.AlreadyReported;
        };
        defer dir.close();
        break :blk try FileId.initFromDir(dir, path_link);
    };

    if (builtin.os.tag == .windows) {
        const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return,
            else => |e| return e,
        };
        defer allocator.free(path_env);

        var free_pathext: ?[]const u8 = null;
        defer if (free_pathext) |p| allocator.free(p);

        const pathext_env = blk: {
            if (std.process.getEnvVarOwned(allocator, "PATHEXT")) |env| {
                free_pathext = env;
                break :blk env;
            } else |err| switch (err) {
                error.EnvironmentVariableNotFound => break :blk "",
                else => |e| return e,
            }
            break :blk "";
        };

        var path_it = std.mem.tokenize(u8, path_env, ";");
        while (path_it.next()) |path| {
            switch (try compareDir(path_link_dir_id, path)) {
                .missing => continue,
                // can't be the same directory because we were able to open and get
                // the file id for path_link_dir_id
                .access_denied => {},
                .match => return,
                .mismatch => {},
            }
            {
                const exe = try std.fs.path.join(allocator, &.{ path, "zig" });
                defer allocator.free(exe);
                try enforceNoZig(path_link, exe);
            }

            var ext_it = std.mem.tokenize(u8, pathext_env, ";");
            while (ext_it.next()) |ext| {
                if (ext.len == 0) continue;
                const basename = try std.mem.concat(allocator, u8, &.{ "zig", ext });
                defer allocator.free(basename);

                const exe = try std.fs.path.join(allocator, &.{ path, basename });
                defer allocator.free(exe);

                try enforceNoZig(path_link, exe);
            }
        }
    } else {
        var path_it = std.mem.tokenize(u8, std.os.getenv("PATH") orelse "", ":");
        while (path_it.next()) |path| {
            switch (try compareDir(path_link_dir_id, path)) {
                .missing => continue,
                // can't be the same directory because we were able to open and get
                // the file id for path_link_dir_id
                .access_denied => {},
                .match => return,
                .mismatch => {},
            }
            const exe = try std.fs.path.join(allocator, &.{ path, "zig" });
            defer allocator.free(exe);
            try enforceNoZig(path_link, exe);
        }
    }

    std.log.err("the path link '{s}' is not in PATH", .{path_link});
    return error.AlreadyReported;
}

fn compareDir(dir_id: FileId, other_dir: []const u8) !enum { missing, access_denied, match, mismatch } {
    var dir = std.fs.cwd().openDir(other_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => return .missing,
        error.AccessDenied => return .access_denied,
        else => |e| return e,
    };
    defer dir.close();
    return if (dir_id.eql(try FileId.initFromDir(dir, other_dir))) .match else .mismatch;
}

fn enforceNoZig(path_link: []const u8, exe: []const u8) !void {
    var file = std.fs.cwd().openFile(exe, .{}) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return,
        error.AccessDenied => return, // if there is a Zig it must not be accessible
        else => |e| return e,
    };
    defer file.close();

    // todo: on posix systems ignore the file if it is not executable
    std.log.err("zig compiler '{s}' is higher priority in PATH than the path-link '{s}'", .{ exe, path_link });
}

const FileId = struct {
    dev: if (builtin.os.tag == .windows) u32 else blk: {
        var st: std.os.Stat = undefined;
        break :blk @TypeOf(st.dev);
    },
    ino: if (builtin.os.tag == .windows) u64 else blk: {
        var st: std.os.Stat = undefined;
        break :blk @TypeOf(st.ino);
    },

    pub fn initFromFile(file: std.fs.File, filename_for_error: []const u8) !FileId {
        if (builtin.os.tag == .windows) {
            var info: win32.BY_HANDLE_FILE_INFORMATION = undefined;
            if (0 == win32.GetFileInformationByHandle(file.handle, &info)) {
                std.log.err("GetFileInformationByHandle on '{s}' failed, error={}", .{ filename_for_error, std.os.windows.kernel32.GetLastError() });
                return error.AlreadyReported;
            }
            return FileId{
                .dev = info.dwVolumeSerialNumber,
                .ino = (@as(u64, @intCast(info.nFileIndexHigh)) << 32) | @as(u64, @intCast(info.nFileIndexLow)),
            };
        }
        const st = try std.os.fstat(file.handle);
        return FileId{
            .dev = st.dev,
            .ino = st.ino,
        };
    }

    pub fn initFromDir(dir: std.fs.Dir, name_for_error: []const u8) !FileId {
        if (builtin.os.tag == .windows) {
            return initFromFile(std.fs.File{ .handle = dir.fd }, name_for_error);
        }
        return initFromFile(std.fs.File{ .handle = dir.fd }, name_for_error);
    }

    pub fn eql(self: FileId, other: FileId) bool {
        return self.dev == other.dev and self.ino == other.ino;
    }
};

const win32 = struct {
    pub const BOOL = i32;
    pub const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };
    pub const BY_HANDLE_FILE_INFORMATION = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        dwVolumeSerialNumber: u32,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
        nNumberOfLinks: u32,
        nFileIndexHigh: u32,
        nFileIndexLow: u32,
    };
    pub extern "kernel32" fn GetFileInformationByHandle(
        hFile: ?@import("std").os.windows.HANDLE,
        lpFileInformation: ?*BY_HANDLE_FILE_INFORMATION,
    ) callconv(@import("std").os.windows.WINAPI) BOOL;
};

const win32exelink = struct {
    const content = @embedFile("win32exelink");
    const exe_offset: usize = if (builtin.os.tag != .windows) 0 else blk: {
        @setEvalBranchQuota(content.len * 2);
        const marker = "!!!THIS MARKS THE zig_exe_string MEMORY!!#";
        const offset = std.mem.indexOf(u8, content, marker) orelse {
            @compileError("win32exelink is missing the marker: " ++ marker);
        };
        if (std.mem.indexOf(u8, content[offset + 1 ..], marker) != null) {
            @compileError("win32exelink contains multiple markers (not implemented)");
        }
        break :blk offset + marker.len;
    };
};
fn createExeLink(link_target: []const u8, path_link: []const u8) !void {
    if (path_link.len > std.fs.MAX_PATH_BYTES) {
        std.debug.print("Error: path_link (size {}) is too large (max {})\n", .{ path_link.len, std.fs.MAX_PATH_BYTES });
        return error.AlreadyReported;
    }
    const file = std.fs.cwd().createFile(path_link, .{}) catch |err| switch (err) {
        error.IsDir => {
            std.debug.print(
                "unable to create the exe link, the path '{s}' is a directory\n",
                .{ path_link},
            );
            std.os.exit(1);
        },
        else => |e| return e,
    };
    defer file.close();
    try file.writer().writeAll(win32exelink.content[0..win32exelink.exe_offset]);
    try file.writer().writeAll(link_target);
    try file.writer().writeAll(win32exelink.content[win32exelink.exe_offset + link_target.len ..]);
}

const VersionKind = enum { release, dev };
fn determineVersionKind(version: []const u8) VersionKind {
    return if (std.mem.indexOfAny(u8, version, "-+")) |_| .dev else .release;
}

fn getDefaultUrl(allocator: Allocator, compiler_version: []const u8) ![]const u8 {
    return switch (determineVersionKind(compiler_version)) {
        .dev => try std.fmt.allocPrint(allocator, "https://ziglang.org/builds/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext, .{compiler_version}),
        .release => try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{s}/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext, .{compiler_version}),
    };
}

fn installCompiler(allocator: Allocator, compiler_dir: []const u8, url: []const u8) !void {
    if (try existsAbsolute(compiler_dir)) {
        loginfo("compiler '{s}' already installed", .{compiler_dir});
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
        loginfo("downloading '{s}' to '{s}'", .{ url, archive_absolute });
        downloadToFileAbsolute(allocator, url, archive_absolute) catch |e| switch (e) {
            error.HttpNon200StatusCode => {
                // TODO: more information would be good
                std.log.err("HTTP request failed (TODO: improve ziget library to get better error)", .{});
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
            var recognized = false;
            if (builtin.os.tag == .windows) {
                if (std.mem.endsWith(u8, archive_basename, ".zip")) {
                    recognized = true;
                    archive_root_dir = archive_basename[0 .. archive_basename.len - ".zip".len];

                    var installing_dir_opened = try std.fs.openDirAbsolute(installing_dir, .{});
                    defer installing_dir_opened.close();
                    loginfo("extracting archive to \"{s}\"", .{installing_dir});
                    var timer = try std.time.Timer.start();
                    var archive_file = try std.fs.openFileAbsolute(archive_absolute, .{});
                    defer archive_file.close();
                    const reader = archive_file.reader();
                    var archive = try zarc.zip.load(allocator, reader);
                    defer archive.deinit(allocator);
                    _ = try archive.extract(reader, installing_dir_opened, .{});
                    const time = timer.read();
                    loginfo("extracted archive in {d:.2} s", .{@as(f32, @floatFromInt(time)) / @as(f32, @floatFromInt(std.time.ns_per_s))});
                }
            }

            if (!recognized) {
                std.log.err("unknown archive extension '{s}'", .{archive_basename});
                return error.UnknownArchiveExtension;
            }
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

pub fn run(allocator: Allocator, argv: []const []const u8) !std.ChildProcess.Term {
    try logRun(allocator, argv);
    var proc = std.ChildProcess.init(argv, allocator);
    return proc.spawnAndWait();
}

fn logRun(allocator: Allocator, argv: []const []const u8) !void {
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
    loginfo("[RUN] {s}", .{buffer});
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

pub fn getKeepReason(master_points_to_opt: ?[]const u8, default_compiler_opt: ?[]const u8, name: []const u8) ?[]const u8 {
    if (default_compiler_opt) |default_comp| {
        if (mem.eql(u8, default_comp, name)) {
            return "is default compiler";
        }
    }
    if (master_points_to_opt) |master_points_to| {
        if (mem.eql(u8, master_points_to, name)) {
            return "it is master";
        }
    }
    return null;
}
