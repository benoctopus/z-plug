// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Sample peak meter with hold and exponential decay.
const std = @import("std");
const platform = @import("../../core/platform.zig");
const conversions = @import("../util/conversions.zig");

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
        return conversions.gainToDbFast(self.peak);
    }

    /// Read the held peak in dB.
    pub inline fn readHeldPeakDb(self: *const PeakMeter) f32 {
        return conversions.gainToDbFast(self.held_peak);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PeakMeter detects maximum sample" {
    var meter = PeakMeter.init(100.0, 500.0, 48000.0);

    const samples = [_]f32{ 0.1, -0.8, 0.3, -0.5, 0.7 };
    meter.process(&samples);

    try std.testing.expectApproxEqAbs(0.8, meter.readPeak(), 1e-6);
}
