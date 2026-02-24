/// CLAP extension implementations.
///
/// This module provides the standard CLAP extensions (audio-ports, note-ports,
/// params, state) for the plugin wrapper.
const std = @import("std");
const clap = @import("../../bindings/clap/main.zig");
const core = @import("../../root.zig");
const common = @import("../common.zig");

/// Generate extension implementations for plugin type `T`.
pub fn Extensions(comptime T: type) type {
    const P = core.Plugin(T);

    return struct {
        // -------------------------------------------------------------------
        // Audio Ports Extension
        // -------------------------------------------------------------------

        pub const audio_ports = clap.ext.audio_ports.Plugin{
            .count = audioPortsCount,
            .get = audioPortsGet,
        };

        fn audioPortsCount(_: *const clap.Plugin, is_input: bool) callconv(.c) u32 {
            // For now, we support one main input and one main output port
            for (P.audio_io_layouts) |layout| {
                if (is_input) {
                    if (layout.main_input_channels != null) return 1;
                } else {
                    if (layout.main_output_channels != null) return 1;
                }
            }
            return 0;
        }

        fn audioPortsGet(
            _: *const clap.Plugin,
            index: u32,
            is_input: bool,
            info: *clap.ext.audio_ports.Info,
        ) callconv(.c) bool {
            if (index != 0) return false;

            // Use first layout
            const layout = P.audio_io_layouts[0];

            const channel_count = if (is_input)
                layout.main_input_channels orelse return false
            else
                layout.main_output_channels orelse return false;

            // Determine port type
            const port_type: ?[*:0]const u8 = if (channel_count == 1)
                clap.ext.audio_ports.port_mono
            else if (channel_count == 2)
                clap.ext.audio_ports.port_stereo
            else
                null;

            info.* = clap.ext.audio_ports.Info{
                .id = @enumFromInt(if (is_input) @as(u32, 0) else @as(u32, 1)),
                .name = undefined,
                .flags = .{ .is_main = true },
                .channel_count = channel_count,
                .port_type = port_type,
                .in_place_pair = @enumFromInt(@as(u32, @import("std").math.maxInt(u32))),
            };

            // Set name
            const name = if (is_input) "Audio Input" else "Audio Output";
            @memset(&info.name, 0);
            @memcpy(info.name[0..name.len], name);

            return true;
        }

        // -------------------------------------------------------------------
        // Note Ports Extension
        // -------------------------------------------------------------------

        pub const note_ports = clap.ext.note_ports.Plugin{
            .count = notePortsCount,
            .get = notePortsGet,
        };

        fn notePortsCount(_: *const clap.Plugin, is_input: bool) callconv(.c) u32 {
            if (is_input and P.midi_input != .none) return 1;
            if (!is_input and P.midi_output != .none) return 1;
            return 0;
        }

        fn notePortsGet(
            _: *const clap.Plugin,
            index: u32,
            is_input: bool,
            info: *clap.ext.note_ports.Info,
        ) callconv(.c) bool {
            if (index != 0) return false;

            if (is_input and P.midi_input == .none) return false;
            if (!is_input and P.midi_output == .none) return false;

            info.* = clap.ext.note_ports.Info{
                .id = @enumFromInt(0),
                .supported_dialects = .{ .clap = true, .midi = true },
                .preferred_dialect = .clap,
                .name = undefined,
            };

            const name = if (is_input) "Note Input" else "Note Output";
            @memset(&info.name, 0);
            @memcpy(info.name[0..name.len], name);

            return true;
        }

        // -------------------------------------------------------------------
        // Params Extension
        // -------------------------------------------------------------------

        pub const params = clap.ext.params.Plugin{
            .count = paramsCount,
            .getInfo = paramsGetInfo,
            .getValue = paramsGetValue,
            .valueToText = paramsValueToText,
            .textToValue = paramsTextToValue,
            .flush = paramsFlush,
        };

        fn paramsCount(_: *const clap.Plugin) callconv(.c) u32 {
            return @intCast(P.params.len);
        }

        fn paramsGetInfo(
            _: *const clap.Plugin,
            index: u32,
            info: *clap.ext.params.Info,
        ) callconv(.c) bool {
            if (index >= P.params.len) return false;

            const param = P.params[index];
            const param_id = P.param_ids[index];

            info.* = clap.ext.params.Info{
                .id = @enumFromInt(param_id),
                .flags = .{
                    .is_automatable = param.flags().automatable,
                    .is_modulatable = param.flags().modulatable,
                    .is_hidden = param.flags().hidden,
                    .is_bypass = param.flags().bypass,
                    .is_stepped = param.flags().is_stepped,
                },
                .cookie = null,
                .name = undefined,
                .module = undefined,
                .min_value = switch (param) {
                    .float => |p| switch (p.range) {
                        .linear => |r| r.min,
                        .logarithmic => |r| r.min,
                    },
                    .int => |p| @floatFromInt(p.range.min),
                    .boolean => 0.0,
                    .choice => 0.0,
                },
                .max_value = switch (param) {
                    .float => |p| switch (p.range) {
                        .linear => |r| r.max,
                        .logarithmic => |r| r.max,
                    },
                    .int => |p| @floatFromInt(p.range.max),
                    .boolean => 1.0,
                    .choice => |p| @floatFromInt(p.labels.len - 1),
                },
                .default_value = switch (param) {
                    .float => |p| p.default,
                    .int => |p| @floatFromInt(p.default),
                    .boolean => |p| if (p.default) @as(f64, 1.0) else @as(f64, 0.0),
                    .choice => |p| @floatFromInt(p.default),
                },
            };

            // Copy parameter name
            const name = param.name();
            @memset(&info.name, 0);
            @memcpy(info.name[0..@min(name.len, clap.name_capacity)], name[0..@min(name.len, clap.name_capacity)]);

            // Empty module path for now
            @memset(&info.module, 0);

            return true;
        }

        fn paramsGetValue(
            plugin: *const clap.Plugin,
            id: clap.Id,
            out_value: *f64,
        ) callconv(.c) bool {
            const wrapper = @as(*anyopaque, @ptrFromInt(@intFromPtr(plugin) - @offsetOf(@import("plugin.zig").PluginWrapper(T), "clap_plugin")));
            const self: *@import("plugin.zig").PluginWrapper(T) = @ptrCast(@alignCast(wrapper));

            // Find parameter by ID using binary search
            if (P.findParamIndex(@intFromEnum(id))) |idx| {
                const param = P.params[idx];
                const normalized = self.param_values.get(idx);

                // Convert normalized to plain value using shared helper
                out_value.* = common.normalizedToPlain(param, normalized);
                return true;
            }

            return false;
        }

        fn paramsValueToText(
            _: *const clap.Plugin,
            id: clap.Id,
            value: f64,
            out_buffer: [*]u8,
            out_buffer_capacity: u32,
        ) callconv(.c) bool {
            // Find parameter by ID using binary search
            if (P.findParamIndex(@intFromEnum(id))) |idx| {
                const param = P.params[idx];
                // Format the value
                const text = switch (param) {
                    .float => |p| blk: {
                        var buf: [64]u8 = undefined;
                        const unit = if (p.unit.len > 0) p.unit else "";
                        const formatted = std.fmt.bufPrint(&buf, "{d:.2}{s}", .{ value, unit }) catch break :blk "?";
                        break :blk formatted;
                    },
                    .int => blk: {
                        var buf: [64]u8 = undefined;
                        const formatted = std.fmt.bufPrint(&buf, "{d}", .{@as(i32, @intFromFloat(value))}) catch break :blk "?";
                        break :blk formatted;
                    },
                    .boolean => if (value > 0.5) "On" else "Off",
                    .choice => |p| blk: {
                        const choice_idx = @as(usize, @intFromFloat(value));
                        if (choice_idx < p.labels.len) break :blk p.labels[choice_idx];
                        break :blk "?";
                    },
                };

                const copy_len = @min(text.len, out_buffer_capacity - 1);
                @memcpy(out_buffer[0..copy_len], text[0..copy_len]);
                out_buffer[copy_len] = 0;
                return true;
            }

            return false;
        }

        fn paramsTextToValue(
            _: *const clap.Plugin,
            id: clap.Id,
            value_text: [*:0]const u8,
            out_value: *f64,
        ) callconv(.c) bool {
            const text = std.mem.span(value_text);

            // Find parameter by ID using binary search
            if (P.findParamIndex(@intFromEnum(id))) |idx| {
                const param = P.params[idx];
                switch (param) {
                    .float => {
                        const parsed = std.fmt.parseFloat(f64, text) catch return false;
                        out_value.* = parsed;
                        return true;
                    },
                    .int => {
                        const parsed = std.fmt.parseInt(i32, text, 10) catch return false;
                        out_value.* = @floatFromInt(parsed);
                        return true;
                    },
                    .boolean => {
                        if (std.ascii.eqlIgnoreCase(text, "on") or std.ascii.eqlIgnoreCase(text, "true") or std.ascii.eqlIgnoreCase(text, "1")) {
                            out_value.* = 1.0;
                            return true;
                        } else {
                            out_value.* = 0.0;
                            return true;
                        }
                    },
                    .choice => |p| {
                        // Try to find matching label
                        for (p.labels, 0..) |label, choice_idx| {
                            if (std.ascii.eqlIgnoreCase(text, label)) {
                                out_value.* = @floatFromInt(choice_idx);
                                return true;
                            }
                        }
                        return false;
                    },
                }
            }

            return false;
        }

        fn paramsFlush(
            plugin: *const clap.Plugin,
            in_events: *const clap.events.InputEvents,
            _: *const clap.events.OutputEvents,
        ) callconv(.c) void {
            const wrapper = @as(*anyopaque, @ptrFromInt(@intFromPtr(plugin) - @offsetOf(@import("plugin.zig").PluginWrapper(T), "clap_plugin")));
            const self: *@import("plugin.zig").PluginWrapper(T) = @ptrCast(@alignCast(wrapper));

            // Process all input parameter events
            const event_count = in_events.size(in_events);
            var i: u32 = 0;
            while (i < event_count) : (i += 1) {
                const header = in_events.get(in_events, i);
                if (header.type == .param_value) {
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
                }
            }
        }

        // -------------------------------------------------------------------
        // State Extension
        // -------------------------------------------------------------------

        pub const state = clap.ext.state.Plugin{
            .save = stateSave,
            .load = stateLoad,
        };

        fn stateSave(
            plugin: *const clap.Plugin,
            stream: *const clap.OStream,
        ) callconv(.c) bool {
            const wrapper = @as(*anyopaque, @ptrFromInt(@intFromPtr(plugin) - @offsetOf(@import("plugin.zig").PluginWrapper(T), "clap_plugin")));
            const self: *@import("plugin.zig").PluginWrapper(T) = @ptrCast(@alignCast(wrapper));

            // Create a writer adapter for the CLAP stream
            const Writer = struct {
                stream_ptr: *const clap.OStream,

                pub fn write(ctx: *const anyopaque, bytes: []const u8) !usize {
                    const writer_self: *const @This() = @ptrCast(@alignCast(ctx));
                    const result = writer_self.stream_ptr.write(writer_self.stream_ptr, bytes.ptr, bytes.len);
                    const written = @intFromEnum(result);
                    if (written < 0) return error.WriteFailed;
                    return @intCast(written);
                }
            };

            var writer_ctx = Writer{ .stream_ptr = stream };
            const any_writer = std.io.AnyWriter{
                .context = @ptrCast(&writer_ctx),
                .writeFn = Writer.write,
            };

            // Write state header
            core.writeHeader(any_writer, P.state_version) catch return false;

            // Write parameter values
            for (0..P.params.len) |i| {
                const normalized = self.param_values.get(i);
                const bytes = std.mem.asBytes(&normalized);
                any_writer.writeAll(bytes) catch return false;
            }

            const save_context = core.SaveContext{
                .writer = any_writer,
            };

            return P.save(&self.plugin, save_context);
        }

        fn stateLoad(
            plugin: *const clap.Plugin,
            stream: *const clap.IStream,
        ) callconv(.c) bool {
            const wrapper = @as(*anyopaque, @ptrFromInt(@intFromPtr(plugin) - @offsetOf(@import("plugin.zig").PluginWrapper(T), "clap_plugin")));
            const self: *@import("plugin.zig").PluginWrapper(T) = @ptrCast(@alignCast(wrapper));

            // Create a reader adapter for the CLAP stream
            const Reader = struct {
                stream_ptr: *const clap.IStream,

                pub fn read(ctx: *const anyopaque, buffer: []u8) !usize {
                    const reader_self: *const @This() = @ptrCast(@alignCast(ctx));
                    const result = reader_self.stream_ptr.read(reader_self.stream_ptr, buffer.ptr, buffer.len);
                    const read_result = @intFromEnum(result);
                    if (read_result < 0) return error.ReadFailed;
                    if (read_result == 0) return 0; // EOF
                    return @intCast(read_result);
                }
            };

            var reader_ctx = Reader{ .stream_ptr = stream };
            const any_reader = std.io.AnyReader{
                .context = @ptrCast(&reader_ctx),
                .readFn = Reader.read,
            };

            // Read state header
            const version = core.readHeader(any_reader) catch return false;

            // Read parameter values
            for (0..P.params.len) |i| {
                var normalized: f32 = undefined;
                const bytes = std.mem.asBytes(&normalized);
                const read_count = any_reader.readAll(bytes) catch return false;
                if (read_count != @sizeOf(f32)) return false;
                self.param_values.set(i, normalized);

                // Update smoother target
                const param = P.params[i];
                const plain_value = param.toPlain(normalized);
                self.smoother_bank.setTarget(i, self.buffer_config.sample_rate, plain_value);
            }

            const load_context = core.LoadContext{
                .reader = any_reader,
                .version = version,
            };

            return P.load(&self.plugin, load_context);
        }
    };
}
