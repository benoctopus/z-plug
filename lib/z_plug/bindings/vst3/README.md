# VST3 Bindings Module

Hand-written idiomatic Zig bindings for Steinberg's VST3 C API.

## Purpose

This module provides Zig bindings for the [VST3 C API](https://github.com/steinbergmedia/vst3_c_api). The bindings are:
- **Hand-written** — Idiomatic Zig translations of ~15 core VST3 interfaces
- **Comptime-driven** — GUID parsing and vtable generation via comptime metaprogramming
- **Thin and mechanical** — No framework logic; pure ABI translation
- **COM-compatible** — Implements `FUnknown` pattern with `queryInterface` and reference counting

## License

- **Based on:** [Steinberg vst3_c_api](https://github.com/steinbergmedia/vst3_c_api)
- **License:** MIT (as of October 2025, VST3 moved to MIT licensing)
- Implementation is hand-written based on the upstream C API structure

## Structure

```
src/bindings/vst3/
├── root.zig              # Root module, re-exports all types
├── types.zig             # Fundamental types (tresult, TUID, ParamID, Sample32/64, etc.)
├── guid.zig              # GUID parsing, TUID constants
│
├── funknown.zig          # FUnknown base interface (IID, queryInterface, addRef, release)
├── factory.zig           # IPluginFactory, IPluginFactory2, IPluginFactory3
├── component.zig         # IComponent (plugin lifecycle, bus info, routing)
├── processor.zig         # IAudioProcessor (setupProcessing, process, getTailSamples)
├── controller.zig        # IEditController (parameters, UI state)
│
├── events.zig            # IEventList, Event (note on/off, data, poly pressure)
├── param_changes.zig     # IParameterChanges, IParamValueQueue
├── stream.zig            # IBStream (state I/O)
├── connection.zig        # IConnectionPoint (processor ↔ controller messages)
├── view.zig              # IPlugView (GUI embedding)
│
└── layout_tests.zig      # Test struct layouts match upstream
```

## Key Types

### Fundamental Types (types.zig)

- **`tresult`** — `i32` result code. Constants: `kResultOk`, `kResultFalse`, `kNoInterface`, `kInvalidArgument`, etc.
- **`TUID`** — `[16]u8` — UUID/GUID for interface identification.
- **`ParamID`** — `u32` — Parameter identifier.
- **`ParamValue`** — `f64` — Normalized parameter value (0.0–1.0).
- **`Sample32`, `Sample64`** — `f32`, `f64` — Audio sample types.
- **`SampleRate`** — `f64` — Sample rate in Hz.
- **`TSamples`** — `i64` — Sample count.
- **`TQuarterNotes`** — `f64` — Musical time in quarter notes.
- **Enums:** `MediaTypes`, `BusDirections`, `BusTypes`, `IoModes`, `SymbolicSampleSizes`, `ProcessModes`.

### COM Base (funknown.zig)

- **`FUnknown`** — Base interface with vtable:
  - `queryInterface(iid: *const TUID, obj: **anyopaque) tresult`
  - `addRef() u32`
  - `release() u32`
- All VST3 interfaces inherit from `FUnknown`.
- Use `guid.zig` for comptime GUID generation from string IDs.

### Factory Interfaces (factory.zig)

- **`IPluginFactory`** — Basic plugin factory (get plugin count, info, create instance).
- **`IPluginFactory2`** — Extended with `getClassInfo2` (subcategories, SDK version).
- **`IPluginFactory3`** — Extended with `getClassInfoUnicode` (Unicode metadata).
- **`GetPluginFactory()`** — Exported function that returns `*IPluginFactory`.

### Core Plugin Interfaces

**IComponent** (`component.zig`)
- Plugin lifecycle: `initialize`, `terminate`
- Bus management: `getBusCount`, `getBusInfo`, `activateBus`
- Routing: `getRoutingInfo`, `setIoMode`, `setActive`
- State: `getState`, `setState`

**IAudioProcessor** (`processor.zig`)
- Processing setup: `setBusArrangements`, `getBusArrangement`, `setupProcessing`
- Process control: `setProcessing`, `process`
- Latency/tail: `getLatencySamples`, `getTailSamples`

**IEditController** (`controller.zig`)
- Parameter management: `getParameterCount`, `getParameterInfo`, `setParamNormalized`, `getParamNormalized`
- Value conversion: `normalizedParamToPlain`, `plainParamToNormalized`, `getParamStringByValue`
- UI state: `setComponentState`, `setState`, `getState`

### Process Data (processor.zig)

**`ProcessData`** — Passed to `IAudioProcessor::process`:
- `process_mode` — Realtime, offline, prefetch
- `symbolic_sample_size` — 32-bit or 64-bit samples
- `num_samples` — Number of samples to process
- `num_inputs`, `num_outputs` — Bus counts
- `inputs`, `outputs` — `AudioBusBuffers` arrays
- `input_parameter_changes`, `output_parameter_changes` — `IParameterChanges`
- `input_events`, `output_events` — `IEventList`
- `process_context` — Transport, tempo, time signature, position

**`AudioBusBuffers`** — Non-interleaved audio buffer:
- `num_channels` — Channel count
- `silence_flags` — Bitmask indicating silent channels
- `channel_buffers_32`, `channel_buffers_64` — Audio data pointers

**`ProcessContext`** — Transport and timeline info:
- State flags: `kPlaying`, `kCycleActive`, `kRecording`, etc.
- Time: `project_time_samples`, `continuous_time_samples`, `project_time_music`
- Tempo: `tempo` (BPM), `tempo_increment`
- Time signature: `time_sig_numerator`, `time_sig_denominator`
- Loop: `cycle_start_music`, `cycle_end_music`

### Events (events.zig)

**`Event`** — Generic event structure with union containing:
- `NoteOnEvent` — Note on with velocity, tuning, length, note ID
- `NoteOffEvent` — Note off with velocity, tuning, note ID
- `DataEvent` — Sysex or other data events
- `PolyPressureEvent` — Per-note aftertouch

**`IEventList`** — Event list interface:
- `getEventCount() i32`
- `getEvent(index: i32, e: *Event) tresult`
- `addEvent(e: *const Event) tresult`

### Parameters (param_changes.zig)

**`IParameterChanges`** — Container for parameter change queues:
- `getParameterCount() i32`
- `getParameterData(index: i32) ?*IParamValueQueue`
- `addParameterData(id: *ParamID, index: *i32) ?*IParamValueQueue`

**`IParamValueQueue`** — Sample-accurate parameter automation:
- `getParameterId() ParamID`
- `getPointCount() i32`
- `getPoint(index: i32, sample_offset: *i32, value: *ParamValue) tresult`
- `addPoint(sample_offset: i32, value: ParamValue, index: *i32) tresult`

### State (stream.zig)

**`IBStream`** — Stream interface for state save/load:
- `read(buffer: *anyopaque, num_bytes: i32, num_bytes_read: *i32) tresult`
- `write(buffer: *const anyopaque, num_bytes: i32, num_bytes_written: *i32) tresult`
- `seek(pos: i64, mode: i32, result: *i64) tresult`
- `tell(pos: *i64) tresult`

## Usage by Wrappers

The VST3 wrapper (`src/wrappers/vst3/`) uses these bindings to implement the COM ABI:

1. **Export `GetPluginFactory()`** returning `*IPluginFactory`.
2. **Implement factory** to create plugin component instances.
3. **Implement `IComponent`** with bus management, activation, state.
4. **Implement `IAudioProcessor`** with `process` delegating to framework core.
5. **Implement `IEditController`** for parameter management and UI state.
6. **Translate events** from `IEventList` to framework `NoteEvent`.
7. **Map audio buffers** from `AudioBusBuffers` to framework `Buffer` (zero-copy).
8. **Handle COM reference counting** using `FUnknown` pattern.

## Zig 0.15.2 Compatibility

These bindings are written for Zig 0.15.2:
- All `extern struct` function pointer fields use explicit `callconv(.c)`.
- GUID parsing is done at comptime using `guid.zig`.
- No `usingnamespace` (removed from Zig).

## Testing

The bindings include layout tests verifying struct sizes and offsets match the upstream C API. Run with:

```bash
zig build test
```

VST3 bindings tests are part of the main test suite (2 tests from this module).

## See Also

- **[VST3 C API](https://github.com/steinbergmedia/vst3_c_api)** — Official C API headers
- **[VST3 SDK](https://github.com/steinbergmedia/vst3sdk)** — Full SDK with C++ implementation and examples
- **[VST3 Developer Portal](https://steinbergmedia.github.io/vst3_dev_portal/)** — Official documentation
- **[SuperElectric blog](https://superelectric.dev/post/post1.html)** — VST3 COM vtables in Zig with comptime
- **[docs/architecture.md](../../docs/architecture.md)** — How bindings fit into the overall architecture
