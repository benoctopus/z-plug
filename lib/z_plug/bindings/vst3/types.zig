// VST3 C API Bindings - Fundamental Types
// Based on steinbergmedia/vst3_c_api

const std = @import("std");
const builtin = @import("builtin");

/// Result type for VST3 functions
pub const tresult = i32;

/// Platform-aware result codes (COM-compatible on Windows, non-COM elsewhere)
pub const kResultOk: tresult = if (builtin.os.tag == .windows) 0x00000000 else 0;
pub const kResultTrue: tresult = kResultOk;
pub const kResultFalse: tresult = if (builtin.os.tag == .windows) 0x00000001 else 1;
pub const kNoInterface: tresult = if (builtin.os.tag == .windows) @bitCast(@as(u32, 0x80004002)) else -1;
pub const kInvalidArgument: tresult = if (builtin.os.tag == .windows) @bitCast(@as(u32, 0x80070057)) else 2;
pub const kNotImplemented: tresult = if (builtin.os.tag == .windows) @bitCast(@as(u32, 0x80004001)) else 3;
pub const kInternalError: tresult = if (builtin.os.tag == .windows) @bitCast(@as(u32, 0x80004005)) else 4;
pub const kNotInitialized: tresult = if (builtin.os.tag == .windows) @bitCast(@as(u32, 0x8000FFFF)) else 5;
pub const kOutOfMemory: tresult = if (builtin.os.tag == .windows) @bitCast(@as(u32, 0x8007000E)) else 6;

/// 16-byte unique identifier (GUID/UUID)
pub const TUID = [16]u8;

/// Null-terminated string for interface IDs
pub const FIDString = [*:0]const u8;

/// Boolean type (8-bit)
pub const TBool = u8;

/// Pointer-sized integer
pub const TPtrInt = usize;

/// Size type
pub const TSize = i64;

/// Unicode character (16-bit)
pub const char16 = u16;

/// VST3 string (128 char16 array)
pub const String128 = [128]char16;

/// C-style string
pub const CString = [*:0]const u8;

// Audio and parameter types
pub const ParamID = u32;
pub const ParamValue = f64;
pub const Sample32 = f32;
pub const Sample64 = f64;
pub const SampleRate = f64;
pub const TSamples = i64;
pub const TQuarterNotes = f64;

/// Speaker arrangement bitmask
pub const SpeakerArrangement = u64;
pub const Speaker = u64;

// Bus and I/O types
pub const MediaType = i32;
pub const BusDirection = i32;
pub const BusType = i32;
pub const IoMode = i32;

/// Unit ID for parameter organization
pub const UnitID = i32;

/// Media types
pub const MediaTypes = enum(MediaType) {
    kAudio = 0,
    kEvent = 1,
};

/// Bus directions
pub const BusDirections = enum(BusDirection) {
    kInput = 0,
    kOutput = 1,
};

/// Bus types
pub const BusTypes = enum(BusType) {
    kMain = 0,
    kAux = 1,
};

/// I/O modes
pub const IoModes = enum(IoMode) {
    kSimple = 0,
    kAdvanced = 1,
    kOfflineProcessing = 2,
};

/// Symbolic sample sizes
pub const SymbolicSampleSizes = enum(i32) {
    kSample32 = 0,
    kSample64 = 1,
};

/// Process modes
pub const ProcessModes = enum(i32) {
    kRealtime = 0,
    kPrefetch = 1,
    kOffline = 2,
};

/// Calling convention for VST3 interfaces (stdcall on Windows, C elsewhere)
pub inline fn vst3_callconv() std.builtin.CallingConvention {
    return if (builtin.os.tag == .windows) .stdcall else .C;
}

test "result code values" {
    const testing = std.testing;
    // Just verify they compile and have correct types
    try testing.expectEqual(@TypeOf(kResultOk), tresult);
    try testing.expectEqual(@TypeOf(kResultFalse), tresult);
}
