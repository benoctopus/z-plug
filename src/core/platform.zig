/// Platform-specific constants and utilities.
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
