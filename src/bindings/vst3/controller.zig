// VST3 C API Bindings - IEditController Interface
// Based on steinbergmedia/vst3_c_api

const types = @import("types.zig");
const guid = @import("guid.zig");
const component = @import("component.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;
const TBool = types.TBool;
const ParamID = types.ParamID;
const ParamValue = types.ParamValue;
const String128 = types.String128;
const UnitID = types.UnitID;
const IBStream = component.IBStream;

/// Parameter information
pub const ParameterInfo = extern struct {
    id: ParamID,
    title: String128,
    short_title: String128,
    units: String128,
    step_count: i32,
    default_normalized_value: ParamValue,
    unit_id: UnitID,
    flags: i32,
    
    pub const ParameterFlags = enum(i32) {
        kNoFlags = 0,
        kCanAutomate = 1 << 0,
        kIsReadOnly = 1 << 1,
        kIsWrapAround = 1 << 2,
        kIsList = 1 << 3,
        kIsHidden = 1 << 4,
        kIsProgramChange = 1 << 15,
        kIsBypass = 1 << 16,
    };
};

// Forward declaration for IPlugView
pub const IPlugView = extern struct {
    lpVtbl: *anyopaque,
};

/// IEditController interface
pub const IEditControllerVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IPluginBase methods
    initialize: *const fn (*anyopaque, *anyopaque) callconv(.c) tresult,
    terminate: *const fn (*anyopaque) callconv(.c) tresult,
    
    // IEditController methods
    setComponentState: *const fn (*anyopaque, *IBStream) callconv(.c) tresult,
    setState: *const fn (*anyopaque, *IBStream) callconv(.c) tresult,
    getState: *const fn (*anyopaque, *IBStream) callconv(.c) tresult,
    getParameterCount: *const fn (*anyopaque) callconv(.c) i32,
    getParameterInfo: *const fn (*anyopaque, i32, *ParameterInfo) callconv(.c) tresult,
    getParamStringByValue: *const fn (*anyopaque, ParamID, ParamValue, *String128) callconv(.c) tresult,
    getParamValueByString: *const fn (*anyopaque, ParamID, *types.char16, *ParamValue) callconv(.c) tresult,
    normalizedParamToPlain: *const fn (*anyopaque, ParamID, ParamValue) callconv(.c) ParamValue,
    plainParamToNormalized: *const fn (*anyopaque, ParamID, ParamValue) callconv(.c) ParamValue,
    getParamNormalized: *const fn (*anyopaque, ParamID) callconv(.c) ParamValue,
    setParamNormalized: *const fn (*anyopaque, ParamID, ParamValue) callconv(.c) tresult,
    setComponentHandler: *const fn (*anyopaque, *anyopaque) callconv(.c) tresult,
    createView: *const fn (*anyopaque, types.FIDString) callconv(.c) ?*IPlugView,
};

pub const IEditController = extern struct {
    lpVtbl: *const IEditControllerVtbl,
};

pub const IID_IEditController = guid.IID_IEditController;

/// IComponentHandler interface (host callback for parameter changes)
pub const IComponentHandlerVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IComponentHandler methods
    beginEdit: *const fn (*anyopaque, ParamID) callconv(.c) tresult,
    performEdit: *const fn (*anyopaque, ParamID, ParamValue) callconv(.c) tresult,
    endEdit: *const fn (*anyopaque, ParamID) callconv(.c) tresult,
    restartComponent: *const fn (*anyopaque, i32) callconv(.c) tresult,
};

pub const IComponentHandler = extern struct {
    lpVtbl: *const IComponentHandlerVtbl,
};

pub const IID_IComponentHandler = guid.parseGuid("93A0BEA3-0BD0-45DB-8E89-0B0CC1E46AC6");

/// Restart flags for IComponentHandler.restartComponent
pub const RestartFlags = enum(i32) {
    kReloadComponent = 1 << 0,
    kIoChanged = 1 << 1,
    kParamValuesChanged = 1 << 2,
    kLatencyChanged = 1 << 3,
    kParamTitlesChanged = 1 << 4,
    kMidiCCAssignmentChanged = 1 << 5,
    kNoteExpressionChanged = 1 << 6,
    kIoTitlesChanged = 1 << 7,
    kPrefetchableSupportChanged = 1 << 8,
    kRoutingInfoChanged = 1 << 9,
    kKeyswitchChanged = 1 << 10,
    kParamIDMappingChanged = 1 << 11,
};

test "ParameterInfo size" {
    const testing = @import("std").testing;
    // Verify the struct has the expected fields
    try testing.expectEqual(@as(usize, @offsetOf(ParameterInfo, "id")), 0);
}
