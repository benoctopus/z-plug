/// Comptime parameter declaration and runtime parameter state.
///
/// Plugin authors declare parameters as comptime arrays of `Param` values.
/// The framework uses these declarations to generate metadata for both CLAP
/// and VST3 at compile time and to manage runtime parameter values with
/// lock-free atomics.
const std = @import("std");

// ---------------------------------------------------------------------------
// Ranges
// ---------------------------------------------------------------------------

/// A continuous floating-point parameter range.
pub const FloatRange = struct {
    min: f32,
    max: f32,

    /// Map a plain value to the normalized 0.0–1.0 range.
    pub fn normalize(self: FloatRange, plain: f32) f32 {
        if (self.max == self.min) return 0.0;
        return (self.clamp(plain) - self.min) / (self.max - self.min);
    }

    /// Map a normalized 0.0–1.0 value back to the plain range.
    pub fn unnormalize(self: FloatRange, normalized: f32) f32 {
        const clamped = std.math.clamp(normalized, 0.0, 1.0);
        return self.min + clamped * (self.max - self.min);
    }

    /// Clamp a plain value to the range [min, max].
    pub fn clamp(self: FloatRange, value: f32) f32 {
        return std.math.clamp(value, self.min, self.max);
    }
};

/// A discrete integer parameter range.
pub const IntRange = struct {
    min: i32,
    max: i32,

    /// Map a plain integer value to the normalized 0.0–1.0 range.
    pub fn normalize(self: IntRange, plain: i32) f32 {
        if (self.max == self.min) return 0.0;
        const clamped = self.clamp(plain);
        return @as(f32, @floatFromInt(clamped - self.min)) /
            @as(f32, @floatFromInt(self.max - self.min));
    }

    /// Map a normalized 0.0–1.0 value back to a plain integer (rounded).
    pub fn unnormalize(self: IntRange, normalized: f32) i32 {
        const clamped = std.math.clamp(normalized, 0.0, 1.0);
        const span: f32 = @floatFromInt(self.max - self.min);
        return self.min + @as(i32, @intFromFloat(@round(clamped * span)));
    }

    /// Clamp a plain integer value to the range [min, max].
    pub fn clamp(self: IntRange, value: i32) i32 {
        return std.math.clamp(value, self.min, self.max);
    }

    /// The number of discrete steps in this range (max - min).
    pub fn stepCount(self: IntRange) u32 {
        return @intCast(self.max - self.min);
    }
};

// ---------------------------------------------------------------------------
// Flags
// ---------------------------------------------------------------------------

/// Flags that control how a parameter is exposed to the host.
pub const ParamFlags = packed struct {
    /// Whether the host can automate this parameter. Default: `true`.
    automatable: bool = true,
    /// Whether the parameter supports per-voice modulation (CLAP).
    modulatable: bool = false,
    /// Hide this parameter from the host's generic parameter list.
    hidden: bool = false,
    /// Mark this parameter as the plugin's bypass control.
    bypass: bool = false,
    /// Hint that the parameter is stepped (e.g. switches, choices).
    is_stepped: bool = false,
    _padding: u3 = 0,
};

// ---------------------------------------------------------------------------
// Parameter declarations (comptime)
// ---------------------------------------------------------------------------

/// A continuous floating-point parameter.
pub const FloatParam = struct {
    /// Human-readable parameter name shown in the host.
    name: [:0]const u8,
    /// Stable string identifier. Hashed to generate VST3 `ParamID`.
    id: [:0]const u8,
    /// Default plain value.
    default: f32,
    /// The value range for this parameter.
    range: FloatRange,
    /// Optional step size for hosts that display discrete ticks.
    step_size: ?f32 = null,
    /// Unit label displayed after the value (e.g. "dB", "Hz", "%").
    unit: [:0]const u8 = "",
    /// Flags controlling automation, visibility, etc.
    flags: ParamFlags = .{},
};

/// A discrete integer parameter.
pub const IntParam = struct {
    /// Human-readable parameter name.
    name: [:0]const u8,
    /// Stable string identifier.
    id: [:0]const u8,
    /// Default plain value.
    default: i32,
    /// The integer value range.
    range: IntRange,
    /// Unit label (e.g. "st" for semitones).
    unit: [:0]const u8 = "",
    /// Flags controlling automation, visibility, etc.
    flags: ParamFlags = .{},
};

/// A boolean (on/off, toggle) parameter.
pub const BoolParam = struct {
    /// Human-readable parameter name.
    name: [:0]const u8,
    /// Stable string identifier.
    id: [:0]const u8,
    /// Default value.
    default: bool,
    /// Flags controlling automation, visibility, etc.
    flags: ParamFlags = .{},
};

/// An enum / choice parameter backed by a list of labels.
pub const ChoiceParam = struct {
    /// Human-readable parameter name.
    name: [:0]const u8,
    /// Stable string identifier.
    id: [:0]const u8,
    /// Default choice index (0-based).
    default: u32,
    /// The list of choice labels.
    labels: []const [:0]const u8,
    /// Flags controlling automation, visibility, etc.
    flags: ParamFlags = .{},

    /// The number of discrete steps (choices - 1).
    pub fn stepCount(self: ChoiceParam) u32 {
        if (self.labels.len == 0) return 0;
        return @intCast(self.labels.len - 1);
    }
};

/// A single parameter declaration. Plugin authors build comptime arrays of
/// these to define their parameter set.
pub const Param = union(enum) {
    float: FloatParam,
    int: IntParam,
    boolean: BoolParam,
    choice: ChoiceParam,

    /// Returns the human-readable name of this parameter.
    pub fn name(self: Param) [:0]const u8 {
        return switch (self) {
            .float => |p| p.name,
            .int => |p| p.name,
            .boolean => |p| p.name,
            .choice => |p| p.name,
        };
    }

    /// Returns the stable string ID of this parameter.
    pub fn id(self: Param) [:0]const u8 {
        return switch (self) {
            .float => |p| p.id,
            .int => |p| p.id,
            .boolean => |p| p.id,
            .choice => |p| p.id,
        };
    }

    /// Returns the default value of this parameter, normalized to 0.0–1.0.
    pub fn defaultNormalized(self: Param) f32 {
        return switch (self) {
            .float => |p| p.range.normalize(p.default),
            .int => |p| p.range.normalize(p.default),
            .boolean => |p| if (p.default) @as(f32, 1.0) else @as(f32, 0.0),
            .choice => |p| blk: {
                if (p.labels.len <= 1) break :blk 0.0;
                break :blk @as(f32, @floatFromInt(p.default)) /
                    @as(f32, @floatFromInt(p.labels.len - 1));
            },
        };
    }

    /// Returns the flags for this parameter.
    pub fn flags(self: Param) ParamFlags {
        return switch (self) {
            .float => |p| p.flags,
            .int => |p| p.flags,
            .boolean => |p| p.flags,
            .choice => |p| p.flags,
        };
    }
};

// ---------------------------------------------------------------------------
// Stable ID hashing
// ---------------------------------------------------------------------------

/// Compute a stable 32-bit hash from a parameter's string ID.
///
/// Uses FNV-1a to produce a deterministic `u32` suitable for use as a
/// VST3 `ParamID`. The same string always produces the same hash.
pub fn idHash(comptime str: [:0]const u8) u32 {
    comptime {
        return fnv1a_32(str);
    }
}

/// FNV-1a hash producing a u32.
fn fnv1a_32(data: []const u8) u32 {
    const fnv_offset_basis: u32 = 2166136261;
    const fnv_prime: u32 = 16777619;
    var hash: u32 = fnv_offset_basis;
    for (data) |byte| {
        hash ^= @as(u32, byte);
        hash *%= fnv_prime;
    }
    return hash;
}

// ---------------------------------------------------------------------------
// Runtime parameter values (lock-free atomics)
// ---------------------------------------------------------------------------

/// Runtime storage for parameter values, using atomics for lock-free
/// thread-safe access between the audio thread and the main/GUI thread.
///
/// `N` is the number of parameters, known at comptime from the plugin's
/// parameter declarations.
pub fn ParamValues(comptime N: usize) type {
    return struct {
        const Self = @This();

        /// Normalized values (0.0–1.0) for each parameter.
        values: [N]std.atomic.Value(f32),

        /// Initialize all parameter values to their defaults.
        pub fn init(comptime params: []const Param) Self {
            var vals: [N]std.atomic.Value(f32) = undefined;
            inline for (params, 0..) |p, i| {
                vals[i] = std.atomic.Value(f32).init(p.defaultNormalized());
            }
            return Self{ .values = vals };
        }

        /// Get the normalized value of parameter at `index` (audio-thread safe).
        pub fn get(self: *const Self, index: usize) f32 {
            return self.values[index].load(.monotonic);
        }

        /// Set the normalized value of parameter at `index` (audio-thread safe).
        pub fn set(self: *Self, index: usize, normalized: f32) void {
            self.values[index].store(normalized, .monotonic);
        }

        /// The number of parameters.
        pub fn count(_: *const Self) usize {
            return N;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "FloatRange normalize and unnormalize roundtrip" {
    const range = FloatRange{ .min = -24.0, .max = 24.0 };
    const plain: f32 = 6.0;
    const norm = range.normalize(plain);
    const back = range.unnormalize(norm);
    try std.testing.expectApproxEqAbs(plain, back, 1e-6);
}

test "FloatRange normalize at boundaries" {
    const range = FloatRange{ .min = 0.0, .max = 100.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), range.normalize(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), range.normalize(100.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), range.normalize(50.0), 1e-6);
}

test "FloatRange clamp" {
    const range = FloatRange{ .min = 0.0, .max = 1.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), range.clamp(-1.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), range.clamp(2.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), range.clamp(0.5), 1e-6);
}

test "FloatRange degenerate (min == max)" {
    const range = FloatRange{ .min = 5.0, .max = 5.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), range.normalize(5.0), 1e-6);
}

test "IntRange normalize and unnormalize roundtrip" {
    const range = IntRange{ .min = 0, .max = 10 };
    const plain: i32 = 7;
    const norm = range.normalize(plain);
    const back = range.unnormalize(norm);
    try std.testing.expectEqual(plain, back);
}

test "IntRange boundaries" {
    const range = IntRange{ .min = -12, .max = 12 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), range.normalize(-12), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), range.normalize(12), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), range.normalize(0), 1e-6);
}

test "IntRange clamp" {
    const range = IntRange{ .min = 0, .max = 127 };
    try std.testing.expectEqual(@as(i32, 0), range.clamp(-10));
    try std.testing.expectEqual(@as(i32, 127), range.clamp(200));
}

test "IntRange stepCount" {
    const range = IntRange{ .min = 0, .max = 4 };
    try std.testing.expectEqual(@as(u32, 4), range.stepCount());
}

test "idHash is stable across calls" {
    const h1 = comptime idHash("gain");
    const h2 = comptime idHash("gain");
    try std.testing.expectEqual(h1, h2);
}

test "idHash produces different values for different IDs" {
    const h1 = comptime idHash("gain");
    const h2 = comptime idHash("mix");
    try std.testing.expect(h1 != h2);
}

test "Param defaultNormalized for float" {
    const p = Param{ .float = .{
        .name = "Gain",
        .id = "gain",
        .default = 0.0,
        .range = .{ .min = -24.0, .max = 24.0 },
    } };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.defaultNormalized(), 1e-6);
}

test "Param defaultNormalized for boolean" {
    const p_false = Param{ .boolean = .{
        .name = "Bypass",
        .id = "bypass",
        .default = false,
    } };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), p_false.defaultNormalized(), 1e-6);

    const p_true = Param{ .boolean = .{
        .name = "Bypass",
        .id = "bypass",
        .default = true,
    } };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), p_true.defaultNormalized(), 1e-6);
}

test "Param defaultNormalized for choice" {
    const p = Param{ .choice = .{
        .name = "Mode",
        .id = "mode",
        .default = 1,
        .labels = &.{ "A", "B", "C" },
    } };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.defaultNormalized(), 1e-6);
}

test "ParamValues init and get" {
    const params = [_]Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 0.0,
            .range = .{ .min = -24.0, .max = 24.0 },
        } },
        .{ .boolean = .{
            .name = "Bypass",
            .id = "bypass",
            .default = true,
        } },
    };
    var pv = ParamValues(2).init(&params);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pv.get(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pv.get(1), 1e-6);

    pv.set(0, 0.75);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), pv.get(0), 1e-6);
}
