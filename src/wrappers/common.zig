/// Shared logic between VST3 and CLAP wrappers.
///
/// This module contains constants, helper functions, and utilities
/// that are used by both format-specific wrappers to reduce code duplication.
const std = @import("std");
const core = @import("../root.zig");

// ---------------------------------------------------------------------------
// Shared Constants
// ---------------------------------------------------------------------------

/// Maximum number of events in pre-allocated storage.
pub const max_events = 1024;

/// Maximum number of auxiliary input/output buses.
pub const max_aux_buses = 8;

/// Maximum number of channels per bus.
pub const max_channels = 32;

/// Maximum buffer size for default BufferConfig initialization.
pub const max_buffer_size = 8192;

// ---------------------------------------------------------------------------
// Buffer Processing Helpers
// ---------------------------------------------------------------------------

/// Copy input to output for shared channels (skip if in-place),
/// then zero-fill any extra output channels.
///
/// This is the standard in-place processing setup used by both wrappers:
/// - If input and output pointers differ, copy input to output
/// - If output has more channels than input, zero-fill the extras
pub inline fn copyInPlace(
    channel_slices_in: []const []f32,
    channel_slices_out: [][]f32,
    num_samples: usize,
) void {
    const input_count = channel_slices_in.len;
    const output_count = channel_slices_out.len;
    const common = @min(input_count, output_count);

    // Copy input to output if not already in-place
    for (channel_slices_in[0..common], channel_slices_out[0..common]) |in_ch, out_ch| {
        if (in_ch.ptr != out_ch.ptr) {
            @memcpy(out_ch[0..num_samples], in_ch[0..num_samples]);
        }
    }

    // Zero-fill any extra output channels
    for (channel_slices_out[common..output_count]) |out_ch| {
        @memset(out_ch[0..num_samples], 0.0);
    }
}

// ---------------------------------------------------------------------------
// ProcessContext Construction
// ---------------------------------------------------------------------------

/// Build a ProcessContext struct with all required fields.
///
/// Both wrappers construct ProcessContext identically; this helper
/// centralizes the logic and ensures consistency.
pub inline fn buildProcessContext(
    comptime P: type,
    transport: core.Transport,
    input_events: []const core.NoteEvent,
    output_events: *core.EventOutputList,
    sample_rate: f32,
    param_values_ptr: *core.ParamValues(P.params.len),
    smoother_bank_ptr: *core.SmootherBank(P.params.len),
) core.ProcessContext {
    return core.ProcessContext{
        .transport = transport,
        .input_events = input_events,
        .output_events = output_events,
        .sample_rate = sample_rate,
        .param_values_ptr = @ptrCast(param_values_ptr),
        .smoothers_ptr = @ptrCast(smoother_bank_ptr),
        .params_meta = P.params,
    };
}

// ---------------------------------------------------------------------------
// Parameter Conversion Helpers
// ---------------------------------------------------------------------------

/// Convert a plain parameter value to normalized [0, 1] range.
///
/// Used by CLAP wrapper when receiving plain-value parameter events from the host.
/// VST3 receives pre-normalized values and doesn't need this conversion.
pub inline fn plainToNormalized(param: core.Param, plain_value: f64) f32 {
    return switch (param) {
        .float => |p| p.range.normalize(@floatCast(plain_value)),
        .int => |p| p.range.normalize(@intFromFloat(plain_value)),
        .boolean => if (plain_value > 0.5) @as(f32, 1.0) else @as(f32, 0.0),
        .choice => |p| blk: {
            if (p.labels.len <= 1) break :blk 0.0;
            const idx = @min(@as(u32, @intFromFloat(plain_value)), @as(u32, @intCast(p.labels.len - 1)));
            break :blk @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(p.labels.len - 1));
        },
    };
}

/// Convert a normalized [0, 1] parameter value to plain value.
///
/// Used by both wrappers when returning parameter values to the host
/// or when saving/loading state.
pub inline fn normalizedToPlain(param: core.Param, normalized: f32) f64 {
    return switch (param) {
        .float => |p| p.range.unnormalize(normalized),
        .int => |p| @floatFromInt(p.range.unnormalize(normalized)),
        .boolean => if (normalized > 0.5) @as(f64, 1.0) else @as(f64, 0.0),
        .choice => |p| blk: {
            if (p.labels.len <= 1) break :blk 0.0;
            const idx = @as(u32, @intFromFloat(normalized * @as(f32, @floatFromInt(p.labels.len - 1))));
            break :blk @floatFromInt(idx);
        },
    };
}

// ---------------------------------------------------------------------------
// Wrapper State Initialization
// ---------------------------------------------------------------------------

/// Initialize shared audio state fields on a wrapper instance.
///
/// Both wrappers have similar initialization logic for the audio processing state.
/// This helper ensures consistency and reduces duplication.
pub inline fn initState(
    comptime P: type,
    self: anytype,
    default_layout: core.AudioIOLayout,
) void {
    self.param_values = core.ParamValues(P.params.len).init(P.params);
    self.smoother_bank = core.SmootherBank(P.params.len).init(P.params);
    self.current_layout = default_layout;
    self.event_output_list = core.EventOutputList{
        .events = &[_]core.NoteEvent{},
    };
}
