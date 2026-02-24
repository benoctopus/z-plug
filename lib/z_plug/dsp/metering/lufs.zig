// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Full EBU R128 / ITU-R BS.1770-4 loudness meter.
const std = @import("std");
const Biquad = @import("biquad.zig").Biquad;
const conversions = @import("../util/conversions.zig");

/// Maximum number of channels for LUFS metering (up to 5.1 surround).
pub const max_lufs_channels = 6;

/// Maximum number of 100ms windows for LUFS history.
/// 3600 blocks = 6 minutes of history.
const max_lufs_windows = 3600;

/// Number of histogram bins for LUFS gated integration.
const lufs_histogram_bins = 1000;

/// Full EBU R128 / ITU-R BS.1770-4 loudness meter.
///
/// Per-channel K-weighting + 100ms windowed power accumulation + gated
/// integration. Zero signal latency -- all meters are read-only and do not
/// modify the audio. The K-weighting IIR filters have negligible group delay
/// (~2 samples). Momentary loudness requires 400ms of accumulated audio before
/// the first valid reading; short-term requires 3s. These are measurement
/// windows, not processing latency -- plugin authors do NOT need to report
/// additional latency to the host.
pub const LufsMeter = struct {
    channels: u32,
    filters: [max_lufs_channels][2]Biquad,
    channel_weights: [max_lufs_channels]f32,
    samples_per_100ms: u32,
    sample_count: u32,
    channel_sums: [max_lufs_channels]f32,
    window_buf: [max_lufs_windows]f32,
    window_idx: u32,
    window_count: u32,
    histogram: [lufs_histogram_bins]u32,

    /// Initialize for the given number of channels and sample rate.
    /// Default channel weights: L/R/C = 1.0, Ls/Rs = 1.41, LFE = 0.0 (excluded).
    pub fn init(channels: u32, sample_rate: f32) LufsMeter {
        var meter: LufsMeter = .{
            .channels = @min(channels, max_lufs_channels),
            .filters = undefined,
            .channel_weights = [_]f32{1.0} ** max_lufs_channels,
            .samples_per_100ms = @as(u32, @intFromFloat(sample_rate / 10.0)),
            .sample_count = 0,
            .channel_sums = [_]f32{0.0} ** max_lufs_channels,
            .window_buf = [_]f32{0.0} ** max_lufs_windows,
            .window_idx = 0,
            .window_count = 0,
            .histogram = [_]u32{0} ** lufs_histogram_bins,
        };

        // Initialize K-weighting filters for each channel
        for (0..meter.channels) |ch| {
            meter.filters[ch][0] = Biquad.kWeightHighShelf(sample_rate);
            meter.filters[ch][1] = Biquad.kWeightHighPass(sample_rate);
        }

        // Set standard weights (5.1 layout assumed for 6 channels)
        if (channels >= 5) {
            meter.channel_weights[4] = 1.41; // Ls
            if (channels >= 6) {
                meter.channel_weights[5] = 1.41; // Rs
            }
        }

        return meter;
    }

    /// Reset meter to zero.
    pub fn reset(self: *LufsMeter) void {
        for (0..self.channels) |ch| {
            self.filters[ch][0].reset();
            self.filters[ch][1].reset();
        }
        @memset(&self.channel_sums, 0.0);
        @memset(&self.window_buf, 0.0);
        @memset(&self.histogram, 0);
        self.window_idx = 0;
        self.window_count = 0;
        self.sample_count = 0;
    }

    /// Process a block of multichannel audio.
    /// `channel_data` is an array of channel slices, `num_samples` per channel.
    pub inline fn process(self: *LufsMeter, channel_data: []const []const f32, num_samples: usize) void {
        for (0..num_samples) |sample_idx| {
            // Process each channel: K-weight and accumulate sum-of-squares
            for (0..self.channels) |ch| {
                const sample = channel_data[ch][sample_idx];
                const filtered1 = self.filters[ch][0].process(sample);
                const filtered2 = self.filters[ch][1].process(filtered1);
                self.channel_sums[ch] += filtered2 * filtered2;
            }

            self.sample_count += 1;

            // Complete a 100ms window
            if (self.sample_count >= self.samples_per_100ms) {
                var block_power: f32 = 0.0;
                for (0..self.channels) |ch| {
                    const mean_square = self.channel_sums[ch] / @as(f32, @floatFromInt(self.samples_per_100ms));
                    block_power += mean_square * self.channel_weights[ch];
                    self.channel_sums[ch] = 0.0;
                }

                // Store in ring buffer
                if (self.window_count < max_lufs_windows) {
                    self.window_buf[self.window_count] = block_power;
                    self.window_count += 1;
                } else {
                    self.window_buf[self.window_idx] = block_power;
                }
                self.window_idx = (self.window_idx + 1) % max_lufs_windows;

                // Update histogram for gated integration
                const loudness = powerToLufs(block_power);
                if (loudness >= -70.0 and loudness < 30.0) {
                    const bin = @as(usize, @intFromFloat((loudness + 70.0) * 10.0));
                    if (bin < lufs_histogram_bins) {
                        self.histogram[bin] += 1;
                    }
                }

                self.sample_count = 0;
            }
        }
    }

    /// Read momentary loudness (400ms window, last 4 blocks).
    pub fn momentaryLufs(self: *const LufsMeter) f32 {
        if (self.window_count < 4) return conversions.minus_infinity_db;

        var sum: f32 = 0.0;
        const start_idx = if (self.window_count < max_lufs_windows) self.window_count - 4 else (self.window_idx + max_lufs_windows - 4) % max_lufs_windows;

        for (0..4) |i| {
            const idx = (start_idx + i) % max_lufs_windows;
            sum += self.window_buf[idx];
        }

        return powerToLufs(sum / 4.0);
    }

    /// Read short-term loudness (3s window, last 30 blocks).
    pub fn shortTermLufs(self: *const LufsMeter) f32 {
        if (self.window_count < 30) return conversions.minus_infinity_db;

        var sum: f32 = 0.0;
        const start_idx = if (self.window_count < max_lufs_windows) self.window_count - 30 else (self.window_idx + max_lufs_windows - 30) % max_lufs_windows;

        for (0..30) |i| {
            const idx = (start_idx + i) % max_lufs_windows;
            sum += self.window_buf[idx];
        }

        return powerToLufs(sum / 30.0);
    }

    /// Read integrated loudness with EBU R128 gating.
    pub fn integratedLufs(self: *const LufsMeter) f32 {
        if (self.window_count < 4) return conversions.minus_infinity_db;

        // Use histogram-based gating (more efficient than iterating all blocks)
        var sum_power: f32 = 0.0;
        var count: u32 = 0;

        // Absolute gate: -70 LUFS (bin 0 corresponds to -70 LUFS)
        for (0..lufs_histogram_bins) |bin| {
            if (self.histogram[bin] > 0) {
                const bin_loudness = @as(f32, @floatFromInt(bin)) / 10.0 - 70.0;
                const bin_power = lufsToPower(bin_loudness);
                sum_power += bin_power * @as(f32, @floatFromInt(self.histogram[bin]));
                count += self.histogram[bin];
            }
        }

        if (count == 0) return conversions.minus_infinity_db;

        const absolute_gated_power = sum_power / @as(f32, @floatFromInt(count));
        const absolute_gated_lufs = powerToLufs(absolute_gated_power);

        // Relative gate: -10 LU below absolute-gated loudness
        const relative_threshold = absolute_gated_lufs - 10.0;
        sum_power = 0.0;
        count = 0;

        for (0..lufs_histogram_bins) |bin| {
            if (self.histogram[bin] > 0) {
                const bin_loudness = @as(f32, @floatFromInt(bin)) / 10.0 - 70.0;
                if (bin_loudness >= relative_threshold) {
                    const bin_power = lufsToPower(bin_loudness);
                    sum_power += bin_power * @as(f32, @floatFromInt(self.histogram[bin]));
                    count += self.histogram[bin];
                }
            }
        }

        if (count == 0) return conversions.minus_infinity_db;

        return powerToLufs(sum_power / @as(f32, @floatFromInt(count)));
    }

    /// Read loudness range (LRA) in LU.
    pub fn loudnessRange(self: *const LufsMeter) f32 {
        // Simplified LRA: distribution of short-term loudness
        // Full implementation would require tracking short-term blocks separately
        // For now, return 0 (not implemented)
        _ = self;
        return 0.0;
    }

    /// Convert K-weighted power to LUFS.
    inline fn powerToLufs(power: f32) f32 {
        if (power <= 0.0) return conversions.minus_infinity_db;
        return -0.691 + 10.0 * std.math.log10(power);
    }

    /// Convert LUFS to K-weighted power.
    inline fn lufsToPower(lufs: f32) f32 {
        return std.math.pow(f32, 10.0, (lufs + 0.691) / 10.0);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "LufsMeter measures -23 LUFS for -23 dBFS sine" {
    const sample_rate = 48000.0;
    var meter = LufsMeter.init(2, sample_rate);

    // Generate 20 seconds of 1kHz sine at -23 dBFS
    const duration_samples = @as(usize, @intFromFloat(sample_rate * 20.0));
    const amplitude = conversions.dbToGainFast(-23.0);
    const frequency = 1000.0;

    var left_channel: [4800]f32 = undefined;
    var right_channel: [4800]f32 = undefined;

    var sample_idx: usize = 0;
    while (sample_idx < duration_samples) {
        const block_size = @min(4800, duration_samples - sample_idx);

        for (0..block_size) |i| {
            const t = @as(f32, @floatFromInt(sample_idx + i)) / sample_rate;
            const sample = amplitude * @sin(2.0 * std.math.pi * frequency * t);
            left_channel[i] = sample;
            right_channel[i] = sample;
        }

        const channels = [_][]const f32{ left_channel[0..block_size], right_channel[0..block_size] };
        meter.process(&channels, block_size);
        sample_idx += block_size;
    }

    const integrated = meter.integratedLufs();
    // Allow ±0.5 LU tolerance (stricter tests would use reference files)
    try std.testing.expectApproxEqAbs(-23.0, integrated, 0.5);
}
