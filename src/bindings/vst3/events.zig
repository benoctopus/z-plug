// VST3 C API Bindings - IEventList Interface
// Based on steinbergmedia/vst3_c_api

const types = @import("types.zig");
const guid = @import("guid.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;
const ParamID = types.ParamID;
const ParamValue = types.ParamValue;

/// Event types
pub const EventTypes = enum(u16) {
    kNoteOnEvent = 0,
    kNoteOffEvent = 1,
    kDataEvent = 2,
    kPolyPressureEvent = 3,
    kNoteExpressionValueEvent = 4,
    kNoteExpressionTextEvent = 5,
    kChordEvent = 6,
    kScaleEvent = 7,
    kLegacyMIDICCOutEvent = 65535,
};

/// Event flags
pub const EventFlags = enum(u16) {
    kIsLive = 1 << 0,
    kUserReserved1 = 1 << 14,
    kUserReserved2 = 1 << 15,
};

/// Note on event
pub const NoteOnEvent = extern struct {
    channel: i16,
    pitch: i16,
    tuning: f32,
    velocity: f32,
    length: i32,
    note_id: i32,
};

/// Note off event
pub const NoteOffEvent = extern struct {
    channel: i16,
    pitch: i16,
    velocity: f32,
    note_id: i32,
    tuning: f32,
};

/// Data event
pub const DataEvent = extern struct {
    size: u32,
    type: u32,
    bytes: [*]const u8,
};

/// Poly pressure event
pub const PolyPressureEvent = extern struct {
    channel: i16,
    pitch: i16,
    pressure: f32,
    note_id: i32,
};

/// Generic event structure
pub const Event = extern struct {
    bus_index: i32,
    sample_offset: i32,
    ppq_position: f64,
    flags: u16,
    type: u16,
    data: extern union {
        note_on: NoteOnEvent,
        note_off: NoteOffEvent,
        data: DataEvent,
        poly_pressure: PolyPressureEvent,
    },
};

/// IEventList interface vtable
pub const IEventListVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,
    
    // IEventList methods
    getEventCount: *const fn (*anyopaque) callconv(.c) i32,
    getEvent: *const fn (*anyopaque, i32, *Event) callconv(.c) tresult,
    addEvent: *const fn (*anyopaque, *Event) callconv(.c) tresult,
};

pub const IEventList = extern struct {
    lpVtbl: *const IEventListVtbl,
};

pub const IID_IEventList = guid.parseGuid("3A2C4214-3463-49FE-B2C4-F397B9695A44");
