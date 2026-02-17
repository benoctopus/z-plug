# Getting Started

This guide will help you set up the development environment and start working with zig-plug.

## Prerequisites

- **Nix** (with flakes enabled) — for reproducible development environment
- **direnv** — for automatic environment activation
- Basic familiarity with Zig (0.15.2 specific features)

## Setup

### 1. Clone the repository

```bash
git clone <repository-url>
cd z-plug
```

### 2. Activate the Zig 0.15.2 environment

This project uses Nix with direnv to provide Zig 0.15.2. The system-installed Zig (via Homebrew or other package managers) may be an older version like 0.13.0.

```bash
# Allow direnv to load the .envrc file (first time only)
direnv allow .

# Activate the environment for the current shell session
eval "$(direnv export bash)"

# Verify you have Zig 0.15.2
zig version  # Should output: 0.15.2
```

**Important:** Always run `eval "$(direnv export bash)"` when starting a new shell session in this project. If `zig version` shows anything other than `0.15.2`, the environment is not active.

Alternatively, if you have `direnv` integrated with your shell (recommended), it will activate automatically when you `cd` into the project directory.

## Building and Testing

### Run all tests

```bash
# Make sure the environment is active first!
eval "$(direnv export bash)"

# Run the full test suite
zig build test

# Run with verbose output
zig build test --summary all
```

Tests include:
- Framework core modules (`src/core/`)
- CLAP bindings (`src/bindings/clap/`)
- VST3 bindings (`src/bindings/vst3/`)
- Wrapper implementations

### Build plugins

```bash
# Build all example plugins (outputs to zig-out/plugins/)
zig build

# The gain plugin produces:
# - zig-out/plugins/ZigGain.clap (Linux/macOS) or ZigGain.clap.dll (Windows)
# - zig-out/plugins/ZigGain.vst3/ (macOS bundle) or ZigGain.vst3 (Linux/Windows)
```

### Install plugins for DAW testing

Use the provided helper scripts to install plugins to standard system directories:

```bash
# Install plugins to user directories (recommended)
./install_plugins.sh

# On macOS, plugins must be code-signed for most DAWs
./sign_plugins.sh

# Uninstall plugins
./uninstall_plugins.sh --dry-run  # preview what would be removed
./uninstall_plugins.sh            # actually remove
```

The install script copies plugins to:
- **macOS**: `~/Library/Audio/Plug-Ins/CLAP/` and `~/Library/Audio/Plug-Ins/VST3/`
- **Linux**: `~/.clap/` and `~/.vst3/`
- **Windows**: `%LOCALAPPDATA%\Programs\Common\CLAP\` and `%LOCALAPPDATA%\Programs\Common\VST3\`

After installation, restart your DAW and rescan plugins.

## Project Structure

```
z-plug/
├── docs/                          # High-level documentation (you are here)
│   ├── architecture.md            # Architecture overview
│   ├── getting-started.md         # This file
│   └── plugin-authors.md          # Plugin authoring guide
│
├── src/
│   ├── root.zig                   # Public API re-exports
│   ├── main.zig                   # Test executable entry point
│   │
│   ├── core/                      # Framework core (API-agnostic)
│   │   ├── README.md              # Core module documentation
│   │   ├── plugin.zig             # Plugin interface & validation
│   │   ├── params.zig             # Parameter system with smoothing
│   │   ├── buffer.zig             # Audio buffer abstraction
│   │   ├── events.zig             # Note/MIDI events
│   │   ├── state.zig              # State persistence
│   │   └── audio_layout.zig      # Audio I/O configuration
│   │
│   ├── bindings/
│   │   ├── clap/                  # CLAP C API bindings
│   │   │   ├── README.md          # CLAP bindings docs
│   │   │   ├── main.zig           # CLAP bindings root
│   │   │   └── ... (40+ files)
│   │   │
│   │   └── vst3/                  # VST3 C API bindings
│   │       ├── README.md          # VST3 bindings docs
│   │       ├── root.zig           # VST3 bindings root
│   │       └── ... (~14 files)
│   │
│   └── wrappers/                  # Format-specific wrappers
│       ├── clap/                  # CLAP wrapper implementation
│       │   ├── README.md          # CLAP wrapper docs
│       │   ├── entry.zig          # clap_entry export
│       │   ├── factory.zig        # Plugin factory
│       │   ├── plugin.zig         # Plugin wrapper
│       │   └── extensions.zig     # CLAP extensions
│       │
│       └── vst3/                  # VST3 wrapper implementation
│           ├── README.md          # VST3 wrapper docs
│           ├── factory.zig        # GetPluginFactory export
│           ├── component.zig      # IComponent + IAudioProcessor
│           ├── controller.zig     # IEditController
│           └── com.zig            # COM helpers
│
├── examples/                      # Example plugins
│   └── gain.zig                   # Simple gain plugin (CLAP + VST3)
│
├── build.zig                      # Build system
├── build.zig.zon                  # Package manifest
├── flake.nix                      # Nix development environment
├── install_plugins.sh             # Install plugins to system directories
├── sign_plugins.sh                # Code-sign plugins on macOS
├── uninstall_plugins.sh           # Remove installed plugins
├── AGENTS.md                      # Coding guidelines for AI agents
├── zig-plug-design.md             # Complete design document
└── README.md                      # Project overview
```

## Key References

### Internal Documentation

- **[docs/architecture.md](architecture.md)** — How the layers fit together
- **[docs/plugin-authors.md](plugin-authors.md)** — Writing plugins with zig-plug
- **[AGENTS.md](../AGENTS.md)** — Coding standards and architecture rules
- **Module READMEs** — See `src/*/README.md` for module-specific docs

### External References

- **[nih-plug](https://github.com/robbert-vdh/nih-plug)** — Primary architecture reference (Rust).
- **[CLAP spec](https://github.com/free-audio/clap)** — Official CLAP headers and documentation
- **[VST3 C API](https://github.com/steinbergmedia/vst3_c_api)** — Steinberg's official C API for VST3
- **[SuperElectric blog](https://superelectric.dev/post/post1.html)** — VST3 COM vtables in Zig with comptime
- **[Nakst CLAP tutorials](https://nakst.gitlab.io/tutorial/clap-part-1.html)** — Step-by-step CLAP plugin implementation

## Development Workflow

### Before starting work on a module

1. Read the module's `README.md` (e.g., `src/core/README.md`)
2. Check related docs in `docs/` (e.g., `docs/architecture.md`)
3. Review [AGENTS.md](../AGENTS.md) for coding standards

### After making changes

1. Run tests: `zig build test`
2. Update the module's `README.md` if the public API or structure changed
3. Update related `docs/` files if the change affects high-level architecture or patterns
4. Check lints: `zig build test` includes compile-time checks

### Creating a new module

When adding a new directory under `src/` (e.g., `src/wrappers/clap/`):
1. Create a `README.md` describing the module's purpose, structure, and key types
2. Follow the patterns in existing modules

## Next Steps

- **Writing a plugin:** See [docs/plugin-authors.md](plugin-authors.md)
- **Understanding the architecture:** See [docs/architecture.md](architecture.md)
- **Contributing code:** See [AGENTS.md](../AGENTS.md)
- **Design rationale:** See [docs/architecture.md](architecture.md)
