// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! z_plug_host — C-compatible CLAP plugin host library.
//!
//! All public symbols are prefixed `zph_` and use the C calling convention.
//! Consumers link against the static library and include `z_plug_host.h`.

const std = @import("std");
const PluginInstance = @import("plugin_instance.zig").PluginInstance;
const clap = @import("clap-bindings");

// Use the C allocator so the library works cleanly when linked from C/Rust.
const allocator = std.heap.c_allocator;

// ---------------------------------------------------------------------------
// Opaque handle type (exposed as `ZphPlugin*` in C)
// ---------------------------------------------------------------------------

/// Opaque plugin handle. Callers hold a `*ZphPlugin`; internally it is a
/// `*PluginInstance` cast to this type.
pub const ZphPlugin = opaque {};

fn toInst(p: *ZphPlugin) *PluginInstance {
    return @ptrCast(@alignCast(p));
}

fn toHandle(inst: *PluginInstance) *ZphPlugin {
    return @ptrCast(inst);
}

// ---------------------------------------------------------------------------
// Process status (mirrors clap.Process.Status)
// ---------------------------------------------------------------------------

pub const ZphProcessStatus = enum(i32) {
    @"error" = 0,
    @"continue" = 1,
    continue_if_not_quiet = 2,
    tail = 3,
    sleep = 4,
};

// ---------------------------------------------------------------------------
// Public Zig API (for use from other Zig modules like z_plug_engine)
// ---------------------------------------------------------------------------

/// Process one block of audio. Zig-callable wrapper around the export.
pub fn processPlugin(
    plugin: *ZphPlugin,
    inputs: [*]const [*]const f32,
    outputs: [*]const [*]f32,
    channel_count: u32,
    frame_count: u32,
) ZphProcessStatus {
    return zph_process(plugin, inputs, outputs, channel_count, frame_count);
}

// ---------------------------------------------------------------------------
// Plugin info struct (C-compatible)
// ---------------------------------------------------------------------------

pub const ZphPluginInfo = extern struct {
    id: [*:0]const u8,
    name: [*:0]const u8,
    vendor: [*:0]const u8,
    version: [*:0]const u8,
    description: [*:0]const u8,
    input_channels: u32,
    output_channels: u32,
    latency_samples: u32,
};

// ---------------------------------------------------------------------------
// Parameter info struct (C-compatible)
// ---------------------------------------------------------------------------

pub const ZphParamInfo = extern struct {
    id: u32,
    name: [256]u8,
    module: [1024]u8,
    min_value: f64,
    max_value: f64,
    default_value: f64,
    flags: u32,
};

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Load a .clap file and instantiate a plugin.
/// `path` must be a null-terminated path to the .clap file or bundle.
/// `plugin_id` may be null to load the first available plugin.
/// Returns an opaque handle, or null on failure.
export fn zph_load_plugin(path: [*:0]const u8, plugin_id: ?[*:0]const u8) ?*ZphPlugin {
    const path_slice = std.mem.span(path);
    const id_slice: ?[]const u8 = if (plugin_id) |p| std.mem.span(p) else null;

    const inst = PluginInstance.load(allocator, path_slice, id_slice) catch |err| {
        std.log.err("zph_load_plugin failed: {}", .{err});
        return null;
    };

    inst.init() catch |err| {
        std.log.err("zph_load_plugin init failed: {}", .{err});
        inst.destroy();
        return null;
    };

    return toHandle(inst);
}

/// Destroy a plugin handle and free all resources.
/// The handle must not be used after this call.
export fn zph_destroy(plugin: *ZphPlugin) void {
    toInst(plugin).destroy();
}

/// Activate the plugin for processing.
/// Must be called before `zph_start_processing`.
export fn zph_activate(plugin: *ZphPlugin, sample_rate: f64, max_frames: u32) bool {
    toInst(plugin).activate(sample_rate, max_frames) catch |err| {
        std.log.err("zph_activate failed: {}", .{err});
        return false;
    };
    return true;
}

/// Deactivate the plugin. Stops processing if running.
export fn zph_deactivate(plugin: *ZphPlugin) void {
    toInst(plugin).deactivate();
}

/// Start the processing state. Must be called from the audio thread.
export fn zph_start_processing(plugin: *ZphPlugin) bool {
    toInst(plugin).startProcessing() catch |err| {
        std.log.err("zph_start_processing failed: {}", .{err});
        return false;
    };
    return true;
}

/// Stop the processing state. Must be called from the audio thread.
export fn zph_stop_processing(plugin: *ZphPlugin) void {
    toInst(plugin).stopProcessing();
}

// ---------------------------------------------------------------------------
// Audio processing
// ---------------------------------------------------------------------------

/// Process one block of audio through the plugin.
/// `inputs` and `outputs` are arrays of `channel_count` non-interleaved
/// channel buffers, each containing `frame_count` f32 samples.
/// Must be called from the audio thread while processing is active.
export fn zph_process(
    plugin: *ZphPlugin,
    inputs: [*]const [*]const f32,
    outputs: [*]const [*]f32,
    channel_count: u32,
    frame_count: u32,
) ZphProcessStatus {
    const status = toInst(plugin).process(inputs, outputs, channel_count, frame_count) catch
        return .@"error";
    return switch (status) {
        .@"error" => .@"error",
        .@"continue" => .@"continue",
        .continue_if_not_quiet => .continue_if_not_quiet,
        .tail => .tail,
        .sleep => .sleep,
    };
}

// ---------------------------------------------------------------------------
// Plugin info
// ---------------------------------------------------------------------------

/// Fill `out` with plugin metadata. Returns false if the plugin is not loaded.
export fn zph_get_plugin_info(plugin: *const ZphPlugin, out: *ZphPluginInfo) bool {
    const inst = @as(*const PluginInstance, @ptrCast(@alignCast(plugin)));
    const desc = inst.plugin.descriptor;

    out.id = desc.id;
    out.name = desc.name;
    out.vendor = desc.vendor orelse "";
    out.version = desc.version orelse "";
    out.description = desc.description orelse "";
    out.input_channels = inst.input_channel_count;
    out.output_channels = inst.output_channel_count;
    out.latency_samples = inst.latency_samples;
    return true;
}

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

/// Return the number of parameters the plugin exposes.
export fn zph_get_param_count(plugin: *const ZphPlugin) u32 {
    const inst = @as(*const PluginInstance, @ptrCast(@alignCast(plugin)));
    const p = inst.ext_params orelse return 0;
    return p.count(inst.plugin);
}

/// Fill `out` with info about parameter at `index`. Returns false on failure.
export fn zph_get_param_info(plugin: *const ZphPlugin, index: u32, out: *ZphParamInfo) bool {
    const inst = @as(*const PluginInstance, @ptrCast(@alignCast(plugin)));
    const p = inst.ext_params orelse return false;

    var info: clap.ext.params.Info = undefined;
    if (!p.getInfo(inst.plugin, index, &info)) return false;

    out.id = @intFromEnum(info.id);
    out.min_value = info.min_value;
    out.max_value = info.max_value;
    out.default_value = info.default_value;
    out.flags = @bitCast(info.flags);
    @memcpy(&out.name, &info.name);
    @memcpy(&out.module, &info.module);
    return true;
}

/// Get the current value of a parameter by ID. Returns false on failure.
export fn zph_get_param_value(plugin: *const ZphPlugin, param_id: u32, out: *f64) bool {
    const inst = @as(*const PluginInstance, @ptrCast(@alignCast(plugin)));
    const p = inst.ext_params orelse return false;
    return p.getValue(inst.plugin, @enumFromInt(param_id), out);
}

/// Queue a parameter change to be applied on the next `zph_process` call.
/// Thread-safe; may be called from any thread.
export fn zph_set_param_value(plugin: *ZphPlugin, param_id: u32, value: f64) void {
    toInst(plugin).queueParamChange(param_id, value);
}

// ---------------------------------------------------------------------------
// State persistence
// ---------------------------------------------------------------------------

/// Save plugin state into `buffer`.
/// If `buffer` is null or `*size` is too small, sets `*size` to the required
/// byte count and returns false. On success, sets `*size` to bytes written.
export fn zph_save_state(plugin: *const ZphPlugin, buffer: ?[*]u8, size: *u32) bool {
    const inst = @as(*const PluginInstance, @ptrCast(@alignCast(plugin)));
    const data = inst.saveState() catch return false;
    defer allocator.free(data);

    if (buffer == null or size.* < data.len) {
        size.* = @intCast(data.len);
        return false;
    }
    @memcpy(buffer.?[0..data.len], data);
    size.* = @intCast(data.len);
    return true;
}

/// Load plugin state from `buffer[0..size]`.
export fn zph_load_state(plugin: *ZphPlugin, buffer: [*]const u8, size: u32) bool {
    toInst(plugin).loadState(buffer[0..size]) catch |err| {
        std.log.err("zph_load_state failed: {}", .{err});
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// Main-thread idle
// ---------------------------------------------------------------------------

/// Handle deferred plugin callbacks. Call periodically from the main thread.
export fn zph_idle(plugin: *ZphPlugin) void {
    toInst(plugin).idle();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@import("event_list.zig"));
    std.testing.refAllDecls(@import("audio_buffers.zig"));
}
