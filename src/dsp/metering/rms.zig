// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Running RMS meter with configurable window.
const std = @import("std");
const conversions = @import("../util/conversions.zig");

/// Maximum number of 100ms blocks for RMS window buffering.
/// 128 blocks = 12.8 seconds at 100ms per block.
const max_rms_blocks = 128;

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
        return conversions.gainToDbFast(self.readRms());
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
