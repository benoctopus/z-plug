// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Host-side CLAP extension implementations.
//!
//! Each extension is a static struct whose address is returned by the host's
//! `get_extension` callback when the plugin queries for it. The structs hold
//! function pointers that call back into the PluginInstance.

const std = @import("std");
const clap = @import("clap-bindings");

/// Thread-local variable tracking which logical CLAP thread the current OS
/// thread is acting as. Set by the host before calling plugin functions.
pub const ThreadRole = enum { unknown, main, audio };
pub threadlocal var thread_role: ThreadRole = .unknown;

// ---------------------------------------------------------------------------
// clap.thread-check
// ---------------------------------------------------------------------------

pub const thread_check = clap.ext.thread_check.Host{
    .isMainThread = struct {
        fn f(host: *const clap.Host) callconv(.c) bool {
            _ = host;
            return thread_role == .main;
        }
    }.f,
    .isAudioThread = struct {
        fn f(host: *const clap.Host) callconv(.c) bool {
            _ = host;
            return thread_role == .audio;
        }
    }.f,
};

// ---------------------------------------------------------------------------
// clap.log
// ---------------------------------------------------------------------------

pub const log_ext = clap.ext.log.Host{
    .log = struct {
        fn f(host: *const clap.Host, severity: clap.ext.log.Severity, msg: [*:0]const u8) callconv(.c) void {
            _ = host;
            const str = std.mem.span(msg);
            switch (severity) {
                .debug => std.log.debug("[clap-plugin] {s}", .{str}),
                .info => std.log.info("[clap-plugin] {s}", .{str}),
                .warning => std.log.warn("[clap-plugin] {s}", .{str}),
                .@"error" => std.log.err("[clap-plugin] {s}", .{str}),
                .fatal => std.log.err("[clap-plugin FATAL] {s}", .{str}),
                .host_misbehaving => std.log.warn("[clap-host misbehaving] {s}", .{str}),
                .plugin_misbehaving => std.log.warn("[clap-plugin misbehaving] {s}", .{str}),
            }
        }
    }.f,
};

// ---------------------------------------------------------------------------
// clap.params (host side)
// Callbacks that the plugin calls to notify the host of parameter changes.
// We store flags in the PluginInstance; get_extension returns a pointer to
// the static struct below, and the callbacks recover the instance via
// host.host_data.
// ---------------------------------------------------------------------------

const PluginInstance = @import("plugin_instance.zig").PluginInstance;

pub const params_host = clap.ext.params.Host{
    .rescan = struct {
        fn f(host: *const clap.Host, flags: clap.ext.params.Host.RescanFlags) callconv(.c) void {
            _ = flags;
            const inst: *PluginInstance = @ptrCast(@alignCast(host.host_data));
            inst.needs_param_rescan.store(true, .release);
        }
    }.f,
    .clear = struct {
        fn f(host: *const clap.Host, id: clap.Id, flags: clap.ext.params.Host.ClearFlags) callconv(.c) void {
            _ = host;
            _ = id;
            _ = flags;
        }
    }.f,
    .requestFlush = struct {
        fn f(host: *const clap.Host) callconv(.c) void {
            const inst: *PluginInstance = @ptrCast(@alignCast(host.host_data));
            inst.needs_param_flush.store(true, .release);
        }
    }.f,
};

// ---------------------------------------------------------------------------
// clap.state (host side)
// ---------------------------------------------------------------------------

pub const state_host = clap.ext.state.Host{
    .markDirty = struct {
        fn f(host: *const clap.Host) callconv(.c) void {
            const inst: *PluginInstance = @ptrCast(@alignCast(host.host_data));
            inst.state_dirty.store(true, .release);
        }
    }.f,
};

// ---------------------------------------------------------------------------
// clap.audio-ports (host side) — minimal stubs
// ---------------------------------------------------------------------------

pub const audio_ports_host = clap.ext.audio_ports.Host{
    .isRescanFlagSupported = struct {
        fn f(host: *const clap.Host, flag: clap.ext.audio_ports.Host.RescanFlag) callconv(.c) bool {
            _ = host;
            _ = flag;
            return false;
        }
    }.f,
    .rescan = struct {
        fn f(host: *const clap.Host, flags: clap.ext.audio_ports.Host.RescanFlags) callconv(.c) void {
            _ = host;
            _ = flags;
        }
    }.f,
};

// ---------------------------------------------------------------------------
// clap.latency (host side)
// ---------------------------------------------------------------------------

pub const latency_host = clap.ext.latency.Host{
    .changed = struct {
        fn f(host: *const clap.Host) callconv(.c) void {
            const inst: *PluginInstance = @ptrCast(@alignCast(host.host_data));
            inst.latency_changed.store(true, .release);
        }
    }.f,
};
