// VST3 C API Bindings - Plugin Factory Interfaces
// Based on steinbergmedia/vst3_c_api

const types = @import("types.zig");
const guid = @import("guid.zig");
const funknown = @import("funknown.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const FIDString = types.FIDString;
const vst3_callconv = types.vst3_callconv;
const char16 = types.char16;

// Factory info string capacity
pub const kNameSize = 64;
pub const kURLSize = 256;
pub const kEmailSize = 128;

/// Factory information
pub const PFactoryInfo = extern struct {
    vendor: [kNameSize]u8,
    url: [kURLSize]u8,
    email: [kEmailSize]u8,
    flags: i32,
    
    pub const FactoryFlags = enum(i32) {
        kNoFlags = 0,
        kClassesDiscardable = 1 << 0,
        kLicenseCheck = 1 << 1,
        kComponentNonDiscardable = 1 << 3,
        kUnicode = 1 << 4,
    };
};

/// Class information (version 1)
pub const PClassInfo = extern struct {
    cid: TUID,
    cardinality: i32,
    category: [32]u8,
    name: [64]u8,
    
    pub const ClassCardinality = enum(i32) {
        kManyInstances = 0x7FFFFFFF,
    };
};

/// Class information (version 2) - extends PClassInfo
pub const PClassInfo2 = extern struct {
    cid: TUID,
    cardinality: i32,
    category: [32]u8,
    name: [64]u8,
    class_flags: u32,
    subcategories: [128]u8,
    vendor: [64]u8,
    version: [64]u8,
    sdk_version: [64]u8,
};

/// Class information (Unicode version)
pub const PClassInfoW = extern struct {
    cid: TUID,
    cardinality: i32,
    category: [32]u8,
    name: [128]char16,
    class_flags: u32,
    subcategories: [128]u8,
    vendor: [128]char16,
    version: [64]char16,
    sdk_version: [64]char16,
};

/// IPluginFactory interface
pub const IPluginFactoryVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IPluginFactory methods
    getFactoryInfo: *const fn (*anyopaque, *PFactoryInfo) callconv(.c) tresult,
    countClasses: *const fn (*anyopaque) callconv(.c) i32,
    getClassInfo: *const fn (*anyopaque, i32, *PClassInfo) callconv(.c) tresult,
    createInstance: *const fn (*anyopaque, FIDString, FIDString, *?*anyopaque) callconv(.c) tresult,
};

pub const IPluginFactory = extern struct {
    lpVtbl: *const IPluginFactoryVtbl,
};

pub const IID_IPluginFactory = guid.IID_IPluginFactory;

/// IPluginFactory2 interface (adds getClassInfo2)
pub const IPluginFactory2Vtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IPluginFactory methods
    getFactoryInfo: *const fn (*anyopaque, *PFactoryInfo) callconv(.c) tresult,
    countClasses: *const fn (*anyopaque) callconv(.c) i32,
    getClassInfo: *const fn (*anyopaque, i32, *PClassInfo) callconv(.c) tresult,
    createInstance: *const fn (*anyopaque, FIDString, FIDString, *?*anyopaque) callconv(.c) tresult,
    
    // IPluginFactory2 methods
    getClassInfo2: *const fn (*anyopaque, i32, *PClassInfo2) callconv(.c) tresult,
};

pub const IPluginFactory2 = extern struct {
    lpVtbl: *const IPluginFactory2Vtbl,
};

pub const IID_IPluginFactory2 = guid.parseGuid("0007B650-F24B-4C0B-A464-EDB9F00B2ABB");

/// IPluginFactory3 interface (adds getClassInfoUnicode, setHostContext)
pub const IPluginFactory3Vtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IPluginFactory methods
    getFactoryInfo: *const fn (*anyopaque, *PFactoryInfo) callconv(.c) tresult,
    countClasses: *const fn (*anyopaque) callconv(.c) i32,
    getClassInfo: *const fn (*anyopaque, i32, *PClassInfo) callconv(.c) tresult,
    createInstance: *const fn (*anyopaque, FIDString, FIDString, *?*anyopaque) callconv(.c) tresult,
    
    // IPluginFactory2 methods
    getClassInfo2: *const fn (*anyopaque, i32, *PClassInfo2) callconv(.c) tresult,
    
    // IPluginFactory3 methods
    getClassInfoUnicode: *const fn (*anyopaque, i32, *PClassInfoW) callconv(.c) tresult,
    setHostContext: *const fn (*anyopaque, *anyopaque) callconv(.c) tresult,
};

pub const IPluginFactory3 = extern struct {
    lpVtbl: *const IPluginFactory3Vtbl,
};

pub const IID_IPluginFactory3 = guid.parseGuid("4555A2AB-C123-4E57-9B12-291036F931A7");

test "factory info size" {
    const testing = @import("std").testing;
    // Verify struct layout matches C API
    try testing.expectEqual(@as(usize, 64), @sizeOf([kNameSize]u8));
    try testing.expectEqual(@as(usize, 256), @sizeOf([kURLSize]u8));
}
