/// Spectral Gate - Example demonstrating STFT-based spectral processing.
///
/// This plugin showcases frequency-domain audio processing using the framework's
/// STFT module. It implements a spectral gate with threshold-based bin attenuation
/// and per-bin attack/release smoothing.
///
/// Features demonstrated:
/// - Using the z_plug.dsp.stft.StftProcessor comptime generic
/// - Defining a spectral effect with processBins callback
/// - Per-bin user state (gate envelopes)
/// - Dry/wet mixing
/// - SIMD optimization (handled automatically by the STFT module)
const z_plug = @import("z_plug");
const std = @import("std");

// Spectral effect definition
const SpectralGate = struct {
    // Per-bin user state (gate envelope)
    pub const UserState = f32;
    pub const user_state_default: f32 = 1.0; // Start fully open

    // Parameters passed to processBins
    pub const Params = struct {
        threshold_linear: f32,
        attack_coeff: f32,
        release_coeff: f32,
    };

    /// Process frequency bins in-place.
    /// Called once per hop with pre-computed magnitudes and per-bin state.
    pub fn processBins(
        bins: []z_plug.dsp.stft.Complex,
        magnitudes: []const f32,
        gate_env: []f32,
        context: z_plug.dsp.stft.SpectralContext,
        params: Params,
    ) void {
        _ = context; // Not used in this effect

        const vec_len = z_plug.platform.SIMD_VEC_LEN;
        const F32xV = z_plug.platform.F32xV;

        // SIMD path: process vec_len bins at a time
        var bin_idx: usize = 0;
        while (bin_idx + vec_len <= bins.len) : (bin_idx += vec_len) {
            var real_vec: F32xV = undefined;
            var imag_vec: F32xV = undefined;
            var mag_vec: F32xV = undefined;
            var env_vec: F32xV = undefined;

            for (0..vec_len) |v| {
                const bin = &bins[bin_idx + v];
                real_vec[v] = bin.r;
                imag_vec[v] = bin.i;
                mag_vec[v] = magnitudes[bin_idx + v];
                env_vec[v] = gate_env[bin_idx + v];
            }

            // Determine target gate state (open or closed) using vector comparison
            const threshold_vec: F32xV = @splat(params.threshold_linear);
            const one_vec: F32xV = @splat(1.0);
            const zero_vec: F32xV = @splat(0.0);
            const target = @select(f32, mag_vec > threshold_vec, one_vec, zero_vec);

            // Smooth envelope with attack/release (vectorized)
            const attack_vec: F32xV = @splat(params.attack_coeff);
            const release_vec: F32xV = @splat(params.release_coeff);
            const coeff = @select(f32, target > env_vec, attack_vec, release_vec);
            const new_env = env_vec + (target - env_vec) * coeff;

            // Apply gain to complex bins
            const gain = new_env;
            const new_real = real_vec * gain;
            const new_imag = imag_vec * gain;

            // Store results back
            for (0..vec_len) |v| {
                bins[bin_idx + v].r = new_real[v];
                bins[bin_idx + v].i = new_imag[v];
                gate_env[bin_idx + v] = new_env[v];
            }
        }

        // Scalar tail: process remaining bins
        while (bin_idx < bins.len) : (bin_idx += 1) {
            const bin = &bins[bin_idx];
            const magnitude = magnitudes[bin_idx];

            // Determine target gate state (open or closed)
            const target: f32 = if (magnitude > params.threshold_linear) 1.0 else 0.0;

            // Smooth envelope with attack/release
            const coeff = if (target > gate_env[bin_idx]) params.attack_coeff else params.release_coeff;
            gate_env[bin_idx] += (target - gate_env[bin_idx]) * coeff;

            // Apply gain to complex bin
            const gain = gate_env[bin_idx];
            bin.r *= gain;
            bin.i *= gain;
        }
    }
};

// Instantiate STFT processor with default config (1024-sample FFT, 256-sample hop, stereo)
const stft = z_plug.dsp.stft.StftProcessor(SpectralGate, .{});

const SpectralPlugin = struct {
    // STFT engine (handles all the boilerplate)
    stft_engine: stft,

    // Cached sample rate
    sample_rate: f32,

    // Required plugin metadata
    pub const name: [:0]const u8 = "Zig Spectral Gate";
    pub const vendor: [:0]const u8 = "z-plug";
    pub const url: [:0]const u8 = "https://github.com/example/z-plug";
    pub const version: [:0]const u8 = "0.1.0";
    pub const plugin_id: [:0]const u8 = "com.z-plug.spectral-gate";

    // Audio I/O: stereo in/out
    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO,
    };

    // Parameters: threshold, attack, release, mix
    pub const params = &[_]z_plug.Param{
        // Threshold (dB) - bins below this magnitude are gated
        .{ .float = .{
            .name = "Threshold",
            .id = "threshold_db",
            .default = -30.0,
            .range = .{ .linear = .{ .min = -60.0, .max = 0.0 } },
            .unit = "dB",
            .smoothing = .{ .logarithmic = 50.0 },
        } },

        // Attack (ms) - how fast gates open
        .{ .float = .{
            .name = "Attack",
            .id = "attack_ms",
            .default = 5.0,
            .range = .{ .linear = .{ .min = 1.0, .max = 100.0 } },
            .unit = "ms",
            .smoothing = .{ .linear = 20.0 },
        } },

        // Release (ms) - how fast gates close
        .{ .float = .{
            .name = "Release",
            .id = "release_ms",
            .default = 100.0,
            .range = .{ .linear = .{ .min = 10.0, .max = 1000.0 } },
            .unit = "ms",
            .smoothing = .{ .linear = 20.0 },
        } },

        // Mix (%) - dry/wet blend
        .{ .float = .{
            .name = "Mix",
            .id = "mix_pct",
            .default = 100.0,
            .range = .{ .linear = .{ .min = 0.0, .max = 100.0 } },
            .unit = "%",
            .smoothing = .{ .linear = 10.0 },
        } },
    };

    pub fn init(
        self: *@This(),
        _: *const z_plug.AudioIOLayout,
        config: *const z_plug.BufferConfig,
    ) bool {
        self.sample_rate = config.sample_rate;

        // Initialize STFT engine
        self.stft_engine = stft.init(config.sample_rate) orelse return false;

        return true;
    }

    pub fn deinit(self: *@This()) void {
        self.stft_engine.deinit();
    }

    pub fn process(
        self: *@This(),
        buffer: *z_plug.Buffer,
        _: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        // Enable denormal flushing for performance
        const ftz = z_plug.dsp.util.enableFlushToZero();
        defer z_plug.dsp.util.restoreFloatMode(ftz);

        const num_samples = buffer.num_samples;
        const num_channels = @min(buffer.channel_data.len, 2);

        // Process each sample
        var sample_idx: usize = 0;
        while (sample_idx < num_samples) : (sample_idx += 1) {
            // Get smoothed parameters for this sample
            const threshold_db = context.nextSmoothed(4, 0);
            const attack_ms = context.nextSmoothed(4, 1);
            const release_ms = context.nextSmoothed(4, 2);
            const mix_pct = context.nextSmoothed(4, 3);

            // Convert to linear/per-sample values
            const threshold_linear = z_plug.dsp.util.dbToGainFast(threshold_db);
            const attack_coeff = calculateSmoothingCoeff(attack_ms, self.sample_rate, 256);
            const release_coeff = calculateSmoothingCoeff(release_ms, self.sample_rate, 256);
            const mix = mix_pct * 0.01; // Convert % to 0-1

            // Build params struct for STFT processor
            const effect_params = SpectralGate.Params{
                .threshold_linear = threshold_linear,
                .attack_coeff = attack_coeff,
                .release_coeff = release_coeff,
            };

            // Process each channel
            var ch_idx: usize = 0;
            while (ch_idx < num_channels) : (ch_idx += 1) {
                const input_sample = buffer.channel_data[ch_idx][sample_idx];

                // Process through STFT engine
                const output_sample = self.stft_engine.processSample(ch_idx, input_sample, effect_params);

                // Apply dry/wet mix
                buffer.channel_data[ch_idx][sample_idx] = input_sample * (1.0 - mix) + output_sample * mix;
            }
        }

        return z_plug.ProcessStatus.ok();
    }
};

/// Calculate per-sample smoothing coefficient from time constant in milliseconds
/// For envelope smoothing at hop rate, not per-sample rate
inline fn calculateSmoothingCoeff(time_ms: f32, sample_rate: f32, hop_size: usize) f32 {
    if (time_ms <= 0.0) return 1.0;
    const samples_per_hop = z_plug.dsp.util.msToSamples(time_ms, sample_rate) / @as(f32, @floatFromInt(hop_size));
    if (samples_per_hop <= 1.0) return 1.0;
    return 1.0 / samples_per_hop;
}

// Export CLAP entry point
comptime {
    _ = z_plug.ClapEntry(SpectralPlugin);
}

// Export VST3 factory
comptime {
    _ = z_plug.Vst3Factory(SpectralPlugin);
}
