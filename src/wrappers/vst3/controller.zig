/// VST3 edit controller implementation (IEditController).
///
/// This module provides the controller interface for parameter editing.
const std = @import("std");
const vst3 = @import("../../bindings/vst3/root.zig");
const core = @import("../../root.zig");

/// VST3 controller for plugin type `T`.
pub fn Vst3Controller(comptime T: type) type {
    const P = core.Plugin(T);
    
    // Pre-compute parameter IDs at comptime
    const param_ids = comptime blk: {
        var ids: [P.params.len]u32 = undefined;
        for (P.params, 0..) |param, i| {
            ids[i] = core.idHash(param.id());
        }
        break :blk ids;
    };
    
    return struct {
        const Self = @This();
        
        /// Controller vtable (IEditController interface).
        controller_vtbl: vst3.controller.IEditController,
        
        /// Pointer to shared parameter values (from component).
        param_values: ?*core.ParamValues(P.params.len),
        
        /// Initialize the controller.
        pub fn init() Self {
            return Self{
                .controller_vtbl = vst3.controller.IEditController{
                    .lpVtbl = &controller_vtbl_instance,
                },
                .param_values = null,
            };
        }
        
        // -------------------------------------------------------------------
        // Vtable Instance
        // -------------------------------------------------------------------
        
        const controller_vtbl_instance = vst3.controller.IEditControllerVtbl{
            .queryInterface = controllerQueryInterface,
            .addRef = controllerAddRef,
            .release = controllerRelease,
            .initialize = controllerInitialize,
            .terminate = controllerTerminate,
            .setComponentState = setComponentState,
            .setState = setState,
            .getState = getState,
            .getParameterCount = getParameterCount,
            .getParameterInfo = getParameterInfo,
            .getParamStringByValue = getParamStringByValue,
            .getParamValueByString = getParamValueByString,
            .normalizedParamToPlain = normalizedParamToPlain,
            .plainParamToNormalized = plainParamToNormalized,
            .getParamNormalized = getParamNormalized,
            .setParamNormalized = setParamNormalized,
            .setComponentHandler = setComponentHandler,
            .createView = createView,
        };
        
        // -------------------------------------------------------------------
        // Helper Functions
        // -------------------------------------------------------------------
        
        fn fromController(ctrl: *anyopaque) *Self {
            const controller_ptr: *vst3.controller.IEditController = @ptrCast(@alignCast(ctrl));
            return @fieldParentPtr("controller_vtbl", controller_ptr);
        }
        
        // -------------------------------------------------------------------
        // IEditController Implementation
        // -------------------------------------------------------------------
        
        fn controllerQueryInterface(_: *anyopaque, _: *const vst3.TUID, obj: *?*anyopaque) callconv(.c) vst3.tresult {
            // Controller is part of the component in single-component model
            // This should not be called directly
            obj.* = null;
            return vst3.types.kNoInterface;
        }
        
        fn controllerAddRef(_: *anyopaque) callconv(.c) u32 {
            // Controller is part of the component
            return 1;
        }
        
        fn controllerRelease(_: *anyopaque) callconv(.c) u32 {
            // Controller is part of the component
            return 1;
        }
        
        fn controllerInitialize(_: *anyopaque, _: *anyopaque) callconv(.c) vst3.tresult {
            return vst3.types.kResultOk;
        }
        
        fn controllerTerminate(_: *anyopaque) callconv(.c) vst3.tresult {
            return vst3.types.kResultOk;
        }
        
        fn setComponentState(_: *anyopaque, _: *vst3.component.IBStream) callconv(.c) vst3.tresult {
            // State is already loaded by the component
            return vst3.types.kResultOk;
        }
        
        fn setState(_: *anyopaque, _: *vst3.component.IBStream) callconv(.c) vst3.tresult {
            return vst3.types.kResultOk;
        }
        
        fn getState(_: *anyopaque, _: *vst3.component.IBStream) callconv(.c) vst3.tresult {
            return vst3.types.kResultOk;
        }
        
        fn getParameterCount(_: *anyopaque) callconv(.c) i32 {
            return @intCast(P.params.len);
        }
        
        fn getParameterInfo(
            _: *anyopaque,
            param_index: i32,
            info: *vst3.controller.ParameterInfo,
        ) callconv(.c) vst3.tresult {
            if (param_index < 0 or param_index >= P.params.len) {
                return vst3.types.kResultFalse;
            }
            
            // Return early if no params
            if (P.params.len == 0) {
                return vst3.types.kResultFalse;
            }
            
            const param = P.params[@intCast(param_index)];
            const param_id = param_ids[@intCast(param_index)];
            
            info.* = vst3.controller.ParameterInfo{
                .id = param_id,
                .title = undefined,
                .short_title = undefined,
                .units = undefined,
                .step_count = switch (param) {
                    .float => 0,
                    .int => |p| @intCast(p.range.stepCount()),
                    .boolean => 1,
                    .choice => |p| @intCast(p.stepCount()),
                },
                .default_normalized_value = param.defaultNormalized(),
                .unit_id = 0, // Root unit
                .flags = blk: {
                    var flags: i32 = 0;
                    if (param.flags().automatable) flags |= @intFromEnum(vst3.controller.ParameterInfo.ParameterFlags.kCanAutomate);
                    if (param.flags().hidden) flags |= @intFromEnum(vst3.controller.ParameterInfo.ParameterFlags.kIsHidden);
                    if (param.flags().bypass) flags |= @intFromEnum(vst3.controller.ParameterInfo.ParameterFlags.kIsBypass);
                    break :blk flags;
                },
            };
            
            // Convert title to UTF-16
            @memset(&info.title, 0);
            const name = param.name();
            // Simple ASCII to UTF-16 conversion (proper UTF-8 to UTF-16 would require runtime conversion)
            var i: usize = 0;
            while (i < name.len and i < 128) : (i += 1) {
                info.title[i] = name[i];
            }
            
            // Short title (same as title for now)
            @memcpy(&info.short_title, &info.title);
            
            // Units
            @memset(&info.units, 0);
            const unit = switch (param) {
                .float => |p| p.unit,
                .int => |p| p.unit,
                .boolean, .choice => "",
            };
            if (unit.len > 0) {
                var j: usize = 0;
                while (j < unit.len and j < 128) : (j += 1) {
                    info.units[j] = unit[j];
                }
            }
            
            return vst3.types.kResultOk;
        }
        
        fn getParamStringByValue(
            _: *anyopaque,
            id: vst3.types.ParamID,
            value_normalized: vst3.types.ParamValue,
            string: *vst3.types.String128,
        ) callconv(.c) vst3.tresult {
            // Find parameter by ID
            for (P.params, 0..) |param, i| {
                const param_id = param_ids[i];
                if (param_id == id) {
                    // Format the value
                    const text = switch (param) {
                        .float => |p| blk: {
                            const plain = p.range.unnormalize(@floatCast(value_normalized));
                            var buf: [64]u8 = undefined;
                            const formatted = std.fmt.bufPrint(&buf, "{d:.2}", .{plain}) catch break :blk "?";
                            break :blk formatted;
                        },
                        .int => |p| blk: {
                            const plain = p.range.unnormalize(@floatCast(value_normalized));
                            var buf: [64]u8 = undefined;
                            const formatted = std.fmt.bufPrint(&buf, "{d}", .{plain}) catch break :blk "?";
                            break :blk formatted;
                        },
                        .boolean => if (value_normalized > 0.5) "On" else "Off",
                        .choice => |p| blk: {
                            const idx = @as(usize, @intFromFloat(value_normalized * @as(f32, @floatFromInt(p.labels.len - 1))));
                            if (idx < p.labels.len) break :blk p.labels[idx];
                            break :blk "?";
                        },
                    };
                    
                    // Convert to UTF-16
                    @memset(string, 0);
                    var j: usize = 0;
                    while (j < text.len and j < 128) : (j += 1) {
                        string[j] = text[j];
                    }
                    
                    return vst3.types.kResultOk;
                }
            }
            
            return vst3.types.kResultFalse;
        }
        
        fn getParamValueByString(
            _: *anyopaque,
            _: vst3.types.ParamID,
            _: *vst3.types.char16,
            _: *vst3.types.ParamValue,
        ) callconv(.c) vst3.tresult {
            // TODO: Implement string-to-value parsing
            return vst3.types.kNotImplemented;
        }
        
        fn normalizedParamToPlain(
            _: *anyopaque,
            id: vst3.types.ParamID,
            value_normalized: vst3.types.ParamValue,
        ) callconv(.c) vst3.types.ParamValue {
            // Find parameter by ID
            for (P.params, 0..) |param, i| {
                const param_id = param_ids[i];
                if (param_id == id) {
                    return switch (param) {
                        .float => |p| p.range.unnormalize(@floatCast(value_normalized)),
                        .int => |p| @floatFromInt(p.range.unnormalize(@floatCast(value_normalized))),
                        .boolean => value_normalized,
                        .choice => |p| blk: {
                            const idx = @as(u32, @intFromFloat(value_normalized * @as(f32, @floatFromInt(p.labels.len - 1))));
                            break :blk @floatFromInt(idx);
                        },
                    };
                }
            }
            
            return value_normalized;
        }
        
        fn plainParamToNormalized(
            _: *anyopaque,
            id: vst3.types.ParamID,
            plain_value: vst3.types.ParamValue,
        ) callconv(.c) vst3.types.ParamValue {
            // Find parameter by ID
            for (P.params, 0..) |param, i| {
                const param_id = param_ids[i];
                if (param_id == id) {
                    return switch (param) {
                        .float => |p| p.range.normalize(@floatCast(plain_value)),
                        .int => |p| p.range.normalize(@intFromFloat(plain_value)),
                        .boolean => plain_value,
                        .choice => |p| blk: {
                            if (p.labels.len <= 1) break :blk 0.0;
                            const idx = @as(u32, @intFromFloat(plain_value));
                            break :blk @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(p.labels.len - 1));
                        },
                    };
                }
            }
            
            return plain_value;
        }
        
        fn getParamNormalized(
            self: *anyopaque,
            id: vst3.types.ParamID,
        ) callconv(.c) vst3.types.ParamValue {
            const controller = fromController(self);
            
            if (controller.param_values) |param_values| {
                // Find parameter by ID
                for (P.params, 0..) |_, idx| {
                    const param_id = param_ids[idx];
                    if (param_id == id) {
                        return param_values.get(idx);
                    }
                }
            }
            
            return 0.0;
        }
        
        fn setParamNormalized(
            self: *anyopaque,
            id: vst3.types.ParamID,
            value: vst3.types.ParamValue,
        ) callconv(.c) vst3.tresult {
            const controller = fromController(self);
            
            if (controller.param_values) |param_values| {
                // Find parameter by ID
                for (P.params, 0..) |_, idx| {
                    const param_id = param_ids[idx];
                    if (param_id == id) {
                        param_values.set(idx, @floatCast(value));
                        return vst3.types.kResultOk;
                    }
                }
            }
            
            return vst3.types.kResultFalse;
        }
        
        fn setComponentHandler(_: *anyopaque, _: *anyopaque) callconv(.c) vst3.tresult {
            return vst3.types.kResultOk;
        }
        
        fn createView(_: *anyopaque, _: vst3.types.FIDString) callconv(.c) ?*vst3.controller.IPlugView {
            // GUI not implemented yet
            return null;
        }
    };
}
