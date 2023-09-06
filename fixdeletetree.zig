const std = @import("std");
const builtin = @import("builtin");

//
// TODO: we should fix std library to address these issues
//
pub fn deleteTree(dir: std.fs.Dir, sub_path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        return dir.deleteTree(sub_path);
    }

    // workaround issue on windows where it just doesn't delete things
    const MAX_ATTEMPTS = 10;
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        if (dir.deleteTree(sub_path)) {
            return;
        } else |err| {
            if (attempt == MAX_ATTEMPTS) return err;
            switch (err) {
                error.FileBusy => {
                    std.log.warn("path '{s}' is busy (attempt {}), will retry", .{ sub_path, attempt });
                    std.time.sleep(std.time.ns_per_ms * 100); // sleep for 100 ms
                },
                else => |e| return e,
            }
        }
    }
}
pub fn deleteTreeAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag != .windows) {
        return std.fs.deleteTreeAbsolute(dir_absolute);
    }
    std.debug.assert(std.fs.path.isAbsolute(dir_absolute));
    return deleteTree(std.fs.cwd(), dir_absolute);
}
