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
- Parameter system with atomic runtime storage and smoothing
- State persistence interface (save/load)
- Audio I/O configuration and transport abstraction

✅ **Phase 3: Format Wrappers** — Complete
- CLAP wrapper (C struct ABI) with entry point, factory, plugin, and extensions
- VST3 wrapper (COM vtable ABI) with factory, component, processor, and controller
- Build system `addPlugin()` helper with platform-specific bundling
- VST3 macOS bundle creation (Info.plist, PkgInfo, correct directory structure)
- Platform-specific module init/deinit exports

🔄 **Phase 4: Examples and Polish** — In Progress
- ✅ Example gain plugin (loads and runs in DAWs)
- ✅ Helper scripts for installing and signing plugins
- 🔲 Additional example plugins (synth, effects)
- 🔲 CI/CD integration

## Building

This project requires Zig 0.15.2. The provided `flake.nix` sets up a development environment with Nix.

```bash
# Activate the Zig 0.15.2 environment (if using Nix + direnv)
direnv allow

# Run tests
zig build test

# Build example plugins (outputs to zig-out/plugins/)
zig build

# Install plugins to system directories
zig build install-plugins                # user directories (default)
zig build install-plugins -Dsystem=true  # system directories (requires sudo)

# Sign plugins on macOS (required for most DAWs)
zig build sign-plugins

# Uninstall plugins
zig build uninstall-plugins                # user directories
zig build uninstall-plugins -Dsystem=true  # system directories
```

See [docs/getting-started.md](docs/getting-started.md) for detailed setup instructions.

## Project Structure

```
src/
  core/            # Framework core (API-agnostic) ✅
    plugin.zig     # Plugin interface & comptime validation
    params.zig     # Parameter system with smoothing
    buffer.zig     # Zero-copy audio buffer abstraction
    events.zig     # Unified note/MIDI events
    state.zig      # State persistence
    audio_layout.zig # Audio I/O configuration
  bindings/
    clap/          # CLAP C API bindings (LGPL v3) ✅
    vst3/          # VST3 C API bindings (MIT) ✅
  wrappers/        # Format-specific wrappers ✅
    clap/          # CLAP wrapper implementation
    vst3/          # VST3 wrapper implementation
  root.zig         # Public API ✅
examples/          # Example plugins ✅
  gain.zig         # Simple gain plugin (CLAP + VST3)
docs/              # High-level documentation ✅
build.zig          # Build system with addPlugin() helper ✅
build_tools/       # Plugin management utilities
  install_plugins.zig     # Install plugins to system directories
  sign_plugins.zig        # Code-sign plugins on macOS
  uninstall_plugins.zig   # Remove installed plugins
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
