const std = @import("std");
const zip = @import("../zip.zig");

pub const File = struct {
    name: []const u8,
    content: []const u8,
    compression: zip.CompressionMethod,
};
pub const FileCache = struct {
    offset: u32,
    crc: u32,
    compressed_size: u32,
};

pub fn writeFile(
    out_file: std.fs.File,
    files: []const File,
    cache: []FileCache,
) !void {
    if (cache.len < files.len) return error.FileCacheTooSmall;

    var bw = std.io.bufferedWriter(out_file.writer());
    var counting = std.io.countingWriter(bw.writer());
    const writer = counting.writer();

    for (files, 0..) |file, i| {
        cache[i].offset = @intCast(counting.bytes_written);
        cache[i].crc = std.hash.Crc32.hash(file.content);

        {
            const hdr: zip.LocalFileHeader = .{
                .signature = zip.local_file_header_sig,
                .minimum_version = 0,
                .flags = 0,
                .compression_method = file.compression,
                .last_modification_time = 0,
                .last_modification_date = 0,
                .crc32 = cache[i].crc,
                .compressed_size = 0,
                .uncompressed_size = @intCast(file.content.len),
                .filename_len = @intCast(file.name.len),
                .extra_len = 0,
            };
            try writer.writeAll(&hdr.serialize());
        }
        try writer.writeAll(file.name);
        switch (file.compression) {
            .store => {
                try writer.writeAll(file.content);
                cache[i].compressed_size = @intCast(file.content.len);
            },
            .deflate, .deflate64 => {
                const offset = counting.bytes_written;
                var fbs = std.io.fixedBufferStream(file.content);
                try std.compress.flate.deflate.compress(.raw, fbs.reader(), writer, .{});
                std.debug.assert(fbs.pos == file.content.len);
                cache[i].compressed_size = @intCast(counting.bytes_written - offset);
            },
            else => unreachable,
        }
    }

    const cd_offset = counting.bytes_written;
    for (files, 0..) |file, i| {
        {
            const hdr: zip.CentralDirectoryFileHeader = .{
                .signature = zip.central_file_header_sig,
                .version = 0,
                .minimum_version = 0,
                .flags = 0,
                .compression_method = file.compression,
                .last_modification_time = 0,
                .last_modification_date = 0,
                .crc32 = cache[i].crc,
                .compressed_size = cache[i].compressed_size,
                .uncompressed_size = @intCast(file.content.len),
                .filename_len = @intCast(file.name.len),
                .extra_len = 0,
                .comment_len = 0,
                .disk_number = 0,
                .internal_file_attributes = 0,
                .external_file_attributes = 0,
                .local_file_header_offset = cache[i].offset,
            };
            try writer.writeAll(&hdr.serialize());
        }
        try writer.writeAll(file.name);
    }
    const cd_end = counting.bytes_written;

    {
        const hdr: zip.EndOfCentralDirectoryRecord = .{
            .disk_number = 0,
            .central_directory_disk_number = 0,
            .record_count_disk = @intCast(files.len),
            .record_count_total = @intCast(files.len),
            .central_directory_size = @intCast(cd_end - cd_offset),
            .central_directory_offset = @intCast(cd_offset),
            .comment_len = 0,
        };
        try writer.writeAll(&hdr.serialize());
    }
    try bw.flush();
}
