// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! CoreAudio AudioQueue output backend (macOS only).
//!
//! Uses AudioQueue Services from the AudioToolbox framework — the simplest
//! callback-based audio output API on macOS. Automatically uses the default
//! output device and handles format conversion.

const std = @import("std");

// ---------------------------------------------------------------------------
// AudioToolbox C API declarations
// ---------------------------------------------------------------------------

const OSStatus = i32;
const noErr: OSStatus = 0;

const AudioQueueRef = *anyopaque;
const AudioQueueBufferRef = *AudioQueueBuffer;

const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32,
};

const AudioQueueBuffer = extern struct {
    mAudioDataBytesCapacity: u32,
    mAudioData: *anyopaque,
    mAudioDataByteSize: u32,
    mUserData: ?*anyopaque,
    mPacketDescriptionCapacity: u32,
    mPacketDescriptions: ?*anyopaque,
    mPacketDescriptionCount: u32,
};

const AudioQueueOutputCallback = *const fn (
    inUserData: ?*anyopaque,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef,
) callconv(.c) void;

// Format constants
const kAudioFormatLinearPCM: u32 = 0x6C70636D; // 'lpcm'
const kLinearPCMFormatFlagIsFloat: u32 = 1 << 0;
const kLinearPCMFormatFlagIsPacked: u32 = 1 << 3;
const kAudioFormatFlagsNativeEndian: u32 = 0;

extern fn AudioQueueNewOutput(
    inFormat: *const AudioStreamBasicDescription,
    inCallbackProc: AudioQueueOutputCallback,
    inUserData: ?*anyopaque,
    inCallbackRunLoop: ?*anyopaque,
    inCallbackRunLoopMode: ?*anyopaque,
    inFlags: u32,
    outAQ: *AudioQueueRef,
) OSStatus;

extern fn AudioQueueAllocateBuffer(
    inAQ: AudioQueueRef,
    inBufferByteSize: u32,
    outBuffer: *AudioQueueBufferRef,
) OSStatus;

extern fn AudioQueueEnqueueBuffer(
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef,
    inNumPacketDescs: u32,
    inPacketDescs: ?*anyopaque,
) OSStatus;

extern fn AudioQueueStart(
    inAQ: AudioQueueRef,
    inStartTime: ?*anyopaque,
) OSStatus;

extern fn AudioQueuePause(inAQ: AudioQueueRef) OSStatus;

extern fn AudioQueueStop(
    inAQ: AudioQueueRef,
    inImmediate: bool,
) OSStatus;

extern fn AudioQueueDispose(
    inAQ: AudioQueueRef,
    inImmediate: bool,
) OSStatus;

// ---------------------------------------------------------------------------
// AudioQueueOutput implementation
// ---------------------------------------------------------------------------

/// Number of AudioQueue buffers to use (ring buffer depth).
const NUM_BUFFERS = 3;

/// Callback type that the engine provides to fill audio data.
/// Called from CoreAudio's internal thread.
pub const FillCallback = *const fn (
    user_data: ?*anyopaque,
    output: [*]f32,
    channel_count: u32,
    frame_count: u32,
) void;

pub const AudioQueueOutput = struct {
    queue: AudioQueueRef,
    buffers: [NUM_BUFFERS]AudioQueueBufferRef,
    channel_count: u32,
    buffer_frames: u32,
    fill_callback: FillCallback,
    user_data: ?*anyopaque,
    running: bool,

    /// Initialize an AudioQueue output into an already-allocated `*AudioQueueOutput`.
    /// The caller must ensure `self` is at its final stable address before calling
    /// `start()`, since CoreAudio will call back with `self` as the user data.
    pub fn init(
        self: *AudioQueueOutput,
        sample_rate: f64,
        channel_count: u32,
        buffer_frames: u32,
        fill_callback: FillCallback,
        user_data: ?*anyopaque,
    ) !void {
        const bytes_per_frame = channel_count * @sizeOf(f32);
        const format = AudioStreamBasicDescription{
            .mSampleRate = sample_rate,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            .mBytesPerPacket = bytes_per_frame,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = bytes_per_frame,
            .mChannelsPerFrame = channel_count,
            .mBitsPerChannel = 32,
            .mReserved = 0,
        };

        self.channel_count = channel_count;
        self.buffer_frames = buffer_frames;
        self.fill_callback = fill_callback;
        self.user_data = user_data;
        self.running = false;

        // Pass `self` (the stable heap pointer) as the AudioQueue user data.
        var queue: AudioQueueRef = undefined;
        const status = AudioQueueNewOutput(
            &format,
            audioQueueCallback,
            self,
            null,
            null,
            0,
            &queue,
        );
        if (status != noErr) return error.AudioQueueCreateFailed;
        self.queue = queue;

        // Allocate ring buffers
        const buffer_bytes = buffer_frames * bytes_per_frame;
        for (&self.buffers) |*buf_ref| {
            const alloc_status = AudioQueueAllocateBuffer(queue, buffer_bytes, buf_ref);
            if (alloc_status != noErr) {
                _ = AudioQueueDispose(queue, true);
                return error.AudioQueueBufferAllocFailed;
            }
        }

        // Pre-fill and enqueue all buffers
        for (self.buffers) |buf_ref| {
            buf_ref.mAudioDataByteSize = buffer_bytes;
            const samples: [*]f32 = @ptrCast(@alignCast(buf_ref.mAudioData));
            @memset(samples[0 .. buffer_frames * channel_count], 0.0);
            _ = AudioQueueEnqueueBuffer(queue, buf_ref, 0, null);
        }
    }

    pub fn start(self: *AudioQueueOutput) !void {
        if (self.running) return;
        const status = AudioQueueStart(self.queue, null);
        if (status != noErr) return error.AudioQueueStartFailed;
        self.running = true;
    }

    pub fn pause(self: *AudioQueueOutput) void {
        if (!self.running) return;
        _ = AudioQueuePause(self.queue);
        self.running = false;
    }

    pub fn stop(self: *AudioQueueOutput) void {
        if (!self.running) return;
        _ = AudioQueueStop(self.queue, true);
        self.running = false;
    }

    pub fn deinit(self: *AudioQueueOutput) void {
        _ = AudioQueueDispose(self.queue, true);
    }
};

fn audioQueueCallback(
    inUserData: ?*anyopaque,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef,
) callconv(.c) void {
    const self: *AudioQueueOutput = @ptrCast(@alignCast(inUserData));

    const samples: [*]f32 = @ptrCast(@alignCast(inBuffer.mAudioData));
    const total_samples = self.buffer_frames * self.channel_count;

    // Zero the buffer first (silence if callback doesn't fill it)
    @memset(samples[0..total_samples], 0.0);

    // Ask the engine to fill the buffer
    self.fill_callback(self.user_data, samples, self.channel_count, self.buffer_frames);

    inBuffer.mAudioDataByteSize = self.buffer_frames * self.channel_count * @sizeOf(f32);
    _ = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, null);
}
