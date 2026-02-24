// VST3 C API Bindings - IComponent Interface
// Based on steinbergmedia/vst3_c_api

const types = @import("types.zig");
const guid = @import("guid.zig");
const funknown = @import("funknown.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;
const TBool = types.TBool;
const MediaType = types.MediaType;
const BusDirection = types.BusDirection;
const BusType = types.BusType;
const String128 = types.String128;

/// Bus information
pub const BusInfo = extern struct {
    media_type: MediaType,
    direction: BusDirection,
    channel_count: i32,
    name: String128,
    bus_type: BusType,
    flags: u32,

    pub const BusFlags = enum(u32) {
        kDefaultActive = 1 << 0,
        kIsControlVoltage = 1 << 1,
    };
};

/// Routing information
pub const RoutingInfo = extern struct {
    media_type: MediaType,
    bus_index: i32,
    channel: i32,
};

/// IPluginBase interface (base for IComponent)
pub const IPluginBaseVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,

    // IPluginBase methods
    initialize: *const fn (*anyopaque, *anyopaque) callconv(.c) tresult,
    terminate: *const fn (*anyopaque) callconv(.c) tresult,
};

pub const IPluginBase = extern struct {
    lpVtbl: *const IPluginBaseVtbl,
};

pub const IID_IPluginBase = guid.IID_IPluginBase;

// Forward declarations for IBStream
pub const IBStream = extern struct {
    lpVtbl: *anyopaque,
};

/// IComponent interface
pub const IComponentVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,

    // IPluginBase methods
    initialize: *const fn (*anyopaque, *anyopaque) callconv(.c) tresult,
    terminate: *const fn (*anyopaque) callconv(.c) tresult,

    // IComponent methods
    getControllerClassId: *const fn (*anyopaque, *TUID) callconv(.c) tresult,
    setIoMode: *const fn (*anyopaque, types.IoMode) callconv(.c) tresult,
    getBusCount: *const fn (*anyopaque, MediaType, BusDirection) callconv(.c) i32,
    getBusInfo: *const fn (*anyopaque, MediaType, BusDirection, i32, *BusInfo) callconv(.c) tresult,
    getRoutingInfo: *const fn (*anyopaque, *RoutingInfo, *RoutingInfo) callconv(.c) tresult,
    activateBus: *const fn (*anyopaque, MediaType, BusDirection, i32, TBool) callconv(.c) tresult,
    setActive: *const fn (*anyopaque, TBool) callconv(.c) tresult,
    setState: *const fn (*anyopaque, *IBStream) callconv(.c) tresult,
    getState: *const fn (*anyopaque, *IBStream) callconv(.c) tresult,
};

pub const IComponent = extern struct {
    lpVtbl: *const IComponentVtbl,
};

pub const IID_IComponent = guid.IID_IComponent;

test "BusInfo size" {
    const testing = @import("std").testing;
    // Verify the struct has the expected fields
    try testing.expectEqual(@as(usize, @offsetOf(BusInfo, "media_type")), 0);
}
