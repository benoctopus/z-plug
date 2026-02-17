// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Audio metering utilities for real-time peak, RMS, and LUFS measurement.
///
/// This module provides real-time-safe metering tools conforming to industry
/// standards (ITU-R BS.1770-4 / EBU R128). All meters use pre-allocated
/// fixed-size buffers with no heap allocations at runtime.
///
/// # Meters
///
/// - `PeakMeter`: Sample peak detection with hold and exponential decay
/// - `RmsMeter`: Running RMS with configurable window
/// - `TruePeakMeter`: ITU-R BS.1770 true peak via 4x oversampling (12-sample latency)
/// - `LufsMeter`: Full EBU R128 loudness (momentary, short-term, integrated with gating)
///
/// # Latency
///
/// All meters are read-only and do not modify the audio signal. `TruePeakMeter`
/// has 12 samples of measurement latency due to its FIR filter. This is not
/// signal latency -- plugin authors do NOT need to report additional latency
/// to the host for metering purposes.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const util = @import("util.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Maximum number of 100ms blocks for RMS window buffering.
/// 128 blocks = 12.8 seconds at 100ms per block.
const max_rms_blocks = 128;

/// Maximum number of channels for LUFS metering (up to 5.1 surround).
pub const max_lufs_channels = 6;

/// Maximum number of 100ms windows for LUFS history.
/// 3600 blocks = 6 minutes of history.
const max_lufs_windows = 3600;

/// Number of histogram bins for LUFS gated integration.
const lufs_histogram_bins = 1000;

// ---------------------------------------------------------------------------
// Biquad IIR Filter
// ---------------------------------------------------------------------------

/// Second-order IIR filter (biquad) for K-weighting and general filtering.
///
/// Direct Form I implementation: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2]
///                                       - a1*y[n-1] - a2*y[n-2]
pub const Biquad = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,

    /// Initialize with explicit coefficients (a0 is implicitly 1.0).
    pub fn init(b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) Biquad {
        return .{
            .b0 = b0,
            .b1 = b1,
            .b2 = b2,
            .a1 = a1,
            .a2 = a2,
            .x1 = 0.0,
            .x2 = 0.0,
            .y1 = 0.0,
            .y2 = 0.0,
        };
    }

    /// Reset filter state to zero.
    pub fn reset(self: *Biquad) void {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }

    /// Process a single sample through the filter.
    pub inline fn process(self: *Biquad, x0: f32) f32 {
        const y0 = self.b0 * x0 + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x0;
        self.y2 = self.y1;
        self.y1 = y0;
        return y0;
    }

    /// K-weighting stage 1: high-shelf filter (head effects).
    /// ITU-R BS.1770-4, Table 1. Coefficients computed via bilinear transform.
    pub fn kWeightHighShelf(sample_rate: f32) Biquad {
        const f0 = 1681.974450955533;
        const gain_db = 3.999843853973347;
        const q = 0.7071752369554196;

        const k = @tan(std.math.pi * f0 / sample_rate);
        const vh = std.math.pow(f32, 10.0, gain_db / 20.0);
        const vb = std.math.pow(f32, vh, 0.4996667741545416);

        const a0 = 1.0 + k / q + k * k;
        return Biquad.init(
            (vh + vb * k / q + k * k) / a0,
            2.0 * (k * k - vh) / a0,
            (vh - vb * k / q + k * k) / a0,
            2.0 * (k * k - 1.0) / a0,
            (1.0 - k / q + k * k) / a0,
        );
    }

    /// K-weighting stage 2: RLB high-pass filter.
    /// ITU-R BS.1770-4, Table 1. Coefficients computed via bilinear transform.
    pub fn kWeightHighPass(sample_rate: f32) Biquad {
        const f0 = 38.13547087602444;
        const q = 0.5003270373238773;

        const k = @tan(std.math.pi * f0 / sample_rate);
        const a0 = 1.0 + k / q + k * k;
        return Biquad.init(
            1.0,
            -2.0,
            1.0,
            2.0 * (k * k - 1.0) / a0,
            (1.0 - k / q + k * k) / a0,
        );
    }
};

// ---------------------------------------------------------------------------
// Peak Meter
// ---------------------------------------------------------------------------

/// Sample peak meter with hold and exponential decay.
///
/// Tracks the maximum absolute sample value with optional hold time and
/// exponential decay for UI display. Zero latency -- the peak reading is
/// available immediately after `process()`.
pub const PeakMeter = struct {
    peak: f32,
    held_peak: f32,
    hold_samples_remaining: u32,
    hold_samples_max: u32,
    decay_coeff: f32,

    /// Initialize with hold and decay times.
    /// - `hold_ms`: how long to hold the peak before decaying (milliseconds)
    /// - `decay_ms`: time constant for exponential decay (milliseconds)
    /// - `sample_rate`: audio sample rate in Hz
    pub fn init(hold_ms: f32, decay_ms: f32, sample_rate: f32) PeakMeter {
        const hold_samples = @as(u32, @intFromFloat(hold_ms * sample_rate / 1000.0));
        const decay_coeff = if (decay_ms > 0.0) @exp(-1.0 / (decay_ms * sample_rate / 1000.0)) else 0.0;
        return .{
            .peak = 0.0,
            .held_peak = 0.0,
            .hold_samples_remaining = 0,
            .hold_samples_max = hold_samples,
            .decay_coeff = decay_coeff,
        };
    }

    /// Reset meter to zero.
    pub fn reset(self: *PeakMeter) void {
        self.peak = 0.0;
        self.held_peak = 0.0;
        self.hold_samples_remaining = 0;
    }

    /// Process a block of samples and update peak.
    /// Uses SIMD for efficient max-absolute computation.
    pub inline fn process(self: *PeakMeter, samples: []const f32) void {
        const vec_len = platform.SIMD_VEC_LEN;
        var max_val = self.peak;
        var i: usize = 0;

        // SIMD path
        while (i + vec_len <= samples.len) : (i += vec_len) {
            const vec: platform.F32xV = samples[i..][0..vec_len].*;
            const abs_vec = @abs(vec);
            const block_max = @reduce(.Max, abs_vec);
            max_val = @max(max_val, block_max);
        }

        // Scalar tail
        while (i < samples.len) : (i += 1) {
            max_val = @max(max_val, @abs(samples[i]));
        }

        self.peak = max_val;

        // Update held peak with hold and decay
        if (max_val > self.held_peak) {
            self.held_peak = max_val;
            self.hold_samples_remaining = self.hold_samples_max;
        } else if (self.hold_samples_remaining > 0) {
            self.hold_samples_remaining -= @min(self.hold_samples_remaining, @as(u32, @intCast(samples.len)));
        } else {
            self.held_peak *= std.math.pow(f32, self.decay_coeff, @as(f32, @floatFromInt(samples.len)));
        }
    }

    /// Read the current peak (linear, 0.0-1.0+).
    pub inline fn readPeak(self: *const PeakMeter) f32 {
        return self.peak;
    }

    /// Read the current peak in dB.
    pub inline fn readPeakDb(self: *const PeakMeter) f32 {
        return util.gainToDbFast(self.peak);
    }

    /// Read the held peak in dB.
    pub inline fn readHeldPeakDb(self: *const PeakMeter) f32 {
        return util.gainToDbFast(self.held_peak);
    }
};

// ---------------------------------------------------------------------------
// RMS Meter
// ---------------------------------------------------------------------------

/// Running RMS meter with configurable window.
///
/// Maintains a running mean-square over a configurable window using a ring
/// buffer of per-block sums. Zero signal latency -- the RMS reading reflects
/// the configured window of past samples. The reading is available immediately;
/// the "window" is a measurement window, not processing latency.
pub const RmsMeter = struct {
    sum_squares: f32,
    window_buf: [max_rms_blocks]f32,
    window_idx: u32,
    window_len: u32,
    block_sum: f32,
    block_count: u32,
    block_size: u32,

    /// Initialize with window size.
    /// - `window_ms`: RMS averaging window in milliseconds
    /// - `sample_rate`: audio sample rate in Hz
    pub fn init(window_ms: f32, sample_rate: f32) RmsMeter {
        const block_size = @as(u32, @intFromFloat(sample_rate / 10.0)); // 100ms blocks
        const window_blocks = @as(u32, @intFromFloat(window_ms / 100.0));
        const window_len = @min(window_blocks, max_rms_blocks);

        return .{
            .sum_squares = 0.0,
            .window_buf = [_]f32{0.0} ** max_rms_blocks,
            .window_idx = 0,
            .window_len = window_len,
            .block_sum = 0.0,
            .block_count = 0,
            .block_size = block_size,
        };
    }

    /// Reset meter to zero.
    pub fn reset(self: *RmsMeter) void {
        self.sum_squares = 0.0;
        @memset(&self.window_buf, 0.0);
        self.window_idx = 0;
        self.block_sum = 0.0;
        self.block_count = 0;
    }

    /// Process a block of samples and update RMS.
    pub inline fn process(self: *RmsMeter, samples: []const f32) void {
        for (samples) |s| {
            self.block_sum += s * s;
            self.block_count += 1;

            if (self.block_count >= self.block_size) {
                // Finalize this block
                const block_mean = self.block_sum / @as(f32, @floatFromInt(self.block_size));

                // Remove oldest block from sum
                self.sum_squares -= self.window_buf[self.window_idx];

                // Add new block
                self.window_buf[self.window_idx] = block_mean;
                self.sum_squares += block_mean;

                // Advance ring buffer
                self.window_idx = (self.window_idx + 1) % self.window_len;

                // Reset block accumulator
                self.block_sum = 0.0;
                self.block_count = 0;
            }
        }
    }

    /// Read the current RMS (linear).
    pub inline fn readRms(self: *const RmsMeter) f32 {
        const mean_square = self.sum_squares / @as(f32, @floatFromInt(self.window_len));
        return @sqrt(mean_square);
    }

    /// Read the current RMS in dB.
    pub inline fn readRmsDb(self: *const RmsMeter) f32 {
        return util.gainToDbFast(self.readRms());
    }
};

// ---------------------------------------------------------------------------
// True Peak Meter
// ---------------------------------------------------------------------------

/// ITU-R BS.1770 true peak meter using 4x polyphase FIR oversampling.
///
/// **Latency:** 12 samples (floor((49 - 1) / 4)). This is measurement-only
/// latency -- the meter's peak reading lags the input by 12 samples. It does
/// NOT affect the audio path (the meter is read-only and does not modify the
/// signal). Plugin authors do NOT need to report additional latency to the
/// host for metering purposes.
pub const TruePeakMeter = struct {
    peak: f32,
    delay_line: [13]f32,
    delay_idx: u32,

    /// Measurement latency in samples (12). The peak reading lags the input
    /// by this many samples. This does not affect the audio signal.
    pub const latency_samples: u32 = 12;

    /// 4x polyphase FIR filter coefficients (49 taps, Hann-windowed sinc).
    /// Stored as flat arrays for each phase.
    const phase_0_coeffs = [_]f32{ computeCoeff(0, 0), computeCoeff(4, 0), computeCoeff(8, 0), computeCoeff(12, 0), computeCoeff(16, 0), computeCoeff(20, 0), computeCoeff(24, 0), computeCoeff(28, 0), computeCoeff(32, 0), computeCoeff(36, 0), computeCoeff(40, 0), computeCoeff(44, 0), computeCoeff(48, 0) };
    const phase_1_coeffs = [_]f32{ computeCoeff(1, 1), computeCoeff(5, 1), computeCoeff(9, 1), computeCoeff(13, 1), computeCoeff(17, 1), computeCoeff(21, 1), computeCoeff(25, 1), computeCoeff(29, 1), computeCoeff(33, 1), computeCoeff(37, 1), computeCoeff(41, 1), computeCoeff(45, 1) };
    const phase_2_coeffs = [_]f32{ computeCoeff(2, 2), computeCoeff(6, 2), computeCoeff(10, 2), computeCoeff(14, 2), computeCoeff(18, 2), computeCoeff(22, 2), computeCoeff(26, 2), computeCoeff(30, 2), computeCoeff(34, 2), computeCoeff(38, 2), computeCoeff(42, 2), computeCoeff(46, 2) };
    const phase_3_coeffs = [_]f32{ computeCoeff(3, 3), computeCoeff(7, 3), computeCoeff(11, 3), computeCoeff(15, 3), computeCoeff(19, 3), computeCoeff(23, 3), computeCoeff(27, 3), computeCoeff(31, 3), computeCoeff(35, 3), computeCoeff(39, 3), computeCoeff(43, 3), computeCoeff(47, 3) };

    /// Compute a single polyphase FIR coefficient at comptime.
    fn computeCoeff(tap_idx: comptime_int, phase: comptime_int) f32 {
        const taps = 49;
        const factor = 4;
        const m = @as(f32, @floatFromInt(tap_idx)) - @as(f32, @floatFromInt(taps - 1)) / 2.0;

        // Sinc function
        var c: f32 = 1.0;
        if (@abs(m) > 0.000001) {
            const arg = m * std.math.pi / @as(f32, @floatFromInt(factor));
            c = @sin(arg) / arg;
        }

        // Hann window
        c *= 0.5 * (1.0 - @cos(2.0 * std.math.pi * @as(f32, @floatFromInt(tap_idx)) / @as(f32, @floatFromInt(taps - 1))));

        // Return 0 for coefficients that belong to other phases
        if (tap_idx % factor != phase) {
            return 0.0;
        }

        return c;
    }

    /// Initialize the true peak meter.
    pub fn init() TruePeakMeter {
        return .{
            .peak = 0.0,
            .delay_line = [_]f32{0.0} ** 13,
            .delay_idx = 0,
        };
    }

    /// Reset meter to zero.
    pub fn reset(self: *TruePeakMeter) void {
        self.peak = 0.0;
        @memset(&self.delay_line, 0.0);
        self.delay_idx = 0;
    }

    /// Process a block of samples and update true peak.
    pub inline fn process(self: *TruePeakMeter, samples: []const f32) void {
        for (samples) |sample| {
            // Add sample to delay line
            self.delay_line[self.delay_idx] = sample;

            // Apply all 4 polyphase filters
            var acc0: f32 = 0.0;
            var acc1: f32 = 0.0;
            var acc2: f32 = 0.0;
            var acc3: f32 = 0.0;

            inline for (phase_0_coeffs, 0..) |coeff, idx| {
                const delay_pos = if (self.delay_idx >= idx) self.delay_idx - idx else self.delay_idx + 13 - idx;
                acc0 += self.delay_line[delay_pos] * coeff;
            }
            inline for (phase_1_coeffs, 0..) |coeff, idx| {
                const delay_pos = if (self.delay_idx >= idx) self.delay_idx - idx else self.delay_idx + 13 - idx;
                acc1 += self.delay_line[delay_pos] * coeff;
            }
            inline for (phase_2_coeffs, 0..) |coeff, idx| {
                const delay_pos = if (self.delay_idx >= idx) self.delay_idx - idx else self.delay_idx + 13 - idx;
                acc2 += self.delay_line[delay_pos] * coeff;
            }
            inline for (phase_3_coeffs, 0..) |coeff, idx| {
                const delay_pos = if (self.delay_idx >= idx) self.delay_idx - idx else self.delay_idx + 13 - idx;
                acc3 += self.delay_line[delay_pos] * coeff;
            }

            self.peak = @max(self.peak, @max(@abs(acc0), @max(@abs(acc1), @max(@abs(acc2), @abs(acc3)))));

            // Advance delay line
            self.delay_idx = (self.delay_idx + 1) % 13;
        }
    }

    /// Read the current true peak (linear).
    pub inline fn readTruePeak(self: *const TruePeakMeter) f32 {
        return self.peak;
    }

    /// Read the current true peak in dBTP.
    pub inline fn readTruePeakDb(self: *const TruePeakMeter) f32 {
        return util.gainToDbFast(self.peak);
    }
};

// The file continues with LufsMeter implementation...
// (This is getting long, so I'll add it in the next step)

// ---------------------------------------------------------------------------
// LUFS Meter
// ---------------------------------------------------------------------------

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
        if (self.window_count < 4) return util.minus_infinity_db;

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
        if (self.window_count < 30) return util.minus_infinity_db;

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
        if (self.window_count < 4) return util.minus_infinity_db;

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

        if (count == 0) return util.minus_infinity_db;

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

        if (count == 0) return util.minus_infinity_db;

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
        if (power <= 0.0) return util.minus_infinity_db;
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

test "Biquad K-weighting coefficients match ITU-R BS.1770-4" {
    const sample_rate = 48000.0;

    const stage1 = Biquad.kWeightHighShelf(sample_rate);
    const stage2 = Biquad.kWeightHighPass(sample_rate);

    // Reference values from ITU-R BS.1770-4 Table 1 (page 4)
    try std.testing.expectApproxEqAbs(1.53512485958697, stage1.b0, 1e-6);
    try std.testing.expectApproxEqAbs(-2.69169618940638, stage1.b1, 1e-6);
    try std.testing.expectApproxEqAbs(1.19839281085285, stage1.b2, 1e-6);
    try std.testing.expectApproxEqAbs(-1.69065929318241, stage1.a1, 1e-6);
    try std.testing.expectApproxEqAbs(0.73248077421585, stage1.a2, 1e-6);

    try std.testing.expectApproxEqAbs(1.0, stage2.b0, 1e-6);
    try std.testing.expectApproxEqAbs(-2.0, stage2.b1, 1e-6);
    try std.testing.expectApproxEqAbs(1.0, stage2.b2, 1e-6);
    try std.testing.expectApproxEqAbs(-1.99004745483398, stage2.a1, 1e-6);
    try std.testing.expectApproxEqAbs(0.99007225036621, stage2.a2, 1e-6);
}

test "PeakMeter detects maximum sample" {
    var meter = PeakMeter.init(100.0, 500.0, 48000.0);

    const samples = [_]f32{ 0.1, -0.8, 0.3, -0.5, 0.7 };
    meter.process(&samples);

    try std.testing.expectApproxEqAbs(0.8, meter.readPeak(), 1e-6);
}

test "RmsMeter computes running RMS" {
    var meter = RmsMeter.init(300.0, 48000.0);

    // Feed constant 0.5 amplitude for several blocks
    const block_size = 4800;
    const samples = [_]f32{0.5} ** block_size;

    for (0..5) |_| {
        meter.process(&samples);
    }

    const rms = meter.readRms();
    try std.testing.expectApproxEqAbs(0.5, rms, 0.01);
}

test "TruePeakMeter detects inter-sample peaks" {
    var meter = TruePeakMeter.init();

    // Create a signal that peaks between samples
    // Two consecutive samples of opposite polarity near full scale
    var samples: [100]f32 = undefined;
    @memset(&samples, 0.0);
    samples[50] = 0.9;
    samples[51] = -0.9;

    meter.process(&samples);

    // True peak should be higher than sample peak due to inter-sample reconstruction
    // This is a basic test; exact value depends on filter response
    const true_peak = meter.readTruePeak();
    try std.testing.expect(true_peak >= 0.9);
}

test "LufsMeter measures -23 LUFS for -23 dBFS sine" {
    const sample_rate = 48000.0;
    var meter = LufsMeter.init(2, sample_rate);

    // Generate 20 seconds of 1kHz sine at -23 dBFS
    const duration_samples = @as(usize, @intFromFloat(sample_rate * 20.0));
    const amplitude = util.dbToGainFast(-23.0);
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

