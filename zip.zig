/// The .ZIP File Format Specification is found here:
///    https://pkwaredownloads.blob.core.windows.net/pem/APPNOTE.txt
const std = @import("std");
const testing = std.testing;

pub const File = @import("zip/test.zig").File;
pub const FileCache = @import("zip/test.zig").FileCache;
pub const writeFile = @import("zip/test.zig").writeFile;

pub const CompressionMethod = enum(u16) {
    store = 0,
    deflate = 8,
    deflate64 = 9,
    _,
};

pub const central_file_header_sig = [4]u8{ 'P', 'K', 1, 2 };
pub const local_file_header_sig = [4]u8{ 'P', 'K', 3, 4 };
pub const end_of_central_directory_sig = [4]u8{ 'P', 'K', 5, 6 };

pub const LocalFileHeader = struct {
    signature: [4]u8,
    minimum_version: u16,
    flags: u16,
    compression_method: CompressionMethod,
    last_modification_time: u16,
    last_modification_date: u16,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    filename_len: u16,
    extra_len: u16,
    pub fn deserialize(bytes: [30]u8) LocalFileHeader {
        return .{
            .signature = bytes[0..4].*,
            .minimum_version = std.mem.readInt(u16, bytes[4..6], .little),
            .flags = std.mem.readInt(u16, bytes[6..8], .little),
            .compression_method = @enumFromInt(std.mem.readInt(u16, bytes[8..10], .little)),
            .last_modification_time = std.mem.readInt(u16, bytes[10..12], .little),
            .last_modification_date = std.mem.readInt(u16, bytes[12..14], .little),
            .crc32 = std.mem.readInt(u32, bytes[14..18], .little),
            .compressed_size = std.mem.readInt(u32, bytes[18..22], .little),
            .uncompressed_size = std.mem.readInt(u32, bytes[22..26], .little),
            .filename_len = std.mem.readInt(u16, bytes[26..28], .little),
            .extra_len = std.mem.readInt(u16, bytes[28..30], .little),
        };
    }
    pub fn serialize(self: LocalFileHeader) [30]u8 {
        var result: [30]u8 = undefined;
        result[0..4].* = self.signature;
        std.mem.writeInt(u16, result[4..6], self.minimum_version, .little);
        std.mem.writeInt(u16, result[6..8], self.flags, .little);
        std.mem.writeInt(u16, result[8..10], @intFromEnum(self.compression_method), .little);
        std.mem.writeInt(u16, result[10..12], self.last_modification_time, .little);
        std.mem.writeInt(u16, result[12..14], self.last_modification_date, .little);
        std.mem.writeInt(u32, result[14..18], self.crc32, .little);
        std.mem.writeInt(u32, result[18..22], self.compressed_size, .little);
        std.mem.writeInt(u32, result[22..26], self.uncompressed_size, .little);
        std.mem.writeInt(u16, result[26..28], self.filename_len, .little);
        std.mem.writeInt(u16, result[28..30], self.extra_len, .little);
        return result;
    }
};

pub const CentralDirectoryFileHeader = struct {
    signature: [4]u8,
    version: u16,
    minimum_version: u16,
    flags: u16,
    compression_method: CompressionMethod,
    last_modification_time: u16,
    last_modification_date: u16,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    filename_len: u16,
    extra_len: u16,
    comment_len: u16,
    disk_number: u16,
    internal_file_attributes: u16,
    external_file_attributes: u32,
    local_file_header_offset: u32,

    pub fn deserialize(bytes: [46]u8) CentralDirectoryFileHeader {
        return .{
            .signature = bytes[0..4].*,
            .version = std.mem.readInt(u16, bytes[4..6], .little),
            .minimum_version = std.mem.readInt(u16, bytes[6..8], .little),
            .flags = std.mem.readInt(u16, bytes[8..10], .little),
            .compression_method = @enumFromInt(std.mem.readInt(u16, bytes[10..12], .little)),
            .last_modification_time = std.mem.readInt(u16, bytes[12..14], .little),
            .last_modification_date = std.mem.readInt(u16, bytes[14..16], .little),
            .crc32 = std.mem.readInt(u32, bytes[16..20], .little),
            .compressed_size = std.mem.readInt(u32, bytes[20..24], .little),
            .uncompressed_size = std.mem.readInt(u32, bytes[24..28], .little),
            .filename_len = std.mem.readInt(u16, bytes[28..30], .little),
            .extra_len = std.mem.readInt(u16, bytes[30..32], .little),
            .comment_len = std.mem.readInt(u16, bytes[32..34], .little),
            .disk_number = std.mem.readInt(u16, bytes[34..36], .little),
            .internal_file_attributes = std.mem.readInt(u16, bytes[36..38], .little),
            .external_file_attributes = std.mem.readInt(u32, bytes[38..42], .little),
            .local_file_header_offset = std.mem.readInt(u32, bytes[42..46], .little),
        };
    }
    pub fn serialize(self: CentralDirectoryFileHeader) [46]u8 {
        var result: [46]u8 = undefined;
        result[0..4].* = self.signature;
        std.mem.writeInt(u16, result[4..6], self.version, .little);
        std.mem.writeInt(u16, result[6..8], self.minimum_version, .little);
        std.mem.writeInt(u16, result[8..10], self.flags, .little);
        std.mem.writeInt(u16, result[10..12], @intFromEnum(self.compression_method), .little);
        std.mem.writeInt(u16, result[12..14], self.last_modification_time, .little);
        std.mem.writeInt(u16, result[14..16], self.last_modification_date, .little);
        std.mem.writeInt(u32, result[16..20], self.crc32, .little);
        std.mem.writeInt(u32, result[20..24], self.compressed_size, .little);
        std.mem.writeInt(u32, result[24..28], self.uncompressed_size, .little);
        std.mem.writeInt(u16, result[28..30], self.filename_len, .little);
        std.mem.writeInt(u16, result[30..32], self.extra_len, .little);
        std.mem.writeInt(u16, result[32..34], self.comment_len, .little);
        std.mem.writeInt(u16, result[34..36], self.disk_number, .little);
        std.mem.writeInt(u16, result[36..38], self.internal_file_attributes, .little);
        std.mem.writeInt(u32, result[38..42], self.external_file_attributes, .little);
        std.mem.writeInt(u32, result[42..46], self.local_file_header_offset, .little);
        return result;
    }
};

pub const EndOfCentralDirectoryRecord = struct {
    disk_number: u16,
    central_directory_disk_number: u16,
    record_count_disk: u16,
    record_count_total: u16,
    central_directory_size: u32,
    central_directory_offset: u32,
    comment_len: u16,

    pub fn read(bytes: [22]u8) EndOfCentralDirectoryRecord {
        return EndOfCentralDirectoryRecord{
            .disk_number = std.mem.readInt(u16, bytes[4..6], .little),
            .central_directory_disk_number = std.mem.readInt(u16, bytes[6..8], .little),
            .record_count_disk = std.mem.readInt(u16, bytes[8..10], .little),
            .record_count_total = std.mem.readInt(u16, bytes[10..12], .little),
            .central_directory_size = std.mem.readInt(u32, bytes[12..16], .little),
            .central_directory_offset = std.mem.readInt(u32, bytes[16..20], .little),
            .comment_len = std.mem.readInt(u16, bytes[20..22], .little),
        };
    }
    pub fn serialize(self: EndOfCentralDirectoryRecord) [22]u8 {
        var result: [22]u8 = undefined;
        result[0..4].* = end_of_central_directory_sig;
        std.mem.writeInt(u16, result[4..6], self.disk_number, .little);
        std.mem.writeInt(u16, result[6..8], self.central_directory_disk_number, .little);
        std.mem.writeInt(u16, result[8..10], self.record_count_disk, .little);
        std.mem.writeInt(u16, result[10..12], self.record_count_total, .little);
        std.mem.writeInt(u32, result[12..16], self.central_directory_size, .little);
        std.mem.writeInt(u32, result[16..20], self.central_directory_offset, .little);
        std.mem.writeInt(u16, result[20..22], self.comment_len, .little);
        return result;
    }
};

pub fn findEocdr(file: std.fs.File) ![22]u8 {
    // The EOCD record can contain a variable-length comment at the end,
    // which makes ZIP file parsing ambiguous in general, since a valid
    // comment could contain the bytes of another valid EOCD record.
    // Here we just search backwards for the first instance of the EOCD
    // signature, and return an error if a valid EOCD record doesn't follow.

    // TODO: make this more efficient
    //       we need a backward_buffered_reader
    const file_size = try file.getEndPos();

    const record_len = 22;
    var record: [record_len]u8 = undefined;
    if (file_size < record_len)
        return error.ZipTruncated;
    try file.seekFromEnd(-record_len);
    {
        const len = try file.readAll(&record);
        if (len != record_len)
            return error.ZipTruncated;
    }

    var comment_len: u16 = 0;
    while (true) {
        if (std.mem.eql(u8, record[0..4], &end_of_central_directory_sig) and
            std.mem.readInt(u16, record[20..22], .little) == comment_len)
        {
            break;
        }

        if (comment_len == std.math.maxInt(u16))
            return error.ZipMissingEocdr;
        std.mem.copyBackwards(u8, record[1..], record[0 .. record.len - 1]);
        comment_len += 1;

        if (@as(u64, record_len) + @as(u64, comment_len) > file_size)
            return error.ZipMissingEocdr;

        try file.seekFromEnd(-record_len - @as(i64, comment_len));
        {
            const len = try file.readAll(record[0..1]);
            if (len != 1)
                return error.ZipTruncated;
        }
    }
    return record;
}

fn LimitedReader(comptime UnderlyingReader: type) type {
    return struct {
        const Self = @This();

        underlying_reader: UnderlyingReader,
        remaining: usize,

        pub const Error = UnderlyingReader.Error;
        pub const Reader = std.io.Reader(*Self, Error, read);
        fn read(self: *Self, buffer: []u8) Error!usize {
            const next_read_len = @min(buffer.len, self.remaining);
            if (next_read_len == 0) return 0;
            const len = try self.underlying_reader.read(buffer[0..next_read_len]);
            self.remaining -= len;
            return len;
        }
        pub fn reader(self: *Self) Reader {
            return Reader{ .context = self };
        }
    };
}
fn limitedReader(reader: anytype, limit: usize) LimitedReader(@TypeOf(reader)) {
    return .{
        .underlying_reader = reader,
        .remaining = limit,
    };
}

/// `decompress` returns the actual CRC-32 of the decompressed bytes,
/// which should be validated against the expected entry.crc32 value.
/// `writer` can be anything with a `writeAll(self: *Self, chunk: []const u8) anyerror!void` method.
pub fn decompress(
    method: CompressionMethod,
    uncompressed_size: u32,
    reader: anytype,
    writer: anytype,
) !u32 {
    var hash = std.hash.Crc32.init();

    switch (method) {
        .store => {
            var buf: [std.mem.page_size]u8 = undefined;
            while (true) {
                const len = try reader.read(&buf);
                if (len == 0) break;
                try writer.writeAll(buf[0..len]);
                hash.update(buf[0..len]);
            }
        },
        .deflate, .deflate64 => {
            var br = std.io.bufferedReader(reader);
            var total_uncompressed: u32 = 0;
            var decompressor = std.compress.flate.decompressor(br.reader());
            while (try decompressor.next()) |chunk| {
                try writer.writeAll(chunk);
                hash.update(chunk);
                total_uncompressed += @intCast(chunk.len);
            }
            if (br.end != br.start)
                return error.ZipDeflateTruncated;
            if (total_uncompressed != uncompressed_size)
                return error.ZipUncompressSizeMismatch;
        },
        _ => return error.UnsupportedCompressionMethod,
    }

    return hash.final();
}

pub const Iterator = struct {
    file: std.fs.File,
    eocdr: EndOfCentralDirectoryRecord,
    next_central_header_index: u16,
    next_central_header_offset: u64,

    pub fn init(file: std.fs.File) !Iterator {
        const eocdr = blk: {
            const eocdr_bytes = try findEocdr(file);
            break :blk EndOfCentralDirectoryRecord.read(eocdr_bytes);
        };

        // Don't support multi-disk archives.
        if (eocdr.disk_number != 0 or
            eocdr.central_directory_disk_number != 0 or
            eocdr.record_count_disk != eocdr.record_count_total)
        {
            return error.ZipUnsupportedMultiDisk;
        }

        return .{
            .file = file,
            .eocdr = eocdr,
            .next_central_header_offset = 0,
            .next_central_header_index = 0,
        };
    }

    pub fn next(self: *Iterator) !?Entry {
        if (self.next_central_header_index >= self.eocdr.record_count_total) {
            return null;
        }

        const header_file_offset: u64 = @as(u64, self.eocdr.central_directory_offset) + self.next_central_header_offset;
        const header = blk: {
            try self.file.seekTo(header_file_offset);
            var header: [46]u8 = undefined;
            const len = try self.file.readAll(&header);
            if (len != header.len)
                return error.ZipTruncated;
            break :blk CentralDirectoryFileHeader.deserialize(header);
        };
        if (!std.mem.eql(u8, &header.signature, &central_file_header_sig))
            return error.ZipHeader;

        self.next_central_header_index += 1;
        self.next_central_header_offset += 46 + header.filename_len + header.extra_len + header.comment_len;

        if (header.disk_number != 0)
            return error.ZipUnsupportedMultiDisk;
        return .{
            .header_file_offset = header_file_offset,
            .header = header,
        };
    }

    pub const Entry = struct {
        header_file_offset: u64,
        header: CentralDirectoryFileHeader,

        pub fn extract(self: Entry, zip_file: std.fs.File, filename_buf: []u8, dest: std.fs.Dir) !u32 {
            if (filename_buf.len < self.header.filename_len)
                return error.ZipInsufficientBuffer;
            const filename = filename_buf[0..self.header.filename_len];

            try zip_file.seekTo(self.header_file_offset + 46);
            {
                const len = try zip_file.readAll(filename);
                if (len != filename.len)
                    return error.ZipTruncated;
            }

            const local_data_header_offset: u64 = local_data_header_offset: {
                const local_header = blk: {
                    try zip_file.seekTo(self.header.local_file_header_offset);
                    var local_header: [30]u8 = undefined;
                    const len = try zip_file.readAll(&local_header);
                    if (len != local_header.len)
                        return error.ZipTruncated;
                    break :blk LocalFileHeader.deserialize(local_header);
                };
                if (!std.mem.eql(u8, &local_header.signature, &local_file_header_sig))
                    return error.ZipHeader;
                // TODO: verify minimum_version
                // TODO: verify flags
                // TODO: verify compression method
                // TODO: verify last_mod_time
                // TODO: verify last_mod_date
                // TODO: verify filename_len and filename?
                // TODO: extra?

                if (local_header.crc32 != 0 and local_header.crc32 != self.header.crc32)
                    return error.ZipRedundancyFail;
                if (local_header.compressed_size != 0 and
                    local_header.compressed_size != self.header.compressed_size)
                    return error.ZipRedundancyFail;
                if (local_header.uncompressed_size != 0 and
                    local_header.uncompressed_size != self.header.uncompressed_size)
                    return error.ZipRedundancyFail;

                break :local_data_header_offset @as(u64, local_header.filename_len) +
                    @as(u64, local_header.extra_len);
            };

            if (filename.len == 0 or filename[0] == '/')
                return error.ZipBadFilename;

            // All entries that end in '/' are directories
            if (filename[filename.len - 1] == '/') {
                if (self.header.uncompressed_size != 0)
                    return error.ZipBadDirectorySize;
                try dest.makePath(filename[0 .. filename.len - 1]);
                return std.hash.Crc32.hash(&.{});
            }

            const out_file = blk: {
                if (std.fs.path.dirname(filename)) |dirname| {
                    var parent_dir = try dest.makeOpenPath(dirname, .{});
                    defer parent_dir.close();

                    const basename = std.fs.path.basename(filename);
                    break :blk try parent_dir.createFile(basename, .{ .exclusive = true });
                }
                break :blk try dest.createFile(filename, .{ .exclusive = true });
            };
            defer out_file.close();
            const local_data_file_offset: u64 =
                @as(u64, self.header.local_file_header_offset) +
                @as(u64, 30) +
                local_data_header_offset;
            try zip_file.seekTo(local_data_file_offset);
            var limited_reader = limitedReader(zip_file.reader(), self.header.compressed_size);
            const crc = try decompress(
                self.header.compression_method,
                self.header.uncompressed_size,
                limited_reader.reader(),
                out_file.writer(),
            );
            if (limited_reader.remaining != 0)
                return error.ZipDecompressTruncated;
            return crc;
        }
    };
};

pub fn pipeToFileSystem(dest: std.fs.Dir, file: std.fs.File) !void {
    var iter = try Iterator.init(file);

    var filename_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    while (try iter.next()) |entry| {
        const crc32 = try entry.extract(file, &filename_buf, dest);
        if (crc32 != entry.header.crc32)
            return error.ZipCrcMismatch;
    }
}

fn testZip(comptime files: []const File) !void {
    var cache: [files.len]FileCache = undefined;
    try testZipWithCache(files, &cache);
}
fn testZipWithCache(files: []const File, cache: []FileCache) !void {
    var tmp = testing.tmpDir(.{ .no_follow = true });
    defer tmp.cleanup();
    const dir = tmp.dir;

    {
        var file = try dir.createFile("zip", .{});
        defer file.close();
        try writeFile(file, files, cache);
    }

    var zip_file = try dir.openFile("zip", .{});
    defer zip_file.close();
    try pipeToFileSystem(dir, zip_file);

    for (files) |test_file| {
        var file = try dir.openFile(test_file.name, .{});
        defer file.close();
        var buf: [4096]u8 = undefined;
        const n = try file.reader().readAll(&buf);
        try testing.expectEqualStrings(test_file.content, buf[0..n]);
    }
}

test "zip one file" {
    try testZip(&[_]File{
        .{ .name = "onefile.txt", .content = "Just a single file\n", .compression = .store },
    });
}
test "zip multiple files" {
    try testZip(&[_]File{
        .{ .name = "foo", .content = "a foo file\n", .compression = .store },
        .{ .name = "subdir/bar", .content = "bar is this right?\nanother newline\n", .compression = .store },
        .{ .name = "subdir/another/baz", .content = "bazzy mc bazzerson", .compression = .store },
    });
}
test "zip deflated" {
    try testZip(&[_]File{
        .{ .name = "deflateme", .content = "This is a deflated file.\nIt should be smaller in the Zip file1\n", .compression = .deflate },
        .{ .name = "deflateme64", .content = "The 64k version of deflate!\n", .compression = .deflate64 },
        .{ .name = "raw", .content = "Not all files need to be deflated in the same Zip.\n", .compression = .store },
    });
}
