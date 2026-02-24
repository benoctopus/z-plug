# CLAP Bindings Module

Low-level idiomatic Zig translation of the CLAP 1.2.2 C API.

## Purpose

This module provides direct Zig bindings for the [CLAP (CLever Audio Plug-in)](https://github.com/free-audio/clap) C API. The bindings are:
- **Thin and mechanical** — Direct translation of C structs and function pointers to Zig `extern struct` types
- **Idiomatic Zig** — Uses Zig naming conventions, `callconv(.c)` for function pointers, proper null safety
- **No framework logic** — Pure ABI translation; wrappers in `src/wrappers/clap/` add framework integration

## Origin and License

- **Derived from:** [clap-zig-bindings](https://git.sr.ht/~interpunct/clap-zig-bindings) by interpunct
- **Modifications:** Adapted for Zig 0.15.2 compatibility (explicit `callconv(.c)`, no `usingnamespace`)
- **License:** GNU LGPL v3.0 or later
- See [LICENSE](LICENSE) and [NOTICE](NOTICE) for full attribution

### LGPL Compliance

When distributing binaries or using this framework, you must comply with LGPL v3 requirements. Users must be able to replace the LGPL-licensed library. This is satisfied by:
1. **Distributing source code** (recommended for open source projects), or
2. **Using dynamic linking** for the CLAP bindings portion

## Structure

```
src/bindings/clap/
├── main.zig              # Root module, re-exports all types
├── LICENSE               # GNU LGPL v3.0 license text
├── NOTICE                # Attribution to original authors
│
├── version.zig           # CLAP version struct
├── entry.zig             # clap_entry (plugin entry point)
├── plugin.zig            # clap_plugin (plugin descriptor + vtable)
├── host.zig              # clap_host (host callbacks)
├── process.zig           # clap_process_t (audio processing context)
├── stream.zig            # clap_istream_t, clap_ostream_t (state I/O)
├── events.zig            # Event types (note, param, transport, MIDI)
├── audio_buffer.zig      # clap_audio_buffer_t (32/64-bit audio data)
│
├── factory/
│   ├── plugin.zig        # clap_plugin_factory_t
│   └── preset_discovery.zig  # clap_preset_discovery_factory_t
│
└── ext/                  # CLAP extensions (30+ files)
    ├── params.zig        # clap_plugin_params extension
    ├── state.zig         # clap_plugin_state extension
    ├── audio_ports.zig   # clap_plugin_audio_ports extension
    ├── note_ports.zig    # clap_plugin_note_ports extension
    ├── gui.zig           # clap_plugin_gui extension
    ├── latency.zig       # clap_plugin_latency extension
    ├── tail.zig          # clap_plugin_tail extension
    └── ... (25+ more extension files)
```

## Key Types

### Core Plugin Types

- **`clap_entry`** (`entry.zig`) — Plugin entry point struct with `init`, `deinit`, `get_factory`.
- **`clap_plugin`** (`plugin.zig`) — Plugin descriptor with metadata and vtable (function pointers for `activate`, `deactivate`, `start_processing`, `stop_processing`, `process`, etc.).
- **`clap_host`** (`host.zig`) — Host callbacks provided to the plugin.
- **`clap_plugin_factory`** (`factory/plugin.zig`) — Factory for creating plugin instances.

### Process and Audio

- **`clap_process_t`** (`process.zig`) — Audio processing context containing:
  - `frames_count` — Number of samples to process
  - `audio_inputs`, `audio_outputs` — Audio buffer arrays
  - `in_events`, `out_events` — Event lists (input/output)
  - `transport` — Transport info (optional)
- **`clap_audio_buffer_t`** (`audio_buffer.zig`) — Non-interleaved audio buffer (32-bit or 64-bit float).
- **Status enum:** `CLAP_PROCESS_ERROR`, `CLAP_PROCESS_CONTINUE`, `CLAP_PROCESS_CONTINUE_IF_NOT_QUIET`, `CLAP_PROCESS_TAIL`, `CLAP_PROCESS_SLEEP`.

### Events

All in `events.zig`:
- **`clap_event_header_t`** — Common header for all events (size, time, space_id, type, flags).
- **Note events:** `clap_event_note_t` (note on/off/choke/end).
- **Note expression:** `clap_event_note_expression_t` (volume, pan, tuning, vibrato, etc.).
- **Parameters:** `clap_event_param_value_t`, `clap_event_param_mod_t`, `clap_event_param_gesture_begin/end_t`.
- **Transport:** `clap_event_transport_t` (tempo, time signature, position, loop points).
- **MIDI:** `clap_event_midi_t`, `clap_event_midi_sysex_t`, `clap_event_midi2_t`.

### Extensions

CLAP uses an extension-based architecture. Common extensions include:
- **`clap_plugin_params`** (`ext/params.zig`) — Parameter info, value queries, text conversion.
- **`clap_plugin_state`** (`ext/state.zig`) — State save/load via streams.
- **`clap_plugin_audio_ports`** (`ext/audio_ports.zig`) — Audio bus info (channel counts, names).
- **`clap_plugin_note_ports`** (`ext/note_ports.zig`) — Note input/output port info.
- **`clap_plugin_gui`** (`ext/gui.zig`) — GUI creation, embedding, resizing.
- **`clap_plugin_latency`** (`ext/latency.zig`) — Report processing latency.
- **`clap_plugin_tail`** (`ext/tail.zig`) — Report tail length (e.g., reverb decay).

All extensions follow the pattern: plugin exposes an extension struct with function pointers, host queries via `clap_plugin::get_extension`.

## Usage by Wrappers

The CLAP wrapper (`src/wrappers/clap/`) uses these bindings to implement the CLAP ABI:

1. **Export `clap_entry`** with `init`, `deinit`, `get_factory`.
2. **Implement `clap_plugin_factory`** to create plugin instances.
3. **Implement `clap_plugin`** with vtable functions that delegate to the framework core.
4. **Translate events** from `clap_event_*` to framework `NoteEvent`.
5. **Map audio buffers** from `clap_audio_buffer_t` to framework `Buffer` (zero-copy).
6. **Implement extensions** to expose parameters, state, ports, etc.

## Zig 0.15.2 Compatibility

These bindings have been updated for Zig 0.15.2:
- All `extern struct` function pointer fields use explicit `callconv(.c)`.
- No `usingnamespace` (was removed from Zig).
- Explicit type annotations where required by 0.15.2 type inference changes.

## Testing

The bindings include basic tests verifying struct layouts and function pointer types. Run with:

```bash
zig build test
```

CLAP bindings tests are part of the main test suite (43 tests from this module).

## See Also

- **[CLAP specification](https://github.com/free-audio/clap)** — Official CLAP headers and documentation
- **[Nakst CLAP tutorials](https://nakst.gitlab.io/tutorial/clap-part-1.html)** — Step-by-step C implementation
- **[docs/architecture.md](../../docs/architecture.md)** — How bindings fit into the overall architecture
- **Original bindings:** [clap-zig-bindings](https://git.sr.ht/~interpunct/clap-zig-bindings)
