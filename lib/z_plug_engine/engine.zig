// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Audio engine core.
//!
//! Ties together WAV file playback, CLAP plugin processing, and CoreAudio
//! output. Playback state is managed with atomics so the CoreAudio callback
//! thread can read/advance position safely.

const std = @import("std");
const WavData = @import("wav.zig").WavData;
const loadWav = @import("wav.zig").load;
const AudioQueueOutput = @import("coreaudio.zig").AudioQueueOutput;
const zph = @import("z_plug_host");

pub const DEFAULT_BUFFER_SIZE: u32 = 512;
pub const DEFAULT_SAMPLE_RATE: f64 = 44100.0;

pub const Engine = struct {
    allocator: std.mem.Allocator,

    // Audio file data (owned; null until a file is loaded)
    wav_data: ?WavData,

    // Plugin handle from z_plug_host (not owned; caller manages lifecycle).
    // Stored as opaque pointer; processed via zph.processPlugin().
    plugin: ?*zph.ZphPlugin,

    // CoreAudio output (null until play() is called; heap-allocated for stable pointer)
    audio_queue: ?*AudioQueueOutput,

    // Playback state — written from main thread, read from audio callback
    position: std.atomic.Value(u64),
    is_playing: std.atomic.Value(bool),
    should_loop: std.atomic.Value(bool),

    // Configuration (set at create time, immutable after)
    sample_rate: f64,
    buffer_size: u32,

    // Per-channel scratch buffers for deinterleaved plugin I/O.
    // Allocated at engine creation with buffer_size frames per channel.
    // Max 8 channels (covers stereo and surround).
    scratch_in: [8][]f32,
    scratch_out: [8][]f32,
    scratch_channel_count: u32,

    // Pointers into scratch_in/scratch_out for passing to zph_process
    input_ptrs: [8][*]const f32,
    output_ptrs: [8][*]f32,

    pub fn init(allocator: std.mem.Allocator, sample_rate: f64, buffer_size: u32) !*Engine {
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);

        self.* = Engine{
            .allocator = allocator,
            .wav_data = null,
            .plugin = null,
            .audio_queue = null,
            .position = std.atomic.Value(u64).init(0),
            .is_playing = std.atomic.Value(bool).init(false),
            .should_loop = std.atomic.Value(bool).init(false),
            .sample_rate = if (sample_rate > 0) sample_rate else DEFAULT_SAMPLE_RATE,
            .buffer_size = if (buffer_size > 0) buffer_size else DEFAULT_BUFFER_SIZE,
            .scratch_in = undefined,
            .scratch_out = undefined,
            .scratch_channel_count = 0,
            .input_ptrs = undefined,
            .output_ptrs = undefined,
        };

        return self;
    }

    /// Allocate scratch buffers for `channel_count` channels.
    fn allocateScratch(self: *Engine, channel_count: u32) !void {
        if (channel_count == self.scratch_channel_count) return;

        // Free old scratch buffers
        for (self.scratch_in[0..self.scratch_channel_count]) |buf| self.allocator.free(buf);
        for (self.scratch_out[0..self.scratch_channel_count]) |buf| self.allocator.free(buf);

        const n = @min(channel_count, 8);
        for (0..n) |i| {
            self.scratch_in[i] = try self.allocator.alloc(f32, self.buffer_size);
            errdefer for (self.scratch_in[0..i]) |b| self.allocator.free(b);
            self.scratch_out[i] = try self.allocator.alloc(f32, self.buffer_size);
            errdefer for (self.scratch_out[0..i]) |b| self.allocator.free(b);
            self.input_ptrs[i] = self.scratch_in[i].ptr;
            self.output_ptrs[i] = self.scratch_out[i].ptr;
        }
        self.scratch_channel_count = n;
    }

    /// Load a WAV file. Replaces any previously loaded file.
    /// Stops playback if currently playing.
    pub fn loadFile(self: *Engine, path: []const u8) !void {
        self.stop();
        if (self.wav_data) |*wd| {
            wd.deinit();
            self.wav_data = null;
        }
        self.wav_data = try loadWav(self.allocator, path);
        const wav = &self.wav_data.?;

        // Use the file's sample rate if the engine was created with rate=0
        // (already resolved to DEFAULT_SAMPLE_RATE above, but we can override)
        _ = wav;

        try self.allocateScratch(self.wav_data.?.channel_count);
        self.position.store(0, .release);
    }

    /// Attach a CLAP plugin. Pass null to detach (passthrough mode).
    /// The caller retains ownership of the plugin handle.
    pub fn setPlugin(self: *Engine, plugin: ?*zph.ZphPlugin) void {
        self.plugin = plugin;
    }

    /// Start playback. Creates the AudioQueue if needed.
    pub fn play(self: *Engine) !void {
        if (self.is_playing.load(.acquire)) return;

        const wav = self.wav_data orelse return error.NoFileLoaded;
        const ch = wav.channel_count;

        if (self.audio_queue == null) {
            const aq = try self.allocator.create(AudioQueueOutput);
            errdefer self.allocator.destroy(aq);
            try aq.init(
                self.sample_rate,
                ch,
                self.buffer_size,
                fillCallback,
                self,
            );
            self.audio_queue = aq;
        }

        try self.audio_queue.?.start();
        self.is_playing.store(true, .release);
    }

    /// Pause playback (position is preserved).
    pub fn pause(self: *Engine) void {
        if (!self.is_playing.load(.acquire)) return;
        if (self.audio_queue) |aq| aq.pause();
        self.is_playing.store(false, .release);
    }

    /// Stop playback and reset position to 0.
    pub fn stop(self: *Engine) void {
        self.pause();
        self.position.store(0, .release);
    }

    /// Seek to a specific sample position.
    pub fn seek(self: *Engine, sample_pos: u64) void {
        const len = if (self.wav_data) |wd| wd.num_frames else 0;
        self.position.store(@min(sample_pos, len), .release);
    }

    pub fn getPosition(self: *const Engine) u64 {
        return self.position.load(.acquire);
    }

    pub fn getLength(self: *const Engine) u64 {
        return if (self.wav_data) |wd| wd.num_frames else 0;
    }

    pub fn isPlaying(self: *const Engine) bool {
        return self.is_playing.load(.acquire);
    }

    pub fn setLooping(self: *Engine, loop: bool) void {
        self.should_loop.store(loop, .release);
    }

    pub fn getSampleRate(self: *const Engine) f64 {
        return self.sample_rate;
    }

    pub fn getChannelCount(self: *const Engine) u32 {
        return if (self.wav_data) |wd| wd.channel_count else 0;
    }

    pub fn deinit(self: *Engine) void {
        self.stop();
        if (self.audio_queue) |aq| {
            aq.deinit();
            self.allocator.destroy(aq);
        }
        if (self.wav_data) |*wd| {
            wd.deinit();
        }
        for (self.scratch_in[0..self.scratch_channel_count]) |buf| self.allocator.free(buf);
        for (self.scratch_out[0..self.scratch_channel_count]) |buf| self.allocator.free(buf);
        self.allocator.destroy(self);
    }

    // -----------------------------------------------------------------------
    // AudioQueue fill callback (called from CoreAudio's internal thread)
    // -----------------------------------------------------------------------

    fn fillCallback(
        user_data: ?*anyopaque,
        output: [*]f32,
        channel_count: u32,
        frame_count: u32,
    ) void {
        const self: *Engine = @ptrCast(@alignCast(user_data));

        const wav = self.wav_data orelse {
            // No file loaded — output silence
            @memset(output[0 .. frame_count * channel_count], 0.0);
            return;
        };

        const pos = self.position.load(.acquire);
        const total_frames = wav.num_frames;

        if (!self.is_playing.load(.acquire) or pos >= total_frames) {
            if (self.should_loop.load(.acquire) and pos >= total_frames) {
                self.position.store(0, .release);
            }
            @memset(output[0 .. frame_count * channel_count], 0.0);
            return;
        }

        // How many frames we can read from the file
        const available = total_frames - pos;
        const to_read = @min(frame_count, available);

        // Copy WAV data into deinterleaved scratch buffers
        const n_ch = @min(channel_count, wav.channel_count);
        for (0..n_ch) |ch| {
            const src = wav.channels[ch][pos .. pos + to_read];
            @memcpy(self.scratch_in[ch][0..to_read], src);
            // Zero-pad if to_read < frame_count
            if (to_read < frame_count) {
                @memset(self.scratch_in[ch][to_read..frame_count], 0.0);
            }
        }
        // Zero-fill extra channels if WAV has fewer than requested
        for (n_ch..channel_count) |ch| {
            @memset(self.scratch_in[ch][0..frame_count], 0.0);
        }

        // Run through plugin if attached, otherwise use input as output
        if (self.plugin) |plug| {
            const status = zph.processPlugin(
                plug,
                @ptrCast(&self.input_ptrs),
                @ptrCast(&self.output_ptrs),
                channel_count,
                frame_count,
            );
            _ = status;
            // Interleave output scratch buffers into the AudioQueue buffer
            for (0..frame_count) |f| {
                for (0..channel_count) |ch| {
                    output[f * channel_count + ch] = self.scratch_out[ch][f];
                }
            }
        } else {
            // Passthrough: interleave input directly
            for (0..frame_count) |f| {
                for (0..channel_count) |ch| {
                    output[f * channel_count + ch] = self.scratch_in[ch][f];
                }
            }
        }

        // Advance position
        const new_pos = pos + to_read;
        if (new_pos >= total_frames and self.should_loop.load(.acquire)) {
            self.position.store(0, .release);
        } else {
            self.position.store(new_pos, .release);
            if (new_pos >= total_frames) {
                self.is_playing.store(false, .release);
            }
        }
    }
};
