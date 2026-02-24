/// CLAP plugin factory implementation.
///
/// This module provides the factory that the host uses to enumerate and
/// instantiate plugins.
const std = @import("std");
const clap = @import("../../bindings/clap/main.zig");
const core = @import("../../root.zig");
const plugin = @import("plugin.zig");

/// Generate a CLAP plugin factory for plugin type `T`.
pub fn ClapFactory(comptime T: type) type {
    const P = core.Plugin(T);

    return struct {
        /// The plugin factory structure that the entry point returns.
        pub const plugin_factory = clap.PluginFactory{
            .getPluginCount = getPluginCount,
            .getPluginDescriptor = getPluginDescriptor,
            .createPlugin = createPlugin,
        };

        /// Descriptor for this plugin (generated at comptime).
        const descriptor: clap.Plugin.Descriptor = blk: {
            // Build features array based on audio I/O layouts
            const features = generateFeatures();

            break :blk clap.Plugin.Descriptor{
                .clap_version = clap.Version{ .major = 1, .minor = 2, .revision = 2 },
                .id = P.plugin_id.ptr,
                .name = P.name.ptr,
                .vendor = if (P.vendor.len > 0) P.vendor.ptr else null,
                .url = if (P.url.len > 0) P.url.ptr else null,
                .manual_url = null,
                .support_url = null,
                .version = if (P.version.len > 0) P.version.ptr else null,
                .description = null,
                .features = &features,
            };
        };

        /// Maximum number of features we might add (audio_effect/instrument + stereo + mono).
        const features_count = 3;

        /// Generate the features array based on plugin configuration.
        fn generateFeatures() [features_count:null]?[*:0]const u8 {
            // Determine if this is an instrument or effect based on I/O layouts
            const is_instrument = blk: {
                for (P.audio_io_layouts) |layout| {
                    if (layout.main_input_channels == null and layout.main_output_channels != null) {
                        break :blk true;
                    }
                }
                break :blk false;
            };

            // Determine channel configuration
            const is_stereo = blk: {
                for (P.audio_io_layouts) |layout| {
                    if (layout.main_output_channels) |channels| {
                        if (channels == 2) break :blk true;
                    }
                }
                break :blk false;
            };

            const is_mono = blk: {
                for (P.audio_io_layouts) |layout| {
                    if (layout.main_output_channels) |channels| {
                        if (channels == 1) break :blk true;
                    }
                }
                break :blk false;
            };

            // Build features list
            var features: [features_count:null]?[*:0]const u8 = undefined;
            for (0..features_count + 1) |i| {
                features[i] = null;
            }
            var idx: usize = 0;

            if (is_instrument) {
                features[idx] = clap.Plugin.features.instrument;
                idx += 1;
            } else {
                features[idx] = clap.Plugin.features.audio_effect;
                idx += 1;
            }

            if (is_stereo) {
                features[idx] = clap.Plugin.features.stereo;
                idx += 1;
            }

            if (is_mono) {
                features[idx] = clap.Plugin.features.mono;
                idx += 1;
            }

            return features;
        }

        fn getPluginCount(_: *const clap.PluginFactory) callconv(.c) u32 {
            return 1;
        }

        /// Get the descriptor for a plugin by index.
        fn getPluginDescriptor(_: *const clap.PluginFactory, index: u32) callconv(.c) ?*const clap.Plugin.Descriptor {
            if (index != 0) return null;
            return &descriptor;
        }

        /// Create a plugin instance.
        fn createPlugin(
            _: *const clap.PluginFactory,
            host: *const clap.Host,
            plugin_id: [*:0]const u8,
        ) callconv(.c) ?*const clap.Plugin {
            // Verify the plugin ID matches
            const id_slice = std.mem.span(plugin_id);
            if (!std.mem.eql(u8, id_slice, P.plugin_id)) {
                return null;
            }

            // Allocate the plugin wrapper
            const wrapper = std.heap.page_allocator.create(plugin.PluginWrapper(T)) catch {
                return null;
            };

            // Initialize the wrapper in place (stable pointer)
            wrapper.initInPlace(host);

            // Set the descriptor pointer now that the wrapper is at its final address
            wrapper.clap_plugin.descriptor = &descriptor;

            // Return pointer to the clap_plugin field (must be first field)
            return &wrapper.clap_plugin;
        }
    };
}

test "ClapFactory compiles for test plugin" {
    const TestPlugin = struct {
        pub const name: [:0]const u8 = "Test Plugin";
        pub const vendor: [:0]const u8 = "Test Vendor";
        pub const url: [:0]const u8 = "https://example.com";
        pub const version: [:0]const u8 = "1.0.0";
        pub const plugin_id: [:0]const u8 = "com.example.test";
        pub const audio_io_layouts = &[_]core.AudioIOLayout{core.AudioIOLayout.STEREO};
        pub const params = &[_]core.Param{};

        pub fn init(_: *@This(), _: *const core.AudioIOLayout, _: *const core.BufferConfig) bool {
            return true;
        }

        pub fn deinit(_: *@This()) void {}

        pub fn process(_: *@This(), _: *core.Buffer, _: *core.AuxBuffers, _: *core.ProcessContext) core.ProcessStatus {
            return core.ProcessStatus.ok();
        }
    };

    const Factory = ClapFactory(TestPlugin);

    // Test descriptor generation
    try std.testing.expectEqualStrings("Test Plugin", std.mem.span(Factory.descriptor.name));
    try std.testing.expectEqualStrings("com.example.test", std.mem.span(Factory.descriptor.id));

    // Test factory functions
    try std.testing.expectEqual(@as(u32, 1), Factory.plugin_factory.getPluginCount(&Factory.plugin_factory));

    const desc = Factory.plugin_factory.getPluginDescriptor(&Factory.plugin_factory, 0);
    try std.testing.expect(desc != null);
}
