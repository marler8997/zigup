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
    std.io.getStdErr().writer().writeAll(
        "Usage: zip [-options] ZIP_FILE FILES/DIRS..\n",
    ) catch |e| @panic(@errorName(e));
    std.process.exit(1);
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator)
else
    struct {}{};
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
    return std.os.argv.ptr[1..std.os.argv.len];
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const cmd_args = blk: {
        const cmd_args = cmdlineArgs();
        var arg_index: usize = 0;
        var non_option_len: usize = 0;
        while (arg_index < cmd_args.len) : (arg_index += 1) {
            const arg = std.mem.span(cmd_args[arg_index]);
            if (!std.mem.startsWith(u8, arg, "-")) {
                cmd_args[non_option_len] = arg;
                non_option_len += 1;
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk cmd_args[0..non_option_len];
    };

    if (cmd_args.len < 2) usage();
    const zip_file_arg = std.mem.span(cmd_args[0]);
    const paths_to_include = cmd_args[1..];

    // expand cmdline arguments to a list of files
    var file_entries: std.ArrayListUnmanaged(FileEntry) = .{};
    for (paths_to_include) |path_ptr| {
        const path = std.mem.span(path_ptr);
        const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
            error.FileNotFound => fatal("path '{s}' is not found", .{path}),
            else => |e| return e,
        };
        switch (stat.kind) {
            .directory => {
                @panic("todo: directories");
            },
            .file => {
                if (isBadFilename(path))
                    fatal("filename '{s}' is invalid for zip files", .{path});
                try file_entries.append(arena, .{
                    .path = path,
                    .size = stat.size,
                });
            },
            .sym_link => fatal("todo: symlinks", .{}),
            .block_device,
            .character_device,
            .named_pipe,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            .unknown,
            => fatal("file '{s}' is an unsupported type {s}", .{ path, @tagName(stat.kind) }),
        }
    }

    const store = try arena.alloc(FileStore, file_entries.items.len);
    // no need to free

    {
        const zip_file = std.fs.cwd().createFile(zip_file_arg, .{}) catch |err|
            fatal("create file '{s}' failed: {s}", .{ zip_file_arg, @errorName(err) });
        defer zip_file.close();
        try writeZip(zip_file, file_entries.items, store);
    }

    // go fix up the local file headers
    {
        const zip_file = std.fs.cwd().openFile(zip_file_arg, .{ .mode = .read_write }) catch |err|
            fatal("open file '{s}' failed: {s}", .{ zip_file_arg, @errorName(err) });
        defer zip_file.close();
        for (file_entries.items, 0..) |file, i| {
            try zip_file.seekTo(store[i].file_offset);
            const hdr: std.zip.LocalFileHeader = .{
                .signature = std.zip.local_file_header_sig,
                .version_needed_to_extract = 10,
                .flags = .{ .encrypted = false, ._ = 0 },
                .compression_method = store[i].compression,
                .last_modification_time = 0,
                .last_modification_date = 0,
                .crc32 = store[i].crc32,
                .compressed_size = store[i].compressed_size,
                .uncompressed_size = @intCast(file.size),
                .filename_len = @intCast(file.path.len),
                .extra_len = 0,
            };
            try writeStructEndian(zip_file.writer(), hdr, .little);
        }
    }
}

const FileEntry = struct {
    path: []const u8,
    size: u64,
};

fn writeZip(
    out_zip: std.fs.File,
    file_entries: []const FileEntry,
    store: []FileStore,
) !void {
    var zipper = initZipper(out_zip.writer());
    for (file_entries, 0..) |file_entry, i| {
        const file_offset = zipper.counting_writer.bytes_written;

        const compression: std.zip.CompressionMethod = .deflate;

        try zipper.writeFileHeader(file_entry.path, compression);

        var file = try std.fs.cwd().openFile(file_entry.path, .{});
        defer file.close();

        var crc32: u32 = undefined;

        var compressed_size = file_entry.size;
        switch (compression) {
            .store => {
                var hash = std.hash.Crc32.init();
                var full_rw_buf: [std.mem.page_size]u8 = undefined;
                var remaining = file_entry.size;
                while (remaining > 0) {
                    const buf = full_rw_buf[0..@min(remaining, full_rw_buf.len)];
                    const read_len = try file.reader().read(buf);
                    std.debug.assert(read_len == buf.len);
                    hash.update(buf);
                    try zipper.counting_writer.writer().writeAll(buf);
                    remaining -= buf.len;
                }
                crc32 = hash.final();
            },
            .deflate => {
                const start_offset = zipper.counting_writer.bytes_written;
                var br = std.io.bufferedReader(file.reader());
                var cr = Crc32Reader(@TypeOf(br.reader())){ .underlying_reader = br.reader() };

                try std.compress.flate.deflate.compress(
                    .raw,
                    cr.reader(),
                    zipper.counting_writer.writer(),
                    .{ .level = .best },
                );
                if (br.end != br.start) fatal("deflate compressor didn't read all data", .{});
                compressed_size = zipper.counting_writer.bytes_written - start_offset;
                crc32 = cr.crc32.final();
            },
            else => @panic("codebug"),
        }
        store[i] = .{
            .file_offset = file_offset,
            .compression = compression,
            .uncompressed_size = @intCast(file_entry.size),
            .crc32 = crc32,
            .compressed_size = @intCast(compressed_size),
        };
    }
    for (file_entries, 0..) |file, i| {
        try zipper.writeCentralRecord(store[i], .{
            .name = file.path,
        });
    }
    try zipper.writeEndRecord();
}

pub fn Crc32Reader(comptime ReaderType: type) type {
    return struct {
        underlying_reader: ReaderType,
        crc32: std.hash.Crc32 = std.hash.Crc32.init(),

        pub const Error = ReaderType.Error;
        pub const Reader = std.io.Reader(*Self, Error, read);

        const Self = @This();

        pub fn read(self: *Self, dest: []u8) Error!usize {
            const len = try self.underlying_reader.read(dest);
            self.crc32.update(dest[0..len]);
            return len;
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

fn isBadFilename(filename: []const u8) bool {
    if (std.mem.indexOfScalar(u8, filename, '\\')) |_|
        return true;

    if (filename.len == 0 or filename[0] == '/' or filename[0] == '\\')
        return true;

    var it = std.mem.splitAny(u8, filename, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    return false;
}

// Used to store any data from writing a file to the zip archive that's needed
// when writing the corresponding central directory record.
pub const FileStore = struct {
    file_offset: u64,
    compression: std.zip.CompressionMethod,
    uncompressed_size: u32,
    crc32: u32,
    compressed_size: u32,
};

pub fn initZipper(writer: anytype) Zipper(@TypeOf(writer)) {
    return .{ .counting_writer = std.io.countingWriter(writer) };
}

fn Zipper(comptime Writer: type) type {
    return struct {
        counting_writer: std.io.CountingWriter(Writer),
        central_count: u64 = 0,
        first_central_offset: ?u64 = null,
        last_central_limit: ?u64 = null,

        const Self = @This();

        pub fn writeFileHeader(
            self: *Self,
            name: []const u8,
            compression: std.zip.CompressionMethod,
        ) !void {
            const writer = self.counting_writer.writer();
            const hdr: std.zip.LocalFileHeader = .{
                .signature = std.zip.local_file_header_sig,
                .version_needed_to_extract = 10,
                .flags = .{ .encrypted = false, ._ = 0 },
                .compression_method = compression,
                .last_modification_time = 0,
                .last_modification_date = 0,
                .crc32 = 0,
                .compressed_size = 0,
                .uncompressed_size = 0,
                .filename_len = @intCast(name.len),
                .extra_len = 0,
            };
            try writeStructEndian(writer, hdr, .little);
            try writer.writeAll(name);
        }

        pub fn writeCentralRecord(
            self: *Self,
            store: FileStore,
            opt: struct {
                name: []const u8,
                version_needed_to_extract: u16 = 10,
            },
        ) !void {
            if (self.first_central_offset == null) {
                self.first_central_offset = self.counting_writer.bytes_written;
            }
            self.central_count += 1;

            const hdr: std.zip.CentralDirectoryFileHeader = .{
                .signature = std.zip.central_file_header_sig,
                .version_made_by = 0,
                .version_needed_to_extract = opt.version_needed_to_extract,
                .flags = .{ .encrypted = false, ._ = 0 },
                .compression_method = store.compression,
                .last_modification_time = 0,
                .last_modification_date = 0,
                .crc32 = store.crc32,
                .compressed_size = store.compressed_size,
                .uncompressed_size = @intCast(store.uncompressed_size),
                .filename_len = @intCast(opt.name.len),
                .extra_len = 0,
                .comment_len = 0,
                .disk_number = 0,
                .internal_file_attributes = 0,
                .external_file_attributes = 0,
                .local_file_header_offset = @intCast(store.file_offset),
            };
            try writeStructEndian(self.counting_writer.writer(), hdr, .little);
            try self.counting_writer.writer().writeAll(opt.name);
            self.last_central_limit = self.counting_writer.bytes_written;
        }

        pub fn writeEndRecord(self: *Self) !void {
            const cd_offset = self.first_central_offset orelse 0;
            const cd_end = self.last_central_limit orelse 0;
            const hdr: std.zip.EndRecord = .{
                .signature = std.zip.end_record_sig,
                .disk_number = 0,
                .central_directory_disk_number = 0,
                .record_count_disk = @intCast(self.central_count),
                .record_count_total = @intCast(self.central_count),
                .central_directory_size = @intCast(cd_end - cd_offset),
                .central_directory_offset = @intCast(cd_offset),
                .comment_len = 0,
            };
            try writeStructEndian(self.counting_writer.writer(), hdr, .little);
        }
    };
}

const native_endian = @import("builtin").target.cpu.arch.endian();

fn writeStructEndian(writer: anytype, value: anytype, endian: std.builtin.Endian) anyerror!void {
    // TODO: make sure this value is not a reference type
    if (native_endian == endian) {
        return writer.writeStruct(value);
    } else {
        var copy = value;
        byteSwapAllFields(@TypeOf(value), &copy);
        return writer.writeStruct(copy);
    }
}
pub fn byteSwapAllFields(comptime S: type, ptr: *S) void {
    switch (@typeInfo(S)) {
        .Struct => {
            inline for (std.meta.fields(S)) |f| {
                switch (@typeInfo(f.type)) {
                    .Struct => |struct_info| if (struct_info.backing_integer) |Int| {
                        @field(ptr, f.name) = @bitCast(@byteSwap(@as(Int, @bitCast(@field(ptr, f.name)))));
                    } else {
                        byteSwapAllFields(f.type, &@field(ptr, f.name));
                    },
                    .Array => byteSwapAllFields(f.type, &@field(ptr, f.name)),
                    .Enum => {
                        @field(ptr, f.name) = @enumFromInt(@byteSwap(@intFromEnum(@field(ptr, f.name))));
                    },
                    else => {
                        @field(ptr, f.name) = @byteSwap(@field(ptr, f.name));
                    },
                }
            }
        },
        .Array => {
            for (ptr) |*item| {
                switch (@typeInfo(@TypeOf(item.*))) {
                    .Struct, .Array => byteSwapAllFields(@TypeOf(item.*), item),
                    .Enum => {
                        item.* = @enumFromInt(@byteSwap(@intFromEnum(item.*)));
                    },
                    else => {
                        item.* = @byteSwap(item.*);
                    },
                }
            }
        },
        else => @compileError("byteSwapAllFields expects a struct or array as the first argument"),
    }
}
