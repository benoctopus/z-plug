// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! CLAP event list implementations for the host.
//!
//! InputEventList: host → plugin. Backed by an ArrayList; the host appends
//! events (param changes, note events) before each process() call, then
//! clears after.
//!
//! OutputEventList: plugin → host. Backed by an ArrayList; the plugin pushes
//! events during process(). The host reads them after process() returns.

const std = @import("std");
const clap = @import("clap-bindings");

/// Storage large enough to hold any core CLAP event.
pub const EventStorage = extern union {
    header: clap.events.Header,
    note: clap.events.Note,
    note_expression: clap.events.NoteExpression,
    param_value: clap.events.ParamValue,
    param_mod: clap.events.ParamMod,
    param_gesture: clap.events.ParamGesture,
    midi: clap.events.Midi,
    midi2: clap.events.Midi2,
};

/// A growable list of events that the host provides to the plugin as input.
/// Must be sorted by sample_offset before passing to process().
///
/// IMPORTANT: This struct must not be moved after init() is called, because
/// the vtable.context pointer points into the struct itself. Store it on the
/// heap or as a field of a heap-allocated struct.
pub const InputEventList = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(EventStorage),
    vtable: clap.events.InputEvents,

    pub fn init(allocator: std.mem.Allocator) InputEventList {
        // vtable.context is set to null here; callers must call fixupVtable()
        // after placing the struct in its final location, OR use the pattern
        // of always accessing via pointer (the vtable is updated by fixupVtable).
        return InputEventList{
            .allocator = allocator,
            .events = .empty,
            .vtable = clap.events.InputEvents{
                .context = undefined, // fixed up by fixupVtable()
                .size = sizeImpl,
                .get = getImpl,
            },
        };
    }

    /// Must be called after the struct is placed in its final memory location.
    /// Updates vtable.context to point to this struct.
    pub fn fixupVtable(self: *InputEventList) void {
        self.vtable.context = self;
    }

    pub fn deinit(self: *InputEventList) void {
        self.events.deinit(self.allocator);
    }

    pub fn clear(self: *InputEventList) void {
        self.events.clearRetainingCapacity();
    }

    /// Append a param value event at sample offset 0.
    pub fn pushParamValue(
        self: *InputEventList,
        param_id: clap.Id,
        value: f64,
        sample_offset: u32,
    ) !void {
        var ev: EventStorage = undefined;
        ev.param_value = clap.events.ParamValue{
            .header = clap.events.Header{
                .size = @sizeOf(clap.events.ParamValue),
                .sample_offset = sample_offset,
                .space_id = clap.events.core_space_id,
                .type = .param_value,
                .flags = .{},
            },
            .param_id = param_id,
            .cookie = null,
            .note_id = .unspecified,
            .port_index = .unspecified,
            .channel = .unspecified,
            .key = .unspecified,
            .value = value,
        };
        try self.events.append(self.allocator, ev);
    }

    /// Append a note on event.
    pub fn pushNoteOn(
        self: *InputEventList,
        port_index: i16,
        channel: i16,
        key: i16,
        velocity: f64,
        sample_offset: u32,
    ) !void {
        var ev: EventStorage = undefined;
        ev.note = clap.events.Note{
            .header = clap.events.Header{
                .size = @sizeOf(clap.events.Note),
                .sample_offset = sample_offset,
                .space_id = clap.events.core_space_id,
                .type = .note_on,
                .flags = .{ .is_live = true },
            },
            .note_id = .unspecified,
            .port_index = @enumFromInt(port_index),
            .channel = @enumFromInt(channel),
            .key = @enumFromInt(key),
            .velocity = velocity,
        };
        try self.events.append(self.allocator, ev);
    }

    /// Append a note off event.
    pub fn pushNoteOff(
        self: *InputEventList,
        port_index: i16,
        channel: i16,
        key: i16,
        velocity: f64,
        sample_offset: u32,
    ) !void {
        var ev: EventStorage = undefined;
        ev.note = clap.events.Note{
            .header = clap.events.Header{
                .size = @sizeOf(clap.events.Note),
                .sample_offset = sample_offset,
                .space_id = clap.events.core_space_id,
                .type = .note_off,
                .flags = .{ .is_live = true },
            },
            .note_id = .unspecified,
            .port_index = @enumFromInt(port_index),
            .channel = @enumFromInt(channel),
            .key = @enumFromInt(key),
            .velocity = velocity,
        };
        try self.events.append(self.allocator, ev);
    }

    fn sizeImpl(list: *const clap.events.InputEvents) callconv(.c) u32 {
        const self: *const InputEventList = @ptrCast(@alignCast(list.context));
        return @intCast(self.events.items.len);
    }

    fn getImpl(list: *const clap.events.InputEvents, index: u32) callconv(.c) *const clap.events.Header {
        const self: *const InputEventList = @ptrCast(@alignCast(list.context));
        return &self.events.items[index].header;
    }
};

/// A growable list that the plugin pushes output events into during process().
///
/// IMPORTANT: This struct must not be moved after fixupVtable() is called.
pub const OutputEventList = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(EventStorage),
    vtable: clap.events.OutputEvents,

    pub fn init(allocator: std.mem.Allocator) OutputEventList {
        return OutputEventList{
            .allocator = allocator,
            .events = .empty,
            .vtable = clap.events.OutputEvents{
                .context = undefined, // fixed up by fixupVtable()
                .tryPush = tryPushImpl,
            },
        };
    }

    /// Must be called after the struct is placed in its final memory location.
    pub fn fixupVtable(self: *OutputEventList) void {
        self.vtable.context = self;
    }

    pub fn deinit(self: *OutputEventList) void {
        self.events.deinit(self.allocator);
    }

    pub fn clear(self: *OutputEventList) void {
        self.events.clearRetainingCapacity();
    }

    fn tryPushImpl(list: *const clap.events.OutputEvents, event: *const clap.events.Header) callconv(.c) bool {
        const self: *OutputEventList = @ptrCast(@alignCast(list.context));
        // Copy the raw bytes into an EventStorage. The event size is in the header.
        var storage: EventStorage = undefined;
        const size = @min(event.size, @sizeOf(EventStorage));
        @memcpy(
            @as([*]u8, @ptrCast(&storage))[0..size],
            @as([*]const u8, @ptrCast(event))[0..size],
        );
        self.events.append(self.allocator, storage) catch return false;
        return true;
    }
};

test "InputEventList basic" {
    var list = InputEventList.init(std.testing.allocator);
    defer list.deinit();
    list.fixupVtable();

    try list.pushParamValue(@enumFromInt(42), 0.5, 0);
    try std.testing.expectEqual(@as(u32, 1), list.vtable.size(&list.vtable));
    const hdr = list.vtable.get(&list.vtable, 0);
    try std.testing.expectEqual(clap.events.Header.Type.param_value, hdr.type);
}

test "OutputEventList basic" {
    var list = OutputEventList.init(std.testing.allocator);
    defer list.deinit();
    list.fixupVtable();

    var ev = clap.events.ParamGesture{
        .header = clap.events.Header{
            .size = @sizeOf(clap.events.ParamGesture),
            .sample_offset = 0,
            .space_id = clap.events.core_space_id,
            .type = .param_gesture_begin,
            .flags = .{},
        },
        .param_id = @enumFromInt(1),
    };
    const ok = list.vtable.tryPush(&list.vtable, &ev.header);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 1), list.events.items.len);
}
