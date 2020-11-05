const std = @import("std");
const builtin = std.builtin;
const mem = std.mem;

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const ziget = @import("ziget");

var globalOptionalInstallDir: ?[]const u8 = null;
var globalOptionalPathLink: ?[]const u8 = null;

fn find_zigs(allocator: *Allocator) !?[][]u8 {
    const ziglist = std.ArrayList([]u8).init(allocator);
    // don't worry about free for now, this is a short lived program

    if (builtin.os.tag == .windows) {
        @panic("windows not implemented");
        //const result = try runGetOutput(allocator, .{"where", "-a", "zig"});
    } else {
        const whichResult = try cmdlinetool.runGetOutput(allocator, .{ "which", "zig" });
        if (runutil.runFailed(&whichResult)) {
            return null;
        }
        if (whichResult.stderr.len > 0) {
            std.debug.warn("which command failed with:\n{}\n", .{whichResult.stderr});
            std.os.exit(1);
        }
        std.debug.warn("which output:\n{}\n", .{whichResult.stdout});
        {
            var i = std.mem.split(whichResult.stdout, "\n");
            while (i.next()) |dir| {
                std.debug.warn("path '{}'\n", .{dir});
            }
        }
    }
    @panic("not impl");
}

fn download(allocator: *Allocator, url: []const u8, writer: anytype) !void {
    var downloadOptions = ziget.request.DownloadOptions{
        .flags = 0,
        .allocator = allocator,
        .maxRedirects = 10,
        .forwardBufferSize = 4096,
        .maxHttpResponseHeaders = 8192,
        .onHttpRequest = ignoreHttpCallback,
        .onHttpResponse = ignoreHttpCallback,
    };
    var downloadState = ziget.request.DownloadState.init();
    try ziget.request.download(
        ziget.url.parseUrl(url) catch unreachable,
        writer,
        downloadOptions,
        &downloadState,
    );
}

fn downloadToFileAbsolute(allocator: *Allocator, url: []const u8, fileAbsolute: []const u8) !void {
    const file = try std.fs.createFileAbsolute(fileAbsolute, .{});
    defer file.close();
    try download(allocator, url, file.outStream());
}

fn downloadToString(allocator: *Allocator, url: []const u8) ![]u8 {
    var responseArrayList = try ArrayList(u8).initCapacity(allocator, 20 * 1024); // 20 KB (modify if response is expected to be bigger)
    errdefer responseArrayList.deinit();
    try download(allocator, url, responseArrayList.outStream());
    return responseArrayList.toOwnedSlice();
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
    var optionalDirToFreeOnError: ?[]const u8 = null;
    errdefer if (optionalDirToFreeOnError) |dir| allocator.free(dir);

    const installDir = init: {
        if (globalOptionalInstallDir) |dir| break :init dir;
        optionalDirToFreeOnError = try allocInstallDirString(allocator);
        break :init optionalDirToFreeOnError.?;
    };
    std.debug.assert(std.fs.path.isAbsolute(installDir));
    std.debug.warn("install directory '{}'\n", .{installDir});
    if (options.create) {
        loggyMakeDirAbsolute(installDir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
    return installDir;
}

fn makeZigPathLinkString(allocator: *Allocator) ![]const u8 {
    if (globalOptionalPathLink) |path| return path;

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

    const argsArray = try std.process.argsAlloc(allocator);
    // no need to free, os will do it
    //defer std.process.argsFree(allocator, argsArray);

    var args = if (argsArray.len == 0) argsArray else argsArray[1..];
    // parse common options
    //
    {
        var i: usize = 0;
        var newlen: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "--install-dir", arg)) {
                globalOptionalInstallDir = try getCmdOpt(args, &i);
                if (!std.fs.path.isAbsolute(globalOptionalInstallDir.?)) {
                    globalOptionalInstallDir = try toAbsolute(allocator, globalOptionalInstallDir.?);
                }
            } else if (std.mem.eql(u8, "--path-link", arg)) {
                globalOptionalPathLink = try getCmdOpt(args, &i);
                if (!std.fs.path.isAbsolute(globalOptionalPathLink.?)) {
                    globalOptionalPathLink = try toAbsolute(allocator, globalOptionalPathLink.?);
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
        var downloadIndex = try fetchDownloadIndex(allocator);
        defer downloadIndex.deinit(allocator);
        try std.io.getStdOut().writeAll(downloadIndex.text);
        return 0;
    }
    if (std.mem.eql(u8, "fetch", args[0])) {
        if (args.len != 2) {
            std.debug.warn("Error: 'fetch' command requires 1 argument but got {}\n", .{args.len - 1});
            return 1;
        }
        try fetchCompiler(allocator, args[1], .leaveDefault);
        return 0;
    }
    if (std.mem.eql(u8, "clean", args[0])) {
        if (args.len != 1) {
            std.debug.warn("Error: 'clean' command requires 0 arguments but got {}\n", .{args.len - 1});
            return 1;
        }
        try cleanCompilers(allocator);
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
            const versionString = args[1];
            const installDir = try getInstallDir(allocator, .{ .create = true });
            defer allocator.free(installDir);
            const compilerDir = try std.fs.path.join(allocator, &[_][]const u8{ installDir, versionString });
            defer allocator.free(compilerDir);
            try setDefaultCompiler(allocator, compilerDir);
            return 0;
        }
        std.debug.warn("Error: 'default' command requires 1 or 2 arguments but got {}\n", .{args.len - 1});
        return 1;
    }
    if (args.len == 1) {
        try fetchCompiler(allocator, args[0], .setDefault);
        return 0;
    }
    const command = args[0];
    args = args[1..];
    std.debug.warn("command not impl '{}'\n", .{command});
    return 1;

    //const optionalInstallPath = try find_zigs(allocator);
}

const SetDefault = enum { setDefault, leaveDefault };

fn fetchCompiler(allocator: *Allocator, versionArg: []const u8, setDefault: SetDefault) !void {
    const installDir = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(installDir);

    var optionalDownloadIndex: ?DownloadIndex = null;
    // This is causing an LLVM error
    //defer if (optionalDownloadIndex) |_| optionalDownloadIndex.?.deinit(allocator);
    // Also I would rather do this, but it doesn't work because of const issues
    //defer if (optionalDownloadIndex) |downloadIndex| downloadIndex.deinit(allocator);

    const VersionUrl = struct { version: []const u8, url: []const u8 };

    // NOTE: we only fetch the download index if the user wants to download 'master', we can skip
    //       this step for all other versions because the version to URL mapping is fixed (see getDefaultUrl)
    const isMaster = std.mem.eql(u8, versionArg, "master");
    const versionUrl = blk: {
        if (!isMaster)
            break :blk VersionUrl{ .version = versionArg, .url = try getDefaultUrl(allocator, versionArg) };
        optionalDownloadIndex = try fetchDownloadIndex(allocator);
        const master = optionalDownloadIndex.?.json.root.Object.get("master").?;
        const compilerVersion = master.Object.get("version").?.String;
        const masterLinux = master.Object.get("x86_64-linux").?;
        const masterLinuxTarball = masterLinux.Object.get("tarball").?.String;
        break :blk VersionUrl{ .version = compilerVersion, .url = masterLinuxTarball };
    };
    const compilerDir = try std.fs.path.join(allocator, &[_][]const u8{ installDir, versionUrl.version });
    defer allocator.free(compilerDir);
    try installCompiler(allocator, compilerDir, versionUrl.url);
    if (isMaster) {
        const masterSymlink = try std.fs.path.join(allocator, &[_][]const u8{ installDir, "master" });
        defer allocator.free(masterSymlink);
        _ = try loggyUpdateSymlink(versionUrl.version, masterSymlink, .{ .is_directory = true });
    }
    if (setDefault == .setDefault) {
        try setDefaultCompiler(allocator, compilerDir);
    }
}

const downloadIndexUrl = "https://ziglang.org/download/index.json";

const DownloadIndex = struct {
    text: []u8,
    json: std.json.ValueTree,
    pub fn deinit(self: *DownloadIndex, allocator: *Allocator) void {
        self.json.deinit();
        allocator.free(self.text);
    }
};

fn fetchDownloadIndex(allocator: *Allocator) !DownloadIndex {
    const text = downloadToString(allocator, downloadIndexUrl) catch |e| switch (e) {
        else => {
            std.debug.warn("failed to download '{}': {}\n", .{ downloadIndexUrl, e });
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

fn loggyMakeDirAbsolute(dirAbsolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        std.debug.warn("mkdir \"{}\"\n", .{dirAbsolute});
    } else {
        std.debug.warn("mkdir '{}'\n", .{dirAbsolute});
    }
    try std.fs.makeDirAbsolute(dirAbsolute);
}

fn loggyDeleteTreeAbsolute(dirAbsolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        std.debug.warn("rd /s /q \"{}\"\n", .{dirAbsolute});
    } else {
        std.debug.warn("rm -rf '{}'\n", .{dirAbsolute});
    }
    try std.fs.deleteTreeAbsolute(dirAbsolute);
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
    const installDirString = try getInstallDir(allocator, .{ .create = false });
    defer allocator.free(installDirString);

    var installDir = std.fs.cwd().openDir(installDirString, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer installDir.close();

    const stdout = std.io.getStdOut().writer();
    {
        var it = installDir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .Directory)
                continue;
            if (std.mem.endsWith(u8, entry.name, ".installing"))
                continue;
            try stdout.print("{}\n", .{entry.name});
        }
    }
}

fn cleanCompilers(allocator: *Allocator) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);
    // getting the current compiler
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const default_comp_opt = try getDefaultCompiler(allocator, &buffer);

    var install_dir = std.fs.cwd().openDir(install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close();
    var it = install_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .Directory)
            continue;
        if (default_comp_opt) |default_comp| {
            if (mem.eql(u8, default_comp, entry.name)) {
                std.debug.warn("keeping '{}' (is default compiler)\n", .{default_comp});
                continue;
            }
        }
        const abs_path_to_delete = try std.fs.path.join(allocator, &[_][]const u8{ install_dir_string, entry.name });
        // if its in the compilers to keep, skip it

        {
            const look_for_keep_path = try std.fs.path.join(allocator, &[_][]const u8{ abs_path_to_delete, "keep" });
            defer allocator.free(look_for_keep_path);
            // TODO stdlib should have acccessAbsolute
            if (std.fs.cwd().access(look_for_keep_path, .{})) |_| {
                std.debug.warn("keeping '{}' (has keep file)\n", .{entry.name});
                continue;
            } else |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            }
        }
        defer allocator.free(abs_path_to_delete);
        try loggyDeleteTreeAbsolute(abs_path_to_delete);
    }
}

fn getDefaultCompiler(allocator: *Allocator, buffer: *[std.fs.MAX_PATH_BYTES]u8) !?[]const u8 {
    const pathLink = try makeZigPathLinkString(allocator);
    defer allocator.free(pathLink);
    if (std.fs.readLinkAbsolute(pathLink, buffer)) |targetPath| {
        return std.fs.path.basename(std.fs.path.dirname(std.fs.path.dirname(targetPath).?).?);
    } else |e| switch (e) {
        error.FileNotFound => {
            return null;
        },
        else => return e,
    }
}
fn printDefaultCompiler(allocator: *Allocator) !void {
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const default_compiler_opt = try getDefaultCompiler(allocator, &buffer);
    if (default_compiler_opt) |default_compiler| {
        std.debug.warn("{}\n", .{default_compiler});
    } else {
        std.debug.warn("<no-default>\n", .{});
    }
}

fn setDefaultCompiler(allocator: *Allocator, compilerDir: []const u8) !void {
    const pathLink = try makeZigPathLinkString(allocator);
    defer allocator.free(pathLink);
    const linkTarget = try std.fs.path.join(allocator, &[_][]const u8{ compilerDir, "files", "zig" });
    defer allocator.free(linkTarget);
    if (builtin.os.tag == .windows) {
        // TODO: create zig.bat file
        @panic("setDefaultCompiler not implemented in Windows");
    } else {
        _ = try loggyUpdateSymlink(linkTarget, pathLink, .{});
    }
}

fn getDefaultUrl(allocator: *Allocator, compilerVersion: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "https://ziglang.org/download/{}/zig-linux-x86_64-{}.tar.xz", .{ compilerVersion, compilerVersion });
}

fn installCompiler(allocator: *Allocator, compilerDir: []const u8, url: []const u8) !void {
    if (try existsAbsolute(compilerDir)) {
        std.debug.warn("compiler '{}' already installed\n", .{compilerDir});
        return;
    }

    const installingDir = try std.mem.concat(allocator, u8, &[_][]const u8{ compilerDir, ".installing" });
    defer allocator.free(installingDir);
    try loggyDeleteTreeAbsolute(installingDir);
    try loggyMakeDirAbsolute(installingDir);

    const archiveBasename = std.fs.path.basename(url);
    var archiveRootDir: []const u8 = undefined;

    // download and extract archive
    {
        const archiveAbsolute = try std.fs.path.join(allocator, &[_][]const u8{ installingDir, archiveBasename });
        defer allocator.free(archiveAbsolute);
        std.debug.warn("downloading '{}' to '{}'\n", .{ url, archiveAbsolute });
        downloadToFileAbsolute(allocator, url, archiveAbsolute) catch |e| switch (e) {
            error.HttpNon200StatusCode => {
                // TODO: more information would be good
                std.debug.warn("HTTP request failed (TODO: improve ziget library to get better error)\n", .{});
                // this removes the installing dir if the http request fails so we dont have random directories
                try loggyDeleteTreeAbsolute(installingDir);
                return error.AlreadyReported;
            },
            else => return e,
        };

        if (std.mem.endsWith(u8, archiveBasename, ".tar.xz")) {
            archiveRootDir = archiveBasename[0 .. archiveBasename.len - ".tar.xz".len];
            _ = try run(allocator, &[_][]const u8{ "tar", "xf", archiveAbsolute, "-C", installingDir });
        } else {
            std.debug.warn("Error: unknown archive extension '{}'\n", .{archiveBasename});
            return error.UnknownArchiveExtension;
        }
        try loggyDeleteTreeAbsolute(archiveAbsolute);
    }

    {
        const extractedDir = try std.fs.path.join(allocator, &[_][]const u8{ installingDir, archiveRootDir });
        defer allocator.free(extractedDir);
        const normalizedDir = try std.fs.path.join(allocator, &[_][]const u8{ installingDir, "files" });
        defer allocator.free(normalizedDir);
        try loggyRenameAbsolute(extractedDir, normalizedDir);
    }

    // TODO: write date information (so users can sort compilers by date)

    // finish installation by renaming the install dir
    try loggyRenameAbsolute(installingDir, compilerDir);
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
    var prefixLength: u8 = 0;
    for (argv) |arg| {
        len += prefixLength + arg.len;
        prefixLength = 1;
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
