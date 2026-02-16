/// Simple gain plugin example for zig-plug.
///
/// This plugin demonstrates the minimal viable plugin:
/// - One FloatParam for gain control (0.0 to 2.0)
/// - Stereo processing
/// - Both CLAP and VST3 support
const z_plug = @import("z_plug");

const GainPlugin = struct {
    // Required metadata
    pub const name: [:0]const u8 = "Zig Gain";
    pub const vendor: [:0]const u8 = "zig-plug";
    pub const url: [:0]const u8 = "https://github.com/example/zig-plug";
    pub const version: [:0]const u8 = "0.1.0";
    pub const plugin_id: [:0]const u8 = "com.zig-plug.gain";
    
    // Audio configuration: stereo in/out
    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO,
    };
    
    // Parameters: one gain parameter
    pub const params = &[_]z_plug.Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 1.0,
            .range = .{ .min = 0.0, .max = 2.0 },
            .unit = "",
            .flags = .{},
            .smoothing = .{ .linear = 10.0 },
        } },
    };
    
    // No internal state needed for this simple plugin
    
    /// Initialize the plugin with the selected audio layout and buffer config.
    pub fn init(
        _: *@This(),
        _: *const z_plug.AudioIOLayout,
        _: *const z_plug.BufferConfig,
    ) bool {
        return true;
    }
    
    /// Clean up plugin resources.
    pub fn deinit(_: *@This()) void {
        // No cleanup needed
    }
    
    /// Process audio.
    pub fn process(
        _: *@This(),
        buffer: *z_plug.Buffer,
        _: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        const num_samples = buffer.num_samples;
        const num_channels = buffer.channel_data.len;
        
        // Process sample-by-sample to advance smoothing correctly
        var i: usize = 0;
        while (i < num_samples) : (i += 1) {
            // Get the next smoothed gain value (advances smoother by 1 sample)
            const gain = context.nextSmoothed(1, 0);
            
            // Apply gain to all channels for this sample
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
