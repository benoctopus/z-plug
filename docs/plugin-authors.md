# Plugin Author's Guide

This guide shows how to write audio plugins using zig-plug. For architecture details, see [docs/architecture.md](architecture.md).

## Minimal Plugin Example

A zig-plug plugin is a struct with well-known declarations. The framework validates these at compile time using the `Plugin(T)` function.

```zig
const z_plug = @import("z_plug");

pub const MyPlugin = struct {
    // -- Required metadata (comptime constants) --
    pub const name: [:0]const u8 = "My Plugin";
    pub const vendor: [:0]const u8 = "My Company";
    pub const url: [:0]const u8 = "https://example.com";
    pub const version: [:0]const u8 = "1.0.0";
    pub const plugin_id: [:0]const u8 = "com.example.myplugin";

    // -- Audio I/O layouts --
    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO,
    };

    // -- Parameters (empty for now) --
    pub const params = &[_]z_plug.Param{};

    // -- Plugin state --
    gain: f32,

    // -- Lifecycle functions --

    pub fn init(
        self: *MyPlugin,
        layout: *const z_plug.AudioIOLayout,
        config: *const z_plug.BufferConfig,
    ) bool {
        _ = layout;
        _ = config;
        self.gain = 1.0;
        return true;
    }

    pub fn deinit(self: *MyPlugin) void {
        _ = self;
        // Clean up resources if needed
    }

    pub fn process(
        self: *MyPlugin,
        buffer: *z_plug.Buffer,
        aux: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        _ = aux;
        _ = context;

        // Process audio: apply gain to all channels
        const num_channels = buffer.channel_data.len;
        var ch: usize = 0;
        while (ch < num_channels) : (ch += 1) {
            const channel = buffer.channel_data[ch];
            for (channel) |*sample| {
                sample.* *= self.gain;
            }
        }

        return z_plug.ProcessStatus.ok();
    }
};

// Export CLAP entry point
comptime {
    _ = z_plug.ClapEntry(MyPlugin);
}

// Export VST3 factory
comptime {
    _ = z_plug.Vst3Factory(MyPlugin);
}
```

### Required Declarations

Every plugin struct must declare:

| Declaration | Type | Description |
|-------------|------|-------------|
| `name` | `[:0]const u8` | Human-readable plugin name |
| `vendor` | `[:0]const u8` | Vendor/company name |
| `url` | `[:0]const u8` | Plugin or vendor website |
| `version` | `[:0]const u8` | Semantic version string |
| `plugin_id` | `[:0]const u8` | Unique ID (reverse-DNS style) |
| `audio_io_layouts` | `[]const AudioIOLayout` | Supported channel configurations |
| `params` | `[]const Param` | Parameter declarations |
| `init` | Function | Initialize plugin with layout and config |
| `deinit` | Function | Clean up resources |
| `process` | Function | Process audio buffers |

### Optional Declarations

| Declaration | Type | Default | Description |
|-------------|------|---------|-------------|
| `midi_input` | `MidiConfig` | `.none` | Note/MIDI input configuration |
| `midi_output` | `MidiConfig` | `.none` | Note/MIDI output configuration |
| `state_version` | `u32` | `1` | State format version for migration |
| `reset` | Function | no-op | Clear internal state (e.g., delay lines) |
| `save` | Function | no-op | Save plugin state to stream |
| `load` | Function | no-op | Load plugin state from stream |

## Building and Exporting Plugins

To make your plugin available to hosts, you must export both CLAP and VST3 entry points using comptime blocks at the end of your plugin file:

```zig
// Export CLAP entry point
comptime {
    _ = z_plug.ClapEntry(YourPlugin);
}

// Export VST3 factory
comptime {
    _ = z_plug.Vst3Factory(YourPlugin);
}
```

These comptime blocks generate the necessary C ABI symbols (`clap_entry` and `GetPluginFactory`) that DAW hosts use to load your plugin.

## Declaring Parameters

Parameters are declared as a comptime array of `Param` values:

```zig
pub const params = &[_]z_plug.Param{
    .{ .float = .{
        .name = "Gain",
        .id = "gain",
        .default = 0.0,  // dB
        .range = .{ .linear = .{ .min = -24.0, .max = 24.0 } },
        .unit = "dB",
        .smoothing = .{ .linear = 10.0 },  // 10ms linear smoothing
    }},
    .{ .boolean = .{
        .name = "Bypass",
        .id = "bypass",
        .default = false,
        .flags = .{ .bypass = true },
    }},
    .{ .choice = .{
        .name = "Mode",
        .id = "mode",
        .default = 0,
        .labels = &.{ "Clean", "Warm", "Vintage" },
    }},
};
```

### Parameter Types

- **`FloatParam`** — Continuous floating-point (e.g., gain, frequency, mix)
- **`IntParam`** — Discrete integer (e.g., semitones, sample count)
- **`BoolParam`** — Boolean toggle (e.g., bypass, invert polarity)
- **`ChoiceParam`** — Enum/choice from a list of labels

### Parameter IDs

The `id` field must be a **stable string**. It's used to:
- Generate a stable hash for VST3 `ParamID`
- Identify parameters in state save/load
- **Never change IDs after releasing a plugin** — it breaks presets and automation

### Parameter Ranges

Float parameters support two range types:

```zig
// Linear range (uniform distribution across the knob)
.range = .{ .linear = .{ .min = -24.0, .max = 24.0 } },

// Logarithmic range (for frequency, gain — perceptually uniform)
.range = .{ .logarithmic = .{ .min = 20.0, .max = 20000.0 } },
```

Use `.logarithmic` for parameters where human perception is logarithmic (frequency, gain in dB). The framework handles normalization/unnormalization in log space automatically.

### Parameter Smoothing

Float parameters support automatic smoothing to prevent audio artifacts when values change. Add a `smoothing` field to enable:

```zig
.{ .float = .{
    .name = "Cutoff",
    .id = "cutoff",
    .default = 1000.0,
    .range = .{ .logarithmic = .{ .min = 20.0, .max = 20000.0 } },
    .smoothing = .{ .logarithmic = 10.0 },  // 10ms logarithmic smoothing
}}
```

Available smoothing styles:
- **`.linear`** — Linear ramp over N milliseconds
- **`.exponential`** — Exponential smoothing (single-pole IIR) over N milliseconds
- **`.logarithmic`** — Logarithmic interpolation over N milliseconds (smooths in log space, producing exponential curves in linear space — ideal for frequency sweeps and gain changes)
- **`.none`** — No smoothing (instant value changes)

To use smoothed values in your `process` function, call `context.nextSmoothed()` for each sample:

```zig
pub fn process(
    self: *MyPlugin,
    buffer: *z_plug.Buffer,
    aux: *z_plug.AuxBuffers,
    context: *z_plug.ProcessContext,
) z_plug.ProcessStatus {
    var i: usize = 0;
    while (i < buffer.num_samples) : (i += 1) {
        // Get smoothed parameter value (advances smoother by 1 sample)
        const cutoff = context.nextSmoothed(1, 0);  // (N params, param index)
        
        // Use the smoothed value in your DSP
        self.filter.setCutoff(cutoff);
        // ... process audio ...
    }
    return z_plug.ProcessStatus.ok();
}
```

## Processing Audio

The `process` function receives three arguments:

```zig
pub fn process(
    self: *MyPlugin,
    buffer: *z_plug.Buffer,
    aux: *z_plug.AuxBuffers,
    context: *z_plug.ProcessContext,
) z_plug.ProcessStatus {
    // ...
}
```

### Buffer Access Patterns

**1. Raw slice access** (most direct):

```zig
const num_channels = buffer.channel_data.len;
var ch: usize = 0;
while (ch < num_channels) : (ch += 1) {
    const channel = buffer.channel_data[ch];
    for (channel) |*sample| {
        sample.* *= self.gain;
    }
}
```

**2. Per-sample iteration** (convenient for per-sample SIMD):

```zig
var iter = buffer.iterSamples();
while (iter.next()) |cs| {
    const left = cs.samples[0];
    const right = cs.samples[1];
    cs.samples[0] = left * self.gain;
    cs.samples[1] = right * self.gain;
}
```

**3. Per-block iteration** (for FFT, convolution):

```zig
var iter = buffer.iterBlocks(64);
while (iter.next()) |entry| {
    processBlock(entry.offset, entry.block);
}
```

### ProcessContext API

The `ProcessContext` provides access to transport, events, and parameters:

```zig
pub const ProcessContext = struct {
    transport: Transport,            // Playback state, tempo, timeline
    input_events: []const NoteEvent, // Pre-sorted by timing
    output_events: *EventOutputList, // For sending events to host
    sample_rate: f32,
    
    // Parameter access methods:
    pub fn getFloat(comptime N: usize, comptime index: usize) f32;
    pub fn getInt(comptime N: usize, comptime index: usize) i32;
    pub fn getBool(comptime N: usize, comptime index: usize) bool;
    pub fn getChoice(comptime N: usize, comptime index: usize) u32;
    pub fn nextSmoothed(comptime N: usize, comptime index: usize) f32;
};
```

**Accessing parameter values:**

```zig
// Get current float parameter value (in plain units)
const gain = context.getFloat(1, 0);  // N=1 param, index=0

// Get next smoothed sample (advances smoother)
const smoothed_gain = context.nextSmoothed(1, 0);

// Get boolean parameter
const bypass = context.getBool(2, 1);  // N=2 params, index=1

// Get choice parameter index
const mode = context.getChoice(3, 2);  // N=3 params, index=2
```

### Transport and Events

**Handling note events:**

```zig
for (context.input_events) |event| {
    switch (event) {
        .note_on => |data| {
            // data.timing, data.channel, data.note, data.velocity
            self.startVoice(data.note, data.velocity);
        },
        .note_off => |data| {
            self.stopVoice(data.note);
        },
        else => {},
    }
}
```

**Sending output events:**

```zig
// Voice finished naturally, send note-off to host
// NoteEvent provides factory functions for all event types:
const event = z_plug.NoteEvent.voiceTerminated(sample_offset, voice_id, 0, 60, 0.0);
_ = context.output_events.push(event);

// Other factory functions: noteOn, noteOff, chokeNote, polyPressure,
// polyTuning, polyVibrato, polyExpression, polyBrightness, polyVolume,
// polyPan, midiCC, midiChannelPressure, midiPitchBend, midiProgramChange
```

### ProcessStatus

Return a status from `process` to inform the host:

```zig
return z_plug.ProcessStatus.ok();           // Normal processing
return z_plug.ProcessStatus.silence;         // Output is silent
return .{ .tail = 44100 };                   // Reverb tail (N samples)
return z_plug.ProcessStatus.keep_alive;      // Infinite tail (oscillator)
return z_plug.ProcessStatus.failed("Error"); // Processing error
```

## State Persistence

Implement `save` and `load` for preset persistence:

```zig
pub fn save(self: *MyPlugin, ctx: z_plug.SaveContext) bool {
    ctx.write(f32, self.gain) catch return false;
    ctx.writeString(self.name) catch return false;
    return true;
}

pub fn load(self: *MyPlugin, ctx: z_plug.LoadContext) bool {
    self.gain = ctx.read(f32) catch return false;
    
    // Use an allocator for dynamic data
    const allocator = std.heap.page_allocator;
    const name = ctx.readString(allocator) catch return false;
    defer allocator.free(name);
    
    // Or use a fixed buffer
    var buffer: [256]u8 = undefined;
    const name_slice = ctx.readStringBounded(&buffer) catch return false;
    _ = name_slice;
    
    return true;
}
```

The framework writes a header (magic bytes + version) before calling your `save` function. On `load`, it validates the header and passes the version to your function for migration.

## Audio I/O Layouts

Declare the channel configurations your plugin supports:

```zig
pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
    // Stereo in/out
    z_plug.AudioIOLayout.STEREO,
    
    // Mono in/out
    z_plug.AudioIOLayout.MONO,
    
    // No input (instrument/synth)
    z_plug.AudioIOLayout.STEREO_OUT,
    
    // Custom layout with aux buses
    .{
        .main_input_channels = 2,
        .main_output_channels = 2,
        .aux_input_ports = &.{2},  // One stereo sidechain input
        .name = "Stereo + Sidechain",
    },
};
```

The host picks the first layout it can satisfy. Order them from most preferred to least preferred.

## MIDI Configuration

Control what note/MIDI events your plugin receives:

```zig
pub const midi_input = z_plug.MidiConfig.basic;      // Note on/off/expression
pub const midi_input = z_plug.MidiConfig.midi_cc;    // Also MIDI CC/pitch bend
pub const midi_output = z_plug.MidiConfig.basic;     // Send note events to host
```

## Audio Utilities

The `z_plug.util` module provides common DSP utility functions:

```zig
const util = z_plug.util;

// dB/gain conversions (with -100 dB floor clamping)
const gain = util.dbToGain(db_value);       // precise
const gain_fast = util.dbToGainFast(db_value); // fast approximation
const db = util.gainToDb(gain_value);

// MIDI note/frequency conversions
const freq = util.midiNoteToFreq(69);       // 440.0 Hz (A4)
const note = util.freqToMidiNote(440.0);    // 69

// Time conversions
const samples = util.msToSamples(10.0, sample_rate);
const ms = util.samplesToMs(480, sample_rate);
const hz = util.bpmToHz(120.0);

// Pitch utilities
const ratio = util.semitonesToRatio(12.0);  // 2.0 (one octave up)

// Denormal flushing (important for filters and feedback loops)
const saved = util.enableFlushToZero();
defer util.restoreFloatMode(saved);
// ... DSP code runs with denormals flushed to zero ...
```

### Platform Constants

The `z_plug.platform` module provides platform-adaptive constants:

```zig
// Cache line size (128 bytes on aarch64/Apple Silicon, 64 bytes on x86_64)
const cache_line = z_plug.CACHE_LINE_SIZE;

// Optimal SIMD vector length for f32 (4 on NEON, 8 on AVX2, 16 on AVX-512)
const vec_len = z_plug.SIMD_VEC_LEN;

// Platform-optimal f32 SIMD vector type
const F32xV = z_plug.F32xV;
```

See `examples/super_gain.zig` for a complete example using SIMD, denormal flushing, and block-based processing.

## Real-Time Safety Rules

Code in `process` must never:
- Call allocators (`std.heap.*`, `page_allocator`)
- Acquire locks or mutexes
- Perform I/O (files, logging, network)
- Make blocking syscalls
- Loop unboundedly over dynamic data

**Pre-allocate everything in `init`:**

```zig
pub fn init(self: *MyPlugin, ...) bool {
    self.delay_buffer = allocator.alloc(f32, 96000) catch return false;
    return true;
}

pub fn deinit(self: *MyPlugin) void {
    allocator.free(self.delay_buffer);
}
```

For background work (sample loading, GUI updates), use a separate thread and communicate via lock-free structures (atomic queues, ring buffers).

## Complete Example: Gain Plugin

This is the complete, working gain plugin from `examples/gain.zig` that loads and runs in DAWs:

```zig
/// Simple gain plugin example for z-plug.
///
/// Demonstrates the minimal viable plugin: one dB-scale gain parameter,
/// stereo processing, and both CLAP and VST3 support.
///
/// For a more complete example with stereo width, SIMD, channel routing,
/// and denormal flushing, see examples/super_gain.zig.
const z_plug = @import("z_plug");

const GainPlugin = struct {
    pub const name: [:0]const u8 = "Zig Gain";
    pub const vendor: [:0]const u8 = "zig-plug";
    pub const url: [:0]const u8 = "https://github.com/example/zig-plug";
    pub const version: [:0]const u8 = "0.1.0";
    pub const plugin_id: [:0]const u8 = "com.zig-plug.gain";

    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO,
    };

    pub const params = &[_]z_plug.Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 0.0,
            .range = .{ .linear = .{ .min = -60.0, .max = 24.0 } },
            .unit = "dB",
            .smoothing = .{ .logarithmic = 50.0 },
        } },
    };

    pub fn init(_: *@This(), _: *const z_plug.AudioIOLayout, _: *const z_plug.BufferConfig) bool {
        return true;
    }

    pub fn deinit(_: *@This()) void {}

    pub fn process(
        _: *@This(),
        buffer: *z_plug.Buffer,
        _: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        const num_samples = buffer.num_samples;
        const num_channels = buffer.channel_data.len;

        var i: usize = 0;
        while (i < num_samples) : (i += 1) {
            const gain = z_plug.util.dbToGainFast(context.nextSmoothed(1, 0));

            for (buffer.channel_data[0..num_channels]) |channel| {
                channel[i] *= gain;
            }
        }

        return z_plug.ProcessStatus.ok();
    }
};

// Export CLAP entry point
comptime {
    _ = z_plug.ClapEntry(GainPlugin);
}

// Export VST3 factory
comptime {
    _ = z_plug.Vst3Factory(GainPlugin);
}
```

Build and install:

```bash
# Build the plugin
zig build

# Install to user directories (automatically signs on macOS)
zig build install-plugins

# Install to system directories (requires sudo, automatically signs on macOS)
zig build install-plugins -Dsystem=true
```

## Next Steps

- **Architecture details:** See [docs/architecture.md](architecture.md)
- **Module internals:** See `src/*/README.md` files
- **Coding standards:** See [AGENTS.md](../AGENTS.md)
