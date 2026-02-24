/// CLAP plugin wrapper implementation.
///
/// This module provides the core plugin wrapper that translates between the
/// CLAP ABI and the framework's plugin interface.
const std = @import("std");
const clap = @import("../../bindings/clap/main.zig");
const core = @import("../../root.zig");
const extensions = @import("extensions.zig");
const common = @import("../common.zig");

/// Wrapper struct for a plugin of type `T`.
/// The first field MUST be `clap_plugin` so the host can cast the pointer correctly.
pub fn PluginWrapper(comptime T: type) type {
    const P = core.Plugin(T);

    return struct {
        const Self = @This();

        // --- FIRST FIELD: Must be clap_plugin for pointer casting ---

        /// The CLAP plugin struct that the host interacts with.
        /// MUST be the first field for correct pointer casting.
        clap_plugin: clap.Plugin,

        // --- HOT DATA: Audio thread reads/writes these every process() call ---

        /// Runtime parameter values (lock-free atomic storage, read every buffer).
        param_values: core.ParamValues(P.params.len) align(core.CACHE_LINE_SIZE),

        /// Smoother bank for parameter value smoothing (written per-sample when smoothing active).
        smoother_bank: core.SmootherBank(P.params.len),

        /// Current buffer configuration.
        buffer_config: core.BufferConfig,

        /// Current audio I/O layout.
        current_layout: core.AudioIOLayout,

        /// Whether the plugin is currently activated.
        is_activated: bool,

        /// The actual plugin instance.
        plugin: T,

        /// Pre-allocated storage for input events.
        input_events_storage: [max_events]core.NoteEvent,

        /// Pre-allocated storage for output events.
        output_events_storage: [max_events]core.NoteEvent,

        /// Event output list for plugin to push events.
        event_output_list: core.EventOutputList,

        /// Pre-allocated Buffer structs for auxiliary inputs.
        aux_input_buffers: [max_aux_buses]core.Buffer,

        /// Channel slice arrays for auxiliary input buffers.
        aux_input_channel_slices: [max_aux_buses][max_channels][]f32,

        /// Pre-allocated Buffer structs for auxiliary outputs.
        aux_output_buffers: [max_aux_buses]core.Buffer,

        /// Channel slice arrays for auxiliary output buffers.
        aux_output_channel_slices: [max_aux_buses][max_channels][]f32,

        // --- COLD DATA: Setup/teardown only, not accessed on audio thread ---

        /// Host pointer for callbacks.
        host: *const clap.Host,

        const max_events = common.max_events;
        const max_aux_buses = common.max_aux_buses;
        const max_channels = common.max_channels;
        const max_buffer_size = common.max_buffer_size;

        /// Initialize a new plugin wrapper in-place.
        /// The `self` pointer must point to a valid heap-allocated instance.
        pub fn initInPlace(self: *Self, host: *const clap.Host) void {
            self.host = host;
            common.initState(P, self, P.audio_io_layouts[0]);
            self.is_activated = false;

            // Initialize the clap_plugin struct with function pointers
            // plugin_data now points to the stable heap allocation
            self.clap_plugin = clap.Plugin{
                .descriptor = undefined, // Set by factory
                .plugin_data = @ptrCast(self),
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

            // Large arrays are left uninitialized (will be properly initialized when needed)
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

            // Initialize all smoothers with current parameter values
            for (P.params, 0..) |param, i| {
                const normalized = self.param_values.get(i);
                const plain_value = param.toPlain(normalized);
                self.smoother_bank.reset(i, plain_value);
            }

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

            const output_count = if (process.audio_outputs_count > 0) blk: {
                const clap_buf = process.audio_outputs[0];
                const count = @min(clap_buf.channel_count, 32);
                for (0..@intCast(count)) |i| {
                    channel_slices_out[i] = clap_buf.data32.?[i][0..frames_count];
                }
                break :blk @as(usize, @intCast(count));
            } else 0;

            // In-place processing: copy input to output if pointers differ, zero-fill extra outputs
            common.copyInPlace(
                channel_slices_in[0..input_count],
                channel_slices_out[0..output_count],
                frames_count,
            );

            const output_slices = channel_slices_out[0..output_count];

            var buffer = core.Buffer{
                .channel_data = output_slices,
                .num_samples = @intCast(frames_count),
            };

            // Map auxiliary buffers
            var aux_input_count: usize = 0;
            var aux_output_count: usize = 0;

            // Process auxiliary input buses (index > 0)
            if (process.audio_inputs_count > 1) {
                for (1..process.audio_inputs_count) |bus_idx| {
                    if (aux_input_count >= max_aux_buses) break;

                    const clap_buf = process.audio_inputs[bus_idx];
                    const ch_count = @min(clap_buf.channel_count, max_channels);

                    // Point auxiliary input buffers directly to host input buffers (zero-copy)
                    for (0..@intCast(ch_count)) |ch_idx| {
                        self.aux_input_channel_slices[aux_input_count][ch_idx] = clap_buf.data32.?[ch_idx][0..frames_count];
                    }

                    self.aux_input_buffers[aux_input_count] = core.Buffer{
                        .channel_data = self.aux_input_channel_slices[aux_input_count][0..@intCast(ch_count)],
                        .num_samples = @intCast(frames_count),
                    };
                    aux_input_count += 1;
                }
            }

            // Process auxiliary output buses (index > 0)
            if (process.audio_outputs_count > 1) {
                for (1..process.audio_outputs_count) |bus_idx| {
                    if (aux_output_count >= max_aux_buses) break;

                    const clap_buf = process.audio_outputs[bus_idx];
                    const ch_count = @min(clap_buf.channel_count, max_channels);

                    // Point auxiliary output buffers directly to host output buffers
                    for (0..@intCast(ch_count)) |ch_idx| {
                        self.aux_output_channel_slices[aux_output_count][ch_idx] = clap_buf.data32.?[ch_idx][0..frames_count];
                    }

                    self.aux_output_buffers[aux_output_count] = core.Buffer{
                        .channel_data = self.aux_output_channel_slices[aux_output_count][0..@intCast(ch_count)],
                        .num_samples = @intCast(frames_count),
                    };
                    aux_output_count += 1;
                }
            }

            var aux = core.AuxBuffers{
                .inputs = self.aux_input_buffers[0..aux_input_count],
                .outputs = self.aux_output_buffers[0..aux_output_count],
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

            // TODO: Sample-accurate automation (P.sample_accurate_automation)
            // When enabled, collect all param_value events with their sample offsets,
            // sort by offset, then loop:
            //   1. Apply parameter changes at block_start
            //   2. Call P.process() for sub-block [block_start, next_change)
            //   3. Advance block_start
            // For now, parameter changes apply at the start of the block (via translateInputEvent).

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
            var context = common.buildProcessContext(
                P,
                transport,
                self.input_events_storage[0..input_event_count],
                &self.event_output_list,
                self.buffer_config.sample_rate,
                &self.param_values,
                &self.smoother_bank,
            );

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

        fn pluginGetExtension(_: *const clap.Plugin, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
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
                    out.* = core.NoteEvent.noteOn(
                        header.sample_offset,
                        if (event.note_id == .unspecified) null else @intFromEnum(event.note_id),
                        @intCast(@intFromEnum(event.channel)),
                        @intCast(@intFromEnum(event.key)),
                        @floatCast(event.velocity),
                    );
                    return true;
                },
                .note_off => {
                    const event: *const clap.events.Note = @ptrCast(@alignCast(header));
                    out.* = core.NoteEvent.noteOff(
                        header.sample_offset,
                        if (event.note_id == .unspecified) null else @intFromEnum(event.note_id),
                        @intCast(@intFromEnum(event.channel)),
                        @intCast(@intFromEnum(event.key)),
                        @floatCast(event.velocity),
                    );
                    return true;
                },
                .note_choke => {
                    const event: *const clap.events.Note = @ptrCast(@alignCast(header));
                    out.* = core.NoteEvent.chokeNote(
                        header.sample_offset,
                        if (event.note_id == .unspecified) null else @intFromEnum(event.note_id),
                        @intCast(@intFromEnum(event.channel)),
                        @intCast(@intFromEnum(event.key)),
                    );
                    return true;
                },
                .param_value => {
                    const event: *const clap.events.ParamValue = @ptrCast(@alignCast(header));
                    // Find parameter index by ID using binary search
                    if (P.params.len > 0) {
                        if (P.findParamIndex(@intFromEnum(event.param_id))) |idx| {
                            const param = P.params[idx];
                            // Convert plain value to normalized using shared helper
                            const normalized = common.plainToNormalized(param, event.value);
                            self.param_values.set(idx, normalized);

                            // Update smoother target with the plain value
                            const plain_value: f32 = @floatCast(event.value);
                            self.smoother_bank.setTarget(idx, self.buffer_config.sample_rate, plain_value);
                        }
                    }
                    return false; // Don't add to event list
                },
                .note_expression => {
                    const event: *const clap.events.NoteExpression = @ptrCast(@alignCast(header));

                    const timing = header.sample_offset;
                    const voice_id = if (event.note_id == .unspecified) null else @intFromEnum(event.note_id);
                    const channel: u8 = @intCast(@intFromEnum(event.channel));
                    const note: u8 = @intCast(@intFromEnum(event.key));
                    const value: f32 = @floatCast(event.value);

                    out.* = switch (event.expression_id) {
                        .pressure => core.NoteEvent.polyPressure(timing, voice_id, channel, note, value),
                        .tuning => core.NoteEvent.polyTuning(timing, voice_id, channel, note, value),
                        .vibrato => core.NoteEvent.polyVibrato(timing, voice_id, channel, note, value),
                        .expression => core.NoteEvent.polyExpression(timing, voice_id, channel, note, value),
                        .brightness => core.NoteEvent.polyBrightness(timing, voice_id, channel, note, value),
                        .volume => core.NoteEvent.polyVolume(timing, voice_id, channel, note, value),
                        .pan => core.NoteEvent.polyPan(timing, voice_id, channel, note, value),
                    };
                    return true;
                },
                .midi => {
                    const event: *const clap.events.Midi = @ptrCast(@alignCast(header));
                    const status = event.data[0] & 0xF0;
                    const channel: u8 = @intCast(event.data[0] & 0x0F);

                    switch (status) {
                        0xB0 => { // Control Change
                            out.* = core.NoteEvent.midiCC(
                                header.sample_offset,
                                channel,
                                event.data[1],
                                @as(f32, @floatFromInt(event.data[2])) / 127.0,
                            );
                            return true;
                        },
                        0xD0 => { // Channel Pressure
                            out.* = core.NoteEvent.midiChannelPressure(
                                header.sample_offset,
                                channel,
                                @as(f32, @floatFromInt(event.data[1])) / 127.0,
                            );
                            return true;
                        },
                        0xE0 => { // Pitch Bend
                            const lsb = event.data[1];
                            const msb = event.data[2];
                            const bend_value = (@as(i32, msb) << 7) | @as(i32, lsb);
                            // Convert 0-16383 to -1.0 to +1.0
                            const normalized = (@as(f32, @floatFromInt(bend_value)) - 8192.0) / 8192.0;
                            out.* = core.NoteEvent.midiPitchBend(
                                header.sample_offset,
                                channel,
                                normalized,
                            );
                            return true;
                        },
                        0xC0 => { // Program Change
                            out.* = core.NoteEvent.midiProgramChange(
                                header.sample_offset,
                                channel,
                                event.data[1],
                            );
                            return true;
                        },
                        else => return false, // Unsupported MIDI message
                    }
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
                .choke => |data| {
                    var clap_event = clap.events.Note{
                        .header = .{
                            .size = @sizeOf(clap.events.Note),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_choke,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .velocity = 0.0,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .voice_terminated => |data| {
                    var clap_event = clap.events.Note{
                        .header = .{
                            .size = @sizeOf(clap.events.Note),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_end,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .velocity = 0.0,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .poly_pressure => |data| {
                    var clap_event = clap.events.NoteExpression{
                        .header = .{
                            .size = @sizeOf(clap.events.NoteExpression),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_expression,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .expression_id = .pressure,
                        .value = data.value,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .poly_tuning => |data| {
                    var clap_event = clap.events.NoteExpression{
                        .header = .{
                            .size = @sizeOf(clap.events.NoteExpression),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_expression,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .expression_id = .tuning,
                        .value = data.value,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .poly_vibrato => |data| {
                    var clap_event = clap.events.NoteExpression{
                        .header = .{
                            .size = @sizeOf(clap.events.NoteExpression),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_expression,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .expression_id = .vibrato,
                        .value = data.value,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .poly_expression => |data| {
                    var clap_event = clap.events.NoteExpression{
                        .header = .{
                            .size = @sizeOf(clap.events.NoteExpression),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_expression,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .expression_id = .expression,
                        .value = data.value,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .poly_brightness => |data| {
                    var clap_event = clap.events.NoteExpression{
                        .header = .{
                            .size = @sizeOf(clap.events.NoteExpression),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_expression,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .expression_id = .brightness,
                        .value = data.value,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .poly_volume => |data| {
                    var clap_event = clap.events.NoteExpression{
                        .header = .{
                            .size = @sizeOf(clap.events.NoteExpression),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_expression,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .expression_id = .volume,
                        .value = data.value,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .poly_pan => |data| {
                    var clap_event = clap.events.NoteExpression{
                        .header = .{
                            .size = @sizeOf(clap.events.NoteExpression),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .note_expression,
                            .flags = .{},
                        },
                        .note_id = if (data.voice_id) |id| @enumFromInt(id) else .unspecified,
                        .port_index = @enumFromInt(0),
                        .channel = @enumFromInt(data.channel),
                        .key = @enumFromInt(data.note),
                        .expression_id = .pan,
                        .value = data.value,
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .midi_cc => |data| {
                    var clap_event = clap.events.Midi{
                        .header = .{
                            .size = @sizeOf(clap.events.Midi),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .midi,
                            .flags = .{},
                        },
                        .port_index = 0,
                        .data = .{
                            0xB0 | data.channel, // Control Change + channel
                            data.cc,
                            @intFromFloat(@min(@max(data.value * 127.0, 0.0), 127.0)),
                        },
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .midi_channel_pressure => |data| {
                    var clap_event = clap.events.Midi{
                        .header = .{
                            .size = @sizeOf(clap.events.Midi),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .midi,
                            .flags = .{},
                        },
                        .port_index = 0,
                        .data = .{
                            0xD0 | data.channel, // Channel Pressure + channel
                            @intFromFloat(@min(@max(data.value * 127.0, 0.0), 127.0)),
                            0,
                        },
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .midi_pitch_bend => |data| {
                    // Convert -1.0 to +1.0 back to 0-16383
                    const bend_int = @as(i32, @intFromFloat((data.value + 1.0) * 8192.0));
                    const clamped = @min(@max(bend_int, 0), 16383);
                    const lsb: u8 = @intCast(clamped & 0x7F);
                    const msb: u8 = @intCast((clamped >> 7) & 0x7F);

                    var clap_event = clap.events.Midi{
                        .header = .{
                            .size = @sizeOf(clap.events.Midi),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .midi,
                            .flags = .{},
                        },
                        .port_index = 0,
                        .data = .{
                            0xE0 | data.channel, // Pitch Bend + channel
                            lsb,
                            msb,
                        },
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
                .midi_program_change => |data| {
                    var clap_event = clap.events.Midi{
                        .header = .{
                            .size = @sizeOf(clap.events.Midi),
                            .sample_offset = data.timing,
                            .space_id = clap.events.core_space_id,
                            .type = .midi,
                            .flags = .{},
                        },
                        .port_index = 0,
                        .data = .{
                            0xC0 | data.channel, // Program Change + channel
                            data.program,
                            0,
                        },
                    };
                    _ = out_events.tryPush(out_events, &clap_event.header);
                },
            }
        }
    };
}
