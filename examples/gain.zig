/// Simple gain plugin example for z-plug.
///
/// Demonstrates the minimal viable plugin: one dB-scale gain parameter,
/// stereo processing, and both CLAP and VST3 support.
///
/// For a more complete example with stereo width, SIMD, channel routing,
/// and denormal flushing, see examples/super_gain.zig.
const z_plug = @import("z_plug");

const GainPlugin = struct {
    pub const name: [:0]const u8 = "Zig Gain";
    pub const vendor: [:0]const u8 = "zig-plug";
    pub const url: [:0]const u8 = "https://github.com/example/zig-plug";
    pub const version: [:0]const u8 = "0.1.0";
    pub const plugin_id: [:0]const u8 = "com.zig-plug.gain";

    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO,
    };

    pub const params = &[_]z_plug.Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 0.0,
            .range = .{ .linear = .{ .min = -60.0, .max = 24.0 } },
            .unit = "dB",
            .smoothing = .{ .logarithmic = 50.0 },
        } },
    };

    pub fn init(_: *@This(), _: *const z_plug.AudioIOLayout, _: *const z_plug.BufferConfig) bool {
        return true;
    }

    pub fn deinit(_: *@This()) void {}

    pub fn process(
        _: *@This(),
        buffer: *z_plug.Buffer,
        _: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        const num_samples = buffer.num_samples;
        const num_channels = buffer.channel_data.len;

        var i: usize = 0;
        while (i < num_samples) : (i += 1) {
            const gain = z_plug.dsp.util.dbToGainFast(context.nextSmoothed(1, 0));

            for (buffer.channel_data[0..num_channels]) |channel| {
                channel[i] *= gain;
            }
        }

        return z_plug.ProcessStatus.ok();
    }
};

// Export CLAP entry point
comptime {
    _ = z_plug.ClapEntry(GainPlugin);
}

// Export VST3 factory
comptime {
    _ = z_plug.Vst3Factory(GainPlugin);
}
