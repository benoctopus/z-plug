// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Audio buffer management for the CLAP host.
//!
//! Bridges caller-provided `[*]const [*]f32` (array of channel pointers) into
//! the `clap_audio_buffer_t` structs that `clap_process_t` expects.
//!
//! The caller owns the actual sample memory; this module only manages the
//! pointer arrays and the AudioBuffer descriptors.

const std = @import("std");
const clap = @import("clap-bindings");

/// Manages a single CLAP audio buffer (input or output).
/// The channel pointer array is heap-allocated and updated each process call.
pub const AudioBufferSet = struct {
    allocator: std.mem.Allocator,
    /// Array of per-channel pointers. Length == channel_count.
    channel_ptrs: []?[*]f32,
    /// The CLAP descriptor passed to process().
    descriptor: clap.AudioBuffer,

    pub fn init(allocator: std.mem.Allocator, channel_count: u32) !AudioBufferSet {
        const ptrs = try allocator.alloc(?[*]f32, channel_count);
        @memset(ptrs, null);
        return AudioBufferSet{
            .allocator = allocator,
            .channel_ptrs = ptrs,
            .descriptor = clap.AudioBuffer{
                .data32 = @ptrCast(ptrs.ptr),
                .data64 = null,
                .channel_count = channel_count,
                .latency = 0,
                .constant_mask = 0,
            },
        };
    }

    pub fn deinit(self: *AudioBufferSet) void {
        self.allocator.free(self.channel_ptrs);
    }

    /// Update channel pointers from a caller-supplied array.
    /// `ptrs` must point to at least `channel_count` valid channel buffers.
    pub fn updatePointers(self: *AudioBufferSet, ptrs: [*]const [*]f32) void {
        for (self.channel_ptrs, 0..) |*dst, i| {
            dst.* = ptrs[i];
        }
        self.descriptor.data32 = @ptrCast(self.channel_ptrs.ptr);
    }

    /// Update from a const pointer array (for input buffers).
    pub fn updateConstPointers(self: *AudioBufferSet, ptrs: [*]const [*]const f32) void {
        for (self.channel_ptrs, 0..) |*dst, i| {
            // Safety: we only write to output buffers; inputs are read-only.
            // The CLAP spec uses the same data32 field for both; the plugin
            // must not write to input buffers.
            dst.* = @constCast(ptrs[i]);
        }
        self.descriptor.data32 = @ptrCast(self.channel_ptrs.ptr);
    }

    pub fn resize(self: *AudioBufferSet, new_channel_count: u32) !void {
        if (new_channel_count == self.channel_ptrs.len) return;
        self.allocator.free(self.channel_ptrs);
        self.channel_ptrs = try self.allocator.alloc(?[*]f32, new_channel_count);
        @memset(self.channel_ptrs, null);
        self.descriptor.channel_count = new_channel_count;
        self.descriptor.data32 = @ptrCast(self.channel_ptrs.ptr);
    }
};

test "AudioBufferSet init and update" {
    var buf = try AudioBufferSet.init(std.testing.allocator, 2);
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, 2), buf.descriptor.channel_count);

    var ch0 = [_]f32{ 1.0, 2.0 };
    var ch1 = [_]f32{ 3.0, 4.0 };
    const ptrs = [_][*]f32{ &ch0, &ch1 };
    buf.updatePointers(&ptrs);

    try std.testing.expect(buf.descriptor.data32 != null);
}
