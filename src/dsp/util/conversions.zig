// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Audio parameter conversion functions: dB/gain, MIDI/frequency, time/sample, pitch.
///
/// All functions are marked `inline` for optimal performance in audio processing loops.
const std = @import("std");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Threshold for treating dB values as minus infinity (silent).
pub const minus_infinity_db: f32 = -100.0;

/// Gain value equivalent to -100 dB (10^(-100/20) ≈ 1e-5).
/// Used as a floor to prevent log(0) when converting gain to dB.
pub const minus_infinity_gain: f32 = 1e-5;

/// Precomputed constant: ln(10) / 20 for fast dB to gain conversion.
pub const ln10_over_20: f32 = std.math.ln10 / 20.0;

/// Precomputed constant: 20 / ln(10) for fast gain to dB conversion.
pub const twenty_over_ln10: f32 = 20.0 / std.math.ln10;

/// Note names for the 12 chromatic pitches.
pub const note_names = [_][]const u8{
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
};

// ---------------------------------------------------------------------------
// dB / Gain Conversions
// ---------------------------------------------------------------------------

/// Convert decibels to voltage gain ratio.
/// Values at or below -100 dB are clamped to 0.0 (silence).
///
/// Formula: gain = 10^(dB/20)
///
/// This uses `std.math.pow` which is precise but may be slower than the fast variant.
pub inline fn dbToGain(db: f32) f32 {
    if (db <= minus_infinity_db) return 0.0;
    return std.math.pow(f32, 10.0, db * 0.05);
}

/// Fast approximation of dB to gain conversion using natural exponential.
/// Does not clamp to 0.0 for very negative values.
///
/// Formula: gain ≈ e^(dB * ln(10)/20)
///
/// This is faster than `dbToGain` but may produce small non-zero values for very negative dB.
/// Suitable for inner loops where input range is known to be reasonable.
pub inline fn dbToGainFast(db: f32) f32 {
    return @exp(db * ln10_over_20);
}

/// Convert voltage gain ratio to decibels.
/// Non-positive gains are clamped to -100 dB.
///
/// Formula: dB = 20 * log₁₀(gain)
///
/// Uses natural log with conversion factor since Zig doesn't have @log10 builtin.
pub inline fn gainToDb(gain: f32) f32 {
    const clamped = @max(gain, minus_infinity_gain);
    return @log(clamped) * (20.0 * std.math.log10e);
}

/// Fast approximation of gain to dB conversion using natural logarithm.
///
/// Formula: dB ≈ 20 * ln(gain) / ln(10)
///
/// Slightly faster than `gainToDb` due to precomputed constant.
pub inline fn gainToDbFast(gain: f32) f32 {
    const clamped = @max(gain, minus_infinity_gain);
    return @log(clamped) * twenty_over_ln10;
}

// ---------------------------------------------------------------------------
// MIDI Note / Frequency Conversions
// ---------------------------------------------------------------------------

/// Convert MIDI note number (0-127) to frequency in Hz.
/// Uses equal temperament with A4 (note 69) = 440 Hz.
pub inline fn midiNoteToFreq(note: u8) f32 {
    return midiNoteToFreqF32(@floatFromInt(note));
}

/// Convert fractional MIDI note number to frequency in Hz.
/// Supports fractional notes for cents/pitch bend.
///
/// Formula: freq = 440 * 2^((note - 69) / 12)
pub inline fn midiNoteToFreqF32(note: f32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (note - 69.0) / 12.0);
}

/// Convert frequency in Hz to fractional MIDI note number.
/// Returns fractional value for cents precision.
///
/// Formula: note = 69 + 12 * log₂(freq / 440)
pub inline fn freqToMidiNote(freq: f32) f32 {
    const log2_ratio = @log(freq / 440.0) * std.math.log2e;
    return 69.0 + 12.0 * log2_ratio;
}

// ---------------------------------------------------------------------------
// Time Conversions
// ---------------------------------------------------------------------------

/// Convert milliseconds to sample count at the given sample rate.
pub inline fn msToSamples(ms: f32, sample_rate: f32) f32 {
    return ms * sample_rate / 1000.0;
}

/// Convert sample count to milliseconds at the given sample rate.
pub inline fn samplesToMs(samples: f32, sample_rate: f32) f32 {
    return samples * 1000.0 / sample_rate;
}

/// Convert beats per minute (BPM) to frequency in Hz.
/// Useful for syncing LFOs to tempo.
pub inline fn bpmToHz(bpm: f32) f32 {
    return bpm / 60.0;
}

/// Convert frequency in Hz to beats per minute (BPM).
pub inline fn hzToBpm(hz: f32) f32 {
    return hz * 60.0;
}

// ---------------------------------------------------------------------------
// Pitch Utilities
// ---------------------------------------------------------------------------

/// Convert semitone offset to frequency ratio.
///
/// Formula: ratio = 2^(semitones / 12)
///
/// Example: 12 semitones = octave up = ratio of 2.0
pub inline fn semitonesToRatio(semitones: f32) f32 {
    return std.math.pow(f32, 2.0, semitones / 12.0);
}

/// Convert frequency ratio to semitone offset.
///
/// Formula: semitones = 12 * log₂(ratio)
///
/// Example: ratio of 2.0 = 12 semitones (octave)
pub inline fn ratioToSemitones(ratio: f32) f32 {
    return 12.0 * @log(ratio) * std.math.log2e;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dbToGain edge cases" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dbToGain(-100.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dbToGain(-200.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dbToGain(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), dbToGain(6.0206), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), dbToGain(-6.0206), 1e-3);
}

test "gainToDb edge cases" {
    try std.testing.expectApproxEqAbs(minus_infinity_db, gainToDb(0.0), 0.1); // Allow small error due to clamping
    try std.testing.expectApproxEqAbs(minus_infinity_db, gainToDb(-1.0), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), gainToDb(1.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0206), gainToDb(2.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -6.0206), gainToDb(0.5), 1e-3);
}

test "dB/gain roundtrip" {
    const test_dbs = [_]f32{ -50.0, -24.0, -12.0, -6.0, 0.0, 6.0, 12.0, 24.0 };
    for (test_dbs) |db| {
        const gain = dbToGain(db);
        const back = gainToDb(gain);
        try std.testing.expectApproxEqAbs(db, back, 1e-3);
    }
}

test "dbToGainFast vs dbToGain accuracy" {
    const test_dbs = [_]f32{ -50.0, -24.0, -12.0, -6.0, 0.0, 6.0, 12.0 };
    for (test_dbs) |db| {
        const precise = dbToGain(db);
        const fast = dbToGainFast(db);
        try std.testing.expectApproxEqAbs(precise, fast, precise * 0.01); // 1% tolerance
    }
}

test "gainToDbFast vs gainToDb accuracy" {
    const test_gains = [_]f32{ 0.1, 0.5, 1.0, 2.0, 4.0, 10.0 };
    for (test_gains) |gain| {
        const precise = gainToDb(gain);
        const fast = gainToDbFast(gain);
        try std.testing.expectApproxEqAbs(precise, fast, 0.01); // 0.01 dB tolerance
    }
}

test "midiNoteToFreq standard notes" {
    try std.testing.expectApproxEqAbs(@as(f32, 440.0), midiNoteToFreq(69), 1e-3); // A4
    try std.testing.expectApproxEqAbs(@as(f32, 261.63), midiNoteToFreq(60), 1e-2); // Middle C
    try std.testing.expectApproxEqAbs(@as(f32, 880.0), midiNoteToFreq(81), 1e-3); // A5
}

test "freqToMidiNote standard frequencies" {
    try std.testing.expectApproxEqAbs(@as(f32, 69.0), freqToMidiNote(440.0), 1e-3); // A4
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), freqToMidiNote(261.63), 1e-2); // Middle C
    try std.testing.expectApproxEqAbs(@as(f32, 81.0), freqToMidiNote(880.0), 1e-3); // A5
}

test "MIDI note/freq roundtrip" {
    const test_notes = [_]f32{ 30.0, 45.0, 60.0, 69.0, 81.0, 96.0, 110.0 };
    for (test_notes) |note| {
        const freq = midiNoteToFreqF32(note);
        const back = freqToMidiNote(freq);
        try std.testing.expectApproxEqAbs(note, back, 1e-3);
    }
}

test "semitonesToRatio standard intervals" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), semitonesToRatio(12.0), 1e-6); // Octave up
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), semitonesToRatio(-12.0), 1e-6); // Octave down
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), semitonesToRatio(0.0), 1e-6); // Unison
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), semitonesToRatio(7.0), 1e-2); // Perfect fifth
}

test "ratioToSemitones standard intervals" {
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), ratioToSemitones(2.0), 1e-6); // Octave up
    try std.testing.expectApproxEqAbs(@as(f32, -12.0), ratioToSemitones(0.5), 1e-6); // Octave down
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), ratioToSemitones(1.0), 1e-6); // Unison
}

test "semitone/ratio roundtrip" {
    const test_semitones = [_]f32{ -24.0, -12.0, -7.0, 0.0, 5.0, 7.0, 12.0, 24.0 };
    for (test_semitones) |semitones| {
        const ratio = semitonesToRatio(semitones);
        const back = ratioToSemitones(ratio);
        try std.testing.expectApproxEqAbs(semitones, back, 1e-4);
    }
}

test "msToSamples conversion" {
    try std.testing.expectApproxEqAbs(@as(f32, 44100.0), msToSamples(1000.0, 44100.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 48000.0), msToSamples(1000.0, 48000.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 441.0), msToSamples(10.0, 44100.0), 1e-6);
}

test "samplesToMs conversion" {
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), samplesToMs(44100.0, 44100.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), samplesToMs(48000.0, 48000.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), samplesToMs(441.0, 44100.0), 1e-6);
}

test "bpmToHz conversion" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), bpmToHz(120.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bpmToHz(60.0), 1e-6);
}

test "hzToBpm conversion" {
    try std.testing.expectApproxEqAbs(@as(f32, 120.0), hzToBpm(2.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), hzToBpm(1.0), 1e-6);
}
