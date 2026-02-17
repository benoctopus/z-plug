/// VST3 COM helpers with reference counting.
///
/// This module extends the basic FUnknown implementation from the bindings
/// with real reference counting and multi-interface support.
const std = @import("std");
const vst3 = @import("../../bindings/vst3/root.zig");

/// Wrapper COM object that implements multiple VST3 interfaces with proper
/// reference counting and queryInterface dispatch.
///
/// Usage:
/// ```zig
/// const MyComponent = ComObject(MyComponentState, &.{
///     .{ .iid = vst3.IID_IComponent, .vtbl_field = "component_vtbl" },
///     .{ .iid = vst3.IID_IAudioProcessor, .vtbl_field = "processor_vtbl" },
/// });
/// ```
pub fn ComObject(comptime StateType: type, comptime interfaces: []const InterfaceDesc) type {
    return struct {
        const Self = @This();

        /// Reference count for COM lifetime management.
        ref_count: std.atomic.Value(u32),

        /// The actual state/data for this COM object.
        state: StateType,

        pub const InterfaceDesc = struct {
            iid: vst3.TUID,
            vtbl_field: []const u8,
        };

        /// Initialize the COM object with ref_count = 1.
        pub fn init(state: StateType) Self {
            return Self{
                .ref_count = std.atomic.Value(u32).init(1),
                .state = state,
            };
        }

        /// Generate queryInterface implementation for this object.
        pub fn queryInterface(self: *anyopaque, iid: *const vst3.TUID, obj: *?*anyopaque) callconv(.c) vst3.tresult {
            const self_ptr: *Self = @ptrCast(@alignCast(self));

            // Check against each supported interface
            inline for (interfaces) |interface| {
                if (vst3.guid.eql(iid.*, interface.iid)) {
                    // Get the vtbl field from state
                    const vtbl_ptr = @field(&self_ptr.state, interface.vtbl_field);
                    _ = addRef(@ptrCast(vtbl_ptr));
                    obj.* = @ptrCast(vtbl_ptr);
                    return vst3.types.kResultOk;
                }
            }

            // Check for FUnknown base
            if (vst3.guid.eql(iid.*, vst3.guid.IID_FUnknown)) {
                // Return first interface as FUnknown
                const first_vtbl = @field(&self_ptr.state, interfaces[0].vtbl_field);
                _ = addRef(@ptrCast(first_vtbl));
                obj.* = @ptrCast(first_vtbl);
                return vst3.types.kResultOk;
            }

            obj.* = null;
            return vst3.types.kNoInterface;
        }

        /// Increment reference count.
        pub fn addRef(self: *anyopaque) callconv(.c) u32 {
            const self_ptr: *Self = @ptrCast(@alignCast(self));
            const prev = self_ptr.ref_count.fetchAdd(1, .monotonic);
            return prev + 1;
        }

        /// Decrement reference count and free if it reaches zero.
        pub fn release(self: *anyopaque) callconv(.c) u32 {
            const self_ptr: *Self = @ptrCast(@alignCast(self));
            const prev = self_ptr.ref_count.fetchSub(1, .release);
            const new_count = prev - 1;

            if (new_count == 0) {
                // Synchronize with all previous releases
                _ = self_ptr.ref_count.load(.acquire);
                // Free the object
                std.heap.page_allocator.destroy(self_ptr);
            }

            return new_count;
        }
    };
}

/// Helper to get the COM object from an interface vtbl pointer.
/// The vtbl pointer must be embedded in the state struct of a ComObject.
pub fn fromInterface(comptime ComType: type, interface_ptr: *anyopaque) *ComType {
    // This assumes the interface pointer is within the state field
    // We need to calculate the offset to get back to the ComObject
    // For now, we'll use a simple cast approach
    return @ptrCast(@alignCast(interface_ptr));
}

test "ComObject basic reference counting" {
    const TestState = struct {
        value: i32,
    };

    const TestCom = ComObject(TestState, &.{});

    var obj = TestCom.init(TestState{ .value = 42 });
    try std.testing.expectEqual(@as(u32, 1), obj.ref_count.load(.monotonic));

    const new_ref = TestCom.addRef(&obj);
    try std.testing.expectEqual(@as(u32, 2), new_ref);

    const after_release = TestCom.release(&obj);
    try std.testing.expectEqual(@as(u32, 1), after_release);
}
