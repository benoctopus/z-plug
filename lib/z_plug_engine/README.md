# z_plug_engine

A simple CoreAudio-backed audio engine (macOS only) for testing and debugging z-plug plugins. Loads a WAV file, optionally routes audio through a CLAP plugin via `z_plug_host`, and outputs to the default system audio device.

Exposes a C-compatible API (`zpe_*` prefix) for use from Rust, C, or any language with C FFI.

## Module Structure

| File | Purpose |
|------|---------|
| `root.zig` | C API exports (`zpe_*` functions) |
| `engine.zig` | Core engine: playback state, position tracking, plugin integration |
| `coreaudio.zig` | CoreAudio AudioQueue output backend |
| `wav.zig` | Pure-Zig RIFF/WAVE file loader |

## Key Types

- **`ZpeEngine`** — opaque handle returned by `zpe_create`

## C API Summary

```c
ZpeEngine* zpe_create(double sample_rate, uint32_t buffer_size);
void       zpe_destroy(ZpeEngine* engine);

bool       zpe_load_file(ZpeEngine* engine, const char* path);
void       zpe_set_plugin(ZpeEngine* engine, ZphPlugin* plugin);  // null = passthrough

bool       zpe_play(ZpeEngine* engine);
void       zpe_pause(ZpeEngine* engine);
void       zpe_stop(ZpeEngine* engine);
void       zpe_seek(ZpeEngine* engine, uint64_t sample_position);

uint64_t   zpe_get_position(const ZpeEngine* engine);
uint64_t   zpe_get_length(const ZpeEngine* engine);
double     zpe_get_sample_rate(const ZpeEngine* engine);
uint32_t   zpe_get_channel_count(const ZpeEngine* engine);
bool       zpe_is_playing(const ZpeEngine* engine);
void       zpe_set_looping(ZpeEngine* engine, bool loop);
```

## WAV Support

Supported formats:
- PCM 16-bit, 24-bit, 32-bit integer
- IEEE float 32-bit
- Any channel count (up to 8 for plugin processing)

All formats are converted to deinterleaved `f32` internally.

## Audio Flow

```
WAV file (deinterleaved f32)
    → Engine (reads chunk at current position)
    → CLAP Plugin via zph_process() (if attached)
    → AudioQueue callback (interleave → system output)
```

## CoreAudio Backend

Uses **AudioQueue Services** from the AudioToolbox framework:
- Simpler than AudioUnit HAL (5 functions vs 15+)
- Automatic format conversion and resampling
- Uses the default output device automatically
- Ring buffer of 3 AudioQueue buffers (~512 frames each)

## Design Notes

- Playback position is an atomic `u64` so the CoreAudio callback thread and the main thread can read/write it safely without locks.
- The engine does **not** manage the plugin lifecycle — the caller creates and destroys the `ZphPlugin` handle independently.
- `zpe_set_plugin(engine, NULL)` switches to passthrough mode (WAV → output directly).
