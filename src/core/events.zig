/// Unified note and MIDI event types.
///
/// Both CLAP and VST3 wrappers translate their format-specific events into
/// this single tagged union. All events carry a sample-accurate `timing`
/// offset within the current process buffer.
const std = @import("std");

/// Common data for note on, note off, choke, and voice-terminated events.
pub const NoteData = struct {
    /// Sample offset within the current process buffer.
    timing: u32,
    /// Host-assigned voice identifier, or `null` if not provided.
    voice_id: ?i32 = null,
    /// MIDI channel (0–15).
    channel: u8,
    /// MIDI note number (0–127).
    note: u8,
    /// Velocity in the range 0.0–1.0.
    velocity: f32,
};

/// Common data for per-note (polyphonic) value events such as
/// poly pressure, tuning, vibrato, expression, brightness, volume, and pan.
pub const PolyValueData = struct {
    /// Sample offset within the current process buffer.
    timing: u32,
    /// Host-assigned voice identifier, or `null` if not provided.
    voice_id: ?i32 = null,
    /// MIDI channel (0–15).
    channel: u8,
    /// MIDI note number (0–127).
    note: u8,
    /// The value for this event. The range depends on the event kind
    /// (typically 0.0–1.0 for pressure, or semitones for tuning).
    value: f32,
};

/// Data for MIDI CC (control change) events.
pub const MidiCCData = struct {
    /// Sample offset within the current process buffer.
    timing: u32,
    /// MIDI channel (0–15).
    channel: u8,
    /// MIDI CC number (0–127).
    cc: u8,
    /// CC value normalized to 0.0–1.0.
    value: f32,
};

/// Data for channel-wide MIDI events that carry a single value
/// (channel pressure, pitch bend).
pub const MidiChannelData = struct {
    /// Sample offset within the current process buffer.
    timing: u32,
    /// MIDI channel (0–15).
    channel: u8,
    /// The value for this event (0.0–1.0 for pressure,
    /// -1.0–1.0 for pitch bend).
    value: f32,
};

/// Data for MIDI program change events.
pub const MidiProgramData = struct {
    /// Sample offset within the current process buffer.
    timing: u32,
    /// MIDI channel (0–15).
    channel: u8,
    /// Program number (0–127).
    program: u8,
};

/// A single note or MIDI event, unified across CLAP and VST3.
///
/// The wrappers translate format-specific events into this tagged union
/// before passing them to the plugin's `process` function.
pub const NoteEvent = union(enum) {
    // -- Note events --
    /// A note-on event with velocity.
    note_on: NoteData,
    /// A note-off event with release velocity.
    note_off: NoteData,
    /// Abruptly stop a voice (no release phase).
    choke: NoteData,
    /// Sent by the plugin when a voice finishes naturally (output only).
    voice_terminated: NoteData,

    // -- Per-note (polyphonic) expression events --
    /// Per-note aftertouch / poly pressure (0.0–1.0).
    poly_pressure: PolyValueData,
    /// Per-note tuning offset in semitones.
    poly_tuning: PolyValueData,
    /// Per-note vibrato amount (0.0–1.0).
    poly_vibrato: PolyValueData,
    /// Per-note expression amount (0.0–1.0).
    poly_expression: PolyValueData,
    /// Per-note brightness (0.0–1.0).
    poly_brightness: PolyValueData,
    /// Per-note volume/gain (0.0–1.0, linear).
    poly_volume: PolyValueData,
    /// Per-note pan (-1.0 left .. 1.0 right).
    poly_pan: PolyValueData,

    // -- Channel-wide MIDI events --
    /// MIDI Control Change.
    midi_cc: MidiCCData,
    /// MIDI Channel Pressure (aftertouch).
    midi_channel_pressure: MidiChannelData,
    /// MIDI Pitch Bend (-1.0–1.0).
    midi_pitch_bend: MidiChannelData,
    /// MIDI Program Change.
    midi_program_change: MidiProgramData,

    /// Returns the sample offset (timing) of this event within the buffer.
    pub fn timing(self: NoteEvent) u32 {
        return switch (self) {
            inline else => |data| data.timing,
        };
    }

    /// Returns the MIDI channel of this event, or `null` if not applicable.
    pub fn channel(self: NoteEvent) ?u8 {
        return switch (self) {
            .note_on, .note_off, .choke, .voice_terminated => |d| d.channel,
            .poly_pressure, .poly_tuning, .poly_vibrato, .poly_expression, .poly_brightness, .poly_volume, .poly_pan => |d| d.channel,
            .midi_cc => |d| d.channel,
            .midi_channel_pressure, .midi_pitch_bend => |d| d.channel,
            .midi_program_change => |d| d.channel,
        };
    }

    /// Returns the voice ID of this event, or `null` if not applicable.
    pub fn voiceId(self: NoteEvent) ?i32 {
        return switch (self) {
            .note_on, .note_off, .choke, .voice_terminated => |d| d.voice_id,
            .poly_pressure, .poly_tuning, .poly_vibrato, .poly_expression, .poly_brightness, .poly_volume, .poly_pan => |d| d.voice_id,
            .midi_cc, .midi_channel_pressure, .midi_pitch_bend, .midi_program_change => null,
        };
    }

    // Factory functions for event construction

    /// Create a note-on event.
    pub fn noteOn(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, vel: f32) NoteEvent {
        return .{ .note_on = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .velocity = vel } };
    }

    /// Create a note-off event.
    pub fn noteOff(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, vel: f32) NoteEvent {
        return .{ .note_off = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .velocity = vel } };
    }

    /// Create a choke event (abruptly stop a voice).
    pub fn chokeNote(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8) NoteEvent {
        return .{ .choke = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .velocity = 0.0 } };
    }

    /// Create a voice-terminated event (output only).
    pub fn voiceTerminated(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8) NoteEvent {
        return .{ .voice_terminated = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .velocity = 0.0 } };
    }

    /// Create a polyphonic pressure event.
    pub fn polyPressure(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, val: f32) NoteEvent {
        return .{ .poly_pressure = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .value = val } };
    }

    /// Create a polyphonic tuning event.
    pub fn polyTuning(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, val: f32) NoteEvent {
        return .{ .poly_tuning = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .value = val } };
    }

    /// Create a polyphonic vibrato event.
    pub fn polyVibrato(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, val: f32) NoteEvent {
        return .{ .poly_vibrato = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .value = val } };
    }

    /// Create a polyphonic expression event.
    pub fn polyExpression(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, val: f32) NoteEvent {
        return .{ .poly_expression = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .value = val } };
    }

    /// Create a polyphonic brightness event.
    pub fn polyBrightness(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, val: f32) NoteEvent {
        return .{ .poly_brightness = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .value = val } };
    }

    /// Create a polyphonic volume event.
    pub fn polyVolume(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, val: f32) NoteEvent {
        return .{ .poly_volume = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .value = val } };
    }

    /// Create a polyphonic pan event.
    pub fn polyPan(sample_offset: u32, voice_id: ?i32, ch: u8, note_num: u8, val: f32) NoteEvent {
        return .{ .poly_pan = .{ .timing = sample_offset, .voice_id = voice_id, .channel = ch, .note = note_num, .value = val } };
    }

    /// Create a MIDI CC event.
    pub fn midiCC(sample_offset: u32, ch: u8, cc_num: u8, val: f32) NoteEvent {
        return .{ .midi_cc = .{ .timing = sample_offset, .channel = ch, .cc = cc_num, .value = val } };
    }

    /// Create a MIDI channel pressure event.
    pub fn midiChannelPressure(sample_offset: u32, ch: u8, val: f32) NoteEvent {
        return .{ .midi_channel_pressure = .{ .timing = sample_offset, .channel = ch, .value = val } };
    }

    /// Create a MIDI pitch bend event.
    pub fn midiPitchBend(sample_offset: u32, ch: u8, val: f32) NoteEvent {
        return .{ .midi_pitch_bend = .{ .timing = sample_offset, .channel = ch, .value = val } };
    }

    /// Create a MIDI program change event.
    pub fn midiProgramChange(sample_offset: u32, ch: u8, prog: u8) NoteEvent {
        return .{ .midi_program_change = .{ .timing = sample_offset, .channel = ch, .program = prog } };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "NoteEvent timing extraction" {
    const on = NoteEvent{ .note_on = .{
        .timing = 42,
        .channel = 0,
        .note = 60,
        .velocity = 0.8,
    } };
    try std.testing.expectEqual(@as(u32, 42), on.timing());

    const cc = NoteEvent{ .midi_cc = .{
        .timing = 100,
        .channel = 3,
        .cc = 74,
        .value = 0.5,
    } };
    try std.testing.expectEqual(@as(u32, 100), cc.timing());
}

test "NoteEvent channel extraction" {
    const off = NoteEvent{ .note_off = .{
        .timing = 0,
        .channel = 7,
        .note = 64,
        .velocity = 0.0,
    } };
    try std.testing.expectEqual(@as(?u8, 7), off.channel());

    const pb = NoteEvent{ .midi_pitch_bend = .{
        .timing = 10,
        .channel = 2,
        .value = 0.25,
    } };
    try std.testing.expectEqual(@as(?u8, 2), pb.channel());
}

test "NoteEvent voiceId extraction" {
    const on = NoteEvent{ .note_on = .{
        .timing = 0,
        .voice_id = 42,
        .channel = 0,
        .note = 60,
        .velocity = 1.0,
    } };
    try std.testing.expectEqual(@as(?i32, 42), on.voiceId());

    const cc = NoteEvent{ .midi_cc = .{
        .timing = 0,
        .channel = 0,
        .cc = 1,
        .value = 0.0,
    } };
    try std.testing.expectEqual(@as(?i32, null), cc.voiceId());
}

test "NoteEvent voiceId defaults to null" {
    const on = NoteEvent{ .note_on = .{
        .timing = 0,
        .channel = 0,
        .note = 60,
        .velocity = 0.5,
    } };
    try std.testing.expectEqual(@as(?i32, null), on.voiceId());
}
