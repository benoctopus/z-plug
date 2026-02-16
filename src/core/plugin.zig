/// Plugin interface and comptime validation.
///
/// This module provides the `Plugin(comptime T)` comptime function that
/// validates a plugin struct at compile time and generates metadata for the
/// wrappers. Plugin authors define a struct with well-known declarations
/// (similar to Zig's `std.mem.Allocator` pattern), and the framework validates
/// and consumes those declarations at compile time.
const std = @import("std");
const audio_layout = @import("audio_layout.zig");
const buffer_mod = @import("buffer.zig");
const events_mod = @import("events.zig");
const params_mod = @import("params.zig");
const state_mod = @import("state.zig");

pub const AudioIOLayout = audio_layout.AudioIOLayout;
pub const BufferConfig = audio_layout.BufferConfig;
pub const MidiConfig = audio_layout.MidiConfig;
pub const Transport = audio_layout.Transport;
pub const Buffer = buffer_mod.Buffer;
pub const AuxBuffers = buffer_mod.AuxBuffers;
pub const NoteEvent = events_mod.NoteEvent;
pub const Param = params_mod.Param;
pub const SaveContext = state_mod.SaveContext;
pub const LoadContext = state_mod.LoadContext;

// ---------------------------------------------------------------------------
// ProcessStatus
// ---------------------------------------------------------------------------

/// Return value from the plugin's `process` function, indicating the
/// processing result and tail behavior.
pub const ProcessStatus = union(enum) {
    /// An error occurred during processing.
    err: []const u8,
    /// Normal processing, output contains audio.
    normal,
    /// Processing complete, but a tail of `N` samples remains (e.g., reverb decay).
    tail: u32,
    /// Infinite tail — the plugin should never be deactivated (e.g., continuous oscillator).
    keep_alive,
    /// Output is silent (host may optimize by not processing downstream).
    silence,

    /// Convenience constructor for normal processing.
    pub fn ok() ProcessStatus {
        return .normal;
    }

    /// Convenience constructor for an error with a message.
    pub fn failed(msg: []const u8) ProcessStatus {
        return .{ .err = msg };
    }
};

// ---------------------------------------------------------------------------
// ProcessContext
// ---------------------------------------------------------------------------

/// Context passed to the plugin's `process` function, providing transport
/// info, incoming events, and an output event list.
pub const ProcessContext = struct {
    /// Current transport state and timeline info.
    transport: Transport,
    /// Incoming note/MIDI events for this buffer, pre-sorted by timing.
    input_events: []const NoteEvent,
    /// Output event list for sending events back to the host.
    output_events: *EventOutputList,
    /// The host's current sample rate in Hz.
    sample_rate: f32,
    
    // Parameter access (opaque pointers to avoid making ProcessContext generic)
    param_values_ptr: ?*anyopaque = null,
    smoothers_ptr: ?*anyopaque = null,
    params_meta: []const Param = &[_]Param{},
    
    /// Get the current plain value of a float parameter at comptime-known index.
    /// N is the total number of parameters.
    pub fn getFloat(self: *const ProcessContext, comptime N: usize, comptime index: usize) f32 {
        const param = self.params_meta[index];
        const values: *const params_mod.ParamValues(N) = @ptrCast(@alignCast(self.param_values_ptr));
        const normalized = values.get(index);
        return param.float.range.unnormalize(normalized);
    }
    
    /// Get the current plain value of an int parameter at comptime-known index.
    pub fn getInt(self: *const ProcessContext, comptime N: usize, comptime index: usize) i32 {
        const param = self.params_meta[index];
        const values: *const params_mod.ParamValues(N) = @ptrCast(@alignCast(self.param_values_ptr));
        const normalized = values.get(index);
        return param.int.range.unnormalize(normalized);
    }
    
    /// Get the current value of a bool parameter at comptime-known index.
    pub fn getBool(self: *const ProcessContext, comptime N: usize, comptime index: usize) bool {
        const values: *const params_mod.ParamValues(N) = @ptrCast(@alignCast(self.param_values_ptr));
        const normalized = values.get(index);
        return normalized > 0.5;
    }
    
    /// Get the current choice index of a choice parameter at comptime-known index.
    pub fn getChoice(self: *const ProcessContext, comptime N: usize, comptime index: usize) u32 {
        const param = self.params_meta[index];
        const values: *const params_mod.ParamValues(N) = @ptrCast(@alignCast(self.param_values_ptr));
        const normalized = values.get(index);
        if (param.choice.labels.len <= 1) return 0;
        return @intFromFloat(normalized * @as(f32, @floatFromInt(param.choice.labels.len - 1)));
    }
    
    /// Get the next smoothed sample for a parameter.
    /// Returns the current value if smoothing is not configured for this parameter.
    pub fn nextSmoothed(self: *ProcessContext, comptime N: usize, comptime index: usize) f32 {
        const smoothers: *params_mod.SmootherBank(N) = @ptrCast(@alignCast(self.smoothers_ptr));
        return smoothers.next(index);
    }
};

// ---------------------------------------------------------------------------
// EventOutputList
// ---------------------------------------------------------------------------

/// A bounded, push-only list for output events (e.g., note-off from a
/// voice that finished naturally).
///
/// The wrapper pre-allocates this with a fixed capacity. Plugins push events
/// during `process`; the wrapper translates them to format-specific events
/// after the process call returns.
pub const EventOutputList = struct {
    /// Pre-allocated slice for output events.
    events: []NoteEvent,
    /// Current number of events pushed.
    count: usize = 0,

    /// Push an event to the output list. Returns `false` if the list is full.
    pub fn push(self: *EventOutputList, event: NoteEvent) bool {
        if (self.count >= self.events.len) return false;
        self.events[self.count] = event;
        self.count += 1;
        return true;
    }

    /// Clear all events from the list.
    pub fn clear(self: *EventOutputList) void {
        self.count = 0;
    }

    /// Returns the slice of events that have been pushed.
    pub fn slice(self: *const EventOutputList) []const NoteEvent {
        return self.events[0..self.count];
    }

    /// Returns `true` if no events have been pushed.
    pub fn isEmpty(self: *const EventOutputList) bool {
        return self.count == 0;
    }

    /// Returns the remaining capacity.
    pub fn remaining(self: *const EventOutputList) usize {
        return self.events.len - self.count;
    }
};

// ---------------------------------------------------------------------------
// Plugin comptime validation
// ---------------------------------------------------------------------------

/// Comptime function that validates a plugin struct `T` and returns a
/// namespace with metadata and helper functions for the wrappers.
///
/// Required declarations on `T`:
/// - `name: [:0]const u8`
/// - `vendor: [:0]const u8`
/// - `url: [:0]const u8`
/// - `version: [:0]const u8`
/// - `plugin_id: [:0]const u8`
/// - `audio_io_layouts: []const AudioIOLayout`
/// - `params: []const Param`
/// - `init: fn(*T, *const AudioIOLayout, *const BufferConfig) bool`
/// - `deinit: fn(*T) void`
/// - `process: fn(*T, *Buffer, *AuxBuffers, *ProcessContext) ProcessStatus`
///
/// Optional declarations:
/// - `midi_input: MidiConfig` (default: `.none`)
/// - `midi_output: MidiConfig` (default: `.none`)
/// - `reset: fn(*T) void` (default: no-op)
/// - `save: fn(*T, SaveContext) bool` (default: no-op returning true)
/// - `load: fn(*T, LoadContext) bool` (default: no-op returning true)
pub fn Plugin(comptime T: type) type {
    // Validate metadata fields
    if (!@hasDecl(T, "name")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub const name: [:0]const u8'");
    }
    if (@TypeOf(T.name) != [:0]const u8) {
        @compileError("Plugin '" ++ @typeName(T) ++ "'.name must be of type '[:0]const u8'");
    }

    if (!@hasDecl(T, "vendor")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub const vendor: [:0]const u8'");
    }
    if (@TypeOf(T.vendor) != [:0]const u8) {
        @compileError("Plugin '" ++ @typeName(T) ++ "'.vendor must be of type '[:0]const u8'");
    }

    if (!@hasDecl(T, "url")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub const url: [:0]const u8'");
    }
    if (@TypeOf(T.url) != [:0]const u8) {
        @compileError("Plugin '" ++ @typeName(T) ++ "'.url must be of type '[:0]const u8'");
    }

    if (!@hasDecl(T, "version")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub const version: [:0]const u8'");
    }
    if (@TypeOf(T.version) != [:0]const u8) {
        @compileError("Plugin '" ++ @typeName(T) ++ "'.version must be of type '[:0]const u8'");
    }

    if (!@hasDecl(T, "plugin_id")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub const plugin_id: [:0]const u8'");
    }
    if (@TypeOf(T.plugin_id) != [:0]const u8) {
        @compileError("Plugin '" ++ @typeName(T) ++ "'.plugin_id must be of type '[:0]const u8'");
    }

    // Validate audio I/O layouts
    if (!@hasDecl(T, "audio_io_layouts")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub const audio_io_layouts: []const AudioIOLayout'");
    }
    // Check type compatibility
    const layouts_type_info = @typeInfo(@TypeOf(T.audio_io_layouts));
    if (layouts_type_info != .pointer) {
        @compileError("Plugin '" ++ @typeName(T) ++ "'.audio_io_layouts must be '[]const AudioIOLayout'");
    }

    // Validate params
    if (!@hasDecl(T, "params")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub const params: []const Param'");
    }
    const params_type_info = @typeInfo(@TypeOf(T.params));
    if (params_type_info != .pointer) {
        @compileError("Plugin '" ++ @typeName(T) ++ "'.params must be '[]const Param'");
    }

    // Validate lifecycle functions
    if (!@hasDecl(T, "init")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub fn init(self: *T, layout: *const AudioIOLayout, config: *const BufferConfig) bool'");
    }
    // Basic signature check (full signature validation is complex in comptime)
    const InitFn = @TypeOf(T.init);
    if (@typeInfo(InitFn) != .@"fn") {
        @compileError("Plugin '" ++ @typeName(T) ++ "'.init must be a function");
    }

    if (!@hasDecl(T, "deinit")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub fn deinit(self: *T) void'");
    }

    if (!@hasDecl(T, "process")) {
        @compileError("Plugin '" ++ @typeName(T) ++ "' must declare 'pub fn process(self: *T, buffer: *Buffer, aux: *AuxBuffers, context: *ProcessContext) ProcessStatus'");
    }

    // Return a namespace with plugin metadata and helpers
    return struct {
        pub const PluginType = T;

        // Metadata
        pub const name = T.name;
        pub const vendor = T.vendor;
        pub const url = T.url;
        pub const version = T.version;
        pub const plugin_id = T.plugin_id;
        pub const audio_io_layouts = T.audio_io_layouts;
        pub const params = T.params;

        // MIDI I/O config (with defaults)
        pub const midi_input = if (@hasDecl(T, "midi_input")) T.midi_input else MidiConfig.none;
        pub const midi_output = if (@hasDecl(T, "midi_output")) T.midi_output else MidiConfig.none;
        
        /// Whether the plugin requests sample-accurate parameter automation.
        /// When true, the wrapper will split process buffers at parameter change points.
        /// When false (default), parameter changes apply at the start of each block.
        pub const sample_accurate_automation = if (@hasDecl(T, "sample_accurate_automation")) T.sample_accurate_automation else false;

        // Optional callbacks
        pub const has_reset = @hasDecl(T, "reset");
        pub const has_save = @hasDecl(T, "save");
        pub const has_load = @hasDecl(T, "load");

        /// Call the plugin's `init` function.
        pub fn init(plugin: *T, layout: *const AudioIOLayout, config: *const BufferConfig) bool {
            return T.init(plugin, layout, config);
        }

        /// Call the plugin's `deinit` function.
        pub fn deinit(plugin: *T) void {
            T.deinit(plugin);
        }

        /// Call the plugin's `reset` function (or no-op if not provided).
        pub fn reset(plugin: *T) void {
            if (has_reset) {
                T.reset(plugin);
            }
        }

        /// Call the plugin's `process` function.
        pub fn process(plugin: *T, buf: *Buffer, aux: *AuxBuffers, context: *ProcessContext) ProcessStatus {
            return T.process(plugin, buf, aux, context);
        }

        /// Call the plugin's `save` function (or no-op if not provided).
        pub fn save(plugin: *T, context: SaveContext) bool {
            if (has_save) {
                return T.save(plugin, context);
            }
            return true;
        }

        /// Call the plugin's `load` function (or no-op if not provided).
        pub fn load(plugin: *T, context: LoadContext) bool {
            if (has_load) {
                return T.load(plugin, context);
            }
            return true;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ProcessStatus constructors" {
    const ok_status = ProcessStatus.ok();
    try std.testing.expectEqual(ProcessStatus.normal, ok_status);

    const fail_status = ProcessStatus.failed("test error");
    try std.testing.expectEqualStrings("test error", fail_status.err);
}

test "EventOutputList push and slice" {
    var event_storage: [4]NoteEvent = undefined;
    var list = EventOutputList{ .events = &event_storage };

    try std.testing.expect(list.isEmpty());
    try std.testing.expectEqual(@as(usize, 4), list.remaining());

    const event1 = NoteEvent{ .note_on = .{
        .timing = 0,
        .channel = 0,
        .note = 60,
        .velocity = 1.0,
    } };
    try std.testing.expect(list.push(event1));
    try std.testing.expectEqual(@as(usize, 1), list.count);
    try std.testing.expect(!list.isEmpty());

    const slice = list.slice();
    try std.testing.expectEqual(@as(usize, 1), slice.len);
    try std.testing.expectEqual(@as(u32, 0), slice[0].timing());
}

test "EventOutputList capacity limit" {
    var event_storage: [2]NoteEvent = undefined;
    var list = EventOutputList{ .events = &event_storage };

    const event = NoteEvent{ .note_on = .{
        .timing = 0,
        .channel = 0,
        .note = 60,
        .velocity = 1.0,
    } };

    try std.testing.expect(list.push(event));
    try std.testing.expect(list.push(event));
    try std.testing.expect(!list.push(event)); // Full
    try std.testing.expectEqual(@as(usize, 2), list.count);
}

test "EventOutputList clear" {
    var event_storage: [2]NoteEvent = undefined;
    var list = EventOutputList{ .events = &event_storage };

    const event = NoteEvent{ .note_on = .{
        .timing = 0,
        .channel = 0,
        .note = 60,
        .velocity = 1.0,
    } };

    _ = list.push(event);
    try std.testing.expectEqual(@as(usize, 1), list.count);
    list.clear();
    try std.testing.expectEqual(@as(usize, 0), list.count);
    try std.testing.expect(list.isEmpty());
}

// A minimal valid plugin for compile-time validation testing.
const TestPlugin = struct {
    pub const name: [:0]const u8 = "Test Plugin";
    pub const vendor: [:0]const u8 = "Test Vendor";
    pub const url: [:0]const u8 = "https://example.com";
    pub const version: [:0]const u8 = "1.0.0";
    pub const plugin_id: [:0]const u8 = "com.example.test";
    pub const audio_io_layouts = &[_]AudioIOLayout{AudioIOLayout.STEREO};
    pub const params = &[_]Param{};

    gain: f32 = 1.0,

    pub fn init(_: *TestPlugin, _: *const AudioIOLayout, _: *const BufferConfig) bool {
        return true;
    }

    pub fn deinit(_: *TestPlugin) void {}

    pub fn process(_: *TestPlugin, _: *Buffer, _: *AuxBuffers, _: *ProcessContext) ProcessStatus {
        return ProcessStatus.ok();
    }
};

test "Plugin comptime validation with valid struct" {
    const P = Plugin(TestPlugin);
    try std.testing.expectEqualStrings("Test Plugin", P.name);
    try std.testing.expectEqualStrings("Test Vendor", P.vendor);
    try std.testing.expectEqualStrings("https://example.com", P.url);
    try std.testing.expectEqualStrings("1.0.0", P.version);
    try std.testing.expectEqualStrings("com.example.test", P.plugin_id);
    try std.testing.expectEqual(@as(usize, 1), P.audio_io_layouts.len);
    try std.testing.expectEqual(@as(usize, 0), P.params.len);
    try std.testing.expectEqual(MidiConfig.none, P.midi_input);
    try std.testing.expectEqual(MidiConfig.none, P.midi_output);
    try std.testing.expect(!P.has_reset);
    try std.testing.expect(!P.has_save);
    try std.testing.expect(!P.has_load);
}

test "Plugin optional callbacks" {
    const PluginWithReset = struct {
        pub const name: [:0]const u8 = "Test";
        pub const vendor: [:0]const u8 = "Test";
        pub const url: [:0]const u8 = "https://example.com";
        pub const version: [:0]const u8 = "1.0.0";
        pub const plugin_id: [:0]const u8 = "com.example.test2";
        pub const audio_io_layouts = &[_]AudioIOLayout{AudioIOLayout.MONO};
        pub const params = &[_]Param{};

        pub fn init(_: *@This(), _: *const AudioIOLayout, _: *const BufferConfig) bool {
            return true;
        }
        pub fn deinit(_: *@This()) void {}
        pub fn reset(_: *@This()) void {}
        pub fn process(_: *@This(), _: *Buffer, _: *AuxBuffers, _: *ProcessContext) ProcessStatus {
            return ProcessStatus.ok();
        }
    };

    const P = Plugin(PluginWithReset);
    try std.testing.expect(P.has_reset);
    try std.testing.expect(!P.has_save);
    try std.testing.expect(!P.has_load);
}

test "ProcessContext parameter access via methods" {
    const params = [_]Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 0.0,
            .range = .{ .min = -24.0, .max = 24.0 },
        } },
        .{ .int = .{
            .name = "Cutoff",
            .id = "cutoff",
            .default = 1000,
            .range = .{ .min = 20, .max = 20000 },
        } },
        .{ .boolean = .{
            .name = "Bypass",
            .id = "bypass",
            .default = false,
        } },
    };
    
    var param_values = params_mod.ParamValues(3).init(&params);
    var smoother_bank = params_mod.SmootherBank(3).init(&params);
    
    var event_storage: [4]NoteEvent = undefined;
    var event_list = EventOutputList{ .events = &event_storage };
    
    var context = ProcessContext{
        .transport = Transport{},
        .input_events = &[_]NoteEvent{},
        .output_events = &event_list,
        .sample_rate = 44100.0,
        .param_values_ptr = &param_values,
        .smoothers_ptr = &smoother_bank,
        .params_meta = &params,
    };
    
    // Test getFloat
    param_values.set(0, 0.75); // 0.75 normalized = 12.0 in [-24, 24] range
    const gain = context.getFloat(3, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), gain, 1e-4);
    
    // Test getInt
    param_values.set(1, 0.5); // 0.5 normalized = ~10010 in [20, 20000] range
    const cutoff = context.getInt(3, 1);
    try std.testing.expectEqual(@as(i32, 10010), cutoff);
    
    // Test getBool
    param_values.set(2, 0.0);
    try std.testing.expect(!context.getBool(3, 2));
    param_values.set(2, 1.0);
    try std.testing.expect(context.getBool(3, 2));
}

