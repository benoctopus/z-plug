# Architecture

This document provides a practical overview of how zig-plug's components fit together.

## Four-Layer Design

zig-plug follows a layered architecture inspired by [nih-plug](https://github.com/robbert-vdh/nih-plug):

```
┌──────────────────────────────────────────────┐
│          Plugin Author Code                  │
│   (Your plugin: struct with declarations)    │
├──────────────────────────────────────────────┤
│          Framework Core + DSP                │
│   Core: Plugin, Buffer, NoteEvent, Param    │
│   DSP: util, metering, stft (optional)      │
├───────────────────┬──────────────────────────┤
│   CLAP Wrapper    │     VST3 Wrapper         │
│  (C struct ABI)   │  (COM vtable ABI)        │
├───────────────────┴──────────────────────────┤
│          Low-Level Bindings                  │
│   CLAP bindings      VST3 C API bindings     │
└──────────────────────────────────────────────┘
```

### Layer Responsibilities

**1. Plugin Author Code** (`examples/`, user code)
- Defines a plugin struct with well-known declarations (`name`, `vendor`, `params`, `init`, `process`, etc.)
- Never imports or references CLAP or VST3 types directly
- Uses only framework core types from `@import("z_plug")`

**2. Framework Core** (`src/core/`) + **DSP Building Blocks** (`src/dsp/`)
- **Core**: API-agnostic abstractions: `Plugin(T)`, `Buffer`, `NoteEvent`, `Param`, etc.
  - Comptime validation of plugin structs
  - Zero-copy buffer wrappers, lock-free parameter storage
  - Platform constants (`platform.zig`): cache line size, optimal SIMD vector length
  - **No format-specific code allowed in this layer**
- **DSP**: Optional utilities for plugin authors (accessed via `z_plug.dsp.*`):
  - `util`: dB/gain, MIDI/frequency, time conversions, denormal flushing
  - `metering`: PeakMeter, RmsMeter, TruePeakMeter, LufsMeter (ITU-R BS.1770, EBU R128)
  - `stft`: Comptime-parameterized STFT processor for spectral effects (uses KissFFT)
  - Dependency direction: `dsp/ --> core/platform.zig` (one-way, no circular deps)

**3. Format Wrappers** (`src/wrappers/clap/`, `src/wrappers/vst3/`, `src/wrappers/common.zig`)
- Translate between framework core and format-specific ABIs
- CLAP wrapper: implements `clap_plugin` with function pointers
- VST3 wrapper: implements COM interfaces (`IComponent`, `IAudioProcessor`, `IEditController`)
- Shared utilities (`common.zig`): in-place buffer copy, ProcessContext construction, parameter normalization helpers
- Handles format-specific lifecycle, parameter sync, event translation

**4. Low-Level Bindings** (`src/bindings/clap/`, `src/bindings/vst3/`)
- Thin, idiomatic Zig translations of C APIs
- CLAP: `extern struct` definitions matching the CLAP 1.2.2 spec
- VST3: hand-written bindings for the VST3 C API
- **No framework logic — pure ABI translation**

## Data Flow: Audio Processing

During a `process` call, data flows through the layers like this:

```
Host calls format-specific entry point
  ↓
Wrapper receives format-specific process data
  (CLAP: clap_process_t, VST3: ProcessData*)
  ↓
Wrapper translates to framework types:
  - Copy buffer pointers → Buffer
  - Translate events → []NoteEvent
  - Build ProcessContext
  ↓
Framework core: plugin.process(buffer, aux, context)
  ↓
Plugin author code manipulates buffer and events
  ↓
Wrapper translates output events back to format
  ↓
Return to host
```

**Key principle:** Audio data is never copied. The `Buffer` struct contains pointers into the host's memory. Wrappers only copy pointers, not samples.

## Key Design Decisions

### Comptime Duck-Typing

The `Plugin(comptime T)` function validates plugin structs at compile time using `@hasDecl` and `@TypeOf` checks:

```zig
const MyPlugin = struct {
    pub const name: [:0]const u8 = "My Plugin";
    pub const vendor: [:0]const u8 = "My Company";
    // ... required declarations ...
    pub fn process(self: *MyPlugin, buffer: *Buffer, ...) ProcessStatus {
        // ...
    }
};

// Framework validates and wraps at comptime:
const P = Plugin(MyPlugin);
```

This provides:
- Compile-time validation with clear error messages
- Zero runtime overhead (monomorphization)
- No vtables or dynamic dispatch on the audio thread

### Zero-Copy Buffers

`Buffer` wraps the host's audio data as `[][]f32` (channels × samples) without copying:

```zig
pub const Buffer = struct {
    channel_data: [][]f32,  // Points into host memory
    num_samples: usize,
    // ...
};
```

The wrappers populate `channel_data` with pointers from the format-specific structures (`clap_audio_buffer_t`, `AudioBusBuffers`).

### Lock-Free Parameters

Parameter values are stored in atomic variables for thread-safe access between the main thread and audio thread:

```zig
pub fn ParamValues(comptime N: usize) type {
    return struct {
        values: [N]std.atomic.Value(f32),
        // ...
    };
}
```

No locks are ever acquired on the audio thread. Main thread writes with `.store()`, audio thread reads with `.load()`.

### O(log N) Parameter Lookup

Parameter ID lookups use a comptime-generated binary search table on the `Plugin` type. Both wrappers call `P.findParamIndex()` for O(log N) lookups instead of linear scans, avoiding O(N*M) per process block when translating parameter change events.

### Cache-Line Optimization

Wrapper structs are laid out for CPU cache efficiency:
- Hot audio data (buffers, parameter values) is grouped first
- `ref_count` sits on a separate cache line (`align(CACHE_LINE_SIZE)`) to prevent false sharing
- Cold data (vtables, controller state) is placed last
- `SmootherBank` and `ParamValues` arrays are cache-line aligned

### Event Translation

Both CLAP and VST3 have different event representations. The wrappers translate these to a unified `NoteEvent` tagged union before passing to the plugin:

- CLAP events → `NoteEvent` (wrapper pre-sorts by timing)
- VST3 `IEventList` → `NoteEvent` (wrapper iterates and translates)

The `NoteEvent` type provides factory functions (`noteOn`, `noteOff`, `chokeNote`, `polyPressure`, `midiCC`, etc.) used by both wrappers to construct events uniformly, reducing code duplication.

The plugin sees a simple `[]const NoteEvent` slice, agnostic of the underlying format.

## Module Relationships

- `src/root.zig` re-exports types from `src/core/` and `src/dsp/` for plugin authors
- `src/dsp/` modules import `src/core/platform.zig` for SIMD constants (one-way dependency)
- `src/core/` modules import each other (e.g., `plugin.zig` imports `buffer.zig`, `events.zig`, `params.zig`)
- `src/wrappers/common.zig` provides shared utilities used by both CLAP and VST3 wrappers
- `src/wrappers/` imports both `src/core/`, `src/wrappers/common.zig`, and `src/bindings/`
- `src/bindings/` are standalone (only import `std`)

See each module's `README.md` for detailed structure:
- [src/core/README.md](../src/core/README.md)
- [src/dsp/README.md](../src/dsp/README.md)
- [src/wrappers/clap/README.md](../src/wrappers/clap/README.md)
- [src/wrappers/vst3/README.md](../src/wrappers/vst3/README.md)
- [src/bindings/clap/README.md](../src/bindings/clap/README.md)
- [src/bindings/vst3/README.md](../src/bindings/vst3/README.md)

## Real-Time Safety

The audio thread (anything reachable from `process`) must never:
- Call allocators (`std.heap.*`, `page_allocator`)
- Acquire locks or mutexes
- Perform I/O (files, network, logging)
- Make blocking syscalls (`mmap`, `futex`, `nanosleep`)
- Loop unboundedly over dynamic data

All buffers, scratch space, and DSP state must be pre-allocated in `init` and freed in `deinit`.

For background work (sample loading, GUI updates), use a separate thread and communicate results to the audio thread via lock-free structures (atomic queues, ring buffers).
