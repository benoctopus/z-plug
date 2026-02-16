/// VST3 plugin factory implementation.
///
/// This module provides the GetPluginFactory export and factory COM object
/// that hosts use to enumerate and instantiate plugins.
const std = @import("std");
const vst3 = @import("../../bindings/vst3/root.zig");
const core = @import("../../root.zig");
const component = @import("component.zig");

/// Generate a VST3 plugin factory for plugin type `T`.
pub fn Vst3Factory(comptime T: type) type {
    const P = core.Plugin(T);
    
    return struct {
        /// The GetPluginFactory export that hosts call to get the factory.
        pub export fn GetPluginFactory() callconv(.c) *anyopaque {
            return @ptrCast(&factory_instance);
        }
        
        /// Singleton factory instance.
        var factory_instance = FactoryObject{
            .vtbl = &factory_vtbl,
        };
        
        /// Factory object with vtable pointer.
        const FactoryObject = extern struct {
            vtbl: *const vst3.factory.IPluginFactory2Vtbl,
        };
        
        /// Factory vtable with all methods.
        const factory_vtbl = vst3.factory.IPluginFactory2Vtbl{
            .queryInterface = factoryQueryInterface,
            .addRef = factoryAddRef,
            .release = factoryRelease,
            .getFactoryInfo = getFactoryInfo,
            .countClasses = countClasses,
            .getClassInfo = getClassInfo,
            .createInstance = createInstance,
            .getClassInfo2 = getClassInfo2,
        };
        
        // -------------------------------------------------------------------
        // FUnknown methods
        // -------------------------------------------------------------------
        
        fn factoryQueryInterface(self: *anyopaque, iid: *const vst3.TUID, obj: *?*anyopaque) callconv(.c) vst3.tresult {
            _ = self;
            
            if (vst3.guid.eql(iid.*, vst3.factory.IID_IPluginFactory) or
                vst3.guid.eql(iid.*, vst3.factory.IID_IPluginFactory2) or
                vst3.guid.eql(iid.*, vst3.guid.IID_FUnknown))
            {
                obj.* = @ptrCast(&factory_instance);
                return vst3.types.kResultOk;
            }
            
            obj.* = null;
            return vst3.types.kNoInterface;
        }
        
        fn factoryAddRef(_: *anyopaque) callconv(.c) u32 {
            return 1; // Factory is a singleton, never freed
        }
        
        fn factoryRelease(_: *anyopaque) callconv(.c) u32 {
            return 1; // Factory is a singleton, never freed
        }
        
        // -------------------------------------------------------------------
        // IPluginFactory methods
        // -------------------------------------------------------------------
        
        fn getFactoryInfo(_: *anyopaque, info: *vst3.factory.PFactoryInfo) callconv(.c) vst3.tresult {
            // Fill factory info from plugin metadata
            @memset(&info.vendor, 0);
            @memset(&info.url, 0);
            @memset(&info.email, 0);
            
            const vendor_len = @min(P.vendor.len, vst3.factory.kNameSize - 1);
            @memcpy(info.vendor[0..vendor_len], P.vendor[0..vendor_len]);
            
            const url_len = @min(P.url.len, vst3.factory.kURLSize - 1);
            @memcpy(info.url[0..url_len], P.url[0..url_len]);
            
            info.flags = 0;
            
            return vst3.types.kResultOk;
        }
        
        fn countClasses(_: *anyopaque) callconv(.c) i32 {
            return 1; // One processor class
        }
        
        fn getClassInfo(_: *anyopaque, index: i32, info: *vst3.factory.PClassInfo) callconv(.c) vst3.tresult {
            if (index != 0) return vst3.types.kResultFalse;
            
            // Generate TUID from plugin_id
            const tuid = pluginIdToTuid(P.plugin_id);
            @memcpy(&info.cid, &tuid);
            
            info.cardinality = @intFromEnum(vst3.factory.PClassInfo.ClassCardinality.kManyInstances);
            
            // Category
            @memset(&info.category, 0);
            const category = "Audio Module Class";
            @memcpy(info.category[0..category.len], category);
            
            // Name
            @memset(&info.name, 0);
            const name_len = @min(P.name.len, 64 - 1);
            @memcpy(info.name[0..name_len], P.name[0..name_len]);
            
            return vst3.types.kResultOk;
        }
        
        fn getClassInfo2(_: *anyopaque, index: i32, info: *vst3.factory.PClassInfo2) callconv(.c) vst3.tresult {
            if (index != 0) return vst3.types.kResultFalse;
            
            // Generate TUID from plugin_id
            const tuid = pluginIdToTuid(P.plugin_id);
            @memcpy(&info.cid, &tuid);
            
            info.cardinality = @intFromEnum(vst3.factory.PClassInfo.ClassCardinality.kManyInstances);
            
            // Category
            @memset(&info.category, 0);
            const category = "Audio Module Class";
            @memcpy(info.category[0..category.len], category);
            
            // Name
            @memset(&info.name, 0);
            const name_len = @min(P.name.len, 64 - 1);
            @memcpy(info.name[0..name_len], P.name[0..name_len]);
            
            info.class_flags = 0;
            
            // Subcategories (e.g., "Fx|EQ" for an EQ effect)
            @memset(&info.subcategories, 0);
            const subcategory = "Fx";
            @memcpy(info.subcategories[0..subcategory.len], subcategory);
            
            // Vendor
            @memset(&info.vendor, 0);
            const vendor_len = @min(P.vendor.len, 64 - 1);
            @memcpy(info.vendor[0..vendor_len], P.vendor[0..vendor_len]);
            
            // Version
            @memset(&info.version, 0);
            const version_len = @min(P.version.len, 64 - 1);
            @memcpy(info.version[0..version_len], P.version[0..version_len]);
            
            // SDK version
            @memset(&info.sdk_version, 0);
            const sdk_ver = "VST 3.7.9";
            @memcpy(info.sdk_version[0..sdk_ver.len], sdk_ver);
            
            return vst3.types.kResultOk;
        }
        
        fn createInstance(
            _: *anyopaque,
            cid: vst3.types.FIDString,
            iid: vst3.types.FIDString,
            obj: *?*anyopaque,
        ) callconv(.c) vst3.tresult {
            // Check if the requested class ID matches our plugin
            _ = cid; // For now, skip string comparison
            _ = iid; // Interface ID check handled by queryInterface
            
            // Create the component
            const comp = component.Vst3Component(T).create() catch {
                obj.* = null;
                return vst3.types.kResultFalse;
            };
            
            // Return the IComponent interface
            obj.* = @ptrCast(comp);
            return vst3.types.kResultOk;
        }
        
        /// Convert a plugin ID string to a VST3 TUID using a deterministic hash.
        fn pluginIdToTuid(comptime id: [:0]const u8) vst3.TUID {
            // Use SHA-256 and take first 16 bytes
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(id);
            var hash: [32]u8 = undefined;
            hasher.final(&hash);
            
            var tuid: vst3.TUID = undefined;
            @memcpy(&tuid, hash[0..16]);
            return tuid;
        }
    };
}

test "Vst3Factory compiles for test plugin" {
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
    
    const Factory = Vst3Factory(TestPlugin);
    
    // Test that GetPluginFactory returns something (not null check since it's a pointer)
    const factory_ptr = Factory.GetPluginFactory();
    try std.testing.expect(@intFromPtr(factory_ptr) != 0);
}
