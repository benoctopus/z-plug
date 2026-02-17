/// Platform-specific constants and utilities.
const std = @import("std");
const builtin = @import("builtin");

/// L2 cache line size for the target architecture.
/// - aarch64 (Apple Silicon): 128 bytes
/// - x86_64: 64 bytes
/// - fallback: 64 bytes (conservative default)
pub const CACHE_LINE_SIZE: comptime_int = switch (builtin.cpu.arch) {
    .aarch64 => 128,
    .x86_64 => 64,
    else => 64,
};

/// Optimal SIMD vector length (in elements) for f32 on the target CPU.
/// - aarch64 NEON: 4 (128-bit / 32-bit)
/// - x86_64 AVX2: 8 (256-bit / 32-bit)
/// - x86_64 AVX-512: 16 (512-bit / 32-bit)
/// - fallback: 4 if the target has no known SIMD support
pub const SIMD_VEC_LEN: comptime_int = std.simd.suggestVectorLength(f32) orelse 4;

/// Platform-optimal f32 SIMD vector type.
/// Use this for consistent SIMD operations across the framework.
pub const F32xV = @Vector(SIMD_VEC_LEN, f32);
