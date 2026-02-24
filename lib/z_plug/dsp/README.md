# DSP Building Blocks Module

DSP utilities and processors for z-plug plugin authors. This module is located at `src/dsp/` and provides common building blocks for audio processing: utility functions, metering, and spectral processing.

## Overview

The `dsp` module is separate from the core plugin interface (`src/core/`) to clearly distinguish:

- **Core** (`src/core/`): Plugin interface contract (Buffer, Param, NoteEvent, etc.) — the API plugins must implement
- **DSP** (`src/dsp/`): Optional building blocks for plugin authors — utilities they can use but don't have to

Platform constants (`src/core/platform.zig`) remain in `core/` because they're foundational — used by both core types and DSP utilities.

## Module Structure

```
src/dsp/
├── root.zig           # Namespace entry point
├── util/              # Audio DSP utility functions
│   ├── root.zig
│   ├── conversions.zig  # dB/gain, MIDI/freq, time/sample, pitch
│   └── denormals.zig    # Flush-to-zero for denormal handling
├── metering/          # Real-time audio metering
│   ├── root.zig
│   ├── biquad.zig       # Biquad IIR filter (K-weighting)
│   ├── peak.zig         # PeakMeter
│   ├── rms.zig          # RmsMeter
│   ├── true_peak.zig    # TruePeakMeter (ITU-R BS.1770)
│   └── lufs.zig         # LufsMeter (EBU R128)
└── stft/              # STFT spectral processing
    ├── root.zig
    ├── config.zig       # StftConfig, SpectralContext
    ├── fft.zig          # KissFFT C interop
    └── processor.zig    # StftProcessor comptime generic
```

## Usage

All DSP modules are accessed via the `z_plug.dsp.*` namespace:

```zig
const z_plug = @import("z_plug");

// Utility functions
const gain = z_plug.dsp.util.dbToGainFast(-6.0);
const freq = z_plug.dsp.util.midiNoteToFreq(60); // Middle C

// Denormal flushing
const ftz = z_plug.dsp.util.enableFlushToZero();
defer z_plug.dsp.util.restoreFloatMode(ftz);

// Metering
var peak_meter = z_plug.dsp.metering.PeakMeter.init(100.0, 500.0, 48000.0);
peak_meter.process(samples);
const peak_db = peak_meter.readPeakDb();

// STFT processing
const MyEffect = struct {
    pub const UserState = f32; // Per-bin state
    pub const Params = struct { threshold: f32 };
    
    pub fn processBins(
        bins: []z_plug.dsp.stft.Complex,
        magnitudes: []const f32,
        user_state: []f32,
        context: z_plug.dsp.stft.SpectralContext,
        params: Params,
    ) void {
        // Effect-specific spectral processing
    }
};

const stft = z_plug.dsp.stft.StftProcessor(MyEffect, .{
    .fft_size = 1024,
    .hop_size = 256,
    .max_channels = 2,
});
```

### Backward Compatibility

For legacy code, `z_plug.util` and `z_plug.metering` are aliased to `z_plug.dsp.util` and `z_plug.dsp.metering`. New code should use the canonical `z_plug.dsp.*` namespace.

## Modules

### util (Utility Functions)

Zero-cost inline functions for common audio programming tasks:

- **dB/gain conversions**: `dbToGain`, `dbToGainFast`, `gainToDb`, `gainToDbFast`
- **MIDI/frequency**: `midiNoteToFreq`, `freqToMidiNote`
- **Time/sample**: `msToSamples`, `samplesToMs`, `bpmToHz`, `hzToBpm`
- **Pitch**: `semitonesToRatio`, `ratioToSemitones`
- **Denormal flushing**: `enableFlushToZero`, `restoreFloatMode`

All functions are marked `inline` for zero overhead.

### metering (Real-Time Metering)

Real-time-safe meters with pre-allocated buffers (no heap allocations):

- **PeakMeter**: Sample peak with hold and exponential decay
- **RmsMeter**: Running RMS with configurable window
- **TruePeakMeter**: ITU-R BS.1770 true peak via 4x oversampling (12-sample measurement latency)
- **LufsMeter**: Full EBU R128 loudness (momentary, short-term, integrated with gating)

All meters are read-only (no signal modification) and conform to industry standards.

### stft (Spectral Processing)

Comptime-parameterized STFT engine that handles all the plumbing (ring buffers, windowing, KissFFT, overlap-add, SIMD) while letting plugin authors focus on spectral processing logic.

**Key abstractions**:

- `StftProcessor(Effect, config)`: Comptime generic that generates an STFT engine
- `Effect`: User-defined struct with `processBins` callback
- `StftConfig`: FFT size, hop size, max channels (comptime)
- `SpectralContext`: Sample rate, FFT size, hop size, num bins (runtime)

**Effect interface** (comptime duck-typing):

```zig
const MyEffect = struct {
    // Optional: per-bin state type (default: void)
    pub const UserState = f32;
    pub const user_state_default: f32 = 0.0;

    // Optional: parameters passed to processBins (default: void)
    pub const Params = struct {
        threshold: f32,
        gain: f32,
    };

    // Required: process frequency bins in-place
    pub fn processBins(
        bins: []Complex,              // Frequency bins (r+i)
        magnitudes: []const f32,       // Precomputed magnitudes
        user_state: []UserState,       // Per-bin state
        context: SpectralContext,      // FFT metadata
        params: Params,                // User parameters
    ) void {
        // Effect-specific processing
    }
};
```

The STFT module uses KissFFT (BSD-3-Clause, vendored in `vendor/kissfft/`) for real-valued FFTs.

## Dependencies

- **Core**: Platform constants (`src/core/platform.zig`) for SIMD vector types and cache line sizes
- **KissFFT**: C library for FFT operations (used by `stft` module only, lazy compilation)
- **Standard library**: Math functions, memory operations, inline assembly (denormal flushing)

## Design Principles

1. **Real-time safety**: No heap allocations in audio processing paths — all buffers pre-allocated during init
2. **SIMD everywhere**: Platform-adaptive vectorization for windowing, magnitude computation, overlap-add
3. **Comptime generics**: STFT processor uses duck-typing (like `std.mem.Allocator`) for type-safe, zero-cost abstraction
4. **Minimal overhead**: Inline functions, comptime dispatch, lazy compilation

## See Also

- [`src/core/README.md`](../core/README.md) — Core plugin interface module
- [`docs/plugin-authors.md`](../../docs/plugin-authors.md) — Public API guide for plugin authors
- [`examples/spectral.zig`](../../examples/spectral.zig) — Spectral gate example using STFT module
