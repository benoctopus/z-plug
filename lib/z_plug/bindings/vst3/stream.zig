// VST3 C API Bindings - IBStream Interface
// Based on steinbergmedia/vst3_c_api

const types = @import("types.zig");
const guid = @import("guid.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;
const TSize = types.TSize;

/// Seek modes for IBStream
pub const IStreamSeekMode = enum(i32) {
    kIBSeekSet = 0,
    kIBSeekCur = 1,
    kIBSeekEnd = 2,
};

/// IBStream interface vtable
pub const IBStreamVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,

    // IBStream methods
    read: *const fn (*anyopaque, *anyopaque, i32, *i32) callconv(.c) tresult,
    write: *const fn (*anyopaque, *anyopaque, i32, *i32) callconv(.c) tresult,
    seek: *const fn (*anyopaque, i64, i32, *i64) callconv(.c) tresult,
    tell: *const fn (*anyopaque, *i64) callconv(.c) tresult,
};

pub const IBStream = extern struct {
    lpVtbl: *const IBStreamVtbl,
};

pub const IID_IBStream = guid.parseGuid("C3BF6EA2-3099-4752-9B6B-F9901EE33E9B");
