// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! z_plug_engine — C-compatible audio engine library.
//!
//! All public symbols are prefixed `zpe_` and use the C calling convention.
//! Consumers link against the static library and include `z_plug_engine.h`.
//!
//! The engine loads a WAV file, optionally routes audio through a CLAP plugin
//! (from z_plug_host), and outputs to the default system audio device via
//! CoreAudio AudioQueue Services (macOS only).

const std = @import("std");
const Engine = @import("engine.zig").Engine;

// Re-export the ZphPlugin opaque type so the engine can accept plugin handles
pub const zph = @import("z_plug_host");

const allocator = std.heap.c_allocator;

// ---------------------------------------------------------------------------
// Opaque handle type (exposed as `ZpeEngine*` in C)
// ---------------------------------------------------------------------------

pub const ZpeEngine = opaque {};

fn toEngine(e: *ZpeEngine) *Engine {
    return @ptrCast(@alignCast(e));
}

fn toHandle(e: *Engine) *ZpeEngine {
    return @ptrCast(e);
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Create a new engine.
/// `sample_rate` — output sample rate; pass 0 to use 44100 Hz.
/// `buffer_size` — frames per audio callback; pass 0 to use 512.
/// Returns null on allocation failure.
export fn zpe_create(sample_rate: f64, buffer_size: u32) ?*ZpeEngine {
    const engine = Engine.init(allocator, sample_rate, buffer_size) catch |err| {
        std.log.err("zpe_create failed: {}", .{err});
        return null;
    };
    return toHandle(engine);
}

/// Destroy the engine and free all resources.
export fn zpe_destroy(engine: *ZpeEngine) void {
    toEngine(engine).deinit();
}

// ---------------------------------------------------------------------------
// File loading
// ---------------------------------------------------------------------------

/// Load a WAV file. Returns false if the file cannot be parsed.
/// Stops playback and resets position if a file was already loaded.
export fn zpe_load_file(engine: *ZpeEngine, path: [*:0]const u8) bool {
    const path_slice = std.mem.span(path);
    toEngine(engine).loadFile(path_slice) catch |err| {
        std.log.err("zpe_load_file failed: {}", .{err});
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// Plugin attachment
// ---------------------------------------------------------------------------

/// Attach a CLAP plugin from z_plug_host. Pass null to detach (passthrough).
/// The caller retains ownership of the plugin handle.
export fn zpe_set_plugin(engine: *ZpeEngine, plugin: ?*zph.ZphPlugin) void {
    toEngine(engine).setPlugin(plugin);
}

// ---------------------------------------------------------------------------
// Playback controls
// ---------------------------------------------------------------------------

/// Start playback. Returns false if no file is loaded or audio init fails.
export fn zpe_play(engine: *ZpeEngine) bool {
    toEngine(engine).play() catch |err| {
        std.log.err("zpe_play failed: {}", .{err});
        return false;
    };
    return true;
}

/// Pause playback. Position is preserved.
export fn zpe_pause(engine: *ZpeEngine) void {
    toEngine(engine).pause();
}

/// Stop playback and reset position to 0.
export fn zpe_stop(engine: *ZpeEngine) void {
    toEngine(engine).stop();
}

/// Seek to a specific sample position.
export fn zpe_seek(engine: *ZpeEngine, sample_position: u64) void {
    toEngine(engine).seek(sample_position);
}

// ---------------------------------------------------------------------------
// State queries
// ---------------------------------------------------------------------------

/// Return the current playback position in samples.
export fn zpe_get_position(engine: *const ZpeEngine) u64 {
    return @as(*const Engine, @ptrCast(@alignCast(engine))).getPosition();
}

/// Return the total length of the loaded file in samples. Returns 0 if no
/// file is loaded.
export fn zpe_get_length(engine: *const ZpeEngine) u64 {
    return @as(*const Engine, @ptrCast(@alignCast(engine))).getLength();
}

/// Return the engine's output sample rate.
export fn zpe_get_sample_rate(engine: *const ZpeEngine) f64 {
    return @as(*const Engine, @ptrCast(@alignCast(engine))).getSampleRate();
}

/// Return the channel count of the loaded file. Returns 0 if no file loaded.
export fn zpe_get_channel_count(engine: *const ZpeEngine) u32 {
    return @as(*const Engine, @ptrCast(@alignCast(engine))).getChannelCount();
}

/// Return true if the engine is currently playing.
export fn zpe_is_playing(engine: *const ZpeEngine) bool {
    return @as(*const Engine, @ptrCast(@alignCast(engine))).isPlaying();
}

// ---------------------------------------------------------------------------
// Looping
// ---------------------------------------------------------------------------

/// Enable or disable looping. When enabled, playback restarts from the
/// beginning when the end of the file is reached.
export fn zpe_set_looping(engine: *ZpeEngine, loop: bool) void {
    toEngine(engine).setLooping(loop);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@import("wav.zig"));
}
