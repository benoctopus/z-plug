// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! CLAP plugin instance lifecycle management.
//!
//! Handles DSO loading, clap_entry resolution, macOS bundle path detection,
//! plugin instantiation, and the full lifecycle state machine:
//!
//!   Loaded → Initialized → Activated → Processing
//!                                    ← Activated  (stop_processing)
//!                         ← Initialized (deactivate)
//!            ← Loaded      (destroy)

const std = @import("std");
const clap = @import("clap-bindings");
const extensions = @import("extensions.zig");
const EventList = @import("event_list.zig");
const AudioBufferSet = @import("audio_buffers.zig").AudioBufferSet;

pub const LifecycleState = enum {
    loaded,
    initialized,
    activated,
    processing,
};

/// Queued parameter change to be applied on the next process() call.
pub const PendingParam = struct {
    id: clap.Id,
    value: f64,
};

pub const PluginInstance = struct {
    allocator: std.mem.Allocator,

    // DSO handle — must stay open while plugin is alive
    dynlib: std.DynLib,

    // CLAP entry point resolved from the DSO
    entry: *const clap.Entry,

    // The instantiated plugin
    plugin: *const clap.Plugin,

    // Our host struct — its host_data points back to this PluginInstance
    host: clap.Host,

    // Current lifecycle state
    state: LifecycleState,

    // Cached plugin extensions (queried once after init)
    ext_params: ?*const clap.ext.params.Plugin,
    ext_audio_ports: ?*const clap.ext.audio_ports.Plugin,
    ext_state: ?*const clap.ext.state.Plugin,
    ext_latency: ?*const clap.ext.latency.Plugin,

    // Atomic flags set by plugin callbacks (thread-safe)
    needs_param_rescan: std.atomic.Value(bool),
    needs_param_flush: std.atomic.Value(bool),
    state_dirty: std.atomic.Value(bool),
    latency_changed: std.atomic.Value(bool),
    request_restart: std.atomic.Value(bool),
    request_callback: std.atomic.Value(bool),

    // Parameter change queue — written from main thread, drained on audio thread
    pending_params: std.ArrayListUnmanaged(PendingParam),
    pending_params_mutex: std.Thread.Mutex,

    // Audio port configuration (queried after init, before activate)
    input_channel_count: u32,
    output_channel_count: u32,
    latency_samples: u32,

    // Audio buffers for process()
    input_buf: AudioBufferSet,
    output_buf: AudioBufferSet,

    // Event lists for process()
    in_events: EventList.InputEventList,
    out_events: EventList.OutputEventList,

    // Monotonic sample counter for steady_time
    steady_time: i64,

    /// Load a .clap file and instantiate the first plugin matching `plugin_id`.
    /// If `plugin_id` is null, the first plugin in the file is used.
    /// The returned instance is heap-allocated; call `destroy` to free it.
    pub fn load(
        allocator: std.mem.Allocator,
        path: []const u8,
        plugin_id: ?[]const u8,
    ) !*PluginInstance {
        // Resolve the actual binary path (handles macOS bundles)
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const binary_path = try resolveBinaryPath(path, &path_buf);

        var dynlib = try std.DynLib.open(binary_path);
        errdefer dynlib.close();

        const entry = dynlib.lookup(*const clap.Entry, "clap_entry") orelse
            return error.NoClapEntry;

        // Convert path to null-terminated for the C API
        var path_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});

        if (!entry.init(path_z)) return error.ClapEntryInitFailed;
        errdefer entry.deinit();

        const factory_ptr = entry.getFactory("clap.plugin-factory") orelse
            return error.NoPluginFactory;
        const factory: *const clap.PluginFactory = @ptrCast(@alignCast(factory_ptr));

        const count = factory.getPluginCount(factory);
        if (count == 0) return error.NoPluginsInFactory;

        // Find the plugin descriptor
        var target_desc: ?*const clap.Plugin.Descriptor = null;
        for (0..count) |i| {
            const desc = factory.getPluginDescriptor(factory, @intCast(i)) orelse continue;
            if (plugin_id) |wanted_id| {
                const desc_id = std.mem.span(desc.id);
                if (std.mem.eql(u8, desc_id, wanted_id)) {
                    target_desc = desc;
                    break;
                }
            } else {
                target_desc = desc;
                break;
            }
        }
        const desc = target_desc orelse return error.PluginNotFound;

        // Allocate the instance before creating the plugin so we can set host_data
        const inst = try allocator.create(PluginInstance);
        errdefer allocator.destroy(inst);

        inst.* = PluginInstance{
            .allocator = allocator,
            .dynlib = dynlib,
            .entry = entry,
            .plugin = undefined, // set below
            .host = undefined, // set below
            .state = .loaded,
            .ext_params = null,
            .ext_audio_ports = null,
            .ext_state = null,
            .ext_latency = null,
            .needs_param_rescan = std.atomic.Value(bool).init(false),
            .needs_param_flush = std.atomic.Value(bool).init(false),
            .state_dirty = std.atomic.Value(bool).init(false),
            .latency_changed = std.atomic.Value(bool).init(false),
            .request_restart = std.atomic.Value(bool).init(false),
            .request_callback = std.atomic.Value(bool).init(false),
            .pending_params = .empty,
            .pending_params_mutex = .{},
            .input_channel_count = 2,
            .output_channel_count = 2,
            .latency_samples = 0,
            .input_buf = try AudioBufferSet.init(allocator, 2),
            .output_buf = try AudioBufferSet.init(allocator, 2),
            .in_events = EventList.InputEventList.init(allocator),
            .out_events = EventList.OutputEventList.init(allocator),
            .steady_time = 0,
        };
        errdefer {
            inst.input_buf.deinit();
            inst.output_buf.deinit();
            inst.in_events.deinit();
            inst.out_events.deinit();
            inst.pending_params.deinit(allocator);
        }

        // Fix up vtable context pointers now that the struct is at its final address
        inst.in_events.fixupVtable();
        inst.out_events.fixupVtable();

        // Build the host struct with host_data pointing to this instance
        inst.host = buildHost(inst);

        const plugin = factory.createPlugin(factory, &inst.host, desc.id) orelse
            return error.CreatePluginFailed;
        inst.plugin = plugin;

        return inst;
    }

    /// Initialize the plugin (call after load, before activate).
    /// Must be called from the main thread.
    pub fn init(self: *PluginInstance) !void {
        std.debug.assert(self.state == .loaded);
        extensions.thread_role = .main;
        if (!self.plugin.init(self.plugin)) return error.PluginInitFailed;
        self.state = .initialized;

        // Cache extensions
        self.ext_params = @ptrCast(@alignCast(
            self.plugin.getExtension(self.plugin, clap.ext.params.id),
        ));
        self.ext_audio_ports = @ptrCast(@alignCast(
            self.plugin.getExtension(self.plugin, clap.ext.audio_ports.id),
        ));
        self.ext_state = @ptrCast(@alignCast(
            self.plugin.getExtension(self.plugin, clap.ext.state.id),
        ));
        self.ext_latency = @ptrCast(@alignCast(
            self.plugin.getExtension(self.plugin, clap.ext.latency.id),
        ));

        // Query audio port configuration
        self.queryAudioPorts();
    }

    /// Activate the plugin for processing.
    /// Must be called from the main thread after init().
    pub fn activate(self: *PluginInstance, sample_rate: f64, max_frames: u32) !void {
        std.debug.assert(self.state == .initialized);
        extensions.thread_role = .main;
        if (!self.plugin.activate(self.plugin, sample_rate, 1, max_frames))
            return error.PluginActivateFailed;
        self.state = .activated;

        // Re-query latency after activation
        if (self.ext_latency) |lat| {
            self.latency_samples = lat.get(self.plugin);
        }
    }

    /// Deactivate the plugin. Must be called from the main thread.
    pub fn deactivate(self: *PluginInstance) void {
        if (self.state == .processing) self.stopProcessing();
        if (self.state != .activated) return;
        extensions.thread_role = .main;
        self.plugin.deactivate(self.plugin);
        self.state = .initialized;
    }

    /// Start the audio processing state. Must be called from the audio thread.
    pub fn startProcessing(self: *PluginInstance) !void {
        std.debug.assert(self.state == .activated);
        extensions.thread_role = .audio;
        if (!self.plugin.startProcessing(self.plugin))
            return error.StartProcessingFailed;
        self.state = .processing;
    }

    /// Stop the audio processing state. Must be called from the audio thread.
    pub fn stopProcessing(self: *PluginInstance) void {
        if (self.state != .processing) return;
        extensions.thread_role = .audio;
        self.plugin.stopProcessing(self.plugin);
        self.state = .activated;
    }

    /// Process one block of audio. Must be called from the audio thread.
    /// `inputs` and `outputs` are arrays of `channel_count` channel pointers,
    /// each pointing to `frame_count` f32 samples.
    pub fn process(
        self: *PluginInstance,
        inputs: [*]const [*]const f32,
        outputs: [*]const [*]f32,
        channel_count: u32,
        frame_count: u32,
    ) !clap.Process.Status {
        if (self.state != .processing) return error.NotProcessing;

        extensions.thread_role = .audio;

        // Resize audio buffers if channel count changed
        if (channel_count != self.input_buf.descriptor.channel_count) {
            try self.input_buf.resize(channel_count);
            try self.output_buf.resize(channel_count);
        }

        self.input_buf.updateConstPointers(inputs);
        self.output_buf.updatePointers(outputs);

        // Drain pending param changes into the input event list
        self.in_events.clear();
        self.out_events.clear();
        {
            self.pending_params_mutex.lock();
            defer self.pending_params_mutex.unlock();
            for (self.pending_params.items) |p| {
                self.in_events.pushParamValue(p.id, p.value, 0) catch {};
            }
            self.pending_params.clearRetainingCapacity();
        }

        const proc = clap.Process{
            .steady_time = @enumFromInt(self.steady_time),
            .frames_count = frame_count,
            .transport = null,
            .audio_inputs = @ptrCast(&self.input_buf.descriptor),
            .audio_outputs = @ptrCast(&self.output_buf.descriptor),
            .audio_inputs_count = 1,
            .audio_outputs_count = 1,
            .in_events = &self.in_events.vtable,
            .out_events = &self.out_events.vtable,
        };

        const status = self.plugin.process(self.plugin, &proc);
        self.steady_time += @intCast(frame_count);
        return status;
    }

    /// Queue a parameter change to be applied on the next process() call.
    /// Thread-safe; may be called from any thread.
    pub fn queueParamChange(self: *PluginInstance, param_id: u32, value: f64) void {
        self.pending_params_mutex.lock();
        defer self.pending_params_mutex.unlock();
        self.pending_params.append(self.allocator, .{
            .id = @enumFromInt(param_id),
            .value = value,
        }) catch {};
    }

    /// Handle deferred main-thread work. Call periodically from the main thread.
    pub fn idle(self: *PluginInstance) void {
        extensions.thread_role = .main;

        if (self.request_callback.swap(false, .acq_rel)) {
            self.plugin.onMainThread(self.plugin);
        }

        if (self.request_restart.swap(false, .acq_rel)) {
            self.deactivate();
            // Caller is responsible for re-activating with desired params
        }

        // Flush params if plugin requested it and we're not currently processing
        if (self.needs_param_flush.swap(false, .acq_rel)) {
            if (self.state == .initialized or self.state == .activated) {
                if (self.ext_params) |p| {
                    self.in_events.clear();
                    self.out_events.clear();
                    p.flush(self.plugin, &self.in_events.vtable, &self.out_events.vtable);
                }
            }
        }

        if (self.needs_param_rescan.swap(false, .acq_rel)) {
            // Nothing to do for a simple host — params are queried on demand
        }

        if (self.latency_changed.swap(false, .acq_rel)) {
            if (self.ext_latency) |lat| {
                self.latency_samples = lat.get(self.plugin);
            }
        }
    }

    /// Save plugin state into a newly allocated byte slice.
    /// Caller must free the returned slice with `allocator.free`.
    pub fn saveState(self: *const PluginInstance) ![]u8 {
        const ext = self.ext_state orelse return error.StateNotSupported;
        extensions.thread_role = .main;

        const SaveCtx = struct {
            list: std.ArrayListUnmanaged(u8),
            alloc: std.mem.Allocator,
        };
        var save_ctx = SaveCtx{ .list = .empty, .alloc = self.allocator };
        errdefer save_ctx.list.deinit(self.allocator);

        const stream = clap.OStream{
            .context = &save_ctx,
            .write = struct {
                fn f(s: *const clap.OStream, data: *const anyopaque, size: u64) callconv(.c) clap.OStream.Result {
                    const ctx: *SaveCtx = @ptrCast(@alignCast(s.context));
                    const bytes: [*]const u8 = @ptrCast(data);
                    ctx.list.appendSlice(ctx.alloc, bytes[0..size]) catch return .write_error;
                    return @enumFromInt(@as(i64, @intCast(size)));
                }
            }.f,
        };

        if (!ext.save(self.plugin, &stream)) return error.StateSaveFailed;
        return try save_ctx.list.toOwnedSlice(self.allocator);
    }

    /// Load plugin state from a byte slice.
    pub fn loadState(self: *PluginInstance, data: []const u8) !void {
        const ext = self.ext_state orelse return error.StateNotSupported;
        extensions.thread_role = .main;

        const ctx = struct {
            data: []const u8,
            pos: usize,
        }{ .data = data, .pos = 0 };
        var mutable_ctx = ctx;

        const stream = clap.IStream{
            .context = &mutable_ctx,
            .read = struct {
                fn f(s: *const clap.IStream, buf: *anyopaque, size: u64) callconv(.c) clap.IStream.Result {
                    const c = @as(*@TypeOf(mutable_ctx), @ptrCast(@alignCast(s.context)));
                    const remaining = c.data.len - c.pos;
                    if (remaining == 0) return .end_of_file;
                    const to_read = @min(size, remaining);
                    const dst: [*]u8 = @ptrCast(buf);
                    @memcpy(dst[0..to_read], c.data[c.pos .. c.pos + to_read]);
                    c.pos += to_read;
                    return @enumFromInt(@as(i64, @intCast(to_read)));
                }
            }.f,
        };

        if (!ext.load(self.plugin, &stream)) return error.StateLoadFailed;
    }

    /// Destroy the plugin instance and free all resources.
    /// Must be called from the main thread.
    pub fn destroy(self: *PluginInstance) void {
        extensions.thread_role = .main;

        if (self.state == .processing) self.stopProcessing();
        if (self.state == .activated) self.deactivate();
        if (self.state == .initialized) {
            self.plugin.destroy(self.plugin);
            self.state = .loaded;
        }

        self.entry.deinit();
        self.dynlib.close();

        self.input_buf.deinit();
        self.output_buf.deinit();
        self.in_events.deinit();
        self.out_events.deinit();
        self.pending_params.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    fn queryAudioPorts(self: *PluginInstance) void {
        const ap = self.ext_audio_ports orelse return;

        const in_count = ap.count(self.plugin, true);
        if (in_count > 0) {
            var info: clap.ext.audio_ports.Info = undefined;
            if (ap.get(self.plugin, 0, true, &info)) {
                self.input_channel_count = info.channel_count;
            }
        } else {
            self.input_channel_count = 0;
        }

        const out_count = ap.count(self.plugin, false);
        if (out_count > 0) {
            var info: clap.ext.audio_ports.Info = undefined;
            if (ap.get(self.plugin, 0, false, &info)) {
                self.output_channel_count = info.channel_count;
            }
        } else {
            self.output_channel_count = 0;
        }
    }
};

/// Build the clap_host_t struct for this instance.
fn buildHost(inst: *PluginInstance) clap.Host {
    return clap.Host{
        .clap_version = clap.version,
        .host_data = inst,
        .name = "z_plug_host",
        .vendor = "z-plug",
        .url = null,
        .version = "0.1.0",
        .getExtension = getExtension,
        .requestRestart = requestRestart,
        .requestProcess = requestProcess,
        .requestCallback = requestCallback,
    };
}

fn getExtension(host: *const clap.Host, id: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const id_str = std.mem.span(id);
    if (std.mem.eql(u8, id_str, clap.ext.thread_check.id))
        return &extensions.thread_check;
    if (std.mem.eql(u8, id_str, clap.ext.log.id))
        return &extensions.log_ext;
    if (std.mem.eql(u8, id_str, clap.ext.params.id))
        return &extensions.params_host;
    if (std.mem.eql(u8, id_str, clap.ext.state.id))
        return &extensions.state_host;
    if (std.mem.eql(u8, id_str, clap.ext.audio_ports.id))
        return &extensions.audio_ports_host;
    if (std.mem.eql(u8, id_str, clap.ext.latency.id))
        return &extensions.latency_host;
    _ = host;
    return null;
}

fn requestRestart(host: *const clap.Host) callconv(.c) void {
    const inst: *PluginInstance = @ptrCast(@alignCast(host.host_data));
    inst.request_restart.store(true, .release);
}

fn requestProcess(host: *const clap.Host) callconv(.c) void {
    // For a simple host, nothing special needed — we always call process()
    _ = host;
}

fn requestCallback(host: *const clap.Host) callconv(.c) void {
    const inst: *PluginInstance = @ptrCast(@alignCast(host.host_data));
    inst.request_callback.store(true, .release);
}

/// Resolve the actual binary path for a .clap file.
/// On macOS, .clap files are bundles (directories). We find the binary inside.
/// On other platforms, the path is used as-is.
fn resolveBinaryPath(path: []const u8, buf: []u8) ![]const u8 {
    const stat = std.fs.cwd().statFile(path) catch |err| {
        // If stat fails, just try the path directly
        if (err == error.FileNotFound) return error.FileNotFound;
        return path;
    };

    if (stat.kind == .directory) {
        // macOS bundle: MyPlugin.clap/Contents/MacOS/MyPlugin
        const basename = std.fs.path.stem(std.fs.path.basename(path));
        const result = try std.fmt.bufPrint(
            buf,
            "{s}/Contents/MacOS/{s}",
            .{ path, basename },
        );
        return result;
    }

    return path;
}
