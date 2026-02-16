# z-plug

An audio plugin framework for Zig 0.15.2 that allows you to write one plugin module and produce both VST3 and CLAP binaries from the same source.

## Design Philosophy

Inspired by [nih-plug](https://github.com/robbert-vdh/nih-plug) (Rust), z-plug provides:
- **API-agnostic plugin interface** — Write plugin code once, target both formats
- **Comptime-driven metadata** — Leverage Zig's comptime for vtables, parameters, GUIDs
- **Real-time safety** — No allocations on the audio thread by design
- **Minimal magic** — Explicit over implicit, minimal ceremony

See [zig-plug-design.md](zig-plug-design.md) for the complete design document.

## Project Status

🚧 **Phase 1: Foundations** — Low-level bindings layer complete:
- ✅ CLAP bindings (Zig 0.15.2 compatible)
- ✅ VST3 C API bindings (hand-written, ~12 core interfaces)
- ✅ Build system configured with module support
- 🔲 Framework core (next phase)

## Building

This project requires Zig 0.15.2. The provided `flake.nix` sets up a development environment with zvm.

```bash
# Run tests
zig build test

# Future: Build a plugin (not yet implemented)
# zig build -Dplugin=examples/gain
```

## Project Structure

```
src/
  bindings/
    clap/          # CLAP C API bindings (LGPL v3)
    vst3/          # VST3 C API bindings (MIT)
  core/            # Framework core (coming soon)
  wrappers/        # Format-specific wrappers (coming soon)
  root.zig         # Public API
```

## License and Attribution

This project's framework code is licensed under [TBD].

### Third-Party Components

**CLAP Bindings** (`src/bindings/clap/`):
- Derived from: [clap-zig-bindings](https://git.sr.ht/~interpunct/clap-zig-bindings)
- License: GNU LGPL v3.0 or later
- Modifications: Adapted for Zig 0.15.2 compatibility
- See: `src/bindings/clap/LICENSE` and `src/bindings/clap/NOTICE`

**VST3 Bindings** (`src/bindings/vst3/`):
- Based on: [Steinberg vst3_c_api](https://github.com/steinbergmedia/vst3_c_api)
- License: MIT (as of October 2025)
- Implementation: Hand-written idiomatic Zig bindings

## Documentation

- [zig-plug-design.md](zig-plug-design.md) — Complete design document with architecture, references, and phased implementation plan
- [AGENTS.md](AGENTS.md) — Coding guidelines for AI agents working on this project

## Contributing

See [AGENTS.md](AGENTS.md) for coding standards and architecture guidelines.
