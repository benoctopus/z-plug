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

/// A continuous floating-point parameter range with logarithmic mapping.
/// Useful for parameters where human perception is logarithmic (frequency, gain).
pub const LogFloatRange = struct {
    min: f32,
    max: f32,

    /// Map a plain value to the normalized 0.0–1.0 range using logarithmic scaling.
    pub fn normalize(self: LogFloatRange, plain: f32) f32 {
        if (self.max <= self.min or self.min <= 0.0) return 0.0;
        const clamped = self.clamp(plain);
        const log_min = @log(self.min);
        const log_max = @log(self.max);
        return (@log(clamped) - log_min) / (log_max - log_min);
    }

    /// Map a normalized 0.0–1.0 value back to the plain range using logarithmic scaling.
    pub fn unnormalize(self: LogFloatRange, normalized: f32) f32 {
        const clamped = std.math.clamp(normalized, 0.0, 1.0);
        const log_min = @log(self.min);
        const log_max = @log(self.max);
        return @exp(log_min + clamped * (log_max - log_min));
    }

    /// Clamp a plain value to the range [min, max].
    pub fn clamp(self: LogFloatRange, value: f32) f32 {
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
    /// The value range - can be linear or logarithmic.
    range: union(enum) {
        linear: FloatRange,
        logarithmic: LogFloatRange,
    },
    /// Optional step size for hosts that display discrete ticks.
    step_size: ?f32 = null,
    /// Unit label displayed after the value (e.g. "dB", "Hz", "%").
    unit: [:0]const u8 = "",
    /// Flags controlling automation, visibility, etc.
    flags: ParamFlags = .{},
    /// Optional smoothing style (default: no smoothing).
    smoothing: SmoothingStyle = .none,
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
    /// Optional smoothing style (default: no smoothing).
    smoothing: SmoothingStyle = .none,
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
            .float => |p| switch (p.range) {
                .linear => |r| r.normalize(p.default),
                .logarithmic => |r| r.normalize(p.default),
            },
            .int => |p| p.range.normalize(p.default),
            .boolean => |p| if (p.default) @as(f32, 1.0) else @as(f32, 0.0),
            .choice => |p| blk: {
                if (p.labels.len <= 1) break :blk 0.0;
                break :blk @as(f32, @floatFromInt(p.default)) /
                    @as(f32, @floatFromInt(p.labels.len - 1));
            },
        };
    }

    /// Convert a normalized value to plain (unnormalized) value.
    pub fn toPlain(self: Param, normalized: f32) f32 {
        return switch (self) {
            .float => |p| switch (p.range) {
                .linear => |r| r.unnormalize(normalized),
                .logarithmic => |r| r.unnormalize(normalized),
            },
            .int => |p| @floatFromInt(p.range.unnormalize(normalized)),
            .boolean => if (normalized > 0.5) 1.0 else 0.0,
            .choice => |p| blk: {
                if (p.labels.len <= 1) break :blk 0.0;
                break :blk normalized * @as(f32, @floatFromInt(p.labels.len - 1));
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
        /// Aligned to cache line for optimal access patterns on the audio thread.
        values: [N]std.atomic.Value(f32) align(@import("../root.zig").CACHE_LINE_SIZE),

        /// Initialize all parameter values to their defaults.
        pub fn init(comptime params: []const Param) Self {
            var vals: [N]std.atomic.Value(f32) = undefined;
            inline for (params, 0..) |p, i| {
                vals[i] = std.atomic.Value(f32).init(p.defaultNormalized());
            }
            return Self{ .values = vals };
        }

        /// Get the normalized value of parameter at `index` (audio-thread safe).
        pub inline fn get(self: *const Self, index: usize) f32 {
            return self.values[index].load(.monotonic);
        }

        /// Set the normalized value of parameter at `index` (audio-thread safe).
        pub inline fn set(self: *Self, index: usize, normalized: f32) void {
            self.values[index].store(normalized, .monotonic);
        }

        /// The number of parameters.
        pub fn count(_: *const Self) usize {
            return N;
        }
    };
}

// ---------------------------------------------------------------------------
// Parameter Access During Processing
// ---------------------------------------------------------------------------

/// Parameter access interface for plugins during `process()`.
///
/// Provides type-safe methods to read parameter values and smoothed values.
/// The wrapper populates this with pointers to `ParamValues` and `SmootherBank`.
pub fn ParamAccess(comptime N: usize, comptime params_meta: []const Param) type {
    return struct {
        const Self = @This();

        values: *ParamValues(N),
        smoothers: *SmootherBank(N),

        /// Get the current plain value of a float parameter (no smoothing).
        pub fn getFloat(self: *const Self, comptime index: usize) f32 {
            comptime {
                if (index >= N) @compileError("Parameter index out of bounds");
                if (params_meta[index] != .float) @compileError("Parameter at index is not a float");
            }

            const normalized = self.values.get(index);
            return switch (params_meta[index].float.range) {
                .linear => |r| r.unnormalize(normalized),
                .logarithmic => |r| r.unnormalize(normalized),
            };
        }

        /// Get the current plain value of an int parameter.
        pub fn getInt(self: *const Self, comptime index: usize) i32 {
            comptime {
                if (index >= N) @compileError("Parameter index out of bounds");
                if (params_meta[index] != .int) @compileError("Parameter at index is not an int");
            }

            const normalized = self.values.get(index);
            return params_meta[index].int.range.unnormalize(normalized);
        }

        /// Get the current value of a bool parameter.
        pub fn getBool(self: *const Self, comptime index: usize) bool {
            comptime {
                if (index >= N) @compileError("Parameter index out of bounds");
                if (params_meta[index] != .boolean) @compileError("Parameter at index is not a boolean");
            }

            const normalized = self.values.get(index);
            return normalized > 0.5;
        }

        /// Get the current choice index of a choice parameter.
        pub fn getChoice(self: *const Self, comptime index: usize) u32 {
            comptime {
                if (index >= N) @compileError("Parameter index out of bounds");
                if (params_meta[index] != .choice) @compileError("Parameter at index is not a choice");
            }

            const normalized = self.values.get(index);
            if (params_meta[index].choice.labels.len <= 1) return 0;
            return @intFromFloat(normalized * @as(f32, @floatFromInt(params_meta[index].choice.labels.len - 1)));
        }

        /// Get the next smoothed sample for a parameter.
        /// If the parameter has no smoothing configured, returns the current value.
        pub fn nextSmoothed(self: *Self, comptime index: usize) f32 {
            comptime {
                if (index >= N) @compileError("Parameter index out of bounds");
            }
            return self.smoothers.next(index);
        }

        /// Fill a block with smoothed values for a parameter.
        pub fn nextSmoothedBlock(self: *Self, comptime index: usize, out: []f32) void {
            comptime {
                if (index >= N) @compileError("Parameter index out of bounds");
            }
            for (out) |*sample| {
                sample.* = self.smoothers.next(index);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Parameter Smoothing
// ---------------------------------------------------------------------------

/// Smoothing style for parameter value changes.
pub const SmoothingStyle = union(enum) {
    /// No smoothing — parameter changes take effect immediately.
    none,
    /// Linear ramp over the specified duration in milliseconds.
    linear: f32,
    /// Exponential smoothing (single-pole IIR) over the specified duration.
    /// Reaches approximately 99.99% of target, then snaps to target.
    exponential: f32,
    /// Logarithmic interpolation over the specified duration in milliseconds.
    /// Smooths in log space, producing exponential curves in linear space.
    /// Useful for frequency sweeps and gain changes.
    logarithmic: f32,
};

/// A parameter value smoother that interpolates between current and target
/// values over time.
///
/// Supports linear and exponential smoothing styles. Used to avoid audible
/// clicks and pops when parameters change abruptly.
pub const Smoother = struct {
    /// The smoothing style for this parameter.
    style: SmoothingStyle,
    /// Current smoothed value (plain, not normalized).
    current: f32,
    /// Target value to reach (plain, not normalized).
    target: f32,
    /// Per-sample step size (linear) or coefficient (exponential).
    step_size: f32,
    /// Number of samples remaining until target is reached.
    steps_left: u32,

    /// Initialize a smoother with a starting value and no smoothing.
    pub fn init(initial_value: f32, style: SmoothingStyle) Smoother {
        return Smoother{
            .style = style,
            .current = initial_value,
            .target = initial_value,
            .step_size = 0.0,
            .steps_left = 0,
        };
    }

    /// Set a new target value and compute smoothing parameters.
    pub fn setTarget(self: *Smoother, sample_rate: f32, new_target: f32) void {
        self.target = new_target;

        switch (self.style) {
            .none => {
                self.current = new_target;
                self.steps_left = 0;
                self.step_size = 0.0;
            },
            .linear => |duration_ms| {
                const duration_samples = (sample_rate * duration_ms) / 1000.0;
                self.steps_left = @intFromFloat(@max(1.0, duration_samples));
                const delta = self.target - self.current;
                self.step_size = delta / @as(f32, @floatFromInt(self.steps_left));
            },
            .exponential => |duration_ms| {
                // Single-pole IIR: y[n] = y[n-1] + coeff * (target - y[n-1])
                // We want to reach ~99.99% in duration_samples
                // After N steps: remaining = (1 - coeff)^N ≈ 0.0001
                // coeff = 1 - exp(ln(0.0001) / N)
                const duration_samples = (sample_rate * duration_ms) / 1000.0;
                const n = @max(1.0, duration_samples);
                const ln_remaining = @log(0.0001);
                self.step_size = 1.0 - @exp(ln_remaining / n);
                // For exponential, steps_left is just a sentinel until we snap
                self.steps_left = @intFromFloat(n);
            },
            .logarithmic => |duration_ms| {
                // Interpolate in log space: log(y[n]) = log(y[n-1]) + step
                // Requires both current and target to be positive
                if (self.current <= 0.0 or new_target <= 0.0) {
                    // Fallback to linear if either value is non-positive
                    self.current = new_target;
                    self.steps_left = 0;
                    self.step_size = 0.0;
                    return;
                }

                const duration_samples = (sample_rate * duration_ms) / 1000.0;
                self.steps_left = @intFromFloat(@max(1.0, duration_samples));
                const log_delta = @log(self.target) - @log(self.current);
                self.step_size = log_delta / @as(f32, @floatFromInt(self.steps_left));
            },
        }
    }

    /// Get the next smoothed sample value and advance the smoother.
    pub inline fn next(self: *Smoother) f32 {
        if (self.steps_left == 0) {
            return self.current;
        }

        switch (self.style) {
            .none => {
                return self.current;
            },
            .linear => {
                self.current += self.step_size;
                self.steps_left -= 1;
                if (self.steps_left == 0) {
                    self.current = self.target; // Snap to exact target
                }
                return self.current;
            },
            .exponential => {
                self.current += self.step_size * (self.target - self.current);
                self.steps_left -= 1;
                if (self.steps_left == 0) {
                    self.current = self.target; // Snap to exact target
                }
                return self.current;
            },
            .logarithmic => {
                // Interpolate in log space: multiply by constant factor each step
                const log_current = @log(self.current);
                const log_next = log_current + self.step_size;
                self.current = @exp(log_next);
                self.steps_left -= 1;
                if (self.steps_left == 0) {
                    self.current = self.target; // Snap to exact target
                }
                return self.current;
            },
        }
    }

    /// Fill a block of samples with smoothed values.
    pub inline fn nextBlock(self: *Smoother, out: []f32) void {
        if (out.len == 0) return;

        // Fast path: no smoothing needed
        if (self.steps_left == 0) {
            @memset(out, self.current);
            return;
        }

        // Optimized path for linear smoothing: compute arithmetic progression directly
        // This eliminates the loop-carried dependency and allows compiler auto-vectorization
        if (self.style == .linear) {
            const start = self.current;
            const step = self.step_size;
            const samples_to_smooth = @min(out.len, self.steps_left);

            // Fill smoothed portion with arithmetic progression: start + i*step
            for (out[0..samples_to_smooth], 0..) |*sample, i| {
                sample.* = start + step * @as(f32, @floatFromInt(i));
            }

            // Update state
            self.current = start + step * @as(f32, @floatFromInt(samples_to_smooth));
            self.steps_left -= @intCast(samples_to_smooth);
            if (self.steps_left == 0) {
                self.current = self.target; // Snap to exact target
            }

            // Fill remainder with target value (no smoothing)
            if (samples_to_smooth < out.len) {
                @memset(out[samples_to_smooth..], self.current);
            }
            return;
        }

        // Optimized path for logarithmic smoothing
        if (self.style == .logarithmic) {
            const samples_to_smooth = @min(out.len, self.steps_left);
            const log_start = @log(self.current);
            const step = self.step_size;

            // Fill smoothed portion with geometric progression: start * exp(i*step)
            for (out[0..samples_to_smooth], 0..) |*sample, i| {
                sample.* = @exp(log_start + step * @as(f32, @floatFromInt(i)));
            }

            // Update state
            self.current = @exp(log_start + step * @as(f32, @floatFromInt(samples_to_smooth)));
            self.steps_left -= @intCast(samples_to_smooth);
            if (self.steps_left == 0) {
                self.current = self.target; // Snap to exact target
            }

            // Fill remainder with target value
            if (samples_to_smooth < out.len) {
                @memset(out[samples_to_smooth..], self.current);
            }
            return;
        }

        // Fallback for exponential/other styles: use per-sample next()
        // Exponential has true loop-carried dependency and cannot be vectorized
        for (out) |*sample| {
            sample.* = self.next();
        }
    }

    /// Reset the smoother to a specific value instantly (no smoothing).
    pub fn reset(self: *Smoother, value: f32) void {
        self.current = value;
        self.target = value;
        self.steps_left = 0;
        self.step_size = 0.0;
    }

    /// Returns true if the smoother is actively interpolating.
    pub fn isSmoothing(self: *const Smoother) bool {
        return self.steps_left > 0;
    }
};

/// A bank of smoothers, one per parameter.
///
/// `N` is the number of parameters, known at comptime.
pub fn SmootherBank(comptime N: usize) type {
    return struct {
        const Self = @This();

        /// One smoother per parameter.
        /// Aligned to cache line for optimal access patterns on the audio thread.
        smoothers: [N]Smoother align(@import("../root.zig").CACHE_LINE_SIZE),

        /// Initialize all smoothers from parameter declarations.
        pub fn init(comptime params: []const Param) Self {
            var bank: [N]Smoother = undefined;
            inline for (params, 0..) |p, i| {
                const style: SmoothingStyle = switch (p) {
                    .float => |fp| if (@hasField(@TypeOf(fp), "smoothing")) fp.smoothing else .none,
                    .int => |ip| if (@hasField(@TypeOf(ip), "smoothing")) ip.smoothing else .none,
                    .boolean, .choice => .none,
                };

                const default_plain: f32 = switch (p) {
                    .float => |fp| fp.default,
                    .int => |ip| @floatFromInt(ip.default),
                    .boolean => |bp| if (bp.default) 1.0 else 0.0,
                    .choice => |cp| @floatFromInt(cp.default),
                };

                bank[i] = Smoother.init(default_plain, style);
            }
            return Self{ .smoothers = bank };
        }

        /// Set a new target value for a parameter's smoother.
        pub fn setTarget(self: *Self, index: usize, sample_rate: f32, plain_value: f32) void {
            self.smoothers[index].setTarget(sample_rate, plain_value);
        }

        /// Get the next smoothed sample for a parameter.
        pub fn next(self: *Self, index: usize) f32 {
            return self.smoothers[index].next();
        }

        /// Reset a parameter's smoother to a specific value.
        pub fn reset(self: *Self, index: usize, value: f32) void {
            self.smoothers[index].reset(value);
        }

        /// Returns true if a parameter is currently smoothing.
        pub fn isSmoothing(self: *const Self, index: usize) bool {
            return self.smoothers[index].isSmoothing();
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
        .range = .{ .linear = .{ .min = -24.0, .max = 24.0 } },
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
            .range = .{ .linear = .{ .min = -24.0, .max = 24.0 } },
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

test "Smoother linear reaches target" {
    var smoother = Smoother.init(0.0, .{ .linear = 10.0 }); // 10ms linear
    const sample_rate = 1000.0; // 1kHz

    smoother.setTarget(sample_rate, 10.0);

    // Should reach target in 10 samples (10ms at 1kHz)
    try std.testing.expectEqual(@as(u32, 10), smoother.steps_left);

    // First sample
    const v1 = smoother.next();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v1, 1e-4);

    // Last sample should snap to target
    smoother.steps_left = 1;
    smoother.current = 9.9;
    const v_last = smoother.next();
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), v_last, 1e-6);
    try std.testing.expectEqual(@as(u32, 0), smoother.steps_left);
}

test "Smoother exponential converges" {
    var smoother = Smoother.init(0.0, .{ .exponential = 10.0 });
    const sample_rate = 1000.0;

    smoother.setTarget(sample_rate, 1.0);

    // Exponential should approach target asymptotically
    const v1 = smoother.next();
    try std.testing.expect(v1 > 0.0 and v1 < 1.0);

    const v2 = smoother.next();
    try std.testing.expect(v2 > v1 and v2 < 1.0);

    // After steps_left reaches 0, should snap to target
    smoother.steps_left = 1;
    smoother.current = 0.999;
    const v_snap = smoother.next();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v_snap, 1e-6);
}

test "Smoother none has no smoothing" {
    var smoother = Smoother.init(5.0, .none);

    smoother.setTarget(44100.0, 10.0);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), smoother.current, 1e-6);
    try std.testing.expectEqual(@as(u32, 0), smoother.steps_left);

    const v = smoother.next();
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), v, 1e-6);
}

test "Smoother reset snaps instantly" {
    var smoother = Smoother.init(0.0, .{ .linear = 100.0 });

    smoother.setTarget(44100.0, 10.0);
    try std.testing.expect(smoother.steps_left > 0);

    smoother.reset(5.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), smoother.current, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), smoother.target, 1e-6);
    try std.testing.expectEqual(@as(u32, 0), smoother.steps_left);
}

test "Smoother isSmoothing" {
    var smoother = Smoother.init(0.0, .{ .linear = 10.0 });

    try std.testing.expect(!smoother.isSmoothing());

    smoother.setTarget(1000.0, 1.0);
    try std.testing.expect(smoother.isSmoothing());

    smoother.reset(0.5);
    try std.testing.expect(!smoother.isSmoothing());
}

test "SmootherBank init and setTarget" {
    const params = [_]Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 0.0,
            .range = .{ .linear = .{ .min = -24.0, .max = 24.0 } },
            .smoothing = .{ .linear = 10.0 },
        } },
        .{ .int = .{
            .name = "Cutoff",
            .id = "cutoff",
            .default = 1000,
            .range = .{ .min = 20, .max = 20000 },
        } },
    };

    var bank = SmootherBank(2).init(&params);

    // Initial values should match defaults
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bank.smoothers[0].current, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), bank.smoothers[1].current, 1e-6);

    // Set new targets
    bank.setTarget(0, 44100.0, 6.0);
    try std.testing.expect(bank.isSmoothing(0));
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), bank.smoothers[0].target, 1e-6);
}

test "ParamAccess typed getters" {
    const params = [_]Param{
        .{ .float = .{
            .name = "Gain",
            .id = "gain",
            .default = 0.0,
            .range = .{ .linear = .{ .min = -24.0, .max = 24.0 } },
        } },
        .{ .int = .{
            .name = "Cutoff",
            .id = "cutoff",
            .default = 1000,
            .range = .{ .min = 20, .max = 20000 },
        } },
        .{ .boolean = .{
            .name = "Bypass",
            .id = "bypass",
            .default = false,
        } },
        .{ .choice = .{
            .name = "Mode",
            .id = "mode",
            .default = 0,
            .labels = &.{ "Low", "Mid", "High" },
        } },
    };

    var param_values = ParamValues(4).init(&params);
    var smoother_bank = SmootherBank(4).init(&params);

    const access = ParamAccess(4, &params){
        .values = &param_values,
        .smoothers = &smoother_bank,
    };

    // Test getFloat
    param_values.set(0, 0.75); // 0.75 normalized = 12.0 in [-24, 24] range
    const gain = access.getFloat(0);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), gain, 1e-4);

    // Test getInt
    param_values.set(1, 0.5); // 0.5 normalized = ~10010 in [20, 20000] range
    const cutoff = access.getInt(1);
    try std.testing.expectEqual(@as(i32, 10010), cutoff);

    // Test getBool
    param_values.set(2, 0.0);
    try std.testing.expect(!access.getBool(2));
    param_values.set(2, 1.0);
    try std.testing.expect(access.getBool(2));

    // Test getChoice
    param_values.set(3, 0.5); // Middle choice
    const mode = access.getChoice(3);
    try std.testing.expectEqual(@as(u32, 1), mode);
}

test "Param toPlain conversion" {
    // Float param
    const float_param = Param{ .float = .{
        .name = "Gain",
        .id = "gain",
        .default = 0.0,
        .range = .{ .linear = .{ .min = -24.0, .max = 24.0 } },
    } };
    const float_plain = float_param.toPlain(0.75); // 0.75 normalized = 12.0 in [-24, 24] range
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), float_plain, 1e-4);

    // Int param
    const int_param = Param{ .int = .{
        .name = "Cutoff",
        .id = "cutoff",
        .default = 1000,
        .range = .{ .min = 20, .max = 20000 },
    } };
    const int_plain = int_param.toPlain(0.5); // 0.5 normalized = ~10010 in [20, 20000] range
    try std.testing.expectApproxEqAbs(@as(f32, 10010.0), int_plain, 1.0);

    // Boolean param
    const bool_param = Param{ .boolean = .{
        .name = "Bypass",
        .id = "bypass",
        .default = false,
    } };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bool_param.toPlain(0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bool_param.toPlain(1.0), 1e-6);

    // Choice param
    const choice_param = Param{ .choice = .{
        .name = "Mode",
        .id = "mode",
        .default = 0,
        .labels = &.{ "Low", "Mid", "High" },
    } };
    const choice_plain = choice_param.toPlain(0.5); // Middle choice
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), choice_plain, 1e-6);
}

test "LogFloatRange normalize and unnormalize roundtrip" {
    const range = LogFloatRange{ .min = 20.0, .max = 20000.0 };
    const plain: f32 = 1000.0;
    const norm = range.normalize(plain);
    const back = range.unnormalize(norm);
    try std.testing.expectApproxEqAbs(plain, back, 1e-3);
}

test "LogFloatRange perceptually uniform" {
    const range = LogFloatRange{ .min = 20.0, .max = 20000.0 };
    // At 50% normalized, should be geometric mean
    const mid = range.unnormalize(0.5);
    const expected = @sqrt(20.0 * 20000.0); // ~632.5 Hz
    try std.testing.expectApproxEqAbs(expected, mid, 1.0);
}

test "LogFloatRange boundaries" {
    const range = LogFloatRange{ .min = 20.0, .max = 20000.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), range.normalize(20.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), range.normalize(20000.0), 1e-6);
}

test "LogFloatRange clamp" {
    const range = LogFloatRange{ .min = 20.0, .max = 20000.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), range.clamp(10.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 20000.0), range.clamp(30000.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), range.clamp(1000.0), 1e-6);
}

test "Smoother logarithmic reaches target" {
    var smoother = Smoother.init(100.0, .{ .logarithmic = 10.0 });
    const sample_rate = 1000.0;

    smoother.setTarget(sample_rate, 1000.0);
    try std.testing.expectEqual(@as(u32, 10), smoother.steps_left);

    // Should multiply by constant factor each step
    const v1 = smoother.next();
    try std.testing.expect(v1 > 100.0 and v1 < 1000.0);

    const v2 = smoother.next();
    try std.testing.expect(v2 > v1 and v2 < 1000.0);

    // Last step should snap to target
    smoother.steps_left = 1;
    smoother.current = 990.0;
    const v_last = smoother.next();
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0), v_last, 1e-6);
}

test "Smoother logarithmic geometric progression" {
    var smoother = Smoother.init(100.0, .{ .logarithmic = 10.0 });
    const sample_rate = 1000.0;

    smoother.setTarget(sample_rate, 1000.0);

    // The ratio between consecutive samples should be constant (geometric progression)
    const v1 = smoother.next();
    const v2 = smoother.next();
    const v3 = smoother.next();

    const ratio1 = v2 / v1;
    const ratio2 = v3 / v2;
    try std.testing.expectApproxEqAbs(ratio1, ratio2, 1e-4);
}

test "Smoother logarithmic handles zero gracefully" {
    var smoother = Smoother.init(0.0, .{ .logarithmic = 10.0 });
    const sample_rate = 1000.0;

    // Should snap immediately when starting from 0
    smoother.setTarget(sample_rate, 100.0);
    try std.testing.expectEqual(@as(u32, 0), smoother.steps_left);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), smoother.current, 1e-6);
}

test "Smoother logarithmic nextBlock optimization" {
    var smoother = Smoother.init(100.0, .{ .logarithmic = 100.0 });
    const sample_rate = 44100.0;

    smoother.setTarget(sample_rate, 10000.0);

    var block: [64]f32 = undefined;
    smoother.nextBlock(&block);

    // First sample should be the starting value (before stepping)
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), block[0], 1e-3);

    // Second sample should match what next() would return after one step from 100.0
    var smoother2 = Smoother.init(100.0, .{ .logarithmic = 100.0 });
    smoother2.setTarget(sample_rate, 10000.0);
    const expected_second = smoother2.next();
    try std.testing.expectApproxEqAbs(expected_second, block[1], 1e-3);

    // Values should be monotonically increasing
    for (block[0 .. block.len - 1], block[1..]) |curr, next_val| {
        try std.testing.expect(next_val > curr);
    }
}
