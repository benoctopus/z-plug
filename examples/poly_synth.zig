/// Polyphonic Synthesizer - Example demonstrating MIDI note handling and voice management.
///
/// Features:
/// - 16-voice polyphony with voice stealing (oldest-first)
/// - 4 waveforms: Sine, Saw, Square, Triangle
/// - ADSR envelope per voice
/// - Per-voice pitch detune
/// - Master gain control
/// - Sample-accurate MIDI note-on/note-off handling
/// - Voice-terminated output events
const z_plug = @import("z_plug");
const std = @import("std");

// Platform-specific SIMD vector length for potential future optimizations
const vec_len = z_plug.platform.SIMD_VEC_LEN;
const F32xN = z_plug.platform.F32xV;

// ---------------------------------------------------------------------------
// Oscillator Functions
// ---------------------------------------------------------------------------

/// Generate sine wave sample from phase [0..1)
inline fn sineOsc(phase: f32) f32 {
    return @sin(phase * std.math.tau);
}

/// Generate sawtooth wave sample from phase [0..1)
inline fn sawOsc(phase: f32) f32 {
    return 2.0 * phase - 1.0;
}

/// Generate square wave sample from phase [0..1)
inline fn squareOsc(phase: f32) f32 {
    return if (phase < 0.5) 1.0 else -1.0;
}

/// Generate triangle wave sample from phase [0..1)
inline fn triangleOsc(phase: f32) f32 {
    return if (phase < 0.5)
        4.0 * phase - 1.0
    else
        3.0 - 4.0 * phase;
}

// ---------------------------------------------------------------------------
// Voice State
// ---------------------------------------------------------------------------

const EnvelopeStage = enum {
    idle,
    attack,
    decay,
    sustain,
    release,
};

const Voice = struct {
    /// Current oscillator phase [0..1)
    phase: f32 = 0.0,
    /// Oscillator frequency in Hz
    freq: f32 = 440.0,
    /// Current envelope level [0..1]
    envelope: f32 = 0.0,
    /// Current ADSR stage
    stage: EnvelopeStage = .idle,
    /// MIDI note number
    note: u8 = 0,
    /// MIDI channel
    channel: u8 = 0,
    /// Note-on velocity [0..1]
    velocity: f32 = 0.0,
    /// Host voice ID (for voice_terminated events)
    voice_id: ?i32 = null,
    /// Age counter for voice stealing (incremented on each note-on)
    age: u32 = 0,

    /// Start a note on this voice
    fn noteOn(self: *Voice, note_num: u8, vel: f32, ch: u8, vid: ?i32, frequency: f32, age_counter: u32) void {
        self.note = note_num;
        self.velocity = vel;
        self.channel = ch;
        self.voice_id = vid;
        self.freq = frequency;
        self.age = age_counter;
        self.stage = .attack;
        self.envelope = 0.0;
        // Keep phase continuous to avoid clicks
    }

    /// Trigger release stage
    fn noteOff(self: *Voice) void {
        if (self.stage != .idle) {
            self.stage = .release;
        }
    }

    /// Kill the voice immediately
    fn kill(self: *Voice) void {
        self.stage = .idle;
        self.envelope = 0.0;
    }

    /// Advance envelope by one sample and return current level
    fn tickEnvelope(
        self: *Voice,
        attack_rate: f32,
        decay_rate: f32,
        sustain_level: f32,
        release_rate: f32,
    ) f32 {
        switch (self.stage) {
            .idle => {
                self.envelope = 0.0;
            },
            .attack => {
                self.envelope += attack_rate;
                if (self.envelope >= 1.0) {
                    self.envelope = 1.0;
                    self.stage = .decay;
                }
            },
            .decay => {
                self.envelope -= decay_rate;
                if (self.envelope <= sustain_level) {
                    self.envelope = sustain_level;
                    self.stage = .sustain;
                }
            },
            .sustain => {
                self.envelope = sustain_level;
            },
            .release => {
                self.envelope -= release_rate;
                if (self.envelope <= 0.0) {
                    self.envelope = 0.0;
                    self.stage = .idle;
                }
            },
        }
        return self.envelope;
    }

    /// Advance oscillator phase by one sample
    fn tickPhase(self: *Voice, sample_rate: f32) void {
        const phase_delta = self.freq / sample_rate;
        self.phase += phase_delta;
        // Wrap phase to [0..1)
        while (self.phase >= 1.0) {
            self.phase -= 1.0;
        }
    }

    /// Check if voice is active (not idle)
    fn isActive(self: *const Voice) bool {
        return self.stage != .idle;
    }
};

// ---------------------------------------------------------------------------
// Plugin
// ---------------------------------------------------------------------------

const PolySynthPlugin = struct {
    /// Voice pool (pre-allocated, real-time safe)
    voices: [16]Voice = [_]Voice{.{}} ** 16,
    /// Sample rate (cached from BufferConfig)
    sample_rate: f32 = 44100.0,
    /// Monotonic age counter for voice stealing
    next_voice_age: u32 = 0,

    // Plugin metadata
    pub const name: [:0]const u8 = "Zig Poly Synth";
    pub const vendor: [:0]const u8 = "z-plug";
    pub const url: [:0]const u8 = "https://github.com/example/z-plug";
    pub const version: [:0]const u8 = "0.1.0";
    pub const plugin_id: [:0]const u8 = "com.z-plug.poly-synth";

    // Audio I/O: No input (instrument), stereo output
    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO_OUT,
    };

    // MIDI configuration: receive note on/off and expression
    pub const midi_input: z_plug.MidiConfig = .basic;

    // Parameters: 7 total
    pub const params = &[_]z_plug.Param{
        // Master gain (dB scale)
        .{ .float = .{
            .name = "Gain",
            .id = "gain_db",
            .default = -6.0,
            .range = .{ .linear = .{ .min = -60.0, .max = 12.0 } },
            .unit = "dB",
            .smoothing = .{ .logarithmic = 50.0 },
        } },

        // Waveform selector
        .{ .choice = .{
            .name = "Waveform",
            .id = "waveform",
            .default = 0,
            .labels = &.{ "Sine", "Saw", "Square", "Triangle" },
        } },

        // ADSR envelope parameters
        .{ .float = .{
            .name = "Attack",
            .id = "attack_ms",
            .default = 10.0,
            .range = .{ .linear = .{ .min = 1.0, .max = 5000.0 } },
            .unit = "ms",
            .smoothing = .{ .linear = 20.0 },
        } },

        .{ .float = .{
            .name = "Decay",
            .id = "decay_ms",
            .default = 100.0,
            .range = .{ .linear = .{ .min = 1.0, .max = 5000.0 } },
            .unit = "ms",
            .smoothing = .{ .linear = 20.0 },
        } },

        .{ .float = .{
            .name = "Sustain",
            .id = "sustain",
            .default = 0.7,
            .range = .{ .linear = .{ .min = 0.0, .max = 1.0 } },
            .unit = "",
            .smoothing = .{ .linear = 20.0 },
        } },

        .{ .float = .{
            .name = "Release",
            .id = "release_ms",
            .default = 200.0,
            .range = .{ .linear = .{ .min = 1.0, .max = 5000.0 } },
            .unit = "ms",
            .smoothing = .{ .linear = 20.0 },
        } },

        // Pitch detune in cents
        .{ .float = .{
            .name = "Detune",
            .id = "detune_cents",
            .default = 0.0,
            .range = .{ .linear = .{ .min = 0.0, .max = 50.0 } },
            .unit = "cents",
            .smoothing = .{ .linear = 10.0 },
        } },
    };

    pub fn init(
        self: *@This(),
        _: *const z_plug.AudioIOLayout,
        config: *const z_plug.BufferConfig,
    ) bool {
        self.sample_rate = config.sample_rate;
        self.next_voice_age = 0;

        // Initialize all voices to idle
        for (&self.voices) |*voice| {
            voice.* = Voice{};
        }

        return true;
    }

    pub fn deinit(_: *@This()) void {
        // No cleanup needed (no allocations)
    }

    pub fn reset(self: *@This()) void {
        // Kill all voices on reset
        for (&self.voices) |*voice| {
            voice.kill();
        }
        self.next_voice_age = 0;
    }

    pub fn process(
        self: *@This(),
        buffer: *z_plug.Buffer,
        _: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        // Enable denormal flushing for performance
        const ftz = z_plug.util.enableFlushToZero();
        defer z_plug.util.restoreFloatMode(ftz);

        const num_samples = buffer.num_samples;
        const left = buffer.getChannel(0);
        const right = buffer.getChannel(1);

        // Clear output buffers
        @memset(left, 0.0);
        @memset(right, 0.0);

        // Read non-smoothed parameters once
        const waveform = context.getChoice(7, 1);

        // Process events and render audio sample-by-sample
        var event_index: usize = 0;
        const events = context.input_events;

        var sample_idx: usize = 0;
        while (sample_idx < num_samples) : (sample_idx += 1) {
            // Process all events at this sample offset
            while (event_index < events.len and events[event_index].timing() == sample_idx) {
                const event = events[event_index];
                self.handleEvent(event, context);
                event_index += 1;
            }

            // Get smoothed parameters for this sample
            const gain_db = context.nextSmoothed(7, 0);
            const attack_ms = context.nextSmoothed(7, 2);
            const decay_ms = context.nextSmoothed(7, 3);
            const sustain = context.nextSmoothed(7, 4);
            const release_ms = context.nextSmoothed(7, 5);
            const detune_cents = context.nextSmoothed(7, 6);

            // Convert parameters to rates (per-sample increments)
            const attack_rate = if (attack_ms > 0.0) 1.0 / z_plug.util.msToSamples(attack_ms, self.sample_rate) else 1.0;
            const decay_rate = if (decay_ms > 0.0) 1.0 / z_plug.util.msToSamples(decay_ms, self.sample_rate) else 1.0;
            const release_rate = if (release_ms > 0.0) 1.0 / z_plug.util.msToSamples(release_ms, self.sample_rate) else 1.0;

            // Render all active voices
            var output_sample: f32 = 0.0;

            for (&self.voices) |*voice| {
                if (!voice.isActive()) continue;

                // Advance envelope
                const env = voice.tickEnvelope(attack_rate, decay_rate, sustain, release_rate);

                // Check if voice finished release
                if (voice.stage == .idle and env == 0.0) {
                    // Send voice_terminated event
                    const term_event = z_plug.NoteEvent.voiceTerminated(
                        @intCast(sample_idx),
                        voice.voice_id,
                        voice.channel,
                        voice.note,
                    );
                    _ = context.output_events.push(term_event);
                    continue;
                }

                // Apply detune to frequency
                const detune_ratio = z_plug.util.semitonesToRatio(detune_cents / 100.0);
                const detuned_freq = voice.freq * detune_ratio;
                voice.freq = detuned_freq;

                // Advance phase
                voice.tickPhase(self.sample_rate);

                // Generate oscillator sample based on waveform choice
                const osc_sample = switch (waveform) {
                    0 => sineOsc(voice.phase),
                    1 => sawOsc(voice.phase),
                    2 => squareOsc(voice.phase),
                    3 => triangleOsc(voice.phase),
                    else => 0.0,
                };

                // Apply envelope and velocity
                output_sample += osc_sample * env * voice.velocity;
            }

            // Apply master gain
            const gain = z_plug.util.dbToGainFast(gain_db);
            const final_sample = output_sample * gain * 0.2; // Scale down for multiple voices

            // Write to stereo output (mono summed to both channels)
            left[sample_idx] = final_sample;
            right[sample_idx] = final_sample;
        }

        // Synth should never be deactivated (infinite tail)
        return z_plug.ProcessStatus{ .keep_alive = {} };
    }

    /// Handle a single MIDI event
    fn handleEvent(self: *@This(), event: z_plug.NoteEvent, _: *z_plug.ProcessContext) void {
        switch (event) {
            .note_on => |data| {
                if (data.velocity > 0.0) {
                    self.allocateVoice(data.note, data.velocity, data.channel, data.voice_id);
                } else {
                    // Velocity 0 is note-off
                    self.releaseVoice(data.note, data.channel, data.voice_id);
                }
            },
            .note_off => |data| {
                self.releaseVoice(data.note, data.channel, data.voice_id);
            },
            .choke => |data| {
                self.chokeVoice(data.note, data.channel, data.voice_id);
            },
            else => {
                // Ignore other events (poly expression, MIDI CC, etc.)
            },
        }
    }

    /// Allocate a voice for a new note
    fn allocateVoice(self: *@This(), note: u8, velocity: f32, channel: u8, voice_id: ?i32) void {
        const freq = z_plug.util.midiNoteToFreq(note);

        // First, try to find an idle voice
        for (&self.voices) |*voice| {
            if (voice.stage == .idle) {
                voice.noteOn(note, velocity, channel, voice_id, freq, self.next_voice_age);
                self.next_voice_age +%= 1; // Wrapping increment
                return;
            }
        }

        // No idle voice found, steal the oldest voice
        var oldest_voice: *Voice = &self.voices[0];
        var oldest_age: u32 = oldest_voice.age;

        for (&self.voices) |*voice| {
            if (voice.age < oldest_age) {
                oldest_age = voice.age;
                oldest_voice = voice;
            }
        }

        oldest_voice.noteOn(note, velocity, channel, voice_id, freq, self.next_voice_age);
        self.next_voice_age +%= 1;
    }

    /// Release a voice (trigger release stage)
    fn releaseVoice(self: *@This(), note: u8, channel: u8, voice_id: ?i32) void {
        for (&self.voices) |*voice| {
            if (voice.note == note and voice.channel == channel) {
                // If voice_id is provided, match it; otherwise match by note+channel
                if (voice_id) |vid| {
                    if (voice.voice_id != vid) continue;
                }
                voice.noteOff();
            }
        }
    }

    /// Choke a voice (kill immediately)
    fn chokeVoice(self: *@This(), note: u8, channel: u8, voice_id: ?i32) void {
        for (&self.voices) |*voice| {
            if (voice.note == note and voice.channel == channel) {
                if (voice_id) |vid| {
                    if (voice.voice_id != vid) continue;
                }
                voice.kill();
            }
        }
    }
};

// Export CLAP entry point
comptime {
    _ = z_plug.ClapEntry(PolySynthPlugin);
}

// Export VST3 factory
comptime {
    _ = z_plug.Vst3Factory(PolySynthPlugin);
}
