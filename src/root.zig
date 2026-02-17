/// Public API for plugin authors.
///
/// This module re-exports all core framework types that plugin authors need
/// to implement audio plugins for both CLAP and VST3.
const std = @import("std");

// Core plugin interface
pub const Plugin = @import("core/plugin.zig").Plugin;
pub const ProcessStatus = @import("core/plugin.zig").ProcessStatus;
pub const ProcessContext = @import("core/plugin.zig").ProcessContext;
pub const EventOutputList = @import("core/plugin.zig").EventOutputList;

// Audio buffer types
pub const Buffer = @import("core/buffer.zig").Buffer;
pub const AuxBuffers = @import("core/buffer.zig").AuxBuffers;

// Note and MIDI events
pub const NoteEvent = @import("core/events.zig").NoteEvent;
pub const NoteData = @import("core/events.zig").NoteData;
pub const PolyValueData = @import("core/events.zig").PolyValueData;
pub const MidiCCData = @import("core/events.zig").MidiCCData;
pub const MidiChannelData = @import("core/events.zig").MidiChannelData;
pub const MidiProgramData = @import("core/events.zig").MidiProgramData;

// Parameter system
pub const Param = @import("core/params.zig").Param;
pub const FloatParam = @import("core/params.zig").FloatParam;
pub const IntParam = @import("core/params.zig").IntParam;
pub const BoolParam = @import("core/params.zig").BoolParam;
pub const ChoiceParam = @import("core/params.zig").ChoiceParam;
pub const FloatRange = @import("core/params.zig").FloatRange;
pub const IntRange = @import("core/params.zig").IntRange;
pub const ParamFlags = @import("core/params.zig").ParamFlags;
pub const ParamValues = @import("core/params.zig").ParamValues;
pub const idHash = @import("core/params.zig").idHash;
pub const SmoothingStyle = @import("core/params.zig").SmoothingStyle;
pub const Smoother = @import("core/params.zig").Smoother;
pub const SmootherBank = @import("core/params.zig").SmootherBank;
pub const ParamAccess = @import("core/params.zig").ParamAccess;

// Audio I/O layout and configuration
pub const AudioIOLayout = @import("core/audio_layout.zig").AudioIOLayout;
pub const BufferConfig = @import("core/audio_layout.zig").BufferConfig;
pub const ProcessMode = @import("core/audio_layout.zig").ProcessMode;
pub const MidiConfig = @import("core/audio_layout.zig").MidiConfig;
pub const Transport = @import("core/audio_layout.zig").Transport;

// State persistence
pub const SaveContext = @import("core/state.zig").SaveContext;
pub const LoadContext = @import("core/state.zig").LoadContext;

// Platform constants
pub const platform = @import("core/platform.zig");
pub const CACHE_LINE_SIZE = platform.CACHE_LINE_SIZE;
pub const StateVersion = @import("core/state.zig").StateVersion;
pub const writeHeader = @import("core/state.zig").writeHeader;
pub const readHeader = @import("core/state.zig").readHeader;

// Utility functions for audio DSP
pub const util = @import("core/util.zig");

// Format wrappers
pub const ClapEntry = @import("wrappers/clap/entry.zig").ClapEntry;
pub const Vst3Factory = @import("wrappers/vst3/factory.zig").Vst3Factory;

test {
    // Ensure all core module tests are run.
    std.testing.refAllDecls(@import("core/audio_layout.zig"));
    std.testing.refAllDecls(@import("core/buffer.zig"));
    std.testing.refAllDecls(@import("core/events.zig"));
    std.testing.refAllDecls(@import("core/params.zig"));
    std.testing.refAllDecls(@import("core/state.zig"));
    std.testing.refAllDecls(@import("core/plugin.zig"));
    std.testing.refAllDecls(@import("core/util.zig"));

    // Wrapper tests
    std.testing.refAllDecls(@import("wrappers/clap/entry.zig"));
    std.testing.refAllDecls(@import("wrappers/vst3/factory.zig"));
}
