const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const fixdeletetree = @import("fixdeletetree.zig");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .powerpc64le => "powerpc64le",
    .riscv64 => "riscv64",
    .s390x => "s390x",
    .x86 => "x86",
    .x86_64 => "x86_64",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (builtin.os.tag) {
    .linux => "linux",
    .macos => "macos",
    .windows => "windows",
    else => @compileError("Unsupported OS"),
};
const os_arch = os ++ "-" ++ arch;
const arch_os = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

var global_override_appdata: ?[]const u8 = null; // only used for testing
var global_optional_install_dir: ?[]const u8 = null;
var global_optional_path_link: ?[]const u8 = null;

var global_enable_log = true;
fn loginfo(comptime fmt: []const u8, args: anytype) void {
    if (global_enable_log) {
        std.debug.print(fmt ++ "\n", args);
    }
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const DownloadResult = union(enum) {
    ok: void,
    err: []u8,
    pub fn deinit(self: DownloadResult, allocator: Allocator) void {
        switch (self) {
            .ok => {},
            .err => |e| allocator.free(e),
        }
    }
};
fn download(allocator: Allocator, url: []const u8, writer: anytype) DownloadResult {
    const uri = std.Uri.parse(url) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "the URL is invalid ({s})",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    client.initDefaultProxies(allocator) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to query the HTTP proxy settings with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    var header_buffer: [4096]u8 = undefined;
    var request = client.open(.GET, uri, .{
        .server_header_buffer = &header_buffer,
        .keep_alive = false,
    }) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to connect to the HTTP server with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    defer request.deinit();

    request.send() catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to send the HTTP request with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };
    request.wait() catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to read the HTTP response headers with {s}",
        .{@errorName(err)},
    ) catch |e| oom(e) };

    if (request.response.status != .ok) return .{ .err = std.fmt.allocPrint(
        allocator,
        "the HTTP server replied with unsuccessful response '{d} {s}'",
        .{ @intFromEnum(request.response.status), request.response.status.phrase() orelse "" },
    ) catch |e| oom(e) };

    // TODO: we take advantage of request.response.content_length

    var buf: [4096]u8 = undefined;
    while (true) {
        const len = request.reader().read(&buf) catch |err| return .{ .err = std.fmt.allocPrint(
            allocator,
            "failed to read the HTTP response body with {s}'",
            .{@errorName(err)},
        ) catch |e| oom(e) };
        if (len == 0)
            return .ok;
        writer.writeAll(buf[0..len]) catch |err| return .{ .err = std.fmt.allocPrint(
            allocator,
            "failed to write the HTTP response body with {s}'",
            .{@errorName(err)},
        ) catch |e| oom(e) };
    }
}

const DownloadStringResult = union(enum) {
    ok: []u8,
    err: []u8,
};
fn downloadToString(allocator: Allocator, url: []const u8) DownloadStringResult {
    var response_array_list = ArrayList(u8).initCapacity(allocator, 50 * 1024) catch |e| oom(e); // 50 KB (modify if response is expected to be bigger)
    defer response_array_list.deinit();
    switch (download(allocator, url, response_array_list.writer())) {
        .ok => return .{ .ok = response_array_list.toOwnedSlice() catch |e| oom(e) },
        .err => |e| return .{ .err = e },
    }
}

fn ignoreHttpCallback(request: []const u8) void {
    _ = request;
}

fn allocInstallDirStringXdg(allocator: Allocator) error{AlreadyReported}![]const u8 {
    // see https://specifications.freedesktop.org/basedir-spec/latest/#variables
    // try $XDG_DATA_HOME/zigup first
    xdg_var: {
        const xdg_data_home = std.posix.getenv("XDG_DATA_HOME") orelse break :xdg_var;
        if (xdg_data_home.len == 0) break :xdg_var;
        if (!std.fs.path.isAbsolute(xdg_data_home)) {
            std.log.err("$XDG_DATA_HOME environment variable '{s}' is not an absolute path", .{xdg_data_home});
            return error.AlreadyReported;
        }
        return std.fs.path.join(allocator, &[_][]const u8{ xdg_data_home, "zigup" }) catch |e| oom(e);
    }
    // .. then fallback to $HOME/.local/share/zigup
    const home = std.posix.getenv("HOME") orelse {
        std.log.err("cannot find install directory, neither $HOME nor $XDG_DATA_HOME environment variables are set", .{});
        return error.AlreadyReported;
    };
    if (!std.fs.path.isAbsolute(home)) {
        std.log.err("$HOME environment variable '{s}' is not an absolute path", .{home});
        return error.AlreadyReported;
    }
    return std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "share", "zigup" }) catch |e| oom(e);
}

fn getSettingsDir(allocator: Allocator) ?[]const u8 {
    const appdata: ?[]const u8 = std.fs.getAppDataDir(allocator, "zigup") catch |err| switch (err) {
        error.OutOfMemory => |e| oom(e),
        error.AppDataDirUnavailable => null,
    };
    // just used for testing, but note we still test getting the builtin appdata dir either way
    if (global_override_appdata) |appdata_override| {
        if (appdata) |a| allocator.free(a);
        return allocator.dupe(u8, appdata_override) catch |e| oom(e);
    }
    return appdata;
}

fn readInstallDir(allocator: Allocator) !?[]const u8 {
    const settings_dir_path = getSettingsDir(allocator) orelse return null;
    defer allocator.free(settings_dir_path);
    const setting_path = std.fs.path.join(allocator, &.{ settings_dir_path, "install-dir" }) catch |e| oom(e);
    defer allocator.free(setting_path);
    const content = blk: {
        var file = std.fs.cwd().openFile(setting_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| {
                std.log.err("open '{s}' failed with {s}", .{ setting_path, @errorName(e) });
                return error.AlreadyReported;
            },
        };
        defer file.close();
        break :blk file.readToEndAlloc(allocator, 9999) catch |err| {
            std.log.err("read install dir from '{s}' failed with {s}", .{ setting_path, @errorName(err) });
            return error.AlreadyReported;
        };
    };
    errdefer allocator.free(content);
    const stripped = std.mem.trimRight(u8, content, " \r\n");

    if (!std.fs.path.isAbsolute(stripped)) {
        std.log.err("install directory '{s}' is not an absolute path, fix this by running `zigup set-install-dir`", .{stripped});
        return error.BadInstallDirSetting;
    }

    return allocator.realloc(content, stripped.len) catch |e| oom(e);
}

fn saveInstallDir(allocator: Allocator, maybe_dir: ?[]const u8) !void {
    const settings_dir_path = getSettingsDir(allocator) orelse {
        std.log.err("cannot save install dir, unable to find a suitable settings directory", .{});
        return error.AlreadyReported;
    };
    defer allocator.free(settings_dir_path);
    const setting_path = std.fs.path.join(allocator, &.{ settings_dir_path, "install-dir" }) catch |e| oom(e);
    defer allocator.free(setting_path);
    if (maybe_dir) |d| {
        if (std.fs.path.dirname(setting_path)) |dir| try std.fs.cwd().makePath(dir);

        {
            const file = try std.fs.cwd().createFile(setting_path, .{});
            defer file.close();
            try file.writer().writeAll(d);
        }

        // sanity check, read it back
        const readback = (try readInstallDir(allocator)) orelse {
            std.log.err("unable to readback install-dir after saving it", .{});
            return error.AlreadyReported;
        };
        defer allocator.free(readback);
        if (!std.mem.eql(u8, readback, d)) {
            std.log.err("saved install dir readback mismatch\nwrote: '{s}'\nread : '{s}'\n", .{ d, readback });
            return error.AlreadyReported;
        }
    } else {
        std.fs.cwd().deleteFile(setting_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }
}

fn getBuiltinInstallDir(allocator: Allocator) error{AlreadyReported}![]const u8 {
    if (builtin.os.tag == .windows) {
        const self_exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch |e| {
            std.log.err("failed to get exe dir path with {s}", .{@errorName(e)});
            return error.AlreadyReported;
        };
        defer allocator.free(self_exe_dir);
        return std.fs.path.join(allocator, &.{ self_exe_dir, "zig" }) catch |e| oom(e);
    }
    return allocInstallDirStringXdg(allocator);
}

fn allocInstallDirString(allocator: Allocator) error{ AlreadyReported, BadInstallDirSetting }![]const u8 {
    if (try readInstallDir(allocator)) |d| return d;
    return try getBuiltinInstallDir(allocator);
}
const GetInstallDirOptions = struct {
    create: bool,
    log: bool = true,
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
    if (options.log) {
        loginfo("install directory '{s}'", .{install_dir});
    }
    if (options.create) {
        loggyMakePath(install_dir) catch |e| switch (e) {
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

fn help(allocator: Allocator) !void {
    const builtin_install_dir = getBuiltinInstallDir(allocator) catch |err| switch (err) {
        error.AlreadyReported => "unknown (see error printed above)",
    };
    const current_install_dir = allocInstallDirString(allocator) catch |err| switch (err) {
        error.AlreadyReported => "unknown (see error printed above)",
        error.BadInstallDirSetting => "invalid (fix with zigup set-install-dir)",
    };
    const setting_file: []const u8 = blk: {
        if (getSettingsDir(allocator)) |d| break :blk std.fs.path.join(allocator, &.{ d, "install-dir" }) catch |e| oom(e);
        break :blk "unavailable";
    };

    try std.io.getStdErr().writer().print(
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
        \\  zigup get-install-dir         prints the install directory to stdout
        \\  zigup set-install-dir [PATH]  set the default install directory, omitting the PATH reverts to the builtin default
        \\                                current default: {s}
        \\                                setting file   : {s}
        \\                                builtin default: {s}
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
        \\  --index                       override the default index URL that zig versions/URLs are fetched from.
        \\                                default:
    ++ " " ++ default_index_url ++
        \\
        \\
    ,
        .{
            current_install_dir,
            setting_file,
            builtin_install_dir,
        },
    );
}

fn getCmdOpt(args: [][:0]u8, i: *usize) ![]const u8 {
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

    var index_url: []const u8 = default_index_url;

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
            } else if (std.mem.eql(u8, "--index", arg)) {
                index_url = try getCmdOpt(args, &i);
            } else if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
                try help(allocator);
                return 0;
            } else if (std.mem.eql(u8, "--appdata", arg)) {
                // NOTE: this is a private option just used for testing
                global_override_appdata = try getCmdOpt(args, &i);
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
        try help(allocator);
        return 1;
    }
    if (std.mem.eql(u8, "get-install-dir", args[0])) {
        if (args.len != 1) {
            std.log.err("get-install-dir does not accept any cmdline arguments", .{});
            return 1;
        }
        const install_dir = getInstallDir(allocator, .{ .create = false, .log = false }) catch |err| switch (err) {
            error.AlreadyReported => return 1,
            else => |e| return e,
        };
        try std.io.getStdOut().writer().writeAll(install_dir);
        try std.io.getStdOut().writer().writeAll("\n");
        return 0;
    }
    if (std.mem.eql(u8, "set-install-dir", args[0])) {
        const set_args = args[1..];
        switch (set_args.len) {
            0 => try saveInstallDir(allocator, null),
            1 => {
                const path = set_args[0];
                if (!std.fs.path.isAbsolute(path)) {
                    std.log.err("set-install-dir requires an absolute path", .{});
                    return 1;
                }
                try saveInstallDir(allocator, path);
            },
            else => |set_arg_count| {
                std.log.err("set-install-dir requires 0 or 1 cmdline arg but got {}", .{set_arg_count});
                return 1;
            },
        }
        return 0;
    }
    if (std.mem.eql(u8, "fetch-index", args[0])) {
        if (args.len != 1) {
            std.log.err("'index' command requires 0 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        var download_index = try fetchDownloadIndex(allocator, index_url);
        defer download_index.deinit(allocator);
        try std.io.getStdOut().writeAll(download_index.text);
        return 0;
    }
    if (std.mem.eql(u8, "fetch", args[0])) {
        if (args.len != 2) {
            std.log.err("'fetch' command requires 1 argument but got {d}", .{args.len - 1});
            return 1;
        }
        try fetchCompiler(allocator, index_url, args[1], .leave_default);
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

                const optional_master_dir: ?[]const u8 = blk: {
                    var install_dir = std.fs.openDirAbsolute(install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
                        error.FileNotFound => break :blk null,
                        else => return e,
                    };
                    defer install_dir.close();
                    break :blk try getMasterDir(allocator, &install_dir);
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
        try fetchCompiler(allocator, index_url, args[0], .set_default);
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
    var proc = std.process.Child.init(argv.items, allocator);
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

fn fetchCompiler(
    allocator: Allocator,
    index_url: []const u8,
    version_arg: []const u8,
    set_default: SetDefault,
) !void {
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
        // For default index_url we can build the url so we avoid downloading the index
        if (!is_master and std.mem.eql(u8, default_index_url, index_url))
            break :blk VersionUrl{ .version = version_arg, .url = try getDefaultUrl(allocator, version_arg) };
        optional_download_index = try fetchDownloadIndex(allocator, index_url);
        const master = optional_download_index.?.json.value.object.get(version_arg).?;
        const compiler_version = master.object.get("version").?.string;
        const master_linux = master.object.get(arch_os).?;
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

const default_index_url = "https://ziglang.org/download/index.json";

const DownloadIndex = struct {
    text: []u8,
    json: std.json.Parsed(std.json.Value),
    pub fn deinit(self: *DownloadIndex, allocator: Allocator) void {
        self.json.deinit();
        allocator.free(self.text);
    }
};

fn fetchDownloadIndex(allocator: Allocator, index_url: []const u8) !DownloadIndex {
    const text = switch (downloadToString(allocator, index_url)) {
        .ok => |text| text,
        .err => |err| {
            std.log.err("could not download '{s}': {s}", .{ index_url, err });
            return error.AlreadyReported;
        },
    };
    errdefer allocator.free(text);
    var json = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch |e| {
        std.log.err(
            "failed to parse JSON content from index url '{s}' with {s}",
            .{ index_url, @errorName(e) },
        );
        return error.AlreadyReported;
    };
    errdefer json.deinit();
    return DownloadIndex{ .text = text, .json = json };
}

fn loggyMakePath(dir_absolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        loginfo("mkdir \"{s}\"", .{dir_absolute});
    } else {
        loginfo("mkdir -p '{s}'", .{dir_absolute});
    }
    try std.fs.cwd().makePath(dir_absolute);
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

pub fn loggySymlinkAbsolute(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.Dir.SymLinkFlags) !void {
    loginfo("ln -s '{s}' '{s}'", .{ target_path, sym_link_path });
    // NOTE: can't use symLinkAbsolute because it requires target_path to be absolute but we don't want that
    //       not sure if it is a bug in the standard lib or not
    //try std.fs.symLinkAbsolute(target_path, sym_link_path, flags);
    _ = flags;
    try std.posix.symlink(target_path, sym_link_path);
}

/// returns: true if the symlink was updated, false if it was already set to the given `target_path`
pub fn loggyUpdateSymlink(target_path: []const u8, sym_link_path: []const u8, flags: std.fs.Dir.SymLinkFlags) !bool {
    var current_target_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.readLinkAbsolute(sym_link_path, &current_target_path_buffer)) |current_target_path| {
        if (std.mem.eql(u8, target_path, current_target_path)) {
            loginfo("symlink '{s}' already points to '{s}'", .{ sym_link_path, target_path });
            return false; // already up-to-date
        }
        try std.posix.unlink(sym_link_path);
    } else |e| switch (e) {
        error.FileNotFound => {},
        error.NotLink => {
            std.debug.print(
                "unable to update/overwrite the 'zig' PATH symlink, the file '{s}' already exists and is not a symlink\n",
                .{sym_link_path},
            );
            std.process.exit(1);
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
        error.InvalidUtf8 => return e,
        error.InvalidWtf8 => return e,
        error.ReadOnlyFileSystem => unreachable,
        error.NameTooLong => unreachable,
        error.BadPathName => unreachable,
    };
    return true;
}

fn listCompilers(allocator: Allocator) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = false });
    defer allocator.free(install_dir_string);

    var install_dir = std.fs.openDirAbsolute(install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
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

    var install_dir = try std.fs.openDirAbsolute(install_dir_string, .{ .iterate = true });
    defer install_dir.close();

    var compiler_dir = install_dir.openDir(compiler_version, .{}) catch |e| switch (e) {
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

    var install_dir = std.fs.openDirAbsolute(install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();
    const master_points_to_opt = try getMasterDir(allocator, &install_dir);
    defer if (master_points_to_opt) |master_points_to| allocator.free(master_points_to);
    if (compiler_name_opt) |compiler_name| {
        if (getKeepReason(master_points_to_opt, default_comp_opt, compiler_name)) |reason| {
            std.log.err("cannot clean '{s}' ({s})", .{ compiler_name, reason });
            return error.AlreadyReported;
        }
        loginfo("deleting '{s}{c}{s}'", .{ install_dir_string, std.fs.path.sep, compiler_name });
        try fixdeletetree.deleteTree(install_dir, compiler_name);
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
                var compiler_dir = try install_dir.openDir(entry.name, .{});
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
            try fixdeletetree.deleteTree(install_dir, entry.name);
        }
    }
}
fn readDefaultCompiler(allocator: Allocator, buffer: *[std.fs.max_path_bytes + 1]u8) !?[]const u8 {
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

    const target_path = std.fs.readLinkAbsolute(path_link, buffer[0..std.fs.max_path_bytes]) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer allocator.free(target_path);
    return try allocator.dupe(u8, targetPathToVersion(target_path));
}
fn targetPathToVersion(target_path: []const u8) []const u8 {
    return std.fs.path.basename(std.fs.path.dirname(std.fs.path.dirname(target_path).?).?);
}

fn readMasterDir(buffer: *[std.fs.max_path_bytes]u8, install_dir: *std.fs.Dir) !?[]const u8 {
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
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const slice_path = (try readDefaultCompiler(allocator, &buffer)) orelse return null;
    const path_to_return = try allocator.alloc(u8, slice_path.len);
    @memcpy(path_to_return, slice_path);
    return path_to_return;
}

fn getMasterDir(allocator: Allocator, install_dir: *std.fs.Dir) !?[]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const slice_path = (try readMasterDir(&buffer, install_dir)) orelse return null;
    const path_to_return = try allocator.alloc(u8, slice_path.len);
    @memcpy(path_to_return, slice_path);
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

    const link_target = try std.fs.path.join(
        allocator,
        &[_][]const u8{ compiler_dir, "files", comptime "zig" ++ builtin.target.exeFileExt() },
    );
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

        var path_it = std.mem.tokenizeScalar(u8, path_env, ';');
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

            var ext_it = std.mem.tokenizeScalar(u8, pathext_env, ';');
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
        var path_it = std.mem.tokenizeScalar(u8, std.posix.getenv("PATH") orelse "", ':');
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
        const st: std.posix.Stat = undefined;
        break :blk @TypeOf(st.dev);
    },
    ino: if (builtin.os.tag == .windows) u64 else blk: {
        const st: std.posix.Stat = undefined;
        break :blk @TypeOf(st.ino);
    },

    pub fn initFromFile(file: std.fs.File, filename_for_error: []const u8) !FileId {
        if (builtin.os.tag == .windows) {
            var info: win32.BY_HANDLE_FILE_INFORMATION = undefined;
            if (0 == win32.GetFileInformationByHandle(file.handle, &info)) {
                std.log.err(
                    "GetFileInformationByHandle on '{s}' failed, error={}",
                    .{ filename_for_error, @intFromEnum(std.os.windows.kernel32.GetLastError()) },
                );
                return error.AlreadyReported;
            }
            return FileId{
                .dev = info.dwVolumeSerialNumber,
                .ino = (@as(u64, @intCast(info.nFileIndexHigh)) << 32) | @as(u64, @intCast(info.nFileIndexLow)),
            };
        }
        const st = try std.posix.fstat(file.handle);
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
    if (path_link.len > std.fs.max_path_bytes) {
        std.debug.print("Error: path_link (size {}) is too large (max {})\n", .{ path_link.len, std.fs.max_path_bytes });
        return error.AlreadyReported;
    }
    const file = std.fs.cwd().createFile(path_link, .{}) catch |err| switch (err) {
        error.IsDir => {
            std.debug.print(
                "unable to create the exe link, the path '{s}' is a directory\n",
                .{path_link},
            );
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer file.close();
    try file.writer().writeAll(win32exelink.content[0..win32exelink.exe_offset]);
    try file.writer().writeAll(link_target);
    try file.writer().writeAll(win32exelink.content[win32exelink.exe_offset + link_target.len ..]);
}

const VersionKind = union(enum) { release: Release, dev };
fn determineVersionKind(version: []const u8) VersionKind {
    const v = SemanticVersion.parse(version) orelse std.debug.panic(
        "invalid version '{s}'",
        .{version},
    );
    if (v.pre != null or v.build != null) return .dev;
    return .{ .release = .{ .major = v.major, .minor = v.minor, .patch = v.patch } };
}

const Release = struct {
    major: usize,
    minor: usize,
    patch: usize,
    pub fn order(a: Release, b: Release) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

// The Zig release where the OS-ARCH in the url was swapped to ARCH-OS
const arch_os_swap_release: Release = .{ .major = 0, .minor = 14, .patch = 1 };

const SemanticVersion = struct {
    const max_pre = 50;
    const max_build = 50;
    const max_string = 50 + max_pre + max_build;

    major: usize,
    minor: usize,
    patch: usize,
    pre: ?std.BoundedArray(u8, max_pre),
    build: ?std.BoundedArray(u8, max_build),

    pub fn array(self: *const SemanticVersion) std.BoundedArray(u8, max_string) {
        var result: std.BoundedArray(u8, max_string) = undefined;
        const roundtrip = std.fmt.bufPrint(&result.buffer, "{}", .{self}) catch unreachable;
        result.len = roundtrip.len;
        return result;
    }

    pub fn parse(s: []const u8) ?SemanticVersion {
        const parsed = std.SemanticVersion.parse(s) catch |e| switch (e) {
            error.Overflow, error.InvalidVersion => return null,
        };
        std.debug.assert(s.len <= max_string);

        var result: SemanticVersion = .{
            .major = parsed.major,
            .minor = parsed.minor,
            .patch = parsed.patch,
            .pre = if (parsed.pre) |pre| std.BoundedArray(u8, max_pre).init(pre.len) catch |e| switch (e) {
                error.Overflow => std.debug.panic("semantic version pre '{s}' is too long (max is {})", .{ pre, max_pre }),
            } else null,
            .build = if (parsed.build) |build| std.BoundedArray(u8, max_build).init(build.len) catch |e| switch (e) {
                error.Overflow => std.debug.panic("semantic version build '{s}' is too long (max is {})", .{ build, max_build }),
            } else null,
        };
        if (parsed.pre) |pre| @memcpy(result.pre.?.slice(), pre);
        if (parsed.build) |build| @memcpy(result.build.?.slice(), build);

        {
            // sanity check, ensure format gives us the same string back we just parsed
            const roundtrip = result.array();
            if (!std.mem.eql(u8, roundtrip.slice(), s)) std.debug.panic(
                "codebug parse/format version mismatch:\nparsed: '{s}'\nformat: '{s}'\n",
                .{ s, roundtrip.slice() },
            );
        }

        return result;
    }
    pub fn ref(self: *const SemanticVersion) std.SemanticVersion {
        return .{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .pre = if (self.pre) |*pre| pre.slice() else null,
            .build = if (self.build) |*build| build.slice() else null,
        };
    }
    pub fn format(
        self: SemanticVersion,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try self.ref().format(fmt, options, writer);
    }
};

fn getDefaultUrl(allocator: Allocator, compiler_version: []const u8) ![]const u8 {
    return switch (determineVersionKind(compiler_version)) {
        .dev => try std.fmt.allocPrint(allocator, "https://ziglang.org/builds/zig-" ++ arch_os ++ "-{0s}." ++ archive_ext, .{compiler_version}),
        .release => |release| try std.fmt.allocPrint(
            allocator,
            "https://ziglang.org/download/{s}/zig-{1s}-{0s}." ++ archive_ext,
            .{
                compiler_version,
                switch (release.order(arch_os_swap_release)) {
                    .lt => os_arch,
                    .gt, .eq => arch_os,
                },
            },
        ),
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
    try loggyMakePath(installing_dir);

    const archive_basename = std.fs.path.basename(url);
    var archive_root_dir: []const u8 = undefined;

    // download and extract archive
    {
        const archive_absolute = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_basename });
        defer allocator.free(archive_absolute);
        loginfo("downloading '{s}' to '{s}'", .{ url, archive_absolute });

        switch (blk: {
            const file = try std.fs.createFileAbsolute(archive_absolute, .{});
            // note: important to close the file before we handle errors below
            //       since it will delete the parent directory of this file
            defer file.close();
            break :blk download(allocator, url, file.writer());
        }) {
            .ok => {},
            .err => |err| {
                std.log.err("could not download '{s}': {s}", .{ url, err });
                // this removes the installing dir if the http request fails so we dont have random directories
                try loggyDeleteTreeAbsolute(installing_dir);
                return error.AlreadyReported;
            },
        }

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
                    try std.zip.extract(installing_dir_opened, archive_file.seekableStream(), .{});
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

pub fn run(allocator: Allocator, argv: []const []const u8) !std.process.Child.Term {
    try logRun(allocator, argv);
    var proc = std.process.Child.init(argv, allocator);
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
        @memcpy(buffer[offset .. offset + arg.len], arg);
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
