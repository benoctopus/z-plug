# CLAP Wrapper Module

This module provides the CLAP (CLever Audio Plugin) wrapper that translates between the framework's API-agnostic plugin interface and the CLAP ABI.

## Structure

- **`entry.zig`** — Entry point export (`clap_entry`) that hosts query when loading the plugin
- **`factory.zig`** — Plugin factory implementation for enumerating and creating plugin instances
- **`plugin.zig`** — Core wrapper struct that implements the `clap_plugin` interface and lifecycle
- **`extensions.zig`** — CLAP extension implementations (audio-ports, note-ports, params, state)

## Key Types

- `ClapEntry(comptime T)` — Generates the `clap_entry` export for plugin type `T`
- `ClapFactory(comptime T)` — Generates the plugin factory with descriptor
- `PluginWrapper(comptime T)` — The main wrapper struct containing the plugin instance and CLAP state

## How It Works

1. Host loads the `.clap` shared library and calls `clap_entry.getFactory()`
2. Factory provides plugin descriptor and creates `PluginWrapper` instances via `createPlugin()`
3. Host calls lifecycle methods (`init`, `activate`, `process`, `deactivate`, `destroy`)
4. Process callback translates CLAP events/buffers to framework types, calls plugin, translates results back
5. Extensions provide parameter info, audio/note port configuration, and state persistence

## Design Notes

- Zero-copy audio: channel pointers are mapped directly from CLAP buffers to framework `Buffer`
- Events are translated from CLAP event types to the unified `NoteEvent` enum
- Parameters use atomic storage (`ParamValues`) for thread-safe access
- State save/load wraps CLAP streams in `std.io.AnyWriter`/`AnyReader`
