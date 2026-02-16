# AGENTS.md — Coding Agent Guidelines for zig-plug

## Project Overview

zig-plug is an audio plugin framework for Zig 0.15.2 that lets a plugin author write one Zig module and produce both **VST3** and **CLAP** binaries from the same source. The architecture is inspired by **nih-plug** (Rust): an API-agnostic `PluginInterface` with thin format-specific wrappers that translate between the internal interface and the external ABI.

## Core Design Principles

These are non-negotiable. Every change must respect them:

1. **API-agnostic plugin interface** — Plugin authors never touch VST3 or CLAP types directly. All plugin code goes through framework abstractions.
2. **Comptime-driven metadata** — Use Zig's `comptime` to generate vtables, parameter lists, GUIDs, and export symbols. No runtime reflection or code generation.
3. **No allocations on the audio thread** — The framework enforces real-time safety by design. `process` functions must never call allocators, acquire locks, or perform I/O.
4. **Minimal magic** — Prefer explicit over implicit. No hidden globals, no implicit initialization order.

## Architecture Layers

```
Plugin Author Code  →  Framework Core  →  Format Wrappers  →  Low-Level Bindings
```

- **Plugin Author Code**: Implements a struct with well-known declarations consumed by the framework at comptime.
- **Framework Core**: `PluginInterface`, `Buffer`, `NoteEvent`, `ParamLayout`, `State`, `AudioIOLayout`, `ProcessContext`.
- **Format Wrappers**: CLAP wrapper (C struct ABI, `clap_entry` export) and VST3 wrapper (COM vtable ABI, `GetPluginFactory` export).
- **Low-Level Bindings**: Idiomatic Zig bindings for CLAP C API and VST3 C API (`vst3_c_api`).

When adding code, place it in the correct layer. Never leak format-specific types upward into the core or plugin author layers.

## Zig 0.15.2 Language Rules

These are **mandatory** for all Zig code in this project:

- **`callconv(.c)`** — Use lowercase `.c`, not the deprecated `.C`. All `extern struct` function pointer fields must have an explicit `callconv`.
- **No `usingnamespace`** — It was removed. Use explicit `pub const` aliases or direct `@import`.
- **No `async`/`await`** — Removed from the language. Not relevant for real-time audio anyway.
- **New I/O interfaces** — Use `std.io.Reader` / `std.io.Writer` from 0.15.x, not the old interfaces. State save/load streams must use the new interfaces.
- **`@ptrCast` semantics** — Review 0.15 pointer cast semantics carefully when doing COM vtable pointer arithmetic. Prefer `@ptrCast` + `@alignCast` as separate explicit steps when needed.
- **Explicit error unions** — Always handle errors explicitly. Never use `catch unreachable` unless you can prove the error is impossible.

## Real-Time Audio Safety

Code running on the audio thread (anything reachable from `processFn`) must obey these rules:

- **No heap allocation** — Do not call any allocator (`std.heap`, `page_allocator`, etc.).
- **No locks/mutexes** — No blocking synchronization primitives. Use lock-free data structures (atomic queues, ring buffers) for cross-thread communication.
- **No I/O** — No file reads/writes, no logging, no network calls.
- **No syscalls that can block** — No `mmap`, no `futex`, no `nanosleep`.
- **Bounded loops only** — Every loop must have a known upper bound. No unbounded iteration over dynamic data.
- **Pre-allocate everything** — All buffers, scratch space, and DSP state must be allocated during `initFn` and freed during `deinitFn`.

If you need to perform non-real-time work (e.g., loading samples, updating a GUI), do it on a background thread and communicate results to the audio thread via lock-free structures.

## Comptime Patterns

The plugin interface uses Zig's comptime duck-typing pattern (similar to `std.mem.Allocator`):

- The plugin author defines a struct with well-known declarations (`name`, `vendor`, `processFn`, `params`, etc.).
- The framework validates these at comptime using `@hasDecl` / `@TypeOf` checks.
- Comptime generates format-specific metadata (CLAP `clap_param_info_t` arrays, VST3 `ParameterInfo` arrays, COM vtables, GUIDs from string IDs).

When writing comptime code:
- Provide clear `@compileError` messages when a plugin struct is missing required declarations or has wrong types.
- Test comptime code paths with `comptime { ... }` blocks in tests.
- Keep comptime logic in dedicated helper functions, not inline in wrapper code.

## Parameter System

Parameters follow nih-plug's model:

- Declared as comptime data: name, ID (stable string hash), range, default, step count, unit label, flags.
- The framework generates metadata arrays at comptime for both CLAP and VST3.
- Smoothing is optional and built-in (linear ramp, exponential). Plugin authors opt in per-parameter.
- Sample-accurate automation (buffer splitting at parameter change points) is opt-in via a flag.
- Thread safety: main-thread vs. audio-thread parameter arrays. For VST3, processor↔controller communication uses message passing.

## Buffer and Event Abstractions

**Buffer** provides three iteration strategies:
- Per-sample, per-channel (simple plugins, per-sample SIMD).
- Per-block, per-channel (FFT, convolution).
- Raw slice access (`[][]f32`) for maximum control.

Wrappers copy pointers, **never audio data**, from format-specific buffers into the framework `Buffer`.

**NoteEvent** is a tagged union unifying CLAP and VST3 events:
- `note_on`, `note_off`, `choke`, `poly_pressure`, `note_expression`, `midi_cc`, etc.
- All events carry sample-accurate timestamps (sample offset within the process block).

## File and Module Organization

Follow this project structure:

```
src/
  core/              # Framework core (API-agnostic)
    plugin.zig       # PluginInterface, comptime validation
    params.zig       # Parameter declaration, metadata, smoothing
    buffer.zig       # Buffer abstraction, iterators
    events.zig       # NoteEvent tagged union
    state.zig        # State save/load interface
    audio_layout.zig # AudioIOLayout, BufferConfig
  wrappers/
    clap/            # CLAP format wrapper
      entry.zig      # clap_entry, clap_plugin_factory
      plugin.zig     # clap_plugin implementation
      params.zig     # CLAP params extension
      ports.zig      # audio-ports, note-ports extensions
      state.zig      # CLAP state extension
    vst3/            # VST3 format wrapper
      factory.zig    # IPluginFactory, GetPluginFactory export
      component.zig  # IComponent implementation
      processor.zig  # IAudioProcessor implementation
      controller.zig # IEditController implementation
      com.zig        # FUnknown, queryInterface, COM helpers
  bindings/
    clap.zig         # Low-level CLAP C API bindings
    vst3.zig         # Low-level VST3 C API bindings
  root.zig           # Public API re-exports for plugin authors
build.zig            # Build system: addPlugin helper
```

- One concern per file. Keep files focused and under ~500 lines where feasible.
- Public API that plugin authors use goes through `src/root.zig`.
- Bindings are thin and mechanical — no framework logic in the bindings layer.

## Build System

The build system (`build.zig`) must:
- Provide an `addPlugin()` function that accepts plugin metadata, source file, and target formats.
- Compile as shared library: `.clap` (single `.so`/`.dylib`/`.dll`), `.vst3` (bundle structure).
- Handle platform-specific bundling: macOS `.vst3` bundle directory structure, Linux `.so` paths, Windows `.dll`.
- Support cross-compilation via Zig's built-in cross-compilation support.

## Testing

- **Unit tests**: Use `zig test` for core framework logic (parameter mapping, buffer iteration, event translation, comptime validation).
- **Integration tests**: Build a minimal gain plugin to both formats, verify it loads without crashing.
- **No tests on the audio thread mock**: Test DSP logic with pre-allocated buffers, not by simulating real-time constraints.
- Run `zig build test` before considering any change complete.

## Code Style

- Follow Zig standard library conventions: `snake_case` for functions and variables, `PascalCase` for types, `SCREAMING_SNAKE_CASE` for comptime constants.
- Use `///` doc comments on all public declarations.
- Prefer `const` over `var` — only use `var` when mutation is required.
- Use `defer` for cleanup. Pair every resource acquisition with a `defer` release.
- No `@import("std").debug.print` in production code paths. Use it only in tests.
- Errors should be descriptive: prefer named error sets over `anyerror`.

## Commit and Change Guidelines

- Keep changes small and focused. One logical change per commit.
- When modifying the plugin interface, update both CLAP and VST3 wrappers to maintain parity.
- When adding a new parameter feature, update comptime metadata generation for both formats.
- Never break the compilation of example plugins — they serve as integration tests.
- If a change touches bindings, verify against the upstream C API headers.

## Key References

When implementing, consult these resources:

- **nih-plug Plugin trait**: Primary architecture reference for the plugin interface (`src/plugin.rs`). 
- nih-plug's source is included in this project at ./nih-plug/ for easy reference.
- **SuperElectric blog**: Worked example of VST3 COM vtables in Zig with comptime metaprogramming.
- **Nakst CLAP tutorials**: Step-by-step C implementation of CLAP plugins (parts 1 and 2).
- **arbor (Zig)**: Existing Zig plugin framework for comptime parameter patterns and build system reference.
- **`vst3_c_api` headers**: The ground truth for VST3 C struct layouts.
- **CLAP headers (`free-audio/clap`)**: The ground truth for CLAP struct definitions.

See `zig-plug-design.md` for full URLs and detailed design rationale.
