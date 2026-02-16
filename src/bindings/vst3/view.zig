// VST3 C API Bindings - IPlugView Interface (stub)
// Based on steinbergmedia/vst3_c_api
// GUI implementation is deferred per design doc

const types = @import("types.zig");
const guid = @import("guid.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;
const TBool = types.TBool;

/// View rectangle
pub const ViewRect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// IPlugView interface vtable (minimal stub for now)
pub const IPlugViewVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IPlugView methods
    isPlatformTypeSupported: *const fn (*anyopaque, types.FIDString) callconv(.c) tresult,
    attached: *const fn (*anyopaque, *anyopaque, types.FIDString) callconv(.c) tresult,
    removed: *const fn (*anyopaque) callconv(.c) tresult,
    onWheel: *const fn (*anyopaque, f32) callconv(.c) tresult,
    onKeyDown: *const fn (*anyopaque, types.char16, i16, i16) callconv(.c) tresult,
    onKeyUp: *const fn (*anyopaque, types.char16, i16, i16) callconv(.c) tresult,
    getSize: *const fn (*anyopaque, *ViewRect) callconv(.c) tresult,
    onSize: *const fn (*anyopaque, *ViewRect) callconv(.c) tresult,
    onFocus: *const fn (*anyopaque, TBool) callconv(.c) tresult,
    setFrame: *const fn (*anyopaque, *anyopaque) callconv(.c) tresult,
    canResize: *const fn (*anyopaque) callconv(.c) tresult,
    checkSizeConstraint: *const fn (*anyopaque, *ViewRect) callconv(.c) tresult,
};

pub const IPlugView = extern struct {
    lpVtbl: *const IPlugViewVtbl,
};

pub const IID_IPlugView = guid.parseGuid("5BC32507-D060-49EA-A615-1B522B755B29");
