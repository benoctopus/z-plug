/// Audio I/O layout, buffer configuration, and transport types.
///
/// These are the foundational types that describe how a plugin connects to
/// the host's audio graph and what runtime processing parameters are in effect.
const std = @import("std");

/// Declares a supported channel configuration for a plugin.
///
/// A plugin provides one or more of these at comptime. The host picks
/// the first layout it can satisfy, so order them from most preferred
/// to least preferred.
pub const AudioIOLayout = struct {
    /// Number of channels on the main input bus, or `null` for no main input
    /// (e.g. a synthesizer).
    main_input_channels: ?u32 = null,
    /// Number of channels on the main output bus, or `null` for no main output
    /// (e.g. an analyzer).
    main_output_channels: ?u32 = null,
    /// Channel counts for each auxiliary input bus.
    aux_input_ports: []const u32 = &.{},
    /// Channel counts for each auxiliary output bus.
    aux_output_ports: []const u32 = &.{},
    /// Optional human-readable name for this layout (e.g. "Stereo", "5.1").
    name: ?[:0]const u8 = null,

    /// Mono in, mono out.
    pub const MONO: AudioIOLayout = .{
        .main_input_channels = 1,
        .main_output_channels = 1,
        .name = "Mono",
    };

    /// Stereo in, stereo out.
    pub const STEREO: AudioIOLayout = .{
        .main_input_channels = 2,
        .main_output_channels = 2,
        .name = "Stereo",
    };

    /// No input (instrument/synth), stereo out.
    pub const STEREO_OUT: AudioIOLayout = .{
        .main_input_channels = null,
        .main_output_channels = 2,
        .name = "Stereo Out",
    };

    /// Returns the total number of input channels across all buses.
    pub fn totalInputChannels(self: AudioIOLayout) u32 {
        var total: u32 = self.main_input_channels orelse 0;
        for (self.aux_input_ports) |ch| {
            total += ch;
        }
        return total;
    }

    /// Returns the total number of output channels across all buses.
    pub fn totalOutputChannels(self: AudioIOLayout) u32 {
        var total: u32 = self.main_output_channels orelse 0;
        for (self.aux_output_ports) |ch| {
            total += ch;
        }
        return total;
    }
};

/// Runtime audio configuration provided by the host when the plugin is activated.
pub const BufferConfig = struct {
    /// The host's current sample rate in Hz.
    sample_rate: f32,
    /// Minimum buffer size the host may pass to `process`, or `null` if unknown.
    min_buffer_size: ?u32 = null,
    /// Maximum buffer size the host may pass to `process`.
    max_buffer_size: u32,
    /// Whether processing is real-time, buffered, or offline.
    process_mode: ProcessMode = .realtime,
};

/// How the host drives the plugin's processing.
pub const ProcessMode = enum {
    /// Real-time processing at a fixed rate (normal playback).
    realtime,
    /// Real-time-like but at irregular intervals (VST3 "prefetch" mode).
    buffered,
    /// Offline rendering — the host may call `process` faster than real-time.
    offline,
};

/// Describes what kind of note/MIDI events a plugin wants to receive or send.
pub const MidiConfig = enum {
    /// No MIDI I/O.
    none,
    /// Note on/off, poly pressure, and note expression events.
    basic,
    /// Everything in `basic` plus MIDI CC, pitch bend, channel pressure,
    /// and program change events.
    midi_cc,
};

/// Unified transport and timeline information, abstracted from both CLAP
/// (`clap_event_transport_t`) and VST3 (`ProcessContext`).
///
/// All optional fields are `null` when the host does not provide that
/// information.
pub const Transport = struct {
    /// Whether the host transport is currently playing.
    playing: bool = false,
    /// Whether the host is recording.
    recording: bool = false,
    /// Whether loop/cycle mode is active.
    looping: bool = false,

    /// Tempo in beats per minute, or `null` if unavailable.
    tempo: ?f64 = null,

    /// Time signature numerator (e.g. 4 for 4/4), or `null` if unavailable.
    time_sig_numerator: ?i32 = null,
    /// Time signature denominator (e.g. 4 for 4/4), or `null` if unavailable.
    time_sig_denominator: ?i32 = null,

    /// Current playback position in samples from the project start, or `null`.
    pos_samples: ?i64 = null,
    /// Current playback position in quarter-note beats, or `null`.
    pos_beats: ?f64 = null,
    /// Position of the current bar start in quarter-note beats, or `null`.
    bar_start_beats: ?f64 = null,

    /// Loop start position in quarter-note beats, or `null`.
    loop_start_beats: ?f64 = null,
    /// Loop end position in quarter-note beats, or `null`.
    loop_end_beats: ?f64 = null,

    /// A default transport with nothing playing and no timeline info.
    pub const EMPTY: Transport = .{};
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "AudioIOLayout MONO constant" {
    const mono = AudioIOLayout.MONO;
    try std.testing.expectEqual(@as(?u32, 1), mono.main_input_channels);
    try std.testing.expectEqual(@as(?u32, 1), mono.main_output_channels);
    try std.testing.expectEqual(@as(usize, 0), mono.aux_input_ports.len);
    try std.testing.expectEqual(@as(usize, 0), mono.aux_output_ports.len);
}

test "AudioIOLayout STEREO constant" {
    const stereo = AudioIOLayout.STEREO;
    try std.testing.expectEqual(@as(?u32, 2), stereo.main_input_channels);
    try std.testing.expectEqual(@as(?u32, 2), stereo.main_output_channels);
}

test "AudioIOLayout STEREO_OUT constant" {
    const layout = AudioIOLayout.STEREO_OUT;
    try std.testing.expectEqual(@as(?u32, null), layout.main_input_channels);
    try std.testing.expectEqual(@as(?u32, 2), layout.main_output_channels);
}

test "AudioIOLayout totalInputChannels with aux ports" {
    const layout = AudioIOLayout{
        .main_input_channels = 2,
        .main_output_channels = 2,
        .aux_input_ports = &.{ 2, 1 },
    };
    try std.testing.expectEqual(@as(u32, 5), layout.totalInputChannels());
    try std.testing.expectEqual(@as(u32, 2), layout.totalOutputChannels());
}

test "AudioIOLayout totalInputChannels with null main" {
    const layout = AudioIOLayout{
        .main_input_channels = null,
        .main_output_channels = 2,
    };
    try std.testing.expectEqual(@as(u32, 0), layout.totalInputChannels());
}

test "Transport EMPTY default" {
    const t = Transport.EMPTY;
    try std.testing.expect(!t.playing);
    try std.testing.expect(!t.recording);
    try std.testing.expect(!t.looping);
    try std.testing.expectEqual(@as(?f64, null), t.tempo);
}
