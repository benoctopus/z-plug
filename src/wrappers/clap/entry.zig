/// CLAP entry point and factory access.
///
/// This module provides the `ClapEntry` comptime function that generates the
/// `clap_entry` export symbol that CLAP hosts look for when loading a plugin.
const std = @import("std");
const clap = @import("../../bindings/clap/main.zig");
const core = @import("../../root.zig");
const factory = @import("factory.zig");

/// Generate a CLAP entry point for plugin type `T`.
///
/// Usage in a plugin's main file:
/// ```zig
/// const z_plug = @import("z_plug");
/// const MyPlugin = struct { ... };
/// pub const clap_entry = z_plug.ClapEntry(MyPlugin).clap_entry;
/// ```
pub fn ClapEntry(comptime T: type) type {
    // Validate the plugin at compile time
    const P = core.Plugin(T);
    _ = P; // Used by factory
    
    return struct {
        /// The CLAP entry point structure that hosts will query.
        pub const clap_entry = clap.Entry{
            .version = clap.Version{ .major = 1, .minor = 2, .revision = 2 },
            .init = entryInit,
            .deinit = entryDeinit,
            .getFactory = getFactory,
        };
        
        /// Initialize the plugin entry point.
        /// Called when the host loads the plugin library.
        fn entryInit(_: [*:0]const u8) callconv(.c) bool {
            // No global initialization needed for now
            return true;
        }
        
        /// Deinitialize the plugin entry point.
        /// Called when the host unloads the plugin library.
        fn entryDeinit() callconv(.c) void {
            // No global cleanup needed for now
        }
        
        /// Get a factory by ID.
        /// Returns the plugin factory if the ID matches "clap.plugin-factory".
        fn getFactory(factory_id: [*:0]const u8) callconv(.c) ?*const anyopaque {
            const factory_id_slice = std.mem.span(factory_id);
            
            // Check if the requested factory is the plugin factory
            if (std.mem.eql(u8, factory_id_slice, "clap.plugin-factory")) {
                return @ptrCast(&factory.ClapFactory(T).plugin_factory);
            }
            
            return null;
        }
    };
}

test "ClapEntry compiles for test plugin" {
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
    
    const Entry = ClapEntry(TestPlugin);
    try std.testing.expectEqual(clap.Version{ .major = 1, .minor = 2, .revision = 2 }, Entry.clap_entry.version);
}
