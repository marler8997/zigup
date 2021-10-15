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
        return dir.deleteTree(sub_path) catch |e| {
            if (attempt == MAX_ATTEMPTS) return e;
            switch (e) {
                error.FileBusy => {
                    if (attempt == MAX_ATTEMPTS) return e;
                    std.log.warn("path '{s}' is busy, will retry", .{sub_path});
                    std.time.sleep(std.time.ns_per_ms * 100); // sleep for 100 ms
                },
                else => return e,
            }
        };
    }
}
pub fn deleteTreeAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag != .windows) {
        return std.fs.deleteTreeAbsolute(dir_absolute);
    }
    std.debug.assert(std.fs.path.isAbsolute(dir_absolute));
    return deleteTree(std.fs.cwd(), dir_absolute);
}
