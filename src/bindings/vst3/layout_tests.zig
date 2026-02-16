// VST3 Binding Validation Tests
// Comprehensive layout, GUID, and vtable validation

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const types = @import("types.zig");
const guid = @import("guid.zig");
const funknown = @import("funknown.zig");
const factory = @import("factory.zig");
const component = @import("component.zig");
const processor = @import("processor.zig");
const controller = @import("controller.zig");
const events = @import("events.zig");

// ============================================================================
// STRUCT LAYOUT ASSERTIONS (High Priority - ABI Compatibility)
// ============================================================================

test "ProcessSetup layout" {
    const ProcessSetup = processor.ProcessSetup;
    
    // 4 i32/f64 fields = 4 + 4 + 4 + 8 = 20 bytes minimum (with alignment: 24)
    try testing.expectEqual(@as(usize, 0), @offsetOf(ProcessSetup, "process_mode"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(ProcessSetup, "symbolic_sample_size"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ProcessSetup, "max_samples_per_block"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(ProcessSetup, "sample_rate")); // f64 aligned to 8
    try testing.expect(@sizeOf(ProcessSetup) >= 24);
}

test "AudioBusBuffers layout" {
    const AudioBusBuffers = processor.AudioBusBuffers;
    
    // i32, u64, two optional pointers
    try testing.expectEqual(@as(usize, 0), @offsetOf(AudioBusBuffers, "num_channels"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(AudioBusBuffers, "silence_flags")); // u64 aligned
    // Pointers follow after the u64
    try testing.expect(@offsetOf(AudioBusBuffers, "channel_buffers_32") >= 16);
    try testing.expect(@sizeOf(AudioBusBuffers) >= 32);
}

test "ProcessData layout" {
    const ProcessData = processor.ProcessData;
    
    // Critical audio processing struct - verify first several fields
    try testing.expectEqual(@as(usize, 0), @offsetOf(ProcessData, "process_mode"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(ProcessData, "symbolic_sample_size"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ProcessData, "num_samples"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(ProcessData, "num_inputs"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(ProcessData, "num_outputs"));
    // Pointers follow (size depends on platform)
    try testing.expect(@sizeOf(ProcessData) >= 32);
}

test "ProcessContext layout" {
    const ProcessContext = processor.ProcessContext;
    
    // Large struct with many fields - validate critical ones
    try testing.expectEqual(@as(usize, 0), @offsetOf(ProcessContext, "state"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ProcessContext, "sample_rate")); // f64 aligned
    try testing.expect(@offsetOf(ProcessContext, "tempo") > 0);
    try testing.expect(@offsetOf(ProcessContext, "time_sig_numerator") > 0);
    try testing.expect(@sizeOf(ProcessContext) >= 100);
}

test "Event structs layout" {
    const NoteOnEvent = events.NoteOnEvent;
    const NoteOffEvent = events.NoteOffEvent;
    const Event = events.Event;
    
    // NoteOnEvent
    try testing.expectEqual(@as(usize, 0), @offsetOf(NoteOnEvent, "channel"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(NoteOnEvent, "pitch"));
    try testing.expect(@sizeOf(NoteOnEvent) >= 20);
    
    // NoteOffEvent
    try testing.expectEqual(@as(usize, 0), @offsetOf(NoteOffEvent, "channel"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(NoteOffEvent, "pitch"));
    
    // Event container
    try testing.expectEqual(@as(usize, 0), @offsetOf(Event, "bus_index"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Event, "sample_offset"));
    try testing.expect(@sizeOf(Event) >= 24);
}

test "ParameterInfo layout" {
    const ParameterInfo = controller.ParameterInfo;
    
    // Critical for parameter automation
    try testing.expectEqual(@as(usize, 0), @offsetOf(ParameterInfo, "id"));
    // String128 fields are large (256 bytes each)
    try testing.expect(@offsetOf(ParameterInfo, "title") >= 4);
    try testing.expect(@offsetOf(ParameterInfo, "short_title") > @offsetOf(ParameterInfo, "title"));
    // 3 * String128 (768) + 4 i32s (16) + 1 f64 (8) + padding = ~792-800 bytes
    try testing.expect(@sizeOf(ParameterInfo) >= 792);
}

test "Factory structs layout" {
    const PFactoryInfo = factory.PFactoryInfo;
    const PClassInfo = factory.PClassInfo;
    
    // PFactoryInfo
    try testing.expectEqual(@as(usize, 0), @offsetOf(PFactoryInfo, "vendor"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(PFactoryInfo, "url"));
    try testing.expectEqual(@as(usize, 320), @offsetOf(PFactoryInfo, "email"));
    try testing.expect(@sizeOf(PFactoryInfo) >= 448);
    
    // PClassInfo
    try testing.expectEqual(@as(usize, 0), @offsetOf(PClassInfo, "cid"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(PClassInfo, "cardinality"));
    try testing.expect(@sizeOf(PClassInfo) >= 112);
}

test "BusInfo and RoutingInfo layout" {
    const BusInfo = component.BusInfo;
    const RoutingInfo = component.RoutingInfo;
    
    // BusInfo
    try testing.expectEqual(@as(usize, 0), @offsetOf(BusInfo, "media_type"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(BusInfo, "direction"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(BusInfo, "channel_count"));
    try testing.expect(@sizeOf(BusInfo) >= 268); // String128 + other fields
    
    // RoutingInfo
    try testing.expectEqual(@as(usize, 0), @offsetOf(RoutingInfo, "media_type"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(RoutingInfo, "bus_index"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(RoutingInfo, "channel"));
}

// ============================================================================
// GUID BYTE-EXACT VALIDATION (High Priority - Interface Identity)
// ============================================================================

test "IID_FUnknown byte-exact" {
    // {00000000-0000-0000-C000-000000000046}
    // Big-endian (non-COM) representation
    const expected = [16]u8{
        0x00, 0x00, 0x00, 0x00, // First DWORD
        0x00, 0x00, // First WORD
        0x00, 0x00, // Second WORD
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46, // Eight bytes
    };
    
    try testing.expectEqualSlices(u8, &expected, &guid.IID_FUnknown);
}

test "IID_IPluginFactory byte-exact" {
    // {7A4D811C-5211-4A1F-AED9-D2EE0B43BF9F}
    const expected = [16]u8{
        0x7A, 0x4D, 0x81, 0x1C,
        0x52, 0x11,
        0x4A, 0x1F,
        0xAE, 0xD9, 0xD2, 0xEE, 0x0B, 0x43, 0xBF, 0x9F,
    };
    
    try testing.expectEqualSlices(u8, &expected, &guid.IID_IPluginFactory);
}

test "IID_IComponent byte-exact" {
    // {E831FF31-F2D5-4301-928E-BBEE25697802}
    const expected = [16]u8{
        0xE8, 0x31, 0xFF, 0x31,
        0xF2, 0xD5,
        0x43, 0x01,
        0x92, 0x8E, 0xBB, 0xEE, 0x25, 0x69, 0x78, 0x02,
    };
    
    try testing.expectEqualSlices(u8, &expected, &guid.IID_IComponent);
}

test "IID_IAudioProcessor byte-exact" {
    // {42043F99-B7DA-453C-A569-E79D9AAEC33D}
    const expected = [16]u8{
        0x42, 0x04, 0x3F, 0x99,
        0xB7, 0xDA,
        0x45, 0x3C,
        0xA5, 0x69, 0xE7, 0x9D, 0x9A, 0xAE, 0xC3, 0x3D,
    };
    
    try testing.expectEqualSlices(u8, &expected, &guid.IID_IAudioProcessor);
}

test "IID_IEditController byte-exact" {
    // {DCD7BBE3-7742-448D-A874-AACC979C759E}
    const expected = [16]u8{
        0xDC, 0xD7, 0xBB, 0xE3,
        0x77, 0x42,
        0x44, 0x8D,
        0xA8, 0x74, 0xAA, 0xCC, 0x97, 0x9C, 0x75, 0x9E,
    };
    
    try testing.expectEqualSlices(u8, &expected, &guid.IID_IEditController);
}

test "IID_IPluginBase byte-exact" {
    // {22888DDB-156E-45AE-8358-B34808190625}
    const expected = [16]u8{
        0x22, 0x88, 0x8D, 0xDB,
        0x15, 0x6E,
        0x45, 0xAE,
        0x83, 0x58, 0xB3, 0x48, 0x08, 0x19, 0x06, 0x25,
    };
    
    try testing.expectEqualSlices(u8, &expected, &guid.IID_IPluginBase);
}

test "parseGuid and inlineUid round-trip for FUnknown" {
    // Verify both methods produce the same result
    const from_string = guid.parseGuid("00000000-0000-0000-C000-000000000046");
    const from_inline = guid.inlineUid(0x00000000, 0x00000000, 0xC0000000, 0x00000046);
    
    try testing.expectEqualSlices(u8, &from_string, &from_inline);
}

// ============================================================================
// VTABLE FUNCTION POINTER TYPE VALIDATION (Medium Priority)
// ============================================================================

test "FUnknownVtbl field count" {
    const vtbl_type = @typeInfo(funknown.FUnknownVtbl);
    const fields = vtbl_type.@"struct".fields;
    
    // Must have exactly 3 fields: queryInterface, addRef, release
    try testing.expectEqual(@as(usize, 3), fields.len);
}

test "IPluginFactoryVtbl field count" {
    const vtbl_type = @typeInfo(factory.IPluginFactoryVtbl);
    const fields = vtbl_type.@"struct".fields;
    
    // 3 FUnknown + 4 factory methods = 7
    try testing.expectEqual(@as(usize, 7), fields.len);
}

test "IAudioProcessorVtbl field count" {
    const vtbl_type = @typeInfo(processor.IAudioProcessorVtbl);
    const fields = vtbl_type.@"struct".fields;
    
    // 3 FUnknown + 8 processor methods = 11
    try testing.expectEqual(@as(usize, 11), fields.len);
}

test "IEditControllerVtbl field count" {
    const vtbl_type = @typeInfo(controller.IEditControllerVtbl);
    const fields = vtbl_type.@"struct".fields;
    
    // 3 FUnknown + 2 IPluginBase + 13 controller methods = 18
    try testing.expectEqual(@as(usize, 18), fields.len);
}

test "IComponentVtbl field count" {
    const vtbl_type = @typeInfo(component.IComponentVtbl);
    const fields = vtbl_type.@"struct".fields;
    
    // 3 FUnknown + 2 IPluginBase + 9 component methods = 14
    try testing.expectEqual(@as(usize, 14), fields.len);
}

test "IPluginBaseVtbl field count" {
    const vtbl_type = @typeInfo(component.IPluginBaseVtbl);
    const fields = vtbl_type.@"struct".fields;
    
    // 3 FUnknown + 2 base methods = 5
    try testing.expectEqual(@as(usize, 5), fields.len);
}

test "vtable structs are pointer-sized" {
    // All vtable structs should be N * @sizeOf(usize) bytes
    const ptr_size = @sizeOf(usize);
    
    // FUnknownVtbl = 3 pointers
    try testing.expectEqual(ptr_size * 3, @sizeOf(funknown.FUnknownVtbl));
    
    // IPluginFactoryVtbl = 7 pointers
    try testing.expectEqual(ptr_size * 7, @sizeOf(factory.IPluginFactoryVtbl));
    
    // IAudioProcessorVtbl = 11 pointers
    try testing.expectEqual(ptr_size * 11, @sizeOf(processor.IAudioProcessorVtbl));
}

// ============================================================================
// ADDITIONAL STRUCT SIZE SANITY CHECKS
// ============================================================================

test "String128 is 256 bytes" {
    // char16[128] = u16[128] = 256 bytes
    try testing.expectEqual(@as(usize, 256), @sizeOf(types.String128));
}

test "TUID is exactly 16 bytes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(types.TUID));
}

test "fundamental type sizes" {
    // Verify our type aliases match expected sizes
    try testing.expectEqual(@as(usize, 4), @sizeOf(types.tresult)); // i32
    try testing.expectEqual(@as(usize, 4), @sizeOf(types.ParamID)); // u32
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.ParamValue)); // f64
    try testing.expectEqual(@as(usize, 4), @sizeOf(types.Sample32)); // f32
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.Sample64)); // f64
    try testing.expectEqual(@as(usize, 8), @sizeOf(types.SpeakerArrangement)); // u64
}

test "Chord struct layout" {
    const Chord = processor.Chord;
    
    // u8, u8, i16 = 4 bytes total
    try testing.expectEqual(@as(usize, 0), @offsetOf(Chord, "key_note"));
    try testing.expectEqual(@as(usize, 1), @offsetOf(Chord, "root_note"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(Chord, "chord_mask"));
    try testing.expectEqual(@as(usize, 4), @sizeOf(Chord));
}

test "FrameRate struct layout" {
    const FrameRate = processor.FrameRate;
    
    // Two u32 fields = 8 bytes
    try testing.expectEqual(@as(usize, 0), @offsetOf(FrameRate, "frames_per_second"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(FrameRate, "flags"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(FrameRate));
}

// ============================================================================
// GUID FUNCTIONALITY VALIDATION
// ============================================================================

test "GUID equality works correctly" {
    const guid1 = guid.parseGuid("00000000-0000-0000-C000-000000000046");
    const guid2 = guid.parseGuid("00000000-0000-0000-C000-000000000046");
    const guid3 = guid.parseGuid("7A4D811C-5211-4A1F-AED9-D2EE0B43BF9F");
    
    try testing.expect(guid.eql(guid1, guid2));
    try testing.expect(!guid.eql(guid1, guid3));
    try testing.expect(!guid.eql(guid2, guid3));
}

test "inlineUid produces 16 bytes" {
    const result = guid.inlineUid(0x12345678, 0x9ABCDEF0, 0x11111111, 0x22222222);
    try testing.expectEqual(@as(usize, 16), result.len);
}

// ============================================================================
// INTERFACE STRUCT VALIDATION
// ============================================================================

test "interface structs have lpVtbl field" {
    // Verify all interface structs follow the COM pattern
    try testing.expectEqual(@as(usize, 0), @offsetOf(funknown.FUnknown, "lpVtbl"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(factory.IPluginFactory, "lpVtbl"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(component.IComponent, "lpVtbl"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(processor.IAudioProcessor, "lpVtbl"));
    try testing.expectEqual(@as(usize, 0), @offsetOf(controller.IEditController, "lpVtbl"));
    
    // All interface structs should be pointer-sized (just a vtable pointer)
    const ptr_size = @sizeOf(usize);
    try testing.expectEqual(ptr_size, @sizeOf(funknown.FUnknown));
    try testing.expectEqual(ptr_size, @sizeOf(factory.IPluginFactory));
}
