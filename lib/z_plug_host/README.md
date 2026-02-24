# z_plug_host

A minimal CLAP plugin host library for testing and debugging z-plug plugins. Exposes a C-compatible API (`zph_*` prefix) suitable for use from Rust, C, or any language with C FFI.

## Module Structure

| File | Purpose |
|------|---------|
| `root.zig` | C API exports (`zph_*` functions) |
| `plugin_instance.zig` | Plugin lifecycle state machine, DSO loading, extension caching |
| `extensions.zig` | Host-side CLAP extension implementations |
| `event_list.zig` | `InputEvents` / `OutputEvents` vtable implementations |
| `audio_buffers.zig` | Audio buffer pointer management for `clap_process_t` |

## Key Types

- **`ZphPlugin`** — opaque handle returned by `zph_load_plugin`; wraps `PluginInstance`
- **`ZphPluginInfo`** — plugin metadata (id, name, vendor, channel counts, latency)
- **`ZphParamInfo`** — parameter metadata (id, name, range, flags)
- **`ZphProcessStatus`** — mirrors `clap_process_status` values

## Lifecycle

```
zph_load_plugin()       → loads DSO, calls entry.init, creates plugin, calls plugin.init
zph_activate()          → plugin.activate (main thread)
zph_start_processing()  → plugin.startProcessing (audio thread)
zph_process()           → plugin.process (audio thread, call in a loop)
zph_stop_processing()   → plugin.stopProcessing (audio thread)
zph_deactivate()        → plugin.deactivate (main thread)
zph_destroy()           → plugin.destroy, entry.deinit, close DSO
```

Call `zph_idle()` periodically from the main thread to handle deferred plugin callbacks (`request_restart`, `request_callback`, param flush).

## Host Extensions Provided

| Extension | Implementation |
|-----------|---------------|
| `clap.thread-check` | Thread-local role tracking |
| `clap.log` | Forwards to `std.log` |
| `clap.params` | Rescan/flush flags, drained in `zph_idle` |
| `clap.state` | `markDirty` flag |
| `clap.audio-ports` | Stub (no dynamic port changes) |
| `clap.latency` | Updates cached latency on change |

## macOS Bundle Handling

On macOS, `.clap` files are bundles (directories). The loader automatically resolves the binary inside: `MyPlugin.clap/Contents/MacOS/MyPlugin`.

## Design Notes

- All CLAP types come from `lib/z_plug/bindings/clap/` — no duplication.
- The host does **not** depend on `lib/z_plug/core/` or `lib/z_plug/wrappers/` (those are plugin-side).
- Parameter changes are queued thread-safely and drained into the input event list at the start of each `process()` call.
- Audio buffers are non-interleaved `f32` (one pointer per channel), matching the CLAP spec.
