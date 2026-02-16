/// VST3 component implementation (IComponent + IAudioProcessor).
///
/// This module provides the combined component/processor that implements
/// both IComponent and IAudioProcessor interfaces.
const std = @import("std");
const vst3 = @import("../../bindings/vst3/root.zig");
const core = @import("../../root.zig");
const controller = @import("controller.zig");

/// VST3 component wrapper for plugin type `T`.
pub fn Vst3Component(comptime T: type) type {
    const P = core.Plugin(T);
    
    return struct {
        const Self = @This();
        
        /// Component vtable (IComponent interface).
        component_vtbl: vst3.component.IComponent,
        
        /// Processor vtable (IAudioProcessor interface).
        processor_vtbl: vst3.processor.IAudioProcessor,
        
        /// Controller (IEditController interface).
        controller_interface: controller.Vst3Controller(T),
        
        /// Reference count for COM lifetime management.
        ref_count: std.atomic.Value(u32),
        
        /// The actual plugin instance.
        plugin: T,
        
        /// Runtime parameter values.
        param_values: core.ParamValues(P.params.len),
        
        /// Smoother bank for parameter value smoothing.
        smoother_bank: core.SmootherBank(P.params.len),
        
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
        
        /// Whether the plugin is currently active.
        is_active: bool,
        
        /// Pre-allocated storage for auxiliary input buffers.
        /// [bus_index][channel_index][sample_index]
        aux_input_storage: [max_aux_buses][max_channels][max_buffer_size]f32,
        
        /// Pre-allocated Buffer structs for auxiliary inputs.
        aux_input_buffers: [max_aux_buses]core.Buffer,
        
        /// Channel slice arrays for auxiliary input buffers.
        aux_input_channel_slices: [max_aux_buses][max_channels][]f32,
        
        /// Pre-allocated Buffer structs for auxiliary outputs.
        aux_output_buffers: [max_aux_buses]core.Buffer,
        
        /// Channel slice arrays for auxiliary output buffers.
        aux_output_channel_slices: [max_aux_buses][max_channels][]f32,
        
        const max_events = 1024;
        const max_aux_buses = 8;
        const max_channels = 32;
        const max_buffer_size = 8192;
        
        /// Create a new component instance.
        pub fn create() !*Self {
            const self = try std.heap.page_allocator.create(Self);
            
            self.* = Self{
                .component_vtbl = vst3.component.IComponent{
                    .lpVtbl = &component_vtbl_instance,
                },
                .processor_vtbl = vst3.processor.IAudioProcessor{
                    .lpVtbl = &processor_vtbl_instance,
                },
                .controller_interface = controller.Vst3Controller(T).init(),
                .ref_count = std.atomic.Value(u32).init(1),
                .plugin = undefined,
                .param_values = core.ParamValues(P.params.len).init(P.params),
                .smoother_bank = core.SmootherBank(P.params.len).init(P.params),
                .buffer_config = undefined,
                .current_layout = P.audio_io_layouts[0],
                .input_events_storage = undefined,
                .output_events_storage = undefined,
                .event_output_list = core.EventOutputList{
                    .events = &[_]core.NoteEvent{},
                },
                .is_active = false,
                .aux_input_storage = undefined,
                .aux_input_buffers = undefined,
                .aux_input_channel_slices = undefined,
                .aux_output_buffers = undefined,
                .aux_output_channel_slices = undefined,
            };
            
            // Share param_values with controller
            self.controller_interface.param_values = &self.param_values;
            
            return self;
        }
        
        // -------------------------------------------------------------------
        // Vtable Instances
        // -------------------------------------------------------------------
        
        const component_vtbl_instance = vst3.component.IComponentVtbl{
            .queryInterface = componentQueryInterface,
            .addRef = componentAddRef,
            .release = componentRelease,
            .initialize = componentInitialize,
            .terminate = componentTerminate,
            .getControllerClassId = getControllerClassId,
            .setIoMode = setIoMode,
            .getBusCount = getBusCount,
            .getBusInfo = getBusInfo,
            .getRoutingInfo = getRoutingInfo,
            .activateBus = activateBus,
            .setActive = setActive,
            .setState = componentSetState,
            .getState = componentGetState,
        };
        
        const processor_vtbl_instance = vst3.processor.IAudioProcessorVtbl{
            .queryInterface = processorQueryInterface,
            .addRef = processorAddRef,
            .release = processorRelease,
            .setBusArrangements = setBusArrangements,
            .getBusArrangement = getBusArrangement,
            .canProcessSampleSize = canProcessSampleSize,
            .getLatencySamples = getLatencySamples,
            .setupProcessing = setupProcessing,
            .setProcessing = setProcessing,
            .process = process,
            .getTailSamples = getTailSamples,
        };
        
        // -------------------------------------------------------------------
        // Helper Functions
        // -------------------------------------------------------------------
        
        fn fromComponent(comp: *anyopaque) *Self {
            const component_ptr: *vst3.component.IComponent = @ptrCast(@alignCast(comp));
            return @fieldParentPtr("component_vtbl", component_ptr);
        }
        
        fn fromProcessor(proc: *anyopaque) *Self {
            const processor_ptr: *vst3.processor.IAudioProcessor = @ptrCast(@alignCast(proc));
            return @fieldParentPtr("processor_vtbl", processor_ptr);
        }
        
        // -------------------------------------------------------------------
        // IComponent Implementation
        // -------------------------------------------------------------------
        
        fn componentQueryInterface(self: *anyopaque, iid: *const vst3.TUID, obj: *?*anyopaque) callconv(.c) vst3.tresult {
            const wrapper = fromComponent(self);
            
            if (vst3.guid.eql(iid.*, vst3.component.IID_IComponent) or
                vst3.guid.eql(iid.*, vst3.component.IID_IPluginBase) or
                vst3.guid.eql(iid.*, vst3.guid.IID_FUnknown))
            {
                _ = componentAddRef(self);
                obj.* = @ptrCast(&wrapper.component_vtbl);
                return vst3.types.kResultOk;
            }
            
            if (vst3.guid.eql(iid.*, vst3.processor.IID_IAudioProcessor)) {
                _ = componentAddRef(self);
                obj.* = @ptrCast(&wrapper.processor_vtbl);
                return vst3.types.kResultOk;
            }
            
            if (vst3.guid.eql(iid.*, vst3.controller.IID_IEditController)) {
                _ = componentAddRef(self);
                obj.* = @ptrCast(&wrapper.controller_interface.controller_vtbl);
                return vst3.types.kResultOk;
            }
            
            obj.* = null;
            return vst3.types.kNoInterface;
        }
        
        fn componentAddRef(self: *anyopaque) callconv(.c) u32 {
            const wrapper = fromComponent(self);
            const prev = wrapper.ref_count.fetchAdd(1, .monotonic);
            return prev + 1;
        }
        
        fn componentRelease(self: *anyopaque) callconv(.c) u32 {
            const wrapper = fromComponent(self);
            const prev = wrapper.ref_count.fetchSub(1, .monotonic);
            const new_count = prev - 1;
            
            if (new_count == 0) {
                std.heap.page_allocator.destroy(wrapper);
            }
            
            return new_count;
        }
        
        fn componentInitialize(self: *anyopaque, _: *anyopaque) callconv(.c) vst3.tresult {
            const wrapper = fromComponent(self);
            
            // Initialize buffer config with defaults
            wrapper.buffer_config = core.BufferConfig{
                .sample_rate = 44100.0,
                .min_buffer_size = 64,
                .max_buffer_size = 8192,
                .process_mode = .realtime,
            };
            
            // Initialize the plugin
            const success = P.init(&wrapper.plugin, &wrapper.current_layout, &wrapper.buffer_config);
            if (!success) {
                return vst3.types.kResultFalse;
            }
            
            return vst3.types.kResultOk;
        }
        
        fn componentTerminate(self: *anyopaque) callconv(.c) vst3.tresult {
            const wrapper = fromComponent(self);
            P.deinit(&wrapper.plugin);
            return vst3.types.kResultOk;
        }
        
        fn getControllerClassId(_: *anyopaque, tuid: *vst3.TUID) callconv(.c) vst3.tresult {
            // Return the same TUID (single-component model)
            const plugin_tuid = pluginIdToTuid(P.plugin_id);
            @memcpy(tuid, &plugin_tuid);
            return vst3.types.kResultOk;
        }
        
        fn setIoMode(_: *anyopaque, _: vst3.types.IoMode) callconv(.c) vst3.tresult {
            return vst3.types.kNotImplemented;
        }
        
        fn getBusCount(_: *anyopaque, media_type: vst3.types.MediaType, dir: vst3.types.BusDirection) callconv(.c) i32 {
            if (media_type != @intFromEnum(vst3.types.MediaTypes.kAudio)) return 0;
            
            const layout = P.audio_io_layouts[0];
            
            if (dir == @intFromEnum(vst3.types.BusDirections.kInput)) {
                if (layout.main_input_channels != null) return 1;
            } else {
                if (layout.main_output_channels != null) return 1;
            }
            
            return 0;
        }
        
        fn getBusInfo(
            _: *anyopaque,
            media_type: vst3.types.MediaType,
            dir: vst3.types.BusDirection,
            index: i32,
            info: *vst3.component.BusInfo,
        ) callconv(.c) vst3.tresult {
            if (media_type != @intFromEnum(vst3.types.MediaTypes.kAudio) or index != 0) return vst3.types.kResultFalse;
            
            const layout = P.audio_io_layouts[0];
            
            const channel_count = if (dir == @intFromEnum(vst3.types.BusDirections.kInput))
                layout.main_input_channels orelse return vst3.types.kResultFalse
            else
                layout.main_output_channels orelse return vst3.types.kResultFalse;
            
            info.* = vst3.component.BusInfo{
                .media_type = @intFromEnum(vst3.types.MediaTypes.kAudio),
                .direction = dir,
                .channel_count = @intCast(channel_count),
                .name = undefined,
                .bus_type = @intFromEnum(vst3.types.BusTypes.kMain),
                .flags = @intCast(@intFromEnum(vst3.component.BusInfo.BusFlags.kDefaultActive)),
            };
            
            // Set bus name
            @memset(&info.name, 0);
            const name_str = if (dir == @intFromEnum(vst3.types.BusDirections.kInput)) "Audio Input" else "Audio Output";
            // Convert UTF-8 to UTF-16 at runtime
            var i: usize = 0;
            while (i < name_str.len and i < 128) : (i += 1) {
                info.name[i] = name_str[i];
            }
            
            return vst3.types.kResultOk;
        }
        
        fn getRoutingInfo(_: *anyopaque, _: *vst3.component.RoutingInfo, _: *vst3.component.RoutingInfo) callconv(.c) vst3.tresult {
            return vst3.types.kNotImplemented;
        }
        
        fn activateBus(_: *anyopaque, _: vst3.types.MediaType, _: vst3.types.BusDirection, _: i32, _: vst3.types.TBool) callconv(.c) vst3.tresult {
            return vst3.types.kResultOk;
        }
        
        fn setActive(self: *anyopaque, state: vst3.types.TBool) callconv(.c) vst3.tresult {
            const wrapper = fromComponent(self);
            
            if (state != 0) {
                // Initialize all smoothers with current parameter values
                for (P.params, 0..) |param, i| {
                    const normalized = wrapper.param_values.get(i);
                    const plain_value = param.toPlain(normalized);
                    wrapper.smoother_bank.reset(i, plain_value);
                }
                
                P.reset(&wrapper.plugin);
                wrapper.is_active = true;
            } else {
                wrapper.is_active = false;
            }
            
            return vst3.types.kResultOk;
        }
        
        fn componentSetState(self: *anyopaque, stream: *vst3.component.IBStream) callconv(.c) vst3.tresult {
            const wrapper = fromComponent(self);
            
            // Create a reader adapter for the VST3 stream
            const Reader = struct {
                stream_ptr: *vst3.component.IBStream,
                
                pub fn read(ctx: *const anyopaque, buffer: []u8) !usize {
                    const reader_self: *const @This() = @ptrCast(@alignCast(ctx));
                    var num_read: i32 = 0;
                    const stream_vtbl: *vst3.stream.IBStreamVtbl = @ptrCast(@alignCast(reader_self.stream_ptr.lpVtbl));
                    const result = stream_vtbl.read(
                        @ptrCast(reader_self.stream_ptr),
                        @ptrCast(buffer.ptr),
                        @intCast(buffer.len),
                        &num_read,
                    );
                    if (result != vst3.types.kResultOk) return error.ReadFailed;
                    return @intCast(num_read);
                }
            };
            
            var reader_ctx = Reader{ .stream_ptr = stream };
            const any_reader = std.io.AnyReader{
                .context = @ptrCast(&reader_ctx),
                .readFn = Reader.read,
            };
            
            // Read state header
            const version = core.readHeader(any_reader) catch return vst3.types.kResultFalse;
            
            // Read parameter values
            for (0..P.params.len) |i| {
                var normalized: f32 = undefined;
                const bytes = std.mem.asBytes(&normalized);
                const read_count = any_reader.readAll(bytes) catch return vst3.types.kResultFalse;
                if (read_count != @sizeOf(f32)) return vst3.types.kResultFalse;
                wrapper.param_values.set(i, normalized);
                
                // Update smoother target
                const param = P.params[i];
                const plain_value = param.toPlain(normalized);
                wrapper.smoother_bank.setTarget(i, wrapper.buffer_config.sample_rate, plain_value);
            }
            
            const load_context = core.LoadContext{
                .reader = any_reader,
                .version = version,
            };
            
            const success = P.load(&wrapper.plugin, load_context);
            return if (success) vst3.types.kResultOk else vst3.types.kResultFalse;
        }
        
        fn componentGetState(self: *anyopaque, stream: *vst3.component.IBStream) callconv(.c) vst3.tresult {
            const wrapper = fromComponent(self);
            
            // Create a writer adapter for the VST3 stream
            const Writer = struct {
                stream_ptr: *vst3.component.IBStream,
                
                pub fn write(ctx: *const anyopaque, bytes: []const u8) !usize {
                    const writer_self: *const @This() = @ptrCast(@alignCast(ctx));
                    var num_written: i32 = 0;
                    const stream_vtbl: *vst3.stream.IBStreamVtbl = @ptrCast(@alignCast(writer_self.stream_ptr.lpVtbl));
                    const result = stream_vtbl.write(
                        @ptrCast(writer_self.stream_ptr),
                        @ptrCast(@constCast(bytes.ptr)),
                        @intCast(bytes.len),
                        &num_written,
                    );
                    if (result != vst3.types.kResultOk) return error.WriteFailed;
                    return @intCast(num_written);
                }
            };
            
            var writer_ctx = Writer{ .stream_ptr = stream };
            const any_writer = std.io.AnyWriter{
                .context = @ptrCast(&writer_ctx),
                .writeFn = Writer.write,
            };
            
            // Write state header
            core.writeHeader(any_writer, P.state_version) catch return vst3.types.kResultFalse;
            
            // Write parameter values
            for (0..P.params.len) |i| {
                const normalized = wrapper.param_values.get(i);
                const bytes = std.mem.asBytes(&normalized);
                any_writer.writeAll(bytes) catch return vst3.types.kResultFalse;
            }
            
            const save_context = core.SaveContext{
                .writer = any_writer,
            };
            
            const success = P.save(&wrapper.plugin, save_context);
            return if (success) vst3.types.kResultOk else vst3.types.kResultFalse;
        }
        
        // -------------------------------------------------------------------
        // IAudioProcessor Implementation
        // -------------------------------------------------------------------
        
        fn processorQueryInterface(self: *anyopaque, iid: *const vst3.TUID, obj: *?*anyopaque) callconv(.c) vst3.tresult {
            return componentQueryInterface(@as(*anyopaque, @ptrFromInt(@intFromPtr(self) - @offsetOf(Self, "processor_vtbl"))), iid, obj);
        }
        
        fn processorAddRef(self: *anyopaque) callconv(.c) u32 {
            return componentAddRef(@as(*anyopaque, @ptrFromInt(@intFromPtr(self) - @offsetOf(Self, "processor_vtbl"))));
        }
        
        fn processorRelease(self: *anyopaque) callconv(.c) u32 {
            return componentRelease(@as(*anyopaque, @ptrFromInt(@intFromPtr(self) - @offsetOf(Self, "processor_vtbl"))));
        }
        
        fn setBusArrangements(_: *anyopaque, _: [*]vst3.types.SpeakerArrangement, _: i32, _: [*]vst3.types.SpeakerArrangement, _: i32) callconv(.c) vst3.tresult {
            // Accept any arrangement for now
            return vst3.types.kResultOk;
        }
        
        fn getBusArrangement(_: *anyopaque, dir: vst3.types.BusDirection, _: i32, arr: *vst3.types.SpeakerArrangement) callconv(.c) vst3.tresult {
            const layout = P.audio_io_layouts[0];
            
            const channel_count = if (dir == @intFromEnum(vst3.types.BusDirections.kInput))
                layout.main_input_channels orelse return vst3.types.kResultFalse
            else
                layout.main_output_channels orelse return vst3.types.kResultFalse;
            
            // Set speaker arrangement based on channel count
            if (channel_count <= 8) {
                arr.* = if (channel_count == 1)
                    @intCast(1) // Mono
                else if (channel_count == 2)
                    @intCast(3) // Stereo (L + R)
                else
                    @intCast((@as(i64, 1) << @as(u6, @intCast(channel_count))) - 1);
            } else {
                arr.* = @intCast((@as(i64, 1) << @as(u6, 8)) - 1); // Max 8 channels
            }
            
            return vst3.types.kResultOk;
        }
        
        fn canProcessSampleSize(_: *anyopaque, symbolic_size: i32) callconv(.c) vst3.tresult {
            // Support 32-bit float
            if (symbolic_size == 0) return vst3.types.kResultOk; // kSample32
            return vst3.types.kResultFalse;
        }
        
        fn getLatencySamples(_: *anyopaque) callconv(.c) u32 {
            return 0;
        }
        
        fn setupProcessing(self: *anyopaque, setup: *vst3.processor.ProcessSetup) callconv(.c) vst3.tresult {
            const wrapper = fromProcessor(self);
            
            wrapper.buffer_config = core.BufferConfig{
                .sample_rate = @floatCast(setup.sample_rate),
                .min_buffer_size = @intCast(setup.max_samples_per_block),
                .max_buffer_size = @intCast(setup.max_samples_per_block),
                .process_mode = if (setup.process_mode == 0) .realtime else .offline,
            };
            
            return vst3.types.kResultOk;
        }
        
        fn setProcessing(_: *anyopaque, _: vst3.types.TBool) callconv(.c) vst3.tresult {
            return vst3.types.kResultOk;
        }
        
        /// Translate a VST3 event to the framework's NoteEvent representation.
        /// Returns true if the event was successfully translated.
        fn translateVst3InputEvent(vst3_event: *const vst3.events.Event, out: *core.NoteEvent) bool {
            const event_type: vst3.events.EventTypes = @enumFromInt(vst3_event.type);
            
            switch (event_type) {
                .kNoteOnEvent => {
                    const note_on = vst3_event.data.note_on;
                    out.* = core.NoteEvent{
                        .note_on = .{
                            .timing = @intCast(vst3_event.sample_offset),
                            .voice_id = if (note_on.note_id >= 0) @intCast(note_on.note_id) else null,
                            .channel = @intCast(note_on.channel),
                            .note = @intCast(note_on.pitch),
                            .velocity = note_on.velocity,
                        },
                    };
                    return true;
                },
                .kNoteOffEvent => {
                    const note_off = vst3_event.data.note_off;
                    out.* = core.NoteEvent{
                        .note_off = .{
                            .timing = @intCast(vst3_event.sample_offset),
                            .voice_id = if (note_off.note_id >= 0) @intCast(note_off.note_id) else null,
                            .channel = @intCast(note_off.channel),
                            .note = @intCast(note_off.pitch),
                            .velocity = note_off.velocity,
                        },
                    };
                    return true;
                },
                .kPolyPressureEvent => {
                    const poly_pressure = vst3_event.data.poly_pressure;
                    out.* = core.NoteEvent{
                        .poly_pressure = .{
                            .timing = @intCast(vst3_event.sample_offset),
                            .voice_id = if (poly_pressure.note_id >= 0) @intCast(poly_pressure.note_id) else null,
                            .channel = @intCast(poly_pressure.channel),
                            .note = @intCast(poly_pressure.pitch),
                            .value = @floatCast(poly_pressure.pressure),
                        },
                    };
                    return true;
                },
                .kNoteExpressionValueEvent => {
                    const expr = vst3_event.data.note_expression_value;
                    const type_id: vst3.events.NoteExpressionTypeIDs = @enumFromInt(expr.type_id);
                    
                    const poly_data = core.PolyValueData{
                        .timing = @intCast(vst3_event.sample_offset),
                        .voice_id = if (expr.note_id >= 0) @intCast(expr.note_id) else null,
                        .channel = 0, // VST3 note expression doesn't have channel info
                        .note = 0, // VST3 note expression doesn't have note info
                        .value = @floatCast(expr.value),
                    };
                    
                    out.* = switch (type_id) {
                        .kVolumeTypeID => core.NoteEvent{ .poly_volume = poly_data },
                        .kPanTypeID => core.NoteEvent{ .poly_pan = poly_data },
                        .kTuningTypeID => core.NoteEvent{ .poly_tuning = poly_data },
                        .kVibratoTypeID => core.NoteEvent{ .poly_vibrato = poly_data },
                        .kExpressionTypeID => core.NoteEvent{ .poly_expression = poly_data },
                        .kBrightnessTypeID => core.NoteEvent{ .poly_brightness = poly_data },
                    };
                    return true;
                },
                else => return false, // Unsupported event type
            }
        }
        
        /// Translate a framework NoteEvent to VST3 format.
        /// Returns true if the event was successfully translated.
        fn translateVst3OutputEvent(event: *const core.NoteEvent, out: *vst3.events.Event) bool {
            out.bus_index = 0;
            out.ppq_position = 0.0;
            out.flags = 0;
            
            switch (event.*) {
                .note_on => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kNoteOnEvent);
                    out.data.note_on = .{
                        .channel = @intCast(data.channel),
                        .pitch = @intCast(data.note),
                        .tuning = 0.0,
                        .velocity = data.velocity,
                        .length = 0,
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                    };
                    return true;
                },
                .note_off => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kNoteOffEvent);
                    out.data.note_off = .{
                        .channel = @intCast(data.channel),
                        .pitch = @intCast(data.note),
                        .velocity = data.velocity,
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                        .tuning = 0.0,
                    };
                    return true;
                },
                .poly_pressure => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kPolyPressureEvent);
                    out.data.poly_pressure = .{
                        .channel = @intCast(data.channel),
                        .pitch = @intCast(data.note),
                        .pressure = data.value,
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                    };
                    return true;
                },
                .poly_volume => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kNoteExpressionValueEvent);
                    out.data.note_expression_value = .{
                        .type_id = @intFromEnum(vst3.events.NoteExpressionTypeIDs.kVolumeTypeID),
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                        .value = data.value,
                    };
                    return true;
                },
                .poly_pan => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kNoteExpressionValueEvent);
                    out.data.note_expression_value = .{
                        .type_id = @intFromEnum(vst3.events.NoteExpressionTypeIDs.kPanTypeID),
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                        .value = data.value,
                    };
                    return true;
                },
                .poly_tuning => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kNoteExpressionValueEvent);
                    out.data.note_expression_value = .{
                        .type_id = @intFromEnum(vst3.events.NoteExpressionTypeIDs.kTuningTypeID),
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                        .value = data.value,
                    };
                    return true;
                },
                .poly_vibrato => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kNoteExpressionValueEvent);
                    out.data.note_expression_value = .{
                        .type_id = @intFromEnum(vst3.events.NoteExpressionTypeIDs.kVibratoTypeID),
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                        .value = data.value,
                    };
                    return true;
                },
                .poly_expression => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kNoteExpressionValueEvent);
                    out.data.note_expression_value = .{
                        .type_id = @intFromEnum(vst3.events.NoteExpressionTypeIDs.kExpressionTypeID),
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                        .value = data.value,
                    };
                    return true;
                },
                .poly_brightness => |data| {
                    out.sample_offset = @intCast(data.timing);
                    out.type = @intFromEnum(vst3.events.EventTypes.kNoteExpressionValueEvent);
                    out.data.note_expression_value = .{
                        .type_id = @intFromEnum(vst3.events.NoteExpressionTypeIDs.kBrightnessTypeID),
                        .note_id = if (data.voice_id) |id| @intCast(id) else -1,
                        .value = data.value,
                    };
                    return true;
                },
                // VST3 doesn't have direct equivalents for choke, voice_terminated, and MIDI messages
                // These would need to be handled at a higher level or ignored
                else => return false,
            }
        }
        
        fn process(self: *anyopaque, data: *vst3.processor.ProcessData) callconv(.c) vst3.tresult {
            const wrapper = fromProcessor(self);
            
            const num_samples = data.num_samples;
            
            // Map audio buffers (zero-copy)
            var channel_slices_in: [32][]f32 = undefined;
            var channel_slices_out: [32][]f32 = undefined;
            
            const input_count = if (data.num_inputs > 0) blk: {
                const bus = data.inputs[0];
                const count = @min(bus.num_channels, 32);
                if (bus.channel_buffers_32) |buffers| {
                    for (0..@intCast(count)) |i| {
                        channel_slices_in[i] = buffers[i][0..@intCast(num_samples)];
                    }
                }
                break :blk @as(usize, @intCast(count));
            } else 0;
            
            const output_count = if (data.num_outputs > 0) blk: {
                const bus = data.outputs[0];
                const count = @min(bus.num_channels, 32);
                if (bus.channel_buffers_32) |buffers| {
                    for (0..@intCast(count)) |i| {
                        channel_slices_out[i] = buffers[i][0..@intCast(num_samples)];
                    }
                }
                break :blk @as(usize, @intCast(count));
            } else 0;
            
            // In-place processing: copy input to output if pointers differ
            const common_channels = @min(input_count, output_count);
            for (0..common_channels) |i| {
                if (@intFromPtr(channel_slices_in[i].ptr) != @intFromPtr(channel_slices_out[i].ptr)) {
                    @memcpy(channel_slices_out[i], channel_slices_in[i]);
                }
            }
            
            // Zero-fill extra output channels (if output has more channels than input)
            for (input_count..output_count) |i| {
                @memset(channel_slices_out[i], 0.0);
            }
            
            const output_slices = channel_slices_out[0..output_count];
            
            var buffer = core.Buffer{
                .channel_data = output_slices,
                .num_samples = @intCast(num_samples),
            };
            
            // Map auxiliary buffers
            var aux_input_count: usize = 0;
            var aux_output_count: usize = 0;
            
            // Process auxiliary input buses (index > 0)
            if (data.num_inputs > 1) {
                const aux_buses_available = @min(data.num_inputs - 1, max_aux_buses);
                var bus_idx: i32 = 1;
                while (bus_idx < data.num_inputs) : (bus_idx += 1) {
                    if (aux_input_count >= max_aux_buses) break;
                    
                    const bus = data.inputs[@intCast(bus_idx)];
                    const ch_count = @min(bus.num_channels, max_channels);
                    
                    if (bus.channel_buffers_32) |buffers| {
                        // Copy auxiliary input data to owned storage
                        for (0..@intCast(ch_count)) |ch_idx| {
                            const src = buffers[ch_idx][0..@intCast(num_samples)];
                            const dst = wrapper.aux_input_storage[aux_input_count][ch_idx][0..@intCast(num_samples)];
                            @memcpy(dst, src);
                            wrapper.aux_input_channel_slices[aux_input_count][ch_idx] = dst;
                        }
                        
                        wrapper.aux_input_buffers[aux_input_count] = core.Buffer{
                            .channel_data = wrapper.aux_input_channel_slices[aux_input_count][0..@intCast(ch_count)],
                            .num_samples = @intCast(num_samples),
                        };
                        aux_input_count += 1;
                    }
                }
                _ = aux_buses_available;
            }
            
            // Process auxiliary output buses (index > 0)
            if (data.num_outputs > 1) {
                const aux_buses_available = @min(data.num_outputs - 1, max_aux_buses);
                var bus_idx: i32 = 1;
                while (bus_idx < data.num_outputs) : (bus_idx += 1) {
                    if (aux_output_count >= max_aux_buses) break;
                    
                    const bus = data.outputs[@intCast(bus_idx)];
                    const ch_count = @min(bus.num_channels, max_channels);
                    
                    if (bus.channel_buffers_32) |buffers| {
                        // Point auxiliary output buffers directly to host output buffers
                        for (0..@intCast(ch_count)) |ch_idx| {
                            wrapper.aux_output_channel_slices[aux_output_count][ch_idx] = buffers[ch_idx][0..@intCast(num_samples)];
                        }
                        
                        wrapper.aux_output_buffers[aux_output_count] = core.Buffer{
                            .channel_data = wrapper.aux_output_channel_slices[aux_output_count][0..@intCast(ch_count)],
                            .num_samples = @intCast(num_samples),
                        };
                        aux_output_count += 1;
                    }
                }
                _ = aux_buses_available;
            }
            
            var aux = core.AuxBuffers{
                .inputs = wrapper.aux_input_buffers[0..aux_input_count],
                .outputs = wrapper.aux_output_buffers[0..aux_output_count],
            };
            
            // Translate input events from IEventList
            var input_event_count: usize = 0;
            if (data.input_events) |event_list| {
                const event_vtbl: *const vst3.events.IEventListVtbl = @ptrCast(@alignCast(event_list.lpVtbl));
                const count = event_vtbl.getEventCount(event_list);
                
                var i: i32 = 0;
                while (i < count and input_event_count < wrapper.input_events_storage.len) : (i += 1) {
                    var vst3_event: vst3.events.Event = undefined;
                    if (event_vtbl.getEvent(event_list, i, &vst3_event) == vst3.types.kResultOk) {
                        if (translateVst3InputEvent(&vst3_event, &wrapper.input_events_storage[input_event_count])) {
                            input_event_count += 1;
                        }
                    }
                }
            }
            
            // Process parameter changes from IParameterChanges
            // TODO: Sample-accurate automation (P.sample_accurate_automation)
            // When enabled, collect all parameter changes with their sample offsets from
            // IParameterChanges queues, then split the buffer at change points and call
            // P.process() for each sub-block.
            // For now, we apply only the last value from each queue at the start of the block.
            if (data.input_parameter_changes) |param_changes| {
                const vtbl: *vst3.param_changes.IParameterChangesVtbl = @ptrCast(@alignCast(param_changes.lpVtbl));
                const param_count = vtbl.getParameterCount(param_changes);
                
                var i: i32 = 0;
                while (i < param_count) : (i += 1) {
                    const queue = vtbl.getParameterData(param_changes, i);
                    if (queue) |q| {
                        const queue_vtbl: *const vst3.param_changes.IParamValueQueueVtbl = @ptrCast(@alignCast(q.lpVtbl));
                        const param_id = queue_vtbl.getParameterId(q);
                        
                        // Get the last value in the queue (for now, ignore sample offsets)
                        const point_count = queue_vtbl.getPointCount(q);
                        if (point_count > 0) {
                            var sample_offset: i32 = 0;
                            var value: f64 = 0.0;
                            if (queue_vtbl.getPoint(q, point_count - 1, &sample_offset, &value) == vst3.types.kResultOk) {
                                // Find parameter index by ID
                                for (P.params, 0..) |param, idx| {
                                    const expected_id = core.idHash(param.id());
                                    if (expected_id == param_id) {
                                        // Value is already normalized in VST3
                                        const normalized: f32 = @floatCast(value);
                                        wrapper.param_values.set(idx, normalized);
                                        
                                        // Update smoother target with plain value
                                        const plain_value = param.toPlain(normalized);
                                        wrapper.smoother_bank.setTarget(idx, wrapper.buffer_config.sample_rate, plain_value);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Build transport info
            const transport = if (data.process_context) |ctx| blk: {
                break :blk core.Transport{
                    .tempo = if ((ctx.state & @intFromEnum(vst3.processor.ProcessContext.StatesAndFlags.kTempoValid)) != 0) @floatCast(ctx.tempo) else null,
                    .time_sig_numerator = if ((ctx.state & @intFromEnum(vst3.processor.ProcessContext.StatesAndFlags.kTimeSigValid)) != 0) @intCast(ctx.time_sig_numerator) else null,
                    .time_sig_denominator = if ((ctx.state & @intFromEnum(vst3.processor.ProcessContext.StatesAndFlags.kTimeSigValid)) != 0) @intCast(ctx.time_sig_denominator) else null,
                    .playing = (ctx.state & @intFromEnum(vst3.processor.ProcessContext.StatesAndFlags.kPlaying)) != 0,
                    .recording = (ctx.state & @intFromEnum(vst3.processor.ProcessContext.StatesAndFlags.kRecording)) != 0,
                    .looping = (ctx.state & @intFromEnum(vst3.processor.ProcessContext.StatesAndFlags.kCycleActive)) != 0,
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
            wrapper.event_output_list = core.EventOutputList{
                .events = &wrapper.output_events_storage,
            };
            
            // Build process context
            var context = core.ProcessContext{
                .transport = transport,
                .input_events = wrapper.input_events_storage[0..input_event_count],
                .output_events = &wrapper.event_output_list,
                .sample_rate = wrapper.buffer_config.sample_rate,
                .param_values_ptr = &wrapper.param_values,
                .smoothers_ptr = &wrapper.smoother_bank,
                .params_meta = P.params,
            };
            
            // Call plugin process
            const status = P.process(&wrapper.plugin, &buffer, &aux, &context);
            
            // Translate output events back to VST3 format
            if (data.output_events) |output_event_list| {
                for (wrapper.event_output_list.slice()) |*event| {
                    var vst3_event: vst3.events.Event = undefined;
                    if (translateVst3OutputEvent(event, &vst3_event)) {
                        const event_vtbl: *const vst3.events.IEventListVtbl = @ptrCast(@alignCast(output_event_list.lpVtbl));
                        _ = event_vtbl.addEvent(output_event_list, &vst3_event);
                    }
                }
            }
            
            // Map ProcessStatus to result
            return switch (status) {
                .normal, .tail, .keep_alive => vst3.types.kResultOk,
                .silence => vst3.types.kResultOk,
                .err => vst3.types.kResultFalse,
            };
        }
        
        fn getTailSamples(_: *anyopaque) callconv(.c) u32 {
            return 0;
        }
        
        /// Convert a plugin ID string to a VST3 TUID.
        fn pluginIdToTuid(comptime id: [:0]const u8) vst3.TUID {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(id);
            var hash: [32]u8 = undefined;
            hasher.final(&hash);
            
            var tuid: vst3.TUID = undefined;
            @memcpy(&tuid, hash[0..16]);
            return tuid;
        }
    };
}
