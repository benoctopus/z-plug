/// Super Gain - A showcase example demonstrating z-plug's feature set.
///
/// This plugin is intentionally over-engineered to demonstrate framework capabilities.
/// For a minimal "hello world" example, see examples/gain.zig instead.
///
/// Features demonstrated:
/// - All 4 parameter types (FloatParam, BoolParam, ChoiceParam)
/// - dB-scale gain with logarithmic smoothing
/// - Mid-side stereo width processing
/// - Denormal flushing for real-time safety
/// - Block-based buffer iteration
/// - Platform-adaptive SIMD with @Vector and std.simd
/// - Multiple parameter access patterns
/// - Channel routing
const z_plug = @import("z_plug");

// [Showcase] Use the platform's optimal SIMD vector width from the framework.
// z_plug.platform.SIMD_VEC_LEN queries the target CPU features at comptime:
//   aarch64 NEON → 128-bit → 4 × f32
//   x86_64 AVX2 → 256-bit → 8 × f32
//   x86_64 AVX-512 → 512-bit → 16 × f32
// Falls back to 4 if the target has no known SIMD support.
const vec_len = z_plug.platform.SIMD_VEC_LEN;
const F32xN = z_plug.platform.F32xV;

/// [Showcase] Explicit SIMD to demonstrate Zig's vector types. The compiler
/// would likely auto-vectorize this, but explicit SIMD is useful for more
/// complex DSP where auto-vectorization isn't reliable.
inline fn applyGain(samples: []f32, gains: []const f32) void {
    const len = @min(samples.len, gains.len);
    var i: usize = 0;

    // SIMD path: process vec_len samples at a time
    while (i + vec_len <= len) : (i += vec_len) {
        const s: F32xN = samples[i..][0..vec_len].*;
        const g: F32xN = gains[i..][0..vec_len].*;
        samples[i..][0..vec_len].* = s * g;
    }

    // Scalar tail for remaining samples
    while (i < len) : (i += 1) {
        samples[i] *= gains[i];
    }
}

/// [Practical] Mid-side stereo width. width=0 mono, 1 normal, 2 exaggerated.
/// This is a genuinely useful feature and a good showcase for SIMD arithmetic.
inline fn applyStereoWidth(left: []f32, right: []f32, widths: []const f32) void {
    const len = @min(left.len, @min(right.len, widths.len));
    var i: usize = 0;
    const half: F32xN = @splat(0.5);

    // SIMD path: process vec_len samples at a time
    while (i + vec_len <= len) : (i += vec_len) {
        const l: F32xN = left[i..][0..vec_len].*;
        const r: F32xN = right[i..][0..vec_len].*;
        const w: F32xN = widths[i..][0..vec_len].*;

        // Mid-side encode
        const mid = (l + r) * half;
        const side = (l - r) * half;

        // Apply width and decode
        left[i..][0..vec_len].* = mid + w * side;
        right[i..][0..vec_len].* = mid - w * side;
    }

    // Scalar tail for remaining samples
    while (i < len) : (i += 1) {
        const mid = (left[i] + right[i]) * 0.5;
        const side = (left[i] - right[i]) * 0.5;
        left[i] = mid + widths[i] * side;
        right[i] = mid - widths[i] * side;
    }
}

const SuperGainPlugin = struct {
    // Required metadata
    pub const name: [:0]const u8 = "Zig Super Gain";
    pub const vendor: [:0]const u8 = "z-plug";
    pub const url: [:0]const u8 = "https://github.com/example/z-plug";
    pub const version: [:0]const u8 = "0.1.0";
    pub const plugin_id: [:0]const u8 = "com.z-plug.super-gain";

    // Audio configuration: stereo in/out
    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO,
    };

    // Parameters: 5 total, demonstrating all parameter types
    pub const params = &[_]z_plug.Param{
        // [Practical] dB-scale gain is the standard for audio plugins
        .{
            .float = .{
                .name = "Gain",
                .id = "gain_db",
                .default = 0.0,
                .range = .{ .linear = .{ .min = -60.0, .max = 24.0 } },
                .unit = "dB",
                .smoothing = .{ .logarithmic = 50.0 }, // Smooth in log space for glitch-free sweeps
            },
        },

        // [Practical] Stereo width like Ableton Utility: 0%=mono, 100%=normal, 200%=wide
        .{ .float = .{
            .name = "Width",
            .id = "width",
            .default = 100.0,
            .range = .{ .linear = .{ .min = 0.0, .max = 200.0 } },
            .unit = "%",
            .smoothing = .{ .linear = 20.0 },
        } },

        // [Practical] Secondary gain stage for final level adjustment
        .{ .float = .{
            .name = "Output Trim",
            .id = "trim",
            .default = 1.0,
            .range = .{ .linear = .{ .min = 0.0, .max = 2.0 } },
            .unit = "",
            .smoothing = .{ .linear = 10.0 },
        } },

        // [Practical] Bypass is a standard feature in all plugins
        .{ .boolean = .{
            .name = "Bypass",
            .id = "bypass",
            .default = false,
        } },

        // [Practical] Channel routing adds genuine utility beyond just gain
        .{ .choice = .{
            .name = "Channel Mode",
            .id = "ch_mode",
            .default = 0,
            .labels = &.{ "Stereo", "Left Only", "Right Only", "Swap L/R" },
        } },
    };

    // No internal state needed
    pub fn init(
        _: *@This(),
        _: *const z_plug.AudioIOLayout,
        _: *const z_plug.BufferConfig,
    ) bool {
        return true;
    }

    pub fn deinit(_: *@This()) void {
        // No cleanup needed
    }

    pub fn process(
        _: *@This(),
        buffer: *z_plug.Buffer,
        _: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        // [Practical] Always flush denormals in real plugins with IIR filters or feedback.
        // For a pure gain plugin this is technically unnecessary, but it's good practice.
        const ftz = z_plug.dsp.util.enableFlushToZero();
        defer z_plug.dsp.util.restoreFloatMode(ftz);

        // Read non-smoothed parameters (once per process call)
        const bypass = context.getBool(5, 3);
        const ch_mode = context.getChoice(5, 4);

        // Early exit if bypassed
        if (bypass) return z_plug.ProcessStatus.ok();

        // [Showcase] Block-based processing. For a gain plugin, per-sample iteration
        // works fine too. We use blocks here to demonstrate the buffer.iterBlocks() API,
        // which is practical for FFT, convolution, or other algorithms that work on chunks.
        var blocks = buffer.iterBlocks(64);

        while (blocks.next()) |entry| {
            const block_len = entry.block.samples();

            // Get smoothed parameters for this block
            // These are pre-computed ramps for efficient per-sample application
            var gain_db_buf: [64]f32 = undefined;
            var width_buf: [64]f32 = undefined;
            var trim_buf: [64]f32 = undefined;

            const gain_db_slice = gain_db_buf[0..block_len];
            const width_slice = width_buf[0..block_len];
            const trim_slice = trim_buf[0..block_len];

            // Fill parameter buffers with smoothed values
            for (gain_db_slice, 0..) |*val, i| {
                _ = i;
                val.* = context.nextSmoothed(5, 0);
            }
            for (width_slice, 0..) |*val, i| {
                _ = i;
                val.* = context.nextSmoothed(5, 1) * 0.01; // Convert % to 0-2 range
            }
            for (trim_slice, 0..) |*val, i| {
                _ = i;
                val.* = context.nextSmoothed(5, 2);
            }

            // [Practical] Convert dB to gain. This is the idiomatic pattern for
            // dB-scale parameters - store in dB (what users understand), convert
            // to linear gain in the inner loop.
            for (gain_db_slice) |*db| {
                db.* = z_plug.dsp.util.dbToGainFast(db.*);
            }

            // Get channel slices for this block
            const left = entry.block.getChannel(0);
            const right = if (entry.block.channel_data.len > 1) entry.block.getChannel(1) else null;

            // Apply processing based on channel mode
            switch (ch_mode) {
                0 => { // Stereo
                    if (right) |r| {
                        // [Practical] Apply stereo width first (preserves balance)
                        applyStereoWidth(left, r, width_slice);

                        // [Showcase] SIMD gain application (compiler would auto-vectorize anyway)
                        applyGain(left, gain_db_slice);
                        applyGain(r, gain_db_slice);
                        applyGain(left, trim_slice);
                        applyGain(r, trim_slice);
                    } else {
                        // Mono input - just apply gain
                        applyGain(left, gain_db_slice);
                        applyGain(left, trim_slice);
                    }
                },
                1 => { // Left Only
                    applyGain(left, gain_db_slice);
                    applyGain(left, trim_slice);
                    if (right) |r| {
                        // Copy left to right
                        @memcpy(r, left);
                    }
                },
                2 => { // Right Only
                    if (right) |r| {
                        applyGain(r, gain_db_slice);
                        applyGain(r, trim_slice);
                        // Copy right to left
                        @memcpy(left, r);
                    } else {
                        // No right channel, just process left
                        applyGain(left, gain_db_slice);
                        applyGain(left, trim_slice);
                    }
                },
                3 => { // Swap L/R
                    if (right) |r| {
                        // Process both channels
                        applyStereoWidth(left, r, width_slice);
                        applyGain(left, gain_db_slice);
                        applyGain(r, gain_db_slice);
                        applyGain(left, trim_slice);
                        applyGain(r, trim_slice);

                        // Swap channels by swapping memory
                        for (left, r) |*l, *rr| {
                            const temp = l.*;
                            l.* = rr.*;
                            rr.* = temp;
                        }
                    } else {
                        // Can't swap if there's only one channel
                        applyGain(left, gain_db_slice);
                        applyGain(left, trim_slice);
                    }
                },
                else => unreachable,
            }
        }

        return z_plug.ProcessStatus.ok();
    }
};

// Export CLAP entry point
comptime {
    _ = z_plug.ClapEntry(SuperGainPlugin);
}

// Export VST3 factory
comptime {
    _ = z_plug.Vst3Factory(SuperGainPlugin);
}
