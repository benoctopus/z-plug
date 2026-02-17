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
const event = z_plug.NoteEvent{ .voice_terminated = .{
    .timing = sample_offset,
    .voice_id = voice_id,
    .channel = 0,
    .note = 60,
    .velocity = 0.0,
}};
_ = context.output_events.push(event);
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
/// Simple gain plugin example for zig-plug.
///
/// This plugin demonstrates the minimal viable plugin:
/// - One FloatParam for gain control (0.0 to 2.0)
/// - Stereo processing
/// - Both CLAP and VST3 support
const z_plug = @import("z_plug");

const GainPlugin = struct {
    // Required metadata
    pub const name: [:0]const u8 = "Zig Gain";
    pub const vendor: [:0]const u8 = "zig-plug";
    pub const url: [:0]const u8 = "https://github.com/example/zig-plug";
    pub const version: [:0]const u8 = "0.1.0";
    pub const plugin_id: [:0]const u8 = "com.zig-plug.gain";
    
    // Audio configuration: stereo in/out
    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO,
    };
    
    // Parameters: one gain parameter with linear smoothing
    pub const params = &[_]z_plug.Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 1.0,
            .range = .{ .min = 0.0, .max = 2.0 },
            .unit = "",
            .flags = .{},
            .smoothing = .{ .linear = 10.0 },  // 10ms linear smoothing
        } },
    };
    
    // No internal state needed for this simple plugin
    
    /// Initialize the plugin with the selected audio layout and buffer config.
    pub fn init(
        _: *@This(),
        _: *const z_plug.AudioIOLayout,
        _: *const z_plug.BufferConfig,
    ) bool {
        return true;
    }
    
    /// Clean up plugin resources.
    pub fn deinit(_: *@This()) void {
        // No cleanup needed
    }
    
    /// Process audio.
    pub fn process(
        _: *@This(),
        buffer: *z_plug.Buffer,
        _: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        const num_samples = buffer.num_samples;
        const num_channels = buffer.channel_data.len;
        
        // Process sample-by-sample to advance smoothing correctly
        var i: usize = 0;
        while (i < num_samples) : (i += 1) {
            // Get the next smoothed gain value (advances smoother by 1 sample)
            const gain = context.nextSmoothed(1, 0);
            
            // Apply gain to all channels for this sample
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

# Install to system directories
./install_plugins.sh

# Sign on macOS (required for most DAWs)
./sign_plugins.sh
```

## Next Steps

- **Architecture details:** See [docs/architecture.md](architecture.md)
- **Module internals:** See `src/*/README.md` files
- **Coding standards:** See [AGENTS.md](../AGENTS.md)
