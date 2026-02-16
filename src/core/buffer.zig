/// Zero-copy audio buffer abstraction.
///
/// `Buffer` wraps host-provided audio data as `[][]f32` (channels x samples)
/// without copying any audio samples. It provides three access strategies:
///
/// 1. **Raw slice** — `getChannel()` / `getSample()` / `setSample()` for
///    direct random access.
/// 2. **Per-sample** — `iterSamples()` yields one `ChannelSamples` per sample
///    index, giving access to all channels at that sample.
/// 3. **Per-block** — `iterBlocks(max_block_size)` yields `Block` sub-buffers
///    of up to `max_block_size` samples, useful for FFT or convolution.
const std = @import("std");

/// A lightweight view over host-provided audio data.
///
/// The wrappers populate `channel_data` with pointers directly into the
/// host's buffers — no audio data is ever copied.
pub const Buffer = struct {
    /// One slice per channel, each pointing to `num_samples` contiguous `f32`
    /// values in host memory.
    channel_data: [][]f32,
    /// Number of valid samples per channel in this buffer.
    num_samples: usize,

    /// Returns the number of audio channels.
    pub fn channels(self: Buffer) usize {
        return self.channel_data.len;
    }

    /// Returns the number of samples per channel.
    pub fn samples(self: Buffer) usize {
        return self.num_samples;
    }

    /// Returns `true` if the buffer has no samples or no channels.
    pub fn isEmpty(self: Buffer) bool {
        return self.num_samples == 0 or self.channel_data.len == 0;
    }

    /// Returns the raw sample slice for a single channel.
    pub fn getChannel(self: Buffer, ch: usize) []f32 {
        return self.channel_data[ch][0..self.num_samples];
    }

    /// Read a single sample value.
    pub fn getSample(self: Buffer, ch: usize, sample: usize) f32 {
        return self.channel_data[ch][sample];
    }

    /// Write a single sample value.
    pub fn setSample(self: *Buffer, ch: usize, sample: usize, value: f32) void {
        self.channel_data[ch][sample] = value;
    }

    /// Creates a sub-buffer view of a range of samples.
    /// The sub-buffer is a zero-copy view into the same backing memory.
    /// 
    /// `scratch_channels` must be an array with at least `self.channels()` elements.
    /// The returned `Buffer` uses slices from `scratch_channels` that point into
    /// the original buffer's memory.
    ///
    /// Example:
    /// ```
    /// var scratch: [32][]f32 = undefined;
    /// const sub = buf.subBuffer(&scratch, 10, 20);
    /// // sub now contains samples [10..30) from buf
    /// ```
    pub fn subBuffer(self: Buffer, scratch_channels: [][]f32, offset: usize, len: usize) Buffer {
        for (self.channel_data, 0..) |ch, i| {
            scratch_channels[i] = ch[offset..][0..len];
        }
        return Buffer{
            .channel_data = scratch_channels[0..self.channel_data.len],
            .num_samples = len,
        };
    }

    // -- Per-sample iteration -------------------------------------------------

    /// Returns an iterator that yields one `ChannelSamples` per sample index.
    ///
    /// ```
    /// var iter = buf.iterSamples();
    /// while (iter.next()) |cs| {
    ///     const left = cs.get(0);
    ///     const right = cs.get(1);
    ///     cs.set(0, left * gain);
    ///     cs.set(1, right * gain);
    /// }
    /// ```
    pub fn iterSamples(self: *Buffer) SamplesIter {
        return SamplesIter{
            .channel_data = self.channel_data,
            .num_samples = self.num_samples,
            .current = 0,
        };
    }

    // -- Per-block iteration --------------------------------------------------

    /// Returns an iterator that yields `Block` sub-buffers of up to
    /// `max_block_size` samples.
    ///
    /// ```
    /// var iter = buf.iterBlocks(64);
    /// while (iter.next()) |entry| {
    ///     processBlock(entry.offset, entry.block);
    /// }
    /// ```
    pub fn iterBlocks(self: *Buffer, max_block_size: usize) BlocksIter {
        return BlocksIter{
            .channel_data = self.channel_data,
            .num_samples = self.num_samples,
            .max_block_size = max_block_size,
            .current = 0,
        };
    }
};

/// Provides access to all channels at a single sample index.
pub const ChannelSamples = struct {
    channel_data: [][]f32,
    sample_index: usize,

    /// Read the sample value for channel `ch` at the current sample index.
    pub fn get(self: ChannelSamples, ch: usize) f32 {
        return self.channel_data[ch][self.sample_index];
    }

    /// Write the sample value for channel `ch` at the current sample index.
    pub fn set(self: ChannelSamples, ch: usize, value: f32) void {
        self.channel_data[ch][self.sample_index] = value;
    }

    /// The number of channels.
    pub fn channelCount(self: ChannelSamples) usize {
        return self.channel_data.len;
    }
};

/// Iterator that yields one `ChannelSamples` per sample index.
pub const SamplesIter = struct {
    channel_data: [][]f32,
    num_samples: usize,
    current: usize,

    pub fn next(self: *SamplesIter) ?ChannelSamples {
        if (self.current >= self.num_samples) return null;
        const cs = ChannelSamples{
            .channel_data = self.channel_data,
            .sample_index = self.current,
        };
        self.current += 1;
        return cs;
    }
};

/// A contiguous sub-range of the buffer, up to `max_block_size` samples.
pub const Block = struct {
    channel_data: [][]f32,
    offset: usize,
    len: usize,

    /// Returns the raw sample slice for channel `ch` within this block.
    pub fn getChannel(self: Block, ch: usize) []f32 {
        return self.channel_data[ch][self.offset..][0..self.len];
    }

    /// The number of samples in this block.
    pub fn samples(self: Block) usize {
        return self.len;
    }

    /// The number of channels.
    pub fn channelCount(self: Block) usize {
        return self.channel_data.len;
    }
};

/// An entry yielded by `BlocksIter`: a block plus its sample offset.
pub const BlockEntry = struct {
    /// Sample offset of this block within the full buffer.
    offset: usize,
    /// The sub-buffer block.
    block: Block,
};

/// Iterator that yields `BlockEntry` sub-buffers of up to `max_block_size`.
pub const BlocksIter = struct {
    channel_data: [][]f32,
    num_samples: usize,
    max_block_size: usize,
    current: usize,

    pub fn next(self: *BlocksIter) ?BlockEntry {
        if (self.current >= self.num_samples) return null;
        const remaining = self.num_samples - self.current;
        const block_len = @min(remaining, self.max_block_size);
        const entry = BlockEntry{
            .offset = self.current,
            .block = Block{
                .channel_data = self.channel_data,
                .offset = self.current,
                .len = block_len,
            },
        };
        self.current += block_len;
        return entry;
    }
};

/// Auxiliary (sidechain) audio buffers passed alongside the main `Buffer`.
pub const AuxBuffers = struct {
    /// Auxiliary input buffers (one per aux input bus).
    inputs: []Buffer,
    /// Auxiliary output buffers (one per aux output bus).
    outputs: []Buffer,

    /// An empty set of auxiliary buffers.
    pub const EMPTY: AuxBuffers = .{
        .inputs = &.{},
        .outputs = &.{},
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Buffer basic access" {
    var ch0 = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var ch1 = [_]f32{ 5.0, 6.0, 7.0, 8.0 };
    var channel_data = [_][]f32{ &ch0, &ch1 };
    const buf = Buffer{
        .channel_data = &channel_data,
        .num_samples = 4,
    };

    try std.testing.expectEqual(@as(usize, 2), buf.channels());
    try std.testing.expectEqual(@as(usize, 4), buf.samples());
    try std.testing.expect(!buf.isEmpty());

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), buf.getSample(0, 0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), buf.getSample(1, 3), 1e-6);

    const slice = buf.getChannel(0);
    try std.testing.expectEqual(@as(usize, 4), slice.len);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), slice[2], 1e-6);
}

test "Buffer isEmpty" {
    var channel_data = [_][]f32{};
    const buf = Buffer{
        .channel_data = &channel_data,
        .num_samples = 0,
    };
    try std.testing.expect(buf.isEmpty());
}

test "Buffer setSample" {
    var ch0 = [_]f32{ 0.0, 0.0 };
    var channel_data = [_][]f32{&ch0};
    var buf = Buffer{
        .channel_data = &channel_data,
        .num_samples = 2,
    };
    buf.setSample(0, 1, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), buf.getSample(0, 1), 1e-6);
}

test "Buffer iterSamples" {
    var ch0 = [_]f32{ 1.0, 2.0, 3.0 };
    var ch1 = [_]f32{ 4.0, 5.0, 6.0 };
    var channel_data = [_][]f32{ &ch0, &ch1 };
    var buf = Buffer{
        .channel_data = &channel_data,
        .num_samples = 3,
    };

    var iter = buf.iterSamples();
    var count: usize = 0;

    while (iter.next()) |cs| {
        try std.testing.expectEqual(@as(usize, 2), cs.channelCount());
        if (count == 0) {
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), cs.get(0), 1e-6);
            try std.testing.expectApproxEqAbs(@as(f32, 4.0), cs.get(1), 1e-6);
        }
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "Buffer iterSamples write" {
    var ch0 = [_]f32{ 1.0, 2.0 };
    var channel_data = [_][]f32{&ch0};
    var buf = Buffer{
        .channel_data = &channel_data,
        .num_samples = 2,
    };

    var iter = buf.iterSamples();
    while (iter.next()) |cs| {
        cs.set(0, cs.get(0) * 2.0);
    }

    try std.testing.expectApproxEqAbs(@as(f32, 2.0), ch0[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), ch0[1], 1e-6);
}

test "Buffer iterBlocks" {
    var ch0 = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    var channel_data = [_][]f32{&ch0};
    var buf = Buffer{
        .channel_data = &channel_data,
        .num_samples = 5,
    };

    var iter = buf.iterBlocks(2);
    var block_count: usize = 0;

    // Block 0: offset=0, len=2
    if (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 0), entry.offset);
        try std.testing.expectEqual(@as(usize, 2), entry.block.samples());
        const slice = entry.block.getChannel(0);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), slice[0], 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 2.0), slice[1], 1e-6);
        block_count += 1;
    }
    // Block 1: offset=2, len=2
    if (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 2), entry.offset);
        try std.testing.expectEqual(@as(usize, 2), entry.block.samples());
        block_count += 1;
    }
    // Block 2: offset=4, len=1 (remainder)
    if (iter.next()) |entry| {
        try std.testing.expectEqual(@as(usize, 4), entry.offset);
        try std.testing.expectEqual(@as(usize, 1), entry.block.samples());
        const slice = entry.block.getChannel(0);
        try std.testing.expectApproxEqAbs(@as(f32, 5.0), slice[0], 1e-6);
        block_count += 1;
    }
    // No more blocks.
    try std.testing.expectEqual(@as(?BlockEntry, null), iter.next());
    try std.testing.expectEqual(@as(usize, 3), block_count);
}

test "Buffer zero-copy pointer identity" {
    var ch0 = [_]f32{ 1.0, 2.0, 3.0 };
    var channel_data = [_][]f32{&ch0};
    const buf = Buffer{
        .channel_data = &channel_data,
        .num_samples = 3,
    };

    const slice = buf.getChannel(0);
    try std.testing.expectEqual(@intFromPtr(&ch0[0]), @intFromPtr(&slice[0]));
}

test "AuxBuffers EMPTY" {
    const aux = AuxBuffers.EMPTY;
    try std.testing.expectEqual(@as(usize, 0), aux.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), aux.outputs.len);
}

test "Buffer subBuffer zero-copy slicing" {
    var ch0 = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    var ch1 = [_]f32{ 7.0, 8.0, 9.0, 10.0, 11.0, 12.0 };
    var channel_data = [_][]f32{ &ch0, &ch1 };
    const buf = Buffer{
        .channel_data = &channel_data,
        .num_samples = 6,
    };

    var scratch: [32][]f32 = undefined;
    const sub = buf.subBuffer(&scratch, 2, 3); // samples [2..5)
    
    try std.testing.expectEqual(@as(usize, 2), sub.channels());
    try std.testing.expectEqual(@as(usize, 3), sub.samples());
    
    // Verify correct slice
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), sub.getSample(0, 0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), sub.getSample(0, 1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), sub.getSample(0, 2), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), sub.getSample(1, 0), 1e-6);
    
    // Verify zero-copy (pointer identity)
    const sub_ch0 = sub.getChannel(0);
    try std.testing.expectEqual(@intFromPtr(&ch0[2]), @intFromPtr(&sub_ch0[0]));
}
