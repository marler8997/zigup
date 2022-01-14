const std = @import("std");

const log = std.log.scoped(.zigexelink);

// NOTE: to prevent the exe from having multiple markers, I can't create a separate string literal
//       for the marker and get the length from that, I have to hardcode the length
const exe_marker_len = 42;

// I'm exporting this and making it mutable to make sure the compiler keeps it around
// and prevent it from evaluting its contents at comptime
export var zig_exe_string: [exe_marker_len + std.fs.MAX_PATH_BYTES + 1]u8 =
    ("!!!THIS MARKS THE zig_exe_string MEMORY!!#" ++ ([1]u8 {0} ** (std.fs.MAX_PATH_BYTES + 1))).*;

const global = struct {
    var child: *std.ChildProcess = undefined;
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
};

pub fn main() !u8 {
    // Sanity check that the exe_marker_len is right (note: not fullproof)
    std.debug.assert(zig_exe_string[exe_marker_len - 1] == '#');
    if (zig_exe_string[exe_marker_len] == 0) {
        log.err("the zig target executable has not been set in the exelink", .{});
        return 0xff; // fail
    }
    var zig_exe_len: usize = 1;
    while (zig_exe_string[exe_marker_len + zig_exe_len] != 0) {
        zig_exe_len += 1;
        if (exe_marker_len + zig_exe_len > std.fs.MAX_PATH_BYTES) {
            log.err("the zig target execuable is either too big (over {}) or the exe is corrupt", .{std.fs.MAX_PATH_BYTES});
            return 1;
        }
    }
    const zig_exe = zig_exe_string[exe_marker_len .. exe_marker_len + zig_exe_len :0];

    const args = try std.process.argsAlloc(global.arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "exelink")) {
        try std.io.getStdOut().writer().writeAll(zig_exe);
        return 0;
    }
    args[0] = zig_exe;

    // NOTE: create the ChildProcess before calling SetConsoleCtrlHandler because it uses it
    global.child = try std.ChildProcess.init(args, global.arena);
    defer global.child.deinit();

    if (0 == win32.SetConsoleCtrlHandler(consoleCtrlHandler, 1)) {
        log.err("SetConsoleCtrlHandler failed, error={}", .{win32.GetLastError()});
        return 0xff; // fail
    }

    try global.child.spawn();
    return switch (try global.child.wait()) {
        .Exited => |e| e,
        .Signal =>  0xff,
        .Stopped => 0xff,
        .Unknown => 0xff,
    };
}

fn consoleCtrlHandler(ctrl_type: u32) callconv(@import("std").os.windows.WINAPI) win32.BOOL {
    //
    // NOTE: Do I need to synchronize this with the main thread?
    //
    const name: []const u8 = switch (ctrl_type) {
        win32.CTRL_C_EVENT => "Control-C",
        win32.CTRL_BREAK_EVENT => "Break",
        win32.CTRL_CLOSE_EVENT => "Close",
        win32.CTRL_LOGOFF_EVENT => "Logoff",
        win32.CTRL_SHUTDOWN_EVENT => "Shutdown",
        else => "Unknown",
    };
    // TODO: should we stop the process on a break event?
    log.info("caught ctrl signal {d} ({s}), stopping process...", .{ctrl_type, name});
    const exit_code = switch (global.child.kill() catch |err| {
        log.err("failed to kill process, error={s}", .{@errorName(err)});
        std.os.exit(0xff);
    }) {
        .Exited => |e| e,
        .Signal =>  0xff,
        .Stopped => 0xff,
        .Unknown => 0xff,
    };
    std.os.exit(exit_code);
    unreachable;
}

const win32 = struct {
    pub const BOOL = i32;
    pub const CTRL_C_EVENT = @as(u32, 0);
    pub const CTRL_BREAK_EVENT = @as(u32, 1);
    pub const CTRL_CLOSE_EVENT = @as(u32, 2);
    pub const CTRL_LOGOFF_EVENT = @as(u32, 5);
    pub const CTRL_SHUTDOWN_EVENT = @as(u32, 6);
    pub const GetLastError = std.os.windows.kernel32.GetLastError;
    pub const PHANDLER_ROUTINE = fn(
        CtrlType: u32,
    ) callconv(@import("std").os.windows.WINAPI) BOOL;
    pub extern "KERNEL32" fn SetConsoleCtrlHandler(
        HandlerRoutine: ?PHANDLER_ROUTINE,
        Add: BOOL,
    ) callconv(@import("std").os.windows.WINAPI) BOOL;
};
