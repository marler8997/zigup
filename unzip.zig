const builtin = @import("builtin");
const std = @import("std");

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn usage() noreturn {
    std.io.getStdErr().writer().print("Usage: unzip [-d DIR] ZIP_FILE\n", .{}) catch |e| @panic(@errorName(e));
    std.process.exit(1);
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator) else struct{}{};
pub fn cmdlineArgs() [][*:0]u8 {
    if (builtin.os.tag == .windows) {
        const slices = std.process.argsAlloc(windows_args_arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => oom(error.OutOfMemory),
            //error.InvalidCmdLine => @panic("InvalidCmdLine"),
            error.Overflow => @panic("Overflow while parsing command line"),
        };
        const args = windows_args_arena.allocator().alloc([*:0]u8, slices.len - 1) catch |e| oom(e);
        for (slices[1..], 0..) |slice, i| {
            args[i] = slice.ptr;
        }
        return args;
    }
    return std.os.argv.ptr[1 .. std.os.argv.len];
}

pub fn main() !void {
    var cmdline_opt: struct {
        dir_arg: ?[]u8 = null,
    } = .{};

    const cmd_args = blk: {
        const cmd_args = cmdlineArgs();
        var arg_index: usize = 0;
        var non_option_len: usize = 0;
        while (arg_index < cmd_args.len) : (arg_index += 1) {
            const arg = std.mem.span(cmd_args[arg_index]);
            if (!std.mem.startsWith(u8, arg, "-")) {
                cmd_args[non_option_len] = arg;
                non_option_len += 1;
            } else if (std.mem.eql(u8, arg, "-d")) {
                arg_index += 1;
                if (arg_index == cmd_args.len)
                    fatal("option '{s}' requires an argument", .{arg});
                cmdline_opt.dir_arg = std.mem.span(cmd_args[arg_index]);
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk cmd_args[0 .. non_option_len];
    };

    if (cmd_args.len != 1) usage();
    const zip_file_arg = std.mem.span(cmd_args[0]);

    var out_dir = blk: {
        if (cmdline_opt.dir_arg) |dir| {
            break :blk std.fs.cwd().openDir(dir, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try std.fs.cwd().makePath(dir);
                    break :blk try std.fs.cwd().openDir(dir, .{});
                },
                else => fatal("failed to open output directory '{s}' with {s}", .{dir, @errorName(err)}),
            };
        }
        break :blk std.fs.cwd();
    };
    defer if (cmdline_opt.dir_arg) |_| out_dir.close();

    const zip_file = std.fs.cwd().openFile(zip_file_arg, .{}) catch |err|
        fatal("open '{s}' failed: {s}", .{zip_file_arg, @errorName(err)});
    defer zip_file.close();
    try std.zip.extract(out_dir, zip_file.seekableStream(), .{
        .allow_backslashes = true,
    });
}
