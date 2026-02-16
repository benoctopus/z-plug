# z-plug

An audio plugin framework for Zig 0.15.2 that allows you to write one plugin module and produce both VST3 and CLAP binaries from the same source.

## Design Philosophy

Inspired by [nih-plug](https://github.com/robbert-vdh/nih-plug) (Rust), z-plug provides:
- **API-agnostic plugin interface** — Write plugin code once, target both formats
- **Comptime-driven metadata** — Leverage Zig's comptime for vtables, parameters, GUIDs
- **Real-time safety** — No allocations on the audio thread by design
- **Minimal magic** — Explicit over implicit, minimal ceremony

## Project Status

✅ **Phase 1: Foundations** — Complete
- CLAP bindings (Zig 0.15.2 compatible, LGPL v3)
- VST3 C API bindings (hand-written, ~12 core interfaces, MIT)
- Build system configured with module support

✅ **Phase 2: Framework Core** — Complete
- API-agnostic plugin interface with comptime validation
- Zero-copy buffer abstraction with three iteration strategies
- Unified note/MIDI event system
- Parameter system with atomic runtime storage
- State persistence interface (save/load)
- Audio I/O configuration and transport abstraction

🔲 **Phase 3: Format Wrappers** — Planned
- CLAP wrapper (C struct ABI)
- VST3 wrapper (COM vtable ABI)
- Build system `addPlugin()` helper

🔲 **Phase 4: Examples and Polish** — Planned
- Example plugins (gain, synth)
- Documentation and tutorial expansion
- CI/CD integration

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
  core/            # Framework core (API-agnostic) ✅
  bindings/
    clap/          # CLAP C API bindings (LGPL v3) ✅
    vst3/          # VST3 C API bindings (MIT) ✅
  wrappers/        # Format-specific wrappers (planned)
  root.zig         # Public API ✅
docs/              # High-level documentation ✅
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

### For Plugin Authors
- **[docs/plugin-authors.md](docs/plugin-authors.md)** — Public API guide with examples
- **[docs/getting-started.md](docs/getting-started.md)** — Development environment setup

### For Contributors
- **[docs/architecture.md](docs/architecture.md)** — How the layers fit together
- **[AGENTS.md](AGENTS.md)** — Coding standards and architecture rules
- **Module READMEs** — See `src/*/README.md` for module-specific docs

## Contributing

See [AGENTS.md](AGENTS.md) for coding standards and architecture guidelines.
