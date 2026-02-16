/// CLAP plugin wrapper implementation.
///
/// This module provides the core plugin wrapper that translates between the
/// CLAP ABI and the framework's plugin interface.
const std = @import("std");
const clap = @import("../../bindings/clap/main.zig");
const core = @import("../../root.zig");
const extensions = @import("extensions.zig");

/// Wrapper struct for a plugin of type `T`.
/// The first field MUST be `clap_plugin` so the host can cast the pointer correctly.
pub fn PluginWrapper(comptime T: type) type {
    const P = core.Plugin(T);
    
    return struct {
        const Self = @This();
        
        /// The CLAP plugin struct that the host interacts with.
        /// MUST be the first field for correct pointer casting.
        clap_plugin: clap.Plugin,
        
        /// Host pointer for callbacks.
        host: *const clap.Host,
        
        /// The actual plugin instance.
        plugin: T,
        
        /// Runtime parameter values (lock-free atomic storage).
        param_values: core.ParamValues(P.params.len),
        
        /// Current buffer configuration.
        buffer_config: core.BufferConfig,
        
        /// Current audio I/O layout.
        current_layout: core.AudioIOLayout,
        
        /// Pre-allocated storage for input events.
        input_events_storage: [max_events]core.NoteEvent,
        
        /// Pre-allocated storage for output events.
        output_events_storage: [max_events]core.NoteEvent,
        
        /// Event output list for plugin to push events.
        event_output_list: core.EventOutputList,
        
        /// Whether the plugin is currently activated.
        is_activated: bool,
        
        const max_events = 1024;
        
        /// Initialize a new plugin wrapper.
        pub fn init(host: *const clap.Host) !Self {
            var self = Self{
                .clap_plugin = undefined,
                .host = host,
                .plugin = undefined,
                .param_values = core.ParamValues(P.params.len).init(P.params),
                .buffer_config = undefined,
                .current_layout = P.audio_io_layouts[0], // Default to first layout
                .input_events_storage = undefined,
                .output_events_storage = undefined,
                .event_output_list = core.EventOutputList{
                    .events = &[_]core.NoteEvent{},
                },
                .is_activated = false,
            };
            
            // Initialize the clap_plugin struct with function pointers
            self.clap_plugin = clap.Plugin{
                .descriptor = undefined, // Set by factory
                .plugin_data = @ptrCast(&self),
                .init = pluginInit,
                .destroy = pluginDestroy,
                .activate = pluginActivate,
                .deactivate = pluginDeactivate,
                .startProcessing = pluginStartProcessing,
                .stopProcessing = pluginStopProcessing,
                .reset = pluginReset,
                .process = pluginProcess,
                .getExtension = pluginGetExtension,
                .onMainThread = pluginOnMainThread,
            };
            
            return self;
        }
        
        /// Get the wrapper from a clap_plugin pointer.
        fn fromPlugin(plugin: *const clap.Plugin) *Self {
            return @ptrCast(@alignCast(plugin.plugin_data));
        }
        
        // -----------------------------------------------------------------------
        // CLAP Plugin Callbacks
        // -----------------------------------------------------------------------
        
        fn pluginInit(plugin: *const clap.Plugin) callconv(.c) bool {
            const self = fromPlugin(plugin);
            
            // Initialize the plugin with the default layout
            const success = P.init(&self.plugin, &self.current_layout, &self.buffer_config);
            if (!success) {
                return false;
            }
            
            return true;
        }
        
        fn pluginDestroy(plugin: *const clap.Plugin) callconv(.c) void {
            const self = fromPlugin(plugin);
            
            // Deinitialize the plugin
            P.deinit(&self.plugin);
            
            // Free the wrapper allocation
            std.heap.page_allocator.destroy(self);
        }
        
        fn pluginActivate(
            plugin: *const clap.Plugin,
            sample_rate: f64,
            min_frames_count: u32,
            max_frames_count: u32,
        ) callconv(.c) bool {
            const self = fromPlugin(plugin);
            
            // Store buffer configuration
            self.buffer_config = core.BufferConfig{
                .sample_rate = @floatCast(sample_rate),
                .min_buffer_size = min_frames_count,
                .max_buffer_size = max_frames_count,
                .process_mode = .realtime,
            };
            
            // Call plugin reset
            P.reset(&self.plugin);
            
            self.is_activated = true;
            return true;
        }
        
        fn pluginDeactivate(plugin: *const clap.Plugin) callconv(.c) void {
            const self = fromPlugin(plugin);
            self.is_activated = false;
            
            // Call plugin reset
            P.reset(&self.plugin);
        }
        
        fn pluginStartProcessing(plugin: *const clap.Plugin) callconv(.c) bool {
            _ = plugin;
            return true;
        }
        
        fn pluginStopProcessing(plugin: *const clap.Plugin) callconv(.c) void {
            _ = plugin;
        }
        
        fn pluginReset(plugin: *const clap.Plugin) callconv(.c) void {
            const self = fromPlugin(plugin);
            P.reset(&self.plugin);
        }
        
        fn pluginProcess(plugin: *const clap.Plugin, process: *const clap.Process) callconv(.c) clap.Process.Status {
            const self = fromPlugin(plugin);
            
            const frames_count = process.frames_count;
            
            // Map audio buffers (zero-copy)
            var channel_slices_in: [32][]f32 = undefined;
            var channel_slices_out: [32][]f32 = undefined;
            
            const input_count = if (process.audio_inputs_count > 0) blk: {
                const clap_buf = process.audio_inputs[0];
                const count = @min(clap_buf.channel_count, 32);
                for (0..@intCast(count)) |i| {
                    channel_slices_in[i] = clap_buf.data32.?[i][0..frames_count];
                }
                break :blk @as(usize, @intCast(count));
            } else 0;
            _ = input_count; // TODO: Use for in-place processing check
            
            const output_count = if (process.audio_outputs_count > 0) blk: {
                const clap_buf = process.audio_outputs[0];
                const count = @min(clap_buf.channel_count, 32);
                for (0..@intCast(count)) |i| {
                    channel_slices_out[i] = clap_buf.data32.?[i][0..frames_count];
                }
                break :blk @as(usize, @intCast(count));
            } else 0;
            
            const output_slices = channel_slices_out[0..output_count];
            
            var buffer = core.Buffer{
                .channel_data = output_slices,
                .num_samples = @intCast(frames_count),
            };
            
            var aux = core.AuxBuffers{
                .inputs = &[_]core.Buffer{},
                .outputs = &[_]core.Buffer{},
            };
            
            // Translate input events
            var input_event_count: usize = 0;
            const event_count = process.in_events.size(process.in_events);
            for (0..event_count) |i| {
                if (input_event_count >= max_events) break;
                
                const event_header = process.in_events.get(process.in_events, @intCast(i));
                if (translateInputEvent(event_header, &self.input_events_storage[input_event_count], self)) {
                    input_event_count += 1;
                }
            }
            
            // Build transport info
            const transport = if (process.transport) |t| blk: {
                break :blk core.Transport{
                    .tempo = if (t.flags.has_tempo) @floatCast(t.tempo) else null,
                    .time_sig_numerator = if (t.flags.has_time_signature) @intCast(t.time_signature_numerator) else null,
                    .time_sig_denominator = if (t.flags.has_time_signature) @intCast(t.time_signature_denominator) else null,
                    .playing = t.flags.is_playing,
                    .recording = t.flags.is_recording,
                    .looping = t.flags.is_loop_active,
                    .loop_start_beats = null,
                    .loop_end_beats = null,
                };
            } else core.Transport{
                .tempo = null,
                .time_sig_numerator = null,
                .time_sig_denominator = null,
                .playing = false,
                .recording = false,
                .looping = false,
                .loop_start_beats = null,
                .loop_end_beats = null,
            };
            
            // Set up event output list
            self.event_output_list = core.EventOutputList{
                .events = &self.output_events_storage,
            };
            
            // Build process context
            var context = core.ProcessContext{
                .transport = transport,
                .input_events = self.input_events_storage[0..input_event_count],
                .output_events = &self.event_output_list,
                .sample_rate = self.buffer_config.sample_rate,
            };
            
            // Call plugin process
            const status = P.process(&self.plugin, &buffer, &aux, &context);
            
            // Translate output events
            for (self.event_output_list.slice()) |*event| {
                translateOutputEvent(event, process.out_events);
            }
            
            // Map ProcessStatus to CLAP status
            return switch (status) {
                .normal => .@"continue",
                .tail => .tail,
                .silence => .sleep,
                .keep_alive => .@"continue",
                .err => .@"error",
            };
        }
        
        fn pluginGetExtension(plugin: *const clap.Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
            const self = fromPlugin(plugin);
            const id_slice = std.mem.span(id);
            
            if (std.mem.eql(u8, id_slice, clap.ext.audio_ports.id)) {
                return @ptrCast(&extensions.Extensions(T).audio_ports);
            }
            
            if (std.mem.eql(u8, id_slice, clap.ext.note_ports.id)) {
                if (P.midi_input != .none or P.midi_output != .none) {
                    return @ptrCast(&extensions.Extensions(T).note_ports);
                }
            }
            
            if (std.mem.eql(u8, id_slice, clap.ext.params.id)) {
                if (P.params.len > 0) {
                    return @ptrCast(&extensions.Extensions(T).params);
                }
            }
            
            if (std.mem.eql(u8, id_slice, clap.ext.state.id)) {
                return @ptrCast(&extensions.Extensions(T).state);
            }
            
            _ = self;
            return null;
        }
        
        fn pluginOnMainThread(plugin: *const clap.Plugin) callconv(.c) void {
            _ = plugin;
        }
        
        // -----------------------------------------------------------------------
        // Event Translation Helpers
        // -----------------------------------------------------------------------
        
        fn translateInputEvent(header: *const clap.events.Header, out: *core.NoteEvent, self: *Self) bool {
            switch (header.type) {
                .note_on => {
                    const event: *const clap.events.Note = @ptrCast(@alignCast(header));
                    out.* = core.NoteEvent{
                        .note_on = .{
                            .timing = header.sample_offset,
                            .voice_id = if (event.note_id == .unspecified) null else @intFromEnum(event.note_id),
                            .channel = @intCast(@intFromEnum(event.channel)),
                            .note = @intCast(@intFromEnum(event.key)),
                            .velocity = @floatCast(event.velocity),
                        },
                    };
                    return true;
                },
                .note_off => {
                    const event: *const clap.events.Note = @ptrCast(@alignCast(header));
                    out.* = core.NoteEvent{
                        .note_off = .{
                            .timing = header.sample_offset,
                            .voice_id = if (event.note_id == .unspecified) null else @intFromEnum(event.note_id),
                            .channel = @intCast(@intFromEnum(event.channel)),
                            .note = @intCast(@intFromEnum(event.key)),
                            .velocity = @floatCast(event.velocity),
                        },
                    };
                    return true;
                },
                .note_choke => {
                    const event: *const clap.events.Note = @ptrCast(@alignCast(header));
                    out.* = core.NoteEvent{
                        .choke = .{
                            .timing = header.sample_offset,
                            .voice_id = if (event.note_id == .unspecified) null else @intFromEnum(event.note_id),
                            .channel = @intCast(@intFromEnum(event.channel)),
                            .note = @intCast(@intFromEnum(event.key)),
                            .velocity = 0.0,
                        },
                    };
                    return true;
                },
                .param_value => {
                    const event: *const clap.events.ParamValue = @ptrCast(@alignCast(header));
                    // Find parameter index by ID
                    for (P.params, 0..) |param, idx| {
                        const param_id = core.idHash(param.id());
                        if (param_id == event.param_id) {
                            // Convert plain value to normalized
                            const normalized = switch (param) {
                                .float => |p| p.range.normalize(@floatCast(event.value)),
                                .int => |p| p.range.normalize(@intFromFloat(event.value)),
                                .boolean => if (event.value > 0.5) @as(f32, 1.0) else @as(f32, 0.0),
                                .choice => |p| blk: {
                                    if (p.labels.len <= 1) break :blk 0.0;
                                    const choice_idx = @min(@as(u32, @intFromFloat(event.value)), @as(u32, @intCast(p.labels.len - 1)));
                                    break :blk @as(f32, @floatFromInt(choice_idx)) / @as(f32, @floatFromInt(p.labels.len - 1));
                                },
                            };
                            self.param_values.set(idx, normalized);
                            break;
                        }
                    }
                    return false; // Don't add to event list
                },
                else => return false,
            }
        }
        
        fn translateOutputEvent(event: *const core.NoteEvent, out_events: *const clap.events.OutputEvents) void {
            switch (event.*) {
                .note_on => |data| {
                    var clap_event = clap.events.Note{
                        .header = .{
                            .size = @sizeOf(clap.events.Note),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_on,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .velocity = data.velocity,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .note_off => |data| {
                    var clap_event = clap.events.Note{
                        .header = .{
                            .size = @sizeOf(clap.events.Note),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_off,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .velocity = data.velocity,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                else => {}, // TODO: Implement other event types
            }
        }
    };
}
