# z-plug

Audio plugin framework for Zig. Write a plugin once, get VST3 and CLAP binaries from the same source. Inspired by [nih-plug](https://github.com/robbert-vdh/nih-plug).

Requires Zig 0.15.2.

## Example

A minimal gain plugin (`examples/gain.zig`):

```zig
const z_plug = @import("z_plug");

const GainPlugin = struct {
    pub const name: [:0]const u8 = "Zig Gain";
    pub const vendor: [:0]const u8 = "zig-plug";
    pub const url: [:0]const u8 = "https://github.com/example/zig-plug";
    pub const version: [:0]const u8 = "0.1.0";
    pub const plugin_id: [:0]const u8 = "com.zig-plug.gain";

    pub const audio_io_layouts = &[_]z_plug.AudioIOLayout{
        z_plug.AudioIOLayout.STEREO,
    };

    pub const params = &[_]z_plug.Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 1.0,
            .range = .{ .min = 0.0, .max = 2.0 },
            .unit = "",
            .flags = .{},
            .smoothing = .{ .linear = 10.0 },
        } },
    };

    pub fn init(_: *@This(), _: *const z_plug.AudioIOLayout, _: *const z_plug.BufferConfig) bool {
        return true;
    }

    pub fn deinit(_: *@This()) void {}

    pub fn process(
        _: *@This(),
        buffer: *z_plug.Buffer,
        _: *z_plug.AuxBuffers,
        context: *z_plug.ProcessContext,
    ) z_plug.ProcessStatus {
        const num_samples = buffer.num_samples;
        const num_channels = buffer.channel_data.len;

        var i: usize = 0;
        while (i < num_samples) : (i += 1) {
            const gain = context.nextSmoothed(1, 0);
            for (buffer.channel_data[0..num_channels]) |channel| {
                channel[i] *= gain;
            }
        }

        return z_plug.ProcessStatus.ok();
    }
};

// Export both formats
comptime {
    _ = z_plug.ClapEntry(GainPlugin);
    _ = z_plug.Vst3Factory(GainPlugin);
}
```

Plugin metadata, parameters, and audio layout are declared as comptime constants. The framework uses them to generate vtables, parameter lists, GUIDs, and lookup tables at compile time. No allocations happen on the audio thread.

## Building

The `flake.nix` provides a dev environment with the right Zig version via Nix + direnv.

```bash
# Set up nix + direnv, then run this in the project root:
direnv allow

# Build example plugins (outputs to plugins/)
zig build

# Run tests
zig build test

# Install plugins to user directories
zig build install-plugins

# Install to system directories (requires sudo)
zig build install-plugins -Dsystem=true

# Sign plugins on macOS (required for most DAWs)
zig build sign-plugins

# Uninstall
zig build uninstall-plugins
```

See [docs/getting-started.md](docs/getting-started.md) for more.

## Project Structure

```
src/
  core/              # Framework core (format-agnostic)
    plugin.zig       # Plugin interface & comptime validation
    params.zig       # Parameter system with smoothing
    buffer.zig       # Audio buffer abstraction
    events.zig       # Unified note/MIDI events
    state.zig        # State persistence
    audio_layout.zig # Audio I/O configuration
  bindings/
    clap/            # CLAP C API bindings (LGPL v3)
    vst3/            # VST3 C API bindings (MIT)
  wrappers/          # Format-specific wrappers
    clap/            # CLAP wrapper
    vst3/            # VST3 wrapper
    common.zig       # Shared wrapper utilities
  root.zig           # Public API
examples/
  gain.zig           # Gain plugin (CLAP + VST3)
build.zig            # Build system with addPlugin() helper
build_tools/         # Install/sign/uninstall scripts
docs/                # Documentation
```

## Documentation

- [docs/plugin-authors.md](docs/plugin-authors.md) -- writing plugins with z-plug
- [docs/getting-started.md](docs/getting-started.md) -- dev environment setup
- [docs/architecture.md](docs/architecture.md) -- how the layers fit together
- [AGENTS.md](AGENTS.md) -- coding standards

## Status

The core framework, both wrappers, and the build system work. The example gain plugin loads and runs in DAWs. Still to do: more example plugins, CI, and deciding on a license for the framework itself.

## License

Framework license: TBD.

**CLAP bindings** (`src/bindings/clap/`): derived from [clap-zig-bindings](https://git.sr.ht/~interpunct/clap-zig-bindings), GNU LGPL v3.0+. See `src/bindings/clap/LICENSE`.

**VST3 bindings** (`src/bindings/vst3/`): based on [Steinberg vst3_c_api](https://github.com/steinbergmedia/vst3_c_api), MIT.
