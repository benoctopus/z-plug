/// State persistence interface for plugin presets.
///
/// The framework calls `save` and `load` callbacks provided by the plugin.
/// It wraps format-specific stream types (CLAP `clap_ostream_t`/`clap_istream_t`,
/// VST3 `IBStream`) into a simple reader/writer interface that plugins can use
/// to serialize their parameters and internal state.
///
/// Uses Zig 0.15.2's `std.io.AnyReader` and `std.io.AnyWriter` for type erasure.
const std = @import("std");

/// Version number type for state serialization versioning and migration.
pub const StateVersion = u32;

/// Context passed to the plugin's `save` function.
pub const SaveContext = struct {
    /// Type-erased writer for writing binary data to the host's stream.
    writer: std.io.AnyWriter,

    /// Write a single value of type `T` in native byte order.
    pub fn write(self: SaveContext, comptime T: type, value: T) !void {
        const bytes = std.mem.asBytes(&value);
        try self.writer.writeAll(bytes);
    }

    /// Write a slice of bytes.
    pub fn writeBytes(self: SaveContext, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
    }

    /// Write a length-prefixed string (u32 length + UTF-8 bytes).
    pub fn writeString(self: SaveContext, str: []const u8) !void {
        const len: u32 = @intCast(str.len);
        try self.write(u32, len);
        try self.writer.writeAll(str);
    }
};

/// Context passed to the plugin's `load` function.
pub const LoadContext = struct {
    /// Type-erased reader for reading binary data from the host's stream.
    reader: std.io.AnyReader,
    /// The version number of the saved state, for migration.
    version: StateVersion,

    /// Read a single value of type `T` in native byte order.
    pub fn read(self: LoadContext, comptime T: type) !T {
        var value: T = undefined;
        const bytes = std.mem.asBytes(&value);
        try self.reader.readNoEof(bytes);
        return value;
    }

    /// Read a fixed number of bytes into a buffer.
    pub fn readBytes(self: LoadContext, buffer: []u8) !void {
        try self.reader.readNoEof(buffer);
    }

    /// Read a length-prefixed string into an allocator-owned buffer.
    /// Caller owns the returned slice.
    pub fn readString(self: LoadContext, allocator: std.mem.Allocator) ![]u8 {
        const len = try self.read(u32);
        const buffer = try allocator.alloc(u8, len);
        errdefer allocator.free(buffer);
        try self.reader.readNoEof(buffer);
        return buffer;
    }

    /// Read a length-prefixed string into a provided fixed buffer.
    /// Returns the slice of `buffer` that was written to.
    pub fn readStringBounded(self: LoadContext, buffer: []u8) ![]u8 {
        const len = try self.read(u32);
        if (len > buffer.len) return error.BufferTooSmall;
        const slice = buffer[0..len];
        try self.reader.readNoEof(slice);
        return slice;
    }
};

/// Magic bytes at the start of every saved state ("ZPLG" in ASCII).
pub const MAGIC: u32 = 0x5A504C47;

/// Write the standard state header (magic bytes + version).
///
/// Wrappers call this before delegating to the plugin's `save` callback.
pub fn writeHeader(writer: std.io.AnyWriter, version: StateVersion) !void {
    try writer.writeInt(u32, MAGIC, .little);
    try writer.writeInt(u32, version, .little);
}

/// Read and validate the standard state header, returning the version number.
///
/// Wrappers call this before delegating to the plugin's `load` callback.
pub fn readHeader(reader: std.io.AnyReader) !StateVersion {
    const magic = try reader.readInt(u32, .little);
    if (magic != MAGIC) return error.InvalidStateMagic;
    const version = try reader.readInt(u32, .little);
    return version;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SaveContext write and read roundtrip" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Save
    const writer = stream.writer().any();
    const save_ctx = SaveContext{ .writer = writer };
    try save_ctx.write(f32, 0.5);
    try save_ctx.write(u32, 42);

    // Load
    stream.pos = 0;
    const reader = stream.reader().any();
    const load_ctx = LoadContext{ .reader = reader, .version = 1 };
    const f = try load_ctx.read(f32);
    const u = try load_ctx.read(u32);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f, 1e-6);
    try std.testing.expectEqual(@as(u32, 42), u);
}

test "SaveContext writeString and LoadContext readString" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Save
    const writer = stream.writer().any();
    const save_ctx = SaveContext{ .writer = writer };
    try save_ctx.writeString("hello");

    // Load (allocator-based)
    stream.pos = 0;
    const reader = stream.reader().any();
    const load_ctx = LoadContext{ .reader = reader, .version = 1 };
    const allocator = std.testing.allocator;
    const str = try load_ctx.readString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings("hello", str);
}

test "LoadContext readStringBounded" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Save
    const writer = stream.writer().any();
    const save_ctx = SaveContext{ .writer = writer };
    try save_ctx.writeString("test");

    // Load (bounded)
    stream.pos = 0;
    const reader = stream.reader().any();
    const load_ctx = LoadContext{ .reader = reader, .version = 1 };
    var read_buf: [64]u8 = undefined;
    const str = try load_ctx.readStringBounded(&read_buf);

    try std.testing.expectEqualStrings("test", str);
}

test "LoadContext readStringBounded buffer too small" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Save
    const writer = stream.writer().any();
    const save_ctx = SaveContext{ .writer = writer };
    try save_ctx.writeString("this is a long string");

    // Load (bounded with small buffer)
    stream.pos = 0;
    const reader = stream.reader().any();
    const load_ctx = LoadContext{ .reader = reader, .version = 1 };
    var read_buf: [10]u8 = undefined;
    const result = load_ctx.readStringBounded(&read_buf);

    try std.testing.expectError(error.BufferTooSmall, result);
}

test "writeHeader and readHeader roundtrip" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Write header
    const writer = stream.writer().any();
    try writeHeader(writer, 42);

    // Read header
    stream.pos = 0;
    const reader = stream.reader().any();
    const version = try readHeader(reader);

    try std.testing.expectEqual(@as(StateVersion, 42), version);
}

test "readHeader detects invalid magic" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Write wrong magic
    const writer = stream.writer().any();
    try writer.writeInt(u32, 0xDEADBEEF, .little);
    try writer.writeInt(u32, 1, .little);

    // Read header
    stream.pos = 0;
    const reader = stream.reader().any();
    const result = readHeader(reader);

    try std.testing.expectError(error.InvalidStateMagic, result);
}

test "writeBytes and readBytes" {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Save
    const writer = stream.writer().any();
    const save_ctx = SaveContext{ .writer = writer };
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    try save_ctx.writeBytes(&data);

    // Load
    stream.pos = 0;
    const reader = stream.reader().any();
    const load_ctx = LoadContext{ .reader = reader, .version = 1 };
    var read_data: [5]u8 = undefined;
    try load_ctx.readBytes(&read_data);

    try std.testing.expectEqualSlices(u8, &data, &read_data);
}
