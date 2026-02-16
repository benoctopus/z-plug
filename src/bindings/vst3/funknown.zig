// VST3 C API Bindings - FUnknown (IUnknown) Base Interface
// Based on SuperElectric blog pattern with comptime metaprogramming

const std = @import("std");
const types = @import("types.zig");
const guid = @import("guid.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;

/// FUnknown vtable - base for all VST3 COM interfaces
pub const FUnknownVtbl = extern struct {
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
};

/// FUnknown interface struct
pub const FUnknown = extern struct {
    lpVtbl: *const FUnknownVtbl,
};

/// Interface descriptor for queryInterface
pub const Interface = struct {
    cid: TUID,
    ptr_offset: usize,
};

/// Comptime helper to generate FUnknown implementation for a COM object
/// Based on SuperElectric's pattern adapted for Zig 0.15.2
///
/// Usage:
/// ```
/// const MyObject = struct {
///     i_component: vst3.IComponent,
///     i_audio_processor: vst3.IAudioProcessor,
///     
///     const funknown_component = vst3.funknown.FUnknown(
///         @offsetOf(MyObject, "i_component"),
///         &[_]Interface{
///             .{ .cid = vst3.IID_IComponent, .ptr_offset = @offsetOf(MyObject, "i_component") },
///             .{ .cid = vst3.IID_IAudioProcessor, .ptr_offset = @offsetOf(MyObject, "i_audio_processor") },
///         }
///     );
/// };
/// ```
pub fn FUnknownImpl(comptime self_offset: usize, comptime interfaces: []const Interface) type {
    return struct {
        pub const vtbl = FUnknownVtbl{
            .queryInterface = queryInterface,
            .addRef = addRef,
            .release = release,
        };

        fn queryInterface(self: *anyopaque, iid: *const TUID, obj: *?*anyopaque) callconv(.c) tresult {
            // Check if the requested interface is one we implement
            for (interfaces) |interface| {
                if (guid.eql(iid.*, interface.cid)) {
                    // Calculate the pointer to the requested interface
                    const self_addr = @intFromPtr(self);
                    const object_base = self_addr - self_offset;
                    const interface_ptr = object_base + interface.ptr_offset;
                    
                    const interface_vtbl: *anyopaque = @ptrFromInt(interface_ptr);
                    _ = addRef(interface_vtbl);
                    obj.* = interface_vtbl;
                    return types.kResultOk;
                }
            }
            
            obj.* = null;
            return types.kNoInterface;
        }

        fn addRef(self: *anyopaque) callconv(.c) u32 {
            // TODO: Implement proper reference counting
            // For now, return a constant to indicate the object is always alive
            _ = self;
            return 1;
        }

        fn release(self: *anyopaque) callconv(.c) u32 {
            // TODO: Implement proper reference counting and deallocation
            // For now, return a constant to indicate the object is still alive
            _ = self;
            return 1;
        }
    };
}

test "FUnknownVtbl layout" {
    const testing = std.testing;
    // Verify the vtable has the expected size (3 function pointers)
    const expected_size = @sizeOf(*const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult) +
        @sizeOf(*const fn (*anyopaque) callconv(.c) u32) +
        @sizeOf(*const fn (*anyopaque) callconv(.c) u32);
    try testing.expectEqual(expected_size, @sizeOf(FUnknownVtbl));
}

test "FUnknownImpl compiles" {
    // Basic compilation test
    const TestImpl = FUnknownImpl(0, &[_]Interface{
        .{ .cid = guid.IID_FUnknown, .ptr_offset = 0 },
    });
    _ = TestImpl;
}
