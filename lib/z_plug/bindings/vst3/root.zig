// VST3 C API bindings root module
// Re-exports all VST3 binding submodules

pub const types = @import("types.zig");
pub const guid = @import("guid.zig");
pub const funknown = @import("funknown.zig");
pub const factory = @import("factory.zig");
pub const component = @import("component.zig");
pub const processor = @import("processor.zig");
pub const controller = @import("controller.zig");
pub const stream = @import("stream.zig");
pub const events = @import("events.zig");
pub const param_changes = @import("param_changes.zig");
pub const connection = @import("connection.zig");
pub const view = @import("view.zig");
pub const layout_tests = @import("layout_tests.zig");

// Commonly used types
pub const TUID = types.TUID;
pub const tresult = types.tresult;
pub const kResultOk = types.kResultOk;
pub const kResultFalse = types.kResultFalse;
pub const kNoInterface = types.kNoInterface;

// Commonly used GUIDs
pub const IID_FUnknown = guid.IID_FUnknown;
pub const IID_IPluginBase = guid.IID_IPluginBase;
pub const IID_IPluginFactory = guid.IID_IPluginFactory;
pub const IID_IComponent = guid.IID_IComponent;
pub const IID_IAudioProcessor = guid.IID_IAudioProcessor;
pub const IID_IEditController = guid.IID_IEditController;

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
