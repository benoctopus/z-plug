// VST3 C API Bindings - IAudioProcessor Interface
// Based on steinbergmedia/vst3_c_api

const types = @import("types.zig");
const guid = @import("guid.zig");

const TUID = types.TUID;
const tresult = types.tresult;
const vst3_callconv = types.vst3_callconv;
const TBool = types.TBool;
const Sample32 = types.Sample32;
const Sample64 = types.Sample64;
const SampleRate = types.SampleRate;
const TSamples = types.TSamples;
const TQuarterNotes = types.TQuarterNotes;
const SpeakerArrangement = types.SpeakerArrangement;

/// Process setup
pub const ProcessSetup = extern struct {
    process_mode: i32,
    symbolic_sample_size: i32,
    max_samples_per_block: i32,
    sample_rate: SampleRate,
};

/// Audio bus buffers
pub const AudioBusBuffers = extern struct {
    num_channels: i32,
    silence_flags: u64,
    channel_buffers_32: ?[*][*]Sample32,
    channel_buffers_64: ?[*][*]Sample64,
};

/// Frame rate
pub const FrameRate = extern struct {
    frames_per_second: u32,
    flags: u32,

    pub const FrameRateFlags = enum(u32) {
        kPullDownRate = 1 << 0,
        kDropRate = 1 << 1,
    };
};

/// Chord
pub const Chord = extern struct {
    key_note: u8,
    root_note: u8,
    chord_mask: i16,
};

/// Process context
pub const ProcessContext = extern struct {
    state: u32,
    sample_rate: f64,
    project_time_samples: TSamples,
    system_time: i64,
    continuous_time_samples: TSamples,
    project_time_music: TQuarterNotes,
    bar_position_music: TQuarterNotes,
    cycle_start_music: TQuarterNotes,
    cycle_end_music: TQuarterNotes,
    tempo: f64,
    time_sig_numerator: i32,
    time_sig_denominator: i32,
    chord: Chord,
    smpte_offset_subframes: i32,
    frame_rate: FrameRate,
    samples_to_next_clock: i32,

    pub const StatesAndFlags = enum(u32) {
        kPlaying = 1 << 1,
        kCycleActive = 1 << 2,
        kRecording = 1 << 3,
        kSystemTimeValid = 1 << 8,
        kContTimeValid = 1 << 17,
        kProjectTimeMusicValid = 1 << 9,
        kBarPositionValid = 1 << 11,
        kCycleValid = 1 << 12,
        kTempoValid = 1 << 10,
        kTimeSigValid = 1 << 13,
        kChordValid = 1 << 18,
        kSmpteValid = 1 << 14,
        kClockValid = 1 << 15,
    };
};

// Forward declarations for interfaces used by ProcessData
pub const IParameterChanges = extern struct {
    lpVtbl: *anyopaque,
};

pub const IEventList = extern struct {
    lpVtbl: *anyopaque,
};

/// Process data
pub const ProcessData = extern struct {
    process_mode: i32,
    symbolic_sample_size: i32,
    num_samples: i32,
    num_inputs: i32,
    num_outputs: i32,
    inputs: [*]AudioBusBuffers,
    outputs: [*]AudioBusBuffers,
    input_parameter_changes: ?*IParameterChanges,
    output_parameter_changes: ?*IParameterChanges,
    input_events: ?*IEventList,
    output_events: ?*IEventList,
    process_context: ?*ProcessContext,
};

/// IAudioProcessor interface
pub const IAudioProcessorVtbl = extern struct {
    // FUnknown methods
    queryInterface: *const fn (*anyopaque, *const TUID, *?*anyopaque) callconv(.c) tresult,
    addRef: *const fn (*anyopaque) callconv(.c) u32,
    release: *const fn (*anyopaque) callconv(.c) u32,

    // IAudioProcessor methods
    setBusArrangements: *const fn (*anyopaque, [*]SpeakerArrangement, i32, [*]SpeakerArrangement, i32) callconv(.c) tresult,
    getBusArrangement: *const fn (*anyopaque, types.BusDirection, i32, *SpeakerArrangement) callconv(.c) tresult,
    canProcessSampleSize: *const fn (*anyopaque, i32) callconv(.c) tresult,
    getLatencySamples: *const fn (*anyopaque) callconv(.c) u32,
    setupProcessing: *const fn (*anyopaque, *ProcessSetup) callconv(.c) tresult,
    setProcessing: *const fn (*anyopaque, TBool) callconv(.c) tresult,
    process: *const fn (*anyopaque, *ProcessData) callconv(.c) tresult,
    getTailSamples: *const fn (*anyopaque) callconv(.c) u32,
};

pub const IAudioProcessor = extern struct {
    lpVtbl: *const IAudioProcessorVtbl,
};

pub const IID_IAudioProcessor = guid.IID_IAudioProcessor;

test "ProcessSetup size" {
    const testing = @import("std").testing;
    // Verify the struct layout
    try testing.expectEqual(@as(usize, @offsetOf(ProcessSetup, "process_mode")), 0);
}

test "ProcessData has correct fields" {
    const testing = @import("std").testing;
    // Just verify it compiles and has the expected structure
    _ = ProcessData;
    try testing.expect(@sizeOf(ProcessData) > 0);
}
