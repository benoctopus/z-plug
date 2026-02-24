// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Pure-Zig RIFF/WAVE file parser.
//!
//! Supports:
//!   - PCM 16-bit, 24-bit, 32-bit integer
//!   - IEEE float 32-bit
//!   - Mono and stereo (and any channel count)
//!
//! Output: deinterleaved f32 channel buffers.

const std = @import("std");

pub const WavError = error{
    InvalidRiffHeader,
    InvalidWaveFormat,
    MissingFmtChunk,
    MissingDataChunk,
    UnsupportedFormat,
    UnsupportedBitDepth,
    OutOfMemory,
    EndOfStream,
    Overflow,
    InputOutput,
    AccessDenied,
    FileNotFound,
    IsDir,
    NoSpaceLeft,
    NotOpenForReading,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    Unexpected,
    WouldBlock,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SharingViolation,
    PathAlreadyExists,
    PipeBusy,
    InvalidUtf8,
    BadPathName,
    NetworkNotFound,
    AntivirusInterference,
    SymLinkLoop,
    NoDevice,
    NotDir,
    FileLocksNotSupported,
    FileBusy,
    NameTooLong,
};

const WAVE_FORMAT_PCM: u16 = 0x0001;
const WAVE_FORMAT_IEEE_FLOAT: u16 = 0x0003;
const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

/// Loaded WAV file data. Channels are deinterleaved f32 slices.
/// All slices are owned by this struct; call `deinit` to free.
pub const WavData = struct {
    /// One slice per channel, each of length `num_frames`.
    channels: [][]f32,
    sample_rate: u32,
    num_frames: u64,
    channel_count: u32,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *WavData) void {
        for (self.channels) |ch| {
            self.allocator.free(ch);
        }
        self.allocator.free(self.channels);
        self.* = undefined;
    }
};

/// Load a WAV file from `path` into deinterleaved f32 channel buffers.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !WavData {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return loadFromFile(allocator, file);
}

/// Load a WAV file from an already-opened file handle.
pub fn loadFromFile(allocator: std.mem.Allocator, file: std.fs.File) !WavData {
    // Read entire file into memory so we can use a simple slice reader.
    const file_data = try file.readToEndAlloc(allocator, 512 * 1024 * 1024); // 512 MB max
    defer allocator.free(file_data);
    return loadFromMemory(allocator, file_data);
}

/// Load a WAV file from a byte slice.
pub fn loadFromMemory(allocator: std.mem.Allocator, data: []const u8) !WavData {
    var pos: usize = 0;

    const readBytes = struct {
        fn f(d: []const u8, p: *usize, n: usize) ![]const u8 {
            if (p.* + n > d.len) return error.EndOfStream;
            const slice = d[p.* .. p.* + n];
            p.* += n;
            return slice;
        }
    }.f;

    const readU16 = struct {
        fn f(d: []const u8, p: *usize) !u16 {
            const b = try @import("wav.zig").readBytesHelper(d, p, 2);
            return std.mem.readInt(u16, b[0..2], .little);
        }
    }.f;
    _ = readU16;

    const readU32 = struct {
        fn f(d: []const u8, p: *usize) !u32 {
            const b = try readBytes(d, p, 4);
            return std.mem.readInt(u32, b[0..4], .little);
        }
    }.f;

    // --- RIFF header ---
    const riff_id = try readBytes(data, &pos, 4);
    if (!std.mem.eql(u8, riff_id, "RIFF")) return error.InvalidRiffHeader;
    _ = try readU32(data, &pos); // chunk size (ignored)
    const wave_id = try readBytes(data, &pos, 4);
    if (!std.mem.eql(u8, wave_id, "WAVE")) return error.InvalidWaveFormat;

    // --- Scan chunks ---
    var fmt_found = false;
    var audio_format: u16 = 0;
    var channel_count: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var data_start: usize = 0;
    var data_size: u32 = 0;

    while (pos + 8 <= data.len) {
        const chunk_id = try readBytes(data, &pos, 4);
        const chunk_size = try readU32(data, &pos);
        const chunk_start = pos;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            audio_format = std.mem.readInt(u16, data[pos..][0..2], .little); pos += 2;
            channel_count = std.mem.readInt(u16, data[pos..][0..2], .little); pos += 2;
            sample_rate = std.mem.readInt(u32, data[pos..][0..4], .little); pos += 4;
            pos += 4; // byte rate
            pos += 2; // block align
            bits_per_sample = std.mem.readInt(u16, data[pos..][0..2], .little); pos += 2;

            if (audio_format == WAVE_FORMAT_EXTENSIBLE and chunk_size >= 40) {
                audio_format = if (bits_per_sample == 32) WAVE_FORMAT_IEEE_FLOAT else WAVE_FORMAT_PCM;
            }

            fmt_found = true;
            // Skip any remaining fmt bytes
            pos = chunk_start + chunk_size;
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_start = pos;
            data_size = chunk_size;
            break;
        } else {
            pos = chunk_start + chunk_size;
        }
    }

    if (!fmt_found) return error.MissingFmtChunk;
    if (data_size == 0) return error.MissingDataChunk;
    if (audio_format != WAVE_FORMAT_PCM and audio_format != WAVE_FORMAT_IEEE_FLOAT)
        return error.UnsupportedFormat;
    if (bits_per_sample != 16 and bits_per_sample != 24 and bits_per_sample != 32)
        return error.UnsupportedBitDepth;

    const bytes_per_sample: usize = bits_per_sample / 8;
    const frame_size: usize = bytes_per_sample * channel_count;
    const num_frames: u64 = data_size / frame_size;

    // Allocate deinterleaved channel buffers
    const channels = try allocator.alloc([]f32, channel_count);
    errdefer allocator.free(channels);

    var allocated: usize = 0;
    errdefer for (channels[0..allocated]) |ch| allocator.free(ch);

    for (channels) |*ch| {
        ch.* = try allocator.alloc(f32, num_frames);
        allocated += 1;
    }

    // Deinterleave and convert
    const sample_data = data[data_start .. data_start + data_size];
    for (0..num_frames) |frame_idx| {
        for (0..channel_count) |ch| {
            const byte_offset = frame_idx * frame_size + ch * bytes_per_sample;
            const sample_bytes = sample_data[byte_offset .. byte_offset + bytes_per_sample];
            channels[ch][frame_idx] = convertSample(audio_format, bits_per_sample, sample_bytes);
        }
    }

    return WavData{
        .channels = channels,
        .sample_rate = sample_rate,
        .num_frames = num_frames,
        .channel_count = channel_count,
        .allocator = allocator,
    };
}

/// Helper used by the inline readU16 closures above.
pub fn readBytesHelper(d: []const u8, p: *usize, n: usize) ![]const u8 {
    if (p.* + n > d.len) return error.EndOfStream;
    const slice = d[p.* .. p.* + n];
    p.* += n;
    return slice;
}

fn convertSample(audio_format: u16, bits: u16, bytes: []const u8) f32 {
    if (audio_format == WAVE_FORMAT_IEEE_FLOAT and bits == 32) {
        var val: f32 = undefined;
        @memcpy(std.mem.asBytes(&val), bytes);
        return val;
    }
    // PCM integer formats
    return switch (bits) {
        16 => blk: {
            const raw = std.mem.readInt(i16, bytes[0..2], .little);
            break :blk @as(f32, @floatFromInt(raw)) / 32768.0;
        },
        24 => blk: {
            // 24-bit little-endian signed
            const raw: i32 = @as(i32, bytes[0]) |
                (@as(i32, bytes[1]) << 8) |
                (@as(i32, bytes[2]) << 16);
            // Sign-extend from 24 bits
            const signed: i32 = if (raw & 0x800000 != 0) raw | @as(i32, @bitCast(@as(u32, 0xFF000000))) else raw;
            break :blk @as(f32, @floatFromInt(signed)) / 8388608.0;
        },
        32 => blk: {
            const raw = std.mem.readInt(i32, bytes[0..4], .little);
            break :blk @as(f32, @floatFromInt(raw)) / 2147483648.0;
        },
        else => 0.0,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "WAV loader: minimal 16-bit stereo" {
    // Build a minimal WAV in memory: 4 frames, stereo, 16-bit PCM, 44100 Hz
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);

    const writeAll = struct {
        fn f(b: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8) !void {
            try b.appendSlice(a, s);
        }
    }.f;
    const writeU16 = struct {
        fn f(b: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u16) !void {
            var tmp: [2]u8 = undefined;
            std.mem.writeInt(u16, &tmp, v, .little);
            try b.appendSlice(a, &tmp);
        }
    }.f;
    const writeU32 = struct {
        fn f(b: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u32) !void {
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, v, .little);
            try b.appendSlice(a, &tmp);
        }
    }.f;

    const a = std.testing.allocator;

    // RIFF header
    try writeAll(&buf, a, "RIFF");
    try writeU32(&buf, a, 0); // placeholder size
    try writeAll(&buf, a, "WAVE");

    // fmt chunk
    try writeAll(&buf, a, "fmt ");
    try writeU32(&buf, a, 16);
    try writeU16(&buf, a, WAVE_FORMAT_PCM);
    try writeU16(&buf, a, 2); // channels
    try writeU32(&buf, a, 44100); // sample rate
    try writeU32(&buf, a, 44100 * 2 * 2); // byte rate
    try writeU16(&buf, a, 4); // block align
    try writeU16(&buf, a, 16); // bits per sample

    // data chunk: 4 frames, stereo (L, R interleaved)
    const samples = [_]i16{ 0x4000, -1, 0, 0x2000, -0x4000, 0, 0x1000, 0x1000 };
    try writeAll(&buf, a, "data");
    try writeU32(&buf, a, @intCast(samples.len * 2));
    for (samples) |s| {
        var tmp: [2]u8 = undefined;
        std.mem.writeInt(i16, &tmp, s, .little);
        try buf.appendSlice(a, &tmp);
    }

    // Fix RIFF size
    const total_size: u32 = @intCast(buf.items.len - 8);
    std.mem.writeInt(u32, buf.items[4..8], total_size, .little);

    var wav = try loadFromMemory(std.testing.allocator, buf.items);
    defer wav.deinit();

    try std.testing.expectEqual(@as(u32, 2), wav.channel_count);
    try std.testing.expectEqual(@as(u32, 44100), wav.sample_rate);
    try std.testing.expectEqual(@as(u64, 4), wav.num_frames);

    // 0x4000 / 32768 = 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), wav.channels[0][0], 0.001);
    // Right channel first sample: -1 / 32768 is slightly negative
    try std.testing.expect(wav.channels[1][0] < 0.0);
}
