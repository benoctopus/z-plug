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
            .default = 0.0,
            .range = .{ .linear = .{ .min = -60.0, .max = 24.0 } },
            .unit = "dB",
            .smoothing = .{ .logarithmic = 50.0 },
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
            const gain = z_plug.util.dbToGainFast(context.nextSmoothed(1, 0));
            for (buffer.channel_data[0..num_channels]) |channel| {
                channel[i] *= gain;
            }
        }

        return z_plug.ProcessStatus.ok();
    }
};

comptime { _ = z_plug.ClapEntry(GainPlugin); }
comptime { _ = z_plug.Vst3Factory(GainPlugin); }
```

Plugin metadata, parameters, and audio layout are declared as comptime constants. The framework generates vtables, parameter lists, GUIDs, and lookup tables at compile time. No allocations happen on the audio thread. The `util.dbToGainFast` conversion turns the dB parameter into a linear gain factor in the inner loop.

See [`examples/super_gain.zig`](examples/super_gain.zig) for a more complete showcase: dB-scale gain with logarithmic smoothing, mid-side stereo width, platform-adaptive SIMD, denormal flushing, block-based processing, and channel routing.

## Building

The `flake.nix` provides a dev environment with the right Zig version via Nix + direnv.

```bash
# Set up nix + direnv, then run this in the project root:
direnv allow

# Build example plugins (outputs to plugins/)
zig build

# Run tests
zig build test

# Install plugins to user directories (automatically signs on macOS)
zig build install-plugins

# Install to system directories (requires sudo, automatically signs on macOS)
zig build install-plugins -Dsystem=true

# Sign plugins on macOS without installing (optional - install-plugins does this automatically)
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
  gain.zig           # Minimal gain plugin (CLAP + VST3)
  super_gain.zig     # Feature showcase (dB gain, width, SIMD, etc.)
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

The core framework, both wrappers, and the build system work. The example gain plugin loads and runs in DAWs. Still to do: 
- UI support
- more example plugins
- probably many other things and stuff yet to be determined

This is an **mvp** implementation and a lot of the framework is wholly untested, use at your own risk.

## License

Framework code is licensed under the [Mozilla Public License 2.0](LICENSE).

**CLAP bindings** (`src/bindings/clap/`): derived from [clap-zig-bindings](https://git.sr.ht/~interpunct/clap-zig-bindings), GNU LGPL v3.0+. See `src/bindings/clap/LICENSE`.

**VST3 bindings** (`src/bindings/vst3/`): based on [Steinberg vst3_c_api](https://github.com/steinbergmedia/vst3_c_api), MIT. See `src/bindings/vst3/LICENSE`.
