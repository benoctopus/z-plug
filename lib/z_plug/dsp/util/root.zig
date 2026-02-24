// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// DSP utility functions module.
///
/// Provides zero-cost utility functions for common audio programming tasks:
/// - dB/gain conversions (with fast variants)
/// - MIDI note/frequency conversions
/// - Time/sample conversions
/// - Pitch/semitone conversions
/// - Denormal flushing for real-time performance
const conversions = @import("conversions.zig");
const denorm = @import("denormals.zig");

// Re-export all constants
pub const minus_infinity_db = conversions.minus_infinity_db;
pub const minus_infinity_gain = conversions.minus_infinity_gain;
pub const ln10_over_20 = conversions.ln10_over_20;
pub const twenty_over_ln10 = conversions.twenty_over_ln10;
pub const note_names = conversions.note_names;

// Re-export all conversion functions
pub const dbToGain = conversions.dbToGain;
pub const dbToGainFast = conversions.dbToGainFast;
pub const gainToDb = conversions.gainToDb;
pub const gainToDbFast = conversions.gainToDbFast;
pub const midiNoteToFreq = conversions.midiNoteToFreq;
pub const midiNoteToFreqF32 = conversions.midiNoteToFreqF32;
pub const freqToMidiNote = conversions.freqToMidiNote;
pub const msToSamples = conversions.msToSamples;
pub const samplesToMs = conversions.samplesToMs;
pub const bpmToHz = conversions.bpmToHz;
pub const hzToBpm = conversions.hzToBpm;
pub const semitonesToRatio = conversions.semitonesToRatio;
pub const ratioToSemitones = conversions.ratioToSemitones;

// Re-export denormal flushing
pub const FloatMode = denorm.FloatMode;
pub const enableFlushToZero = denorm.enableFlushToZero;
pub const restoreFloatMode = denorm.restoreFloatMode;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
