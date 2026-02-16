// VST3 C API Bindings - IConnectionPoint and IMessage Interfaces
// Based on steinbergmedia/vst3_c_api

const types = @import("types.zig");
const guid = @import("guid.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;
const FIDString = types.FIDString;

/// IMessage interface (forward declaration, full definition would include attribute list methods)
pub const IMessageVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IMessage methods
    getMessageID: *const fn (*anyopaque) callconv(.c) FIDString,
    setMessageID: *const fn (*anyopaque, FIDString) callconv(.c) void,
    getAttributes: *const fn (*anyopaque) callconv(.c) ?*anyopaque, // Returns IAttributeList
};

pub const IMessage = extern struct {
    lpVtbl: *const IMessageVtbl,
};

pub const IID_IMessage = guid.parseGuid("936F033B-C6C0-47DB-BB08-82F813C1E613");

/// IConnectionPoint interface vtable
pub const IConnectionPointVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IConnectionPoint methods
    connect: *const fn (*anyopaque, *anyopaque) callconv(.c) tresult,
    disconnect: *const fn (*anyopaque, *anyopaque) callconv(.c) tresult,
    notify: *const fn (*anyopaque, *IMessage) callconv(.c) tresult,
};

pub const IConnectionPoint = extern struct {
    lpVtbl: *const IConnectionPointVtbl,
};

pub const IID_IConnectionPoint = guid.parseGuid("70A4156F-6E6E-4026-9891-48BFB91D7B56");
