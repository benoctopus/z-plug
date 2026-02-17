// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Comptime-parameterized STFT processor.
const std = @import("std");
const config_mod = @import("config.zig");
const fft_mod = @import("fft.zig");
const platform = @import("../../core/platform.zig");

pub const StftConfig = config_mod.StftConfig;
pub const SpectralContext = config_mod.SpectralContext;

/// STFT processor generator (comptime generic).
///
/// Takes an Effect type and configuration, returns a struct implementing
/// an STFT engine. The Effect type must implement:
///
/// Required:
/// - `processBins(bins: []fft_mod.Complex, magnitudes: []const f32, user_state: []UserState, context: SpectralContext) void`
///
/// Optional:
/// - `pub const UserState = T;` (per-bin state type, defaults to void)
/// - `pub const user_state_default: T;` (initial value for user state)
/// - `pub const Params = struct { ... };` (parameters passed to processBins)
pub fn StftProcessor(comptime Effect: type, comptime cfg: StftConfig) type {
    const FFT_SIZE = cfg.fft_size;
    const HOP_SIZE = cfg.hop_size;
    const MAX_CHANNELS = cfg.max_channels;
    const NUM_BINS = FFT_SIZE / 2 + 1;
    const vec_len = platform.SIMD_VEC_LEN;
    const F32xV = platform.F32xV;

    // Detect optional Effect declarations
    const has_user_state = @hasDecl(Effect, "UserState");
    const UserState = if (has_user_state) Effect.UserState else void;
    const has_params = @hasDecl(Effect, "Params");
    const Params = if (has_params) Effect.Params else void;

    return struct {
        const Self = @This();

        /// Per-channel STFT state.
        const ChannelState = struct {
            // Input ring buffer (circular)
            input_ring: [FFT_SIZE]f32,
            write_pos: usize,

            // Output overlap-add buffer
            output_ola: [FFT_SIZE]f32,
            read_pos: usize,

            // FFT scratch buffer (windowed time-domain data)
            fft_scratch: [FFT_SIZE]f32,

            // Frequency-domain bins (output of forward FFT, input to inverse FFT)
            freq_bins: [NUM_BINS]fft_mod.Complex,

            // Hop counter (triggers FFT when >= HOP_SIZE)
            hop_counter: usize,

            fn init(self: *ChannelState) void {
                @memset(&self.input_ring, 0.0);
                @memset(&self.output_ola, 0.0);
                @memset(&self.fft_scratch, 0.0);
                self.write_pos = 0;
                self.read_pos = 0;
                self.hop_counter = 0;

                // Zero frequency bins
                for (&self.freq_bins) |*bin| {
                    bin.r = 0.0;
                    bin.i = 0.0;
                }
            }
        };

        channels: [MAX_CHANNELS]ChannelState,
        window: [FFT_SIZE]f32,
        fft_plan: fft_mod.FftPlan,
        magnitudes: [NUM_BINS]f32, // Precomputed bin magnitudes
        user_state: if (has_user_state) [MAX_CHANNELS][NUM_BINS]UserState else void,
        sample_rate: f32,
        context: SpectralContext,

        /// Initialize the STFT processor.
        /// Returns false if FFT plan allocation fails.
        pub fn init(sample_rate: f32) ?Self {
            var self: Self = undefined;
            self.sample_rate = sample_rate;

            // Initialize STFT state for all channels
            for (&self.channels) |*ch| {
                ch.init();
            }

            // Generate Hann window
            for (&self.window, 0..) |*w, i| {
                const phase = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, FFT_SIZE);
                w.* = 0.5 - 0.5 * @cos(phase);
            }

            // Allocate FFT plans
            self.fft_plan = fft_mod.FftPlan.init(FFT_SIZE) orelse return null;

            // Initialize magnitude buffer
            @memset(&self.magnitudes, 0.0);

            // Initialize user state if present
            if (has_user_state) {
                const default_val = if (@hasDecl(Effect, "user_state_default"))
                    Effect.user_state_default
                else
                    std.mem.zeroes(UserState);

                for (&self.user_state) |*ch_state| {
                    for (ch_state) |*bin_state| {
                        bin_state.* = default_val;
                    }
                }
            }

            // Initialize spectral context
            self.context = .{
                .sample_rate = sample_rate,
                .fft_size = FFT_SIZE,
                .hop_size = HOP_SIZE,
                .num_bins = NUM_BINS,
            };

            return self;
        }

        /// Free FFT plans.
        pub fn deinit(self: *Self) void {
            self.fft_plan.deinit();
        }

        /// Process a single sample through the STFT engine for a given channel.
        /// Returns the processed output sample.
        pub fn processSample(self: *Self, ch_idx: usize, input_sample: f32, params: Params) f32 {
            const ch = &self.channels[ch_idx];

            // Write to ring buffer
            ch.input_ring[ch.write_pos] = input_sample;
            ch.write_pos = (ch.write_pos + 1) % FFT_SIZE;

            // Increment hop counter
            ch.hop_counter += 1;

            // Perform STFT when hop is complete
            if (ch.hop_counter >= HOP_SIZE) {
                ch.hop_counter = 0;
                self.performSTFT(ch_idx, params);
            }

            // Read from overlap-add buffer
            const output_sample = ch.output_ola[ch.read_pos];
            ch.output_ola[ch.read_pos] = 0.0; // Clear for next overlap-add
            ch.read_pos = (ch.read_pos + 1) % FFT_SIZE;

            return output_sample;
        }

        /// Process a block of samples for a given channel (convenience method).
        pub fn processBlock(self: *Self, ch_idx: usize, input: []const f32, output: []f32, params: Params) void {
            std.debug.assert(input.len == output.len);
            for (input, output) |in_sample, *out_sample| {
                out_sample.* = self.processSample(ch_idx, in_sample, params);
            }
        }

        /// Perform one STFT frame: analysis -> processing -> synthesis.
        fn performSTFT(self: *Self, ch_idx: usize, params: Params) void {
            const ch = &self.channels[ch_idx];

            // === ANALYSIS ===
            // Copy ring buffer to scratch with window applied (SIMD-optimized)
            var i: usize = 0;

            // SIMD path: process vec_len samples at a time
            while (i + vec_len <= FFT_SIZE) : (i += vec_len) {
                var input_vec: F32xV = undefined;
                var window_vec: F32xV = undefined;

                for (0..vec_len) |j| {
                    const ring_idx = (ch.write_pos + i + j) % FFT_SIZE;
                    input_vec[j] = ch.input_ring[ring_idx];
                    window_vec[j] = self.window[i + j];
                }

                const windowed = input_vec * window_vec;

                for (0..vec_len) |j| {
                    ch.fft_scratch[i + j] = windowed[j];
                }
            }

            // Scalar tail: process remaining samples
            while (i < FFT_SIZE) : (i += 1) {
                const ring_idx = (ch.write_pos + i) % FFT_SIZE;
                ch.fft_scratch[i] = ch.input_ring[ring_idx] * self.window[i];
            }

            // Forward FFT: time domain -> frequency domain
            self.fft_plan.forward(ch.fft_scratch[0..], ch.freq_bins[0..]);

            // === MAGNITUDE PRECOMPUTATION ===
            // Compute magnitudes (SIMD-optimized)
            var bin_idx: usize = 0;

            while (bin_idx + vec_len <= NUM_BINS) : (bin_idx += vec_len) {
                var real_vec: F32xV = undefined;
                var imag_vec: F32xV = undefined;

                for (0..vec_len) |v| {
                    const bin = &ch.freq_bins[bin_idx + v];
                    real_vec[v] = bin.r;
                    imag_vec[v] = bin.i;
                }

                const real_sq = real_vec * real_vec;
                const imag_sq = imag_vec * imag_vec;
                const mag_sq = real_sq + imag_sq;
                const magnitude = @sqrt(mag_sq);

                for (0..vec_len) |v| {
                    self.magnitudes[bin_idx + v] = magnitude[v];
                }
            }

            // Scalar tail
            while (bin_idx < NUM_BINS) : (bin_idx += 1) {
                const bin = &ch.freq_bins[bin_idx];
                self.magnitudes[bin_idx] = @sqrt(bin.r * bin.r + bin.i * bin.i);
            }

            // === PROCESSING ===
            // Call effect's processBins callback
            if (has_user_state) {
                Effect.processBins(
                    ch.freq_bins[0..],
                    self.magnitudes[0..],
                    self.user_state[ch_idx][0..],
                    self.context,
                    params,
                );
            } else {
                // No user state, pass empty slice
                const empty: []UserState = &[_]UserState{};
                Effect.processBins(
                    ch.freq_bins[0..],
                    self.magnitudes[0..],
                    empty,
                    self.context,
                    params,
                );
            }

            // === SYNTHESIS ===
            // Inverse FFT: frequency domain -> time domain
            self.fft_plan.inverse(ch.freq_bins[0..], ch.fft_scratch[0..]);

            // KissFFT does not normalize - divide by FFT_SIZE
            const norm_scale = 1.0 / @as(f32, FFT_SIZE);

            // Apply synthesis window and overlap-add (SIMD-optimized)
            // With Hann window and 75% overlap, reconstruction gain is 2/3 after normalization
            const ola_scale = norm_scale * (2.0 / 3.0);

            i = 0;

            // SIMD path: process vec_len samples at a time
            const ola_scale_vec: F32xV = @splat(ola_scale);
            while (i + vec_len <= FFT_SIZE) : (i += vec_len) {
                var scratch_vec: F32xV = undefined;
                var window_vec: F32xV = undefined;
                var ola_vec: F32xV = undefined;

                for (0..vec_len) |j| {
                    const ola_idx = (ch.read_pos + i + j) % FFT_SIZE;
                    scratch_vec[j] = ch.fft_scratch[i + j];
                    window_vec[j] = self.window[i + j];
                    ola_vec[j] = ch.output_ola[ola_idx];
                }

                const windowed = scratch_vec * window_vec * ola_scale_vec;
                const new_ola = ola_vec + windowed;

                for (0..vec_len) |j| {
                    const ola_idx = (ch.read_pos + i + j) % FFT_SIZE;
                    ch.output_ola[ola_idx] = new_ola[j];
                }
            }

            // Scalar tail: process remaining samples
            while (i < FFT_SIZE) : (i += 1) {
                const ola_idx = (ch.read_pos + i) % FFT_SIZE;
                ch.output_ola[ola_idx] += ch.fft_scratch[i] * self.window[i] * ola_scale;
            }
        }
    };
}
