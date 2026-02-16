// VST3 C API Bindings - IParameterChanges and IParamValueQueue Interfaces
// Based on steinbergmedia/vst3_c_api

const types = @import("types.zig");
const guid = @import("guid.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;
const ParamID = types.ParamID;
const ParamValue = types.ParamValue;

/// IParamValueQueue interface vtable
pub const IParamValueQueueVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IParamValueQueue methods
    getParameterId: *const fn (*anyopaque) callconv(.c) ParamID,
    getPointCount: *const fn (*anyopaque) callconv(.c) i32,
    getPoint: *const fn (*anyopaque, i32, *i32, *ParamValue) callconv(.c) tresult,
    addPoint: *const fn (*anyopaque, i32, ParamValue, *i32) callconv(.c) tresult,
};

pub const IParamValueQueue = extern struct {
    lpVtbl: *const IParamValueQueueVtbl,
};

pub const IID_IParamValueQueue = guid.parseGuid("01263A18-ED07-4F6F-98C9-D3564686F9BA");

/// IParameterChanges interface vtable
pub const IParameterChangesVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IParameterChanges methods
    getParameterCount: *const fn (*anyopaque) callconv(.c) i32,
    getParameterData: *const fn (*anyopaque, i32) callconv(.c) ?*IParamValueQueue,
    addParameterData: *const fn (*anyopaque, *const ParamID, *i32) callconv(.c) ?*IParamValueQueue,
};

pub const IParameterChanges = extern struct {
    lpVtbl: *const IParameterChangesVtbl,
};

pub const IID_IParameterChanges = guid.parseGuid("A4779663-0BB6-4A56-B44D-A83099F2153C");
