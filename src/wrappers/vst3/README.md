# VST3 Wrapper Module

This module provides the VST3 (Virtual Studio Technology 3) wrapper that translates between the framework's API-agnostic plugin interface and the VST3 COM-based ABI.

## Structure

- **`com.zig`** — COM (Component Object Model) helpers for reference counting and queryInterface
- **`factory.zig`** — Plugin factory export (`GetPluginFactory`) and IPluginFactory implementation
- **`component.zig`** — Combined IComponent + IAudioProcessor implementation (single-component model)
- **`controller.zig`** — IEditController implementation for parameter editing

## Key Types

- `Vst3Factory(comptime T)` — Generates the `GetPluginFactory` export and factory COM object
- `Vst3Component(comptime T)` — The main wrapper struct implementing IComponent, IAudioProcessor, and IEditController
- `Vst3Controller(comptime T)` — Controller state for parameter management (embedded in component)

## How It Works

1. Host calls `GetPluginFactory()` which returns an `IPluginFactory` COM object
2. Factory provides class info and creates `Vst3Component` instances via `createInstance()`
3. Component implements three interfaces via COM queryInterface:
   - `IComponent` — Bus configuration, activation, state save/load
   - `IAudioProcessor` — Process callback, bus arrangements, latency/tail
   - `IEditController` — Parameter info, normalized/plain conversion
4. Process callback translates VST3 ProcessData to framework types, calls plugin, translates results back

## Design Notes

- **COM lifetime**: Atomic reference counting, object freed when ref_count reaches zero
- **Single-component model**: Same object implements processor and controller (simpler than split model)
- **GUID generation**: Plugin ID string hashed to deterministic 16-byte TUID
- **Zero-copy audio**: Channel pointers mapped directly from VST3 AudioBusBuffers to framework `Buffer`
- **State persistence**: VST3 IBStream wrapped in `std.io.AnyWriter`/`AnyReader`
- **Parameter IDs**: Generated via FNV-1a hash of parameter string IDs

## COM Interface Layout

```
Vst3Component
├── component_vtbl (IComponent)
├── processor_vtbl (IAudioProcessor)  
├── controller_interface (IEditController)
├── ref_count (atomic)
└── plugin (actual plugin instance)
```

queryInterface returns different vtbl pointers depending on requested IID, but all point to the same component object.
