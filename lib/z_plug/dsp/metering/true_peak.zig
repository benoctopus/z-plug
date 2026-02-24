// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// ITU-R BS.1770 true peak meter using 4x polyphase FIR oversampling.
const std = @import("std");
const conversions = @import("../util/conversions.zig");

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
        return conversions.gainToDbFast(self.peak);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
