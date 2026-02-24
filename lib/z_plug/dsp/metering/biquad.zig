// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Second-order IIR filter (biquad) for K-weighting and general filtering.
const std = @import("std");

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
