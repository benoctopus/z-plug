# Framework Core Module

The framework core provides API-agnostic types that plugin authors interact with. No format-specific code (CLAP or VST3) belongs in this layer.

## Purpose

This module defines the plugin interface and all core abstractions:
- Comptime plugin validation (`Plugin(T)`)
- Audio buffer wrapper (`Buffer`)
- Unified note/MIDI events (`NoteEvent`)
- Parameter system (`Param`, `ParamValues`)
- State persistence (`SaveContext`, `LoadContext`)
- Audio I/O configuration (`AudioIOLayout`, `BufferConfig`, `Transport`)

Plugin authors import these types via `@import("z_plug")`, which re-exports from this module.

## Files

| File | Purpose |
|------|---------|
| `plugin.zig` | Plugin interface, comptime validation, `ProcessContext`, `ProcessStatus`, `EventOutputList` |
| `params.zig` | Parameter declarations (`Param`, `FloatParam`, `IntParam`, `BoolParam`, `ChoiceParam`), ranges, flags, atomic parameter storage |
| `buffer.zig` | Zero-copy audio buffer abstraction with three iteration strategies |
| `events.zig` | Unified `NoteEvent` tagged union (note on/off, poly expression, MIDI CC, etc.) |
| `state.zig` | State save/load interface (`SaveContext`, `LoadContext`) using Zig 0.15.2 I/O |
| `audio_layout.zig` | Audio I/O layouts, buffer config, process modes, MIDI config, transport info |

## Key Types

### Plugin Interface

- **`Plugin(comptime T)`** — Comptime function that validates a plugin struct `T` at compile time using duck-typing (similar to `std.mem.Allocator` pattern). Emits clear `@compileError` messages for missing or wrong-typed declarations.
- **`ProcessContext`** — Passed to `process`, contains transport info, input events, output event list, sample rate.
- **`ProcessStatus`** — Return type from `process`: `normal`, `silence`, `tail`, `keep_alive`, `err`.
- **`EventOutputList`** — Bounded push-only list for output events.

### Buffer and Audio I/O

- **`Buffer`** — Zero-copy wrapper over host audio data (`[][]f32`). Provides raw slice access, per-sample iteration, and per-block iteration.
- **`AuxBuffers`** — Auxiliary I/O buses (sidechain inputs, aux outputs).
- **`AudioIOLayout`** — Declares supported channel configurations (main input/output, aux buses).
- **`BufferConfig`** — Runtime config from host (sample rate, buffer size, process mode).
- **`Transport`** — Unified transport/timeline info (playing, tempo, time signature, position).

### Events

- **`NoteEvent`** — Tagged union unifying CLAP and VST3 events:
  - Note events: `note_on`, `note_off`, `choke`, `voice_terminated`
  - Poly expression: `poly_pressure`, `poly_tuning`, `poly_vibrato`, `poly_expression`, `poly_brightness`, `poly_volume`, `poly_pan`
  - MIDI: `midi_cc`, `midi_channel_pressure`, `midi_pitch_bend`, `midi_program_change`
- All events carry sample-accurate `timing` (offset within buffer).

### Parameters

- **`Param`** — Tagged union for parameter declarations: `float`, `int`, `boolean`, `choice`.
- **`FloatRange` / `IntRange`** — Value ranges with normalize/unnormalize/clamp methods.
- **`ParamFlags`** — Packed struct controlling automation, modulation, visibility, bypass.
- **`ParamValues(comptime N)`** — Lock-free atomic storage for runtime parameter values. Uses `std.atomic.Value(f32)` for thread-safe access between main and audio threads.
- **`idHash(comptime id)`** — Stable FNV-1a hash for generating VST3 `ParamID` from string IDs.

### State Persistence

- **`SaveContext`** — Type-erased writer (`std.io.AnyWriter`) with helper methods (`write`, `writeString`, `writeBytes`).
- **`LoadContext`** — Type-erased reader (`std.io.AnyReader`) with helper methods (`read`, `readString`, `readStringBounded`). Includes `version` field for migration.
- The framework writes a header (magic bytes + version) before calling the plugin's `save` function.

## Design Notes

### Comptime Validation

The `Plugin(comptime T)` function uses `@hasDecl` and `@TypeOf` to validate plugin structs at compile time:

```zig
if (!@hasDecl(T, "name")) {
    @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub const name: [:0]const u8'");
}
```

This provides:
- Zero runtime overhead (monomorphization, no vtables)
- Clear compile-time error messages
- No dynamic dispatch on the audio thread

### Atomic Parameters

`ParamValues(N)` uses `std.atomic.Value(f32)` for lock-free thread safety:

```zig
pub fn get(self: *const Self, index: usize) f32 {
    return self.values[index].load(.monotonic);
}

pub fn set(self: *Self, index: usize, normalized: f32) void {
    self.values[index].store(normalized, .monotonic);
}
```

Main thread writes with `.store()`, audio thread reads with `.load()`. No locks are ever acquired.

### Zero-Copy Buffers

`Buffer` wraps pointers into the host's audio memory:

```zig
pub const Buffer = struct {
    channel_data: [][]f32,  // Points into host memory, never copies
    num_samples: usize,
    // ...
};
```

Wrappers populate `channel_data` with pointers from format-specific structures (`clap_audio_buffer_t`, `AudioBusBuffers`). Audio samples are never copied.

### Three Buffer Iteration Strategies

1. **Raw slice access** — Direct `[]f32` per channel for maximum control.
2. **Per-sample** — `iterSamples()` yields `ChannelSamples` for each sample index (convenient for per-sample SIMD or branching).
3. **Per-block** — `iterBlocks(max_block_size)` yields `Block` sub-buffers (useful for FFT, convolution, or algorithms that operate on fixed-size blocks).

## Testing

Each file includes test blocks at the bottom covering:
- `audio_layout.zig`: Layout constants, total channel calculations
- `events.zig`: Helper methods (timing, channel, voiceId extraction)
- `params.zig`: Range normalize/unnormalize roundtrips, idHash stability, ParamValues atomic access
- `buffer.zig`: Iteration strategies, zero-copy pointer identity
- `state.zig`: SaveContext/LoadContext roundtrips, header validation
- `plugin.zig`: Comptime validation with valid and invalid plugin structs

Run tests with:
```bash
zig build test
```

## See Also

- [docs/architecture.md](../../docs/architecture.md) — How core fits into the overall architecture
- [docs/plugin-authors.md](../../docs/plugin-authors.md) — Public API guide for writing plugins
- [src/root.zig](../root.zig) — Public API re-exports
