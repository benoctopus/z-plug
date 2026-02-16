# High-Level Plan: Zig 0.15.2 Audio Plugin Framework (VST3 + CLAP)

## 1. Project Goals and Design Philosophy

The framework should let a plugin author write one Zig module — defining parameters, audio I/O layout, a `process` function, and optionally a GUI — and produce both VST3 and CLAP binaries from the same source. The design takes heavy inspiration from **nih-plug** (Rust), which achieves exactly this by defining an API-agnostic `Plugin` trait and thin format-specific wrappers that translate between the internal trait and the external ABI.[^1][^2]

Core principles:

- **API-agnostic plugin interface**: the plugin author never touches VST3 or CLAP types directly.
- **Comptime-driven metadata**: leverage Zig's comptime to generate vtables, parameter lists, GUIDs, and export symbols at compile time — no runtime reflection or code generation needed.[^3]
- **No allocations on the audio thread**: the framework must enforce real-time safety by design.
- **Minimal magic**: unlike JUCE, prefer explicit over implicit. Similar to nih-plug's philosophy of reducing ceremony while keeping the amount of magic to a minimum.[^1]

***

## 2. Architecture Overview

The framework has four layers:

```
┌──────────────────────────────────────────────┐
│              Plugin Author Code              │
│   (implements PluginInterface, defines Params)│
├──────────────────────────────────────────────┤
│            Framework Core Layer              │
│  (PluginInterface, Buffer, Events, Params,   │
│   ParamSmoother, State, AudioIOLayout)       │
├───────────────────┬──────────────────────────┤
│   CLAP Wrapper    │     VST3 Wrapper         │
│  (C struct ABI)   │  (COM vtable ABI)        │
├───────────────────┴──────────────────────────┤
│          Low-Level Bindings Layer            │
│   clap-zig-bindings    vst3_c_api bindings   │
└──────────────────────────────────────────────┘
```

### 2.1 Low-Level Bindings

**CLAP**: Use or fork the existing `clap-zig-bindings` project, which is a complete hand-written idiomatic Zig translation of the CLAP 1.2.2 API. It models all CLAP structs as Zig `extern struct`s with `callconv(.c)` function pointers. Since Zig 0.15.x requires explicit `callconv` on all extern struct function pointer fields, verify the bindings are updated for 0.15.2 (they target 0.13.0 currently, so some adaptation will be needed).[^4][^5][^6]

**VST3**: Bind against Steinberg's official **VST3 C API** headers (`vst3_c_api`), which provide the entire VST3 interface as C structs with explicit vtable layouts — no C++ name mangling. You have two options:[^7]
1. Use `@cImport` / `zig translate-c` on the C header to auto-generate Zig bindings (note: comments are not preserved by translate-c).[^3]
2. Hand-write the bindings for the ~15 core interfaces, giving you full control over Zig idioms and comptime GUID parsing.

Option 2 is recommended for the core interfaces. The SuperElectric blog post provides an excellent worked example of implementing VST3 COM vtables in Zig with comptime metaprogramming for `FUnknown`/`queryInterface`.[^3]

**Licensing note**: As of October 2025, VST3 moved to MIT licensing, which significantly simplifies redistribution of bindings.[^8]

### 2.2 Framework Core

This is the API-agnostic layer that plugin authors interact with. Modeled after nih-plug's `Plugin` trait:[^9][^10]

```zig
pub const PluginInterface = struct {
    // --- Metadata (comptime constants) ---
    name: [:0]const u8,
    vendor: [:0]const u8,
    url: [:0]const u8,
    version: [:0]const u8,
    plugin_id: [:0]const u8,       // CLAP ID string / VST3 GUID source
    audio_io_layouts: []const AudioIOLayout,
    midi_input: MidiConfig,
    midi_output: MidiConfig,

    // --- Lifecycle callbacks ---
    initFn: *const fn (*PluginState, *const AudioIOLayout, *const BufferConfig) bool,
    resetFn: *const fn (*PluginState) void,
    processFn: *const fn (*PluginState, *Buffer, *AuxBuffers, *ProcessContext) ProcessStatus,
    deinitFn: *const fn (*PluginState) void,

    // --- Extensions ---
    paramsFn: *const fn (*PluginState) *const ParamLayout,
    editorFn: ?*const fn (*PluginState) ?*Editor,
};
```

In practice, you'd likely use Zig's `comptime` interface pattern: the plugin author defines a struct with well-known decls (like Zig's `std.mem.Allocator` pattern), and the framework validates and consumes those decls at compile time. nih-plug does this via Rust traits with associated constants; in Zig, you achieve the same with `comptime` duck typing or `@hasDecl` checks.[^10]

### 2.3 Format Wrappers

Each wrapper:
1. Implements the format's ABI entry points (exported C functions).
2. Owns the format-specific state (e.g., COM ref counts for VST3, host callback pointers for CLAP).
3. Translates between the format's process call and the framework's `processFn`.
4. Maps format-specific parameter change mechanisms to the framework's unified event model.

**CLAP wrapper** responsibilities:
- Export `clap_entry` → `clap_plugin_factory` → instantiate `clap_plugin` structs with function pointers to wrapper functions.[^11][^12]
- Implement fundamental extensions: `audio-ports`, `note-ports`, `params`, `state`, `latency`, `tail`, `gui`.[^13]
- The `process` callback receives a `clap_process_t` with `frames_count`, audio buffer pointers, `in_events`/`out_events`, and transport info. Map these to your framework's `Buffer` and `ProcessContext`.[^14][^12]

**VST3 wrapper** responsibilities:
- Export `GetPluginFactory()` → return `IPluginFactory` COM object.[^3]
- Implement `IComponent` + `IAudioProcessor` (processor side) and `IEditController` (controller side).[^15][^3]
- The `process(ProcessData*)` callback contains audio bus buffers, `IParameterChanges`, `IEventList`, and `ProcessContext`. Map these to the framework's abstractions.[^16]
- Handle COM reference counting and `queryInterface` using a comptime generic `FUnknown` implementation, as demonstrated in the SuperElectric blog.[^3]

***

## 3. Key Subsystem Designs

### 3.1 Parameter System

Following nih-plug's model:[^10][^1]

- Parameters are declared as comptime data: name, ID (stable string hash), range, default, step count, unit label, flags (automatable, modulatable, hidden, etc.).
- The framework generates parameter metadata arrays at comptime for both CLAP (`clap_param_info_t`) and VST3 (`ParameterInfo`).
- **Smoothing**: Provide built-in parameter smoothers (linear ramp, exponential) that the plugin can optionally use. nih-plug offers `Smoother::next()` for per-sample and `Smoother::next_block()` for block-based processing. Automation buffer splitting (dividing the process block at parameter change points) should be opt-in via a flag, similar to nih-plug's `SAMPLE_ACCURATE_AUTOMATION`.[^17][^9][^10]
- **Thread safety**: CLAP's model of main-thread vs. audio-thread parameter arrays with a sync mutex is clean and maps well. For VST3, the dual-component model (processor + controller) requires message passing between the two halves.[^18]

Arbor (the existing Zig framework) demonstrates a simple comptime parameter generation approach worth studying:[^19]

```zig
const params = &[_]arbor.Parameter{
    arbor.param.Float("Gain", 0.0, 10.0, 0.666, .{ .flags = .{} }),
    arbor.param.Choice("Mode", Mode.Vintage, .{ .flags = .{} }),
};
```

### 3.2 Audio Buffer Abstraction

Provide a `Buffer` struct that offers multiple iteration strategies:[^10]

- **Per-sample, per-channel**: for simple plugins and per-sample SIMD.
- **Per-block, per-channel**: for block-based DSP (FFT, convolution).
- **Raw slice access**: `[][]f32` (channels × samples) for maximum control.

Both CLAP and VST3 provide non-interleaved float/double channel buffers, so the mapping is straightforward. The wrapper copies pointers from the format-specific structures into the framework's `Buffer` without copying audio data.

### 3.3 Event System

Unify CLAP events and VST3 events into a single tagged union:

```zig
pub const NoteEvent = union(enum) {
    note_on: NoteOnData,
    note_off: NoteOffData,
    choke: ChokeData,
    poly_pressure: PolyPressureData,
    note_expression: NoteExpressionData,
    midi_cc: MidiCCData,
    // ...
};
```

CLAP provides events via `clap_input_events_t` / `clap_output_events_t` with sample-accurate timestamps. VST3 uses `IEventList` with similar sample offsets. The wrappers translate between format-specific event types and this unified enum.[^12][^20][^16]

### 3.4 State Persistence

Both formats support save/load via stream interfaces. CLAP uses `clap_ostream_t`/`clap_istream_t`; VST3 uses `IBStream`. Provide a simple serialization interface:[^18]

```zig
pub const State = struct {
    saveFn: *const fn (*PluginState, *Writer) bool,
    loadFn: *const fn (*PluginState, *Reader) bool,
};
```

Include a version field in serialized state for migration support, as nih-plug does with `PluginState::version` and `filter_state()`.[^9]

### 3.5 GUI (Deferred)

GUI is complex and cross-platform. Initially, design the interface but defer implementation. The framework should define an `Editor` interface for creating/destroying a platform window and receiving resize events. nih-plug supports pluggable GUI backends (iced, egui, VIZIA); arbor uses a software renderer (Olivec). For Zig, potential paths include:[^21][^19]
- Sokol (C library with easy Zig integration)
- Olivec-style software rendering
- Platform-native (Core Graphics / Direct2D) via thin wrappers

***

## 4. Build System

Leverage `build.zig` to:

1. Accept a plugin definition (source file, metadata, target format).
2. Compile as a shared library (`.clap`, `.vst3` bundle, or both).
3. Handle platform-specific bundling (macOS `.vst3` bundle structure, Linux `.so` paths, Windows `.dll`).
4. Support cross-compilation via Zig's built-in cross-compilation.[^19]

Arbor's build system is a good reference — it uses `arbor.addPlugin(b, .{ ... })` to configure everything from `build.zig`.[^19]

```zig
// Example build.zig usage
const plugin = framework.addPlugin(b, .{
    .name = "MyPlugin",
    .id = "com.mycompany.myplugin",
    .version = "1.0.0",
    .root_source_file = "src/plugin.zig",
    .formats = .{ .clap = true, .vst3 = true },
    .target = target,
    .optimize = optimize,
});
```

***

## 5. Zig 0.15.2 Specific Considerations

- **`callconv(.c)`**: Use lowercase `.c` instead of the deprecated `.C`. All extern struct function pointer fields must have an explicit callconv.[^6][^22]
- **`usingnamespace` removed**: Cannot re-export binding modules via `usingnamespace`. Use explicit `pub const` aliases or `@import` directly.[^23]
- **`async`/`await` removed**: Not relevant for real-time audio (you shouldn't use async in audio threads anyway), but rules out async-based background task patterns.[^23]
- **New `std.Io.Reader`/`std.Io.Writer`**: The I/O interfaces changed significantly. State save/load streams should use the new interfaces.[^24][^25]
- **`@ptrCast` changes**: Important for COM vtable pointer arithmetic. Review the 0.15 semantics.[^26]
- **Build system improvements**: Filesystem watching and incremental compilation help during development.[^23]

***

## 6. Phased Implementation Plan

### Phase 1: Foundations (Weeks 1–3)
- Set up project structure with `build.zig`.
- Write or adapt CLAP bindings for Zig 0.15.2 (starting from `clap-zig-bindings`).[^4]
- Write VST3 C API bindings for the core ~15 interfaces (using `vst3_c_api` headers as reference, SuperElectric blog for patterns).[^7][^3]
- Implement comptime GUID parsing and vtable generation helpers.
- **Milestone**: Can compile and export a do-nothing CLAP plugin and VST3 plugin that loads in a host.

### Phase 2: Core Framework (Weeks 4–7)
- Define the `PluginInterface` / comptime plugin pattern.
- Implement the parameter system: comptime parameter declaration, metadata generation for both formats, normalized↔plain value mapping.
- Implement `Buffer` abstraction with per-sample and per-block iterators.
- Implement the unified `NoteEvent` system.
- Wire up the CLAP wrapper: entry point, factory, `process`, fundamental extensions (`audio-ports`, `params`, `state`).
- Wire up the VST3 wrapper: `GetPluginFactory`, `IComponent`, `IAudioProcessor`, `IEditController`.
- **Milestone**: A simple gain plugin compiles to both CLAP and VST3, loads in a DAW, and processes audio with a working gain parameter.

### Phase 3: Production Features (Weeks 8–12)
- Parameter smoothing (linear ramp, exponential).
- Sample-accurate automation / buffer splitting.
- Full MIDI/note event support (note on/off, poly pressure, note expression, MIDI CC).
- State save/load with versioning.
- Latency reporting.
- Tail length reporting.
- Background task system for non-RT work.
- Cross-platform bundling in `build.zig` (macOS bundles, Windows DLL, Linux SO).
- **Milestone**: A polyphonic synth plugin and a multi-parameter effect plugin working in multiple DAWs on multiple platforms.

### Phase 4: Polish and Extras (Weeks 13+)
- GUI interface definition and initial backend (likely software rendering or sokol).
- CLAP-specific features: polyphonic modulation, remote controls.[^1]
- Standalone binary support (direct JACK/ALSA/CoreAudio output).
- Plugin validator integration (clap-validator, VST3 pluginval).
- Documentation and example plugins.
- Publish as a Zig package.

***

## 7. Key References

### Specifications and APIs

| Resource | URL | Notes |
|---|---|---|
| CLAP spec + headers | https://github.com/free-audio/clap | Pure C ABI, extension-based architecture[^13] |
| VST3 C API | https://github.com/steinbergmedia/vst3_c_api | Auto-generated C headers from C++ SDK[^7] |
| VST3 C API Generator | https://github.com/steinbergmedia/vst3_c_api_generator | Includes a C gain test plugin[^27] |
| VST3 Developer Portal | https://steinbergmedia.github.io/vst3_dev_portal/ | Official docs for VST3 architecture[^15] |
| VST3 SDK | https://github.com/steinbergmedia/vst3sdk | Full SDK with examples[^28] |
| CLAP tutorial (Nakst) | https://nakst.gitlab.io/tutorial/clap-part-1.html | Excellent step-by-step C implementation[^12] |
| CLAP tutorial Part 2 | https://nakst.gitlab.io/tutorial/clap-part-2.html | Parameters and state[^18] |

### Reference Frameworks

| Resource | URL | Notes |
|---|---|---|
| nih-plug | https://github.com/robbert-vdh/nih-plug | Primary architecture reference (Rust, VST3+CLAP)[^1] |
| nih-plug Plugin trait | https://github.com/robbert-vdh/nih-plug/blob/master/src/plugin.rs | Core trait definition[^9] |
| nih-plug Plugin docs | https://nih-plug.robbertvanderhelm.nl/nih_plug/plugin/trait.Plugin.html | Detailed trait documentation[^10] |
| nih-plug wrappers | https://nih-plug.robbertvanderhelm.nl/nih_plug/wrapper/index.html | CLAP/VST3/standalone wrapper modules[^29] |
| arbor (Zig) | https://github.com/ArborealAudio/arbor | Existing Zig plugin framework (CLAP + VST2)[^19] |

### Zig-Specific

| Resource | URL | Notes |
|---|---|---|
| clap-zig-bindings | https://git.sr.ht/~interpunct/clap-zig-bindings | Full idiomatic Zig CLAP bindings[^4] |
| zig-clap | https://github.com/ramonmeza/zig-clap | Alternative CLAP bindings for Zig[^30] |
| SuperElectric VST3+Zig blog | https://superelectric.dev/post/post1.html | VST3 COM vtables in Zig with comptime metaprogramming[^3] |
| Ziggit VST3 thread | https://ziggit.dev/t/vst3-in-zig/2797 | Community discussion on Zig VST3[^31] |
| nectar (Zig) | https://github.com/ajkachnic/nectar | Early Zig plugin framework (pre-alpha, VST2)[^32] |
| Zig 0.15.1 release notes | https://ziglang.org/download/0.15.1/release-notes.html | Key language/stdlib changes[^33] |
| Zig 0.15.2 release notes | https://ziggit.dev/t/zig-0-15-2-released/12466 | Bug fixes over 0.15.1[^34] |
| Zig 0.14.0 callconv changes | https://ziglang.org/download/0.14.0/release-notes.html | callconv(.c) lowercase, extern struct rules[^22] |

### Community and Ecosystem

| Resource | URL | Notes |
|---|---|---|
| clap-wrapper (CLAP→VST3/AU) | https://github.com/free-audio/clap-wrapper | Wraps CLAP plugins as VST3/AUv2[^35] |
| CLAP plugin database | https://clapdb.tech | List of CLAP-supporting plugins and DAWs |
| KVR CLAP discussion | https://www.kvraudio.com/forum/viewtopic.php?t=583140 | Community discussion on CLAP format[^20] |
| COM in plain C (Jeff Glatt) | Referenced in SuperElectric blog | Foundational COM resource for non-C++ languages[^3] |

---

## References

1. [robbert-vdh/nih-plug: Rust VST3 and CLAP plugin framework and ...](https://github.com/robbert-vdh/nih-plug) - Rust VST3 and CLAP plugin framework and plugins - because everything is better when you do it yourse...

2. [GitHub - robbert-vdh/nih-plug: Rust VST3 and CLAP plugin framework and plugins - because everything is better when you do it yourself](https://github.com/robbert-vdh/nih-plug/tree/master) - Rust VST3 and CLAP plugin framework and plugins - because everything is better when you do it yourse...

3. [SuperElectric](https://superelectric.dev/post/post1.html)

4. [Manually written idiomatic Zig bindings for the CLAP audio API - Sr.ht](https://sr.ht/~interpunct/clap-zig-bindings/) - #clap-zig-bindings. Zig bindings for the CLAP audio API. This is a full hand-written translation. Ev...

5. [GitHub - interpunct/clap-zig-bindings: manually written idiomatic zig bindings for CLAP audio API (mirror)](https://github.com/interpunct/clap-zig-bindings) - manually written idiomatic zig bindings for CLAP audio API (mirror) - interpunct/clap-zig-bindings

6. [non `callconv(.C)` function pointers no longer allowed in extern ...](https://github.com/ziglang/zig/issues/19921) - Its a pointer to an unspecified callconv fn being passed to a callconv(.C) function. it would be see...

7. [steinbergmedia/vst3_c_api: The C API header of the VST3 ...](https://github.com/steinbergmedia/vst3_c_api) - This repository contains the VST3 C API. The VST3 C API has the same dual license as the VST3 C++ AP...

8. [VST3 audio plugin format is now MIT](https://news.ycombinator.com/item?id=45678549) - The C standard similarly does not specify an ABI. Not really, VST3's COM-like API just uses virtual ...

9. [nih-plug/src/plugin.rs at master · robbert-vdh/nih-plug](https://github.com/robbert-vdh/nih-plug/blob/master/src/plugin.rs) - Rust VST3 and CLAP plugin framework and plugins - because everything is better when you do it yourse...

10. [Plugin in nih_plug::plugin - Rust](https://nih-plug.robbertvanderhelm.nl/nih_plug/plugin/trait.Plugin.html) - The main plugin trait covering functionality common across most plugin formats. Most formats also ha...

11. [clap/README.md at main · free-audio/clap](https://github.com/free-audio/clap/blob/main/README.md) - Audio Plugin API. Contribute to free-audio/clap development by creating an account on GitHub.

12. [CLAP tutorial part 1 - GitLab](https://nakst.gitlab.io/tutorial/clap-part-1.html)

13. [free-audio/clap: Audio Plugin API - GitHub](https://github.com/free-audio/clap) - Audio Plugin API. Contribute to free-audio/clap development by creating an account on GitHub.

14. [clap/include/clap/process.h at main · free-audio/clap - GitHub](https://github.com/free-audio/clap/blob/main/include/clap/process.h) - ... events will be provided. const clap_event_transport_t *transport;. // Audio buffers, they must h...

15. [The Editing Part](https://steinbergmedia.github.io/vst3_dev_portal/pages/Technical+Documentation/API+Documentation/Index.html)

16. [vst3_pluginterfaces/vst/ivstaudioprocessor.h at master · steinbergmedia/vst3_pluginterfaces](https://github.com/steinbergmedia/vst3_pluginterfaces/blob/master/vst/ivstaudioprocessor.h) - VST 3 API. Contribute to steinbergmedia/vst3_pluginterfaces development by creating an account on Gi...

17. [Sample accurate parameter automation? - Audio Plugins - JUCE](https://forum.juce.com/t/sample-accurate-parameter-automation/50277) - It's also worth mentioning that slicing buffers not only allows the host to make automations “sound ...

18. [CLAP tutorial part 2 - GitLab](https://nakst.gitlab.io/tutorial/clap-part-2.html)

19. [ArborealAudio/arbor: Easy-to-use audio plugin framework - GitHub](https://github.com/ArborealAudio/arbor) - A nice abstraction layer over plugin APIs which should lend itself nicely to extending support to ot...

20. [CLAP: The New Audio Plug-in Standard (by U-he, Bitwig and others)](https://www.kvraudio.com/forum/viewtopic.php?t=583140&start=210) - CLAP has its own API for playing notes. 'CLAP_NOTE_DIALECT_CLAP' 'clap_event_note' includes a 'note_...

21. [Audio Plugin User Interfaces in Rust](https://www.youtube.com/watch?v=3xO2DNay51M) - This time you can learn how to build modern GPU accelerated user interfaces (GUI) for your audio plu...

22. [0.14.0 Release Notes The Zig Programming Language](https://ziglang.org/download/0.14.0/release-notes.html) - Along with a slew of Build System upgrades, Language Changes, and Target Support enhancements, this ...

23. [Zig 0.15.1 Release: Writergate, Async Removal, and 5x Faster Builds](https://www.youtube.com/watch?v=zZWId9TsXY0) - Zig 0.15.1 is here — and it’s a massive release. In this video, we break down everything you need to...

24. [Zig version 0.15.1](https://lwn.net/Articles/1034583/) - The Zig project has announced version 0.15.1 of the language. The release, much like the last [...]

25. [Zig 0.15.1 I/O Overhaul: Understanding the New Reader/Writer ...](https://dev.to/bkataru/zig-0151-io-overhaul-understanding-the-new-readerwriter-interfaces-30oe) - Introduction Prior to Zig version 0.15.1, writing to standard output was more or less...

26. [Zig got better and I almost missed it](https://www.youtube.com/watch?v=Mr4MB5mtAMY&vl=en) - # Zig 0.15 release review with explanations and examples

Voice by @tokisuno 

**Links:**

- Release...

27. [GitHub - steinbergmedia/vst3_c_api_generator: The VST3 C API Generator](https://github.com/steinbergmedia/vst3_c_api_generator) - The VST3 C API Generator. Contribute to steinbergmedia/vst3_c_api_generator development by creating ...

28. [steinbergmedia/vst3sdk: VST 3 Plug-In SDK - GitHub](https://github.com/steinbergmedia/vst3sdk) - VST 3 Plug-In SDK. Contribute to steinbergmedia/vst3sdk development by creating an account on GitHub...

29. [Module nih_plug::wrapper](https://nih-plug.robbertvanderhelm.nl/nih_plug/wrapper/index.html) - Wrappers for different plugin types. Each wrapper has an entry point macro that you can pass the nam...

30. [GitHub - ramonmeza/zig-clap: Zig bindings for free-audio's CLAP library.](https://github.com/ramonmeza/zig-clap) - Zig bindings for free-audio's CLAP library. Contribute to ramonmeza/zig-clap development by creating...

31. [VST3 in Zig! - Ziggit](https://ziggit.dev/t/vst3-in-zig/2797) - Hey guys! Wrote this blog post on writing VST3 plugins in Zig, thought some of you might be interest...

32. [GitHub - ajkachnic/nectar: A cross-platform audio plugin framework for Zig.](https://github.com/ajkachnic/nectar) - A cross-platform audio plugin framework for Zig. Contribute to ajkachnic/nectar development by creat...

33. [0.15.1 Release Notes The Zig Programming Language](https://ziglang.org/download/0.15.1/release-notes.html)

34. [Zig 0.15.2 Released - News - Ziggit Dev](https://ziggit.dev/t/zig-0-15-2-released/12466) - Fixed issues:

35. [clap_wrapper - Rust - Docs.rs](https://docs.rs/clap-wrapper) - Provides a simple way to export Rust-based CLAP plugins as VST3 and AUv2 plugins. ... You'd still ha...

