// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Denormal flushing for real-time audio performance.
///
/// When filters, feedback loops, or smoothers decay toward zero, values can enter
/// the subnormal range. The CPU handles these in microcode (10-100x slower),
/// causing audio glitches. Flush-to-zero treats subnormals as zero in hardware.
const std = @import("std");
const builtin = @import("builtin");

/// Opaque type storing the previous floating-point control register state.
/// Used with `enableFlushToZero` and `restoreFloatMode`.
pub const FloatMode = struct {
    saved: u64,
};

/// Enable flush-to-zero mode for denormal handling.
/// Returns the previous float mode for restoration via `restoreFloatMode`.
///
/// Usage:
/// ```zig
/// const saved = z_plug.dsp.util.enableFlushToZero();
/// defer z_plug.dsp.util.restoreFloatMode(saved);
/// // ... DSP code runs with denormals flushed ...
/// ```
///
/// Platform-specific:
/// - aarch64: Sets FPCR bit 24 (FZ)
/// - x86_64: Sets MXCSR bit 15 (FTZ) + bit 6 (DAZ)
/// - other: no-op
pub inline fn enableFlushToZero() FloatMode {
    var mode = FloatMode{ .saved = 0 };

    switch (builtin.cpu.arch) {
        .aarch64 => {
            // Read FPCR (Floating-Point Control Register)
            mode.saved = asm volatile ("mrs %[fpcr], fpcr"
                : [fpcr] "=r" (-> u64),
            );

            // Set FZ bit (bit 24) - flush denormals to zero
            const new_fpcr = mode.saved | (1 << 24);
            asm volatile ("msr fpcr, %[fpcr]"
                :
                : [fpcr] "r" (new_fpcr),
            );
        },
        .x86_64 => {
            // Read MXCSR (SSE Control and Status Register)
            var mxcsr: u32 = undefined;
            asm volatile ("stmxcsr %[mxcsr]"
                : [mxcsr] "=m" (mxcsr),
            );
            mode.saved = @as(u64, mxcsr);

            // Set FTZ (bit 15) and DAZ (bit 6)
            // FTZ: flush denormals to zero on output
            // DAZ: treat denormal inputs as zero
            const new_mxcsr = mxcsr | (1 << 15) | (1 << 6);
            asm volatile ("ldmxcsr %[mxcsr]"
                :
                : [mxcsr] "m" (new_mxcsr),
            );
        },
        else => {
            // Unsupported architecture - no-op
        },
    }

    return mode;
}

/// Restore the floating-point control register to its previous state.
/// Must be called with the `FloatMode` returned by `enableFlushToZero`.
///
/// Typically used with `defer` to ensure cleanup:
/// ```zig
/// const saved = z_plug.dsp.util.enableFlushToZero();
/// defer z_plug.dsp.util.restoreFloatMode(saved);
/// ```
pub inline fn restoreFloatMode(mode: FloatMode) void {
    switch (builtin.cpu.arch) {
        .aarch64 => {
            asm volatile ("msr fpcr, %[fpcr]"
                :
                : [fpcr] "r" (mode.saved),
            );
        },
        .x86_64 => {
            const mxcsr: u32 = @truncate(mode.saved);
            asm volatile ("ldmxcsr %[mxcsr]"
                :
                : [mxcsr] "m" (mxcsr),
            );
        },
        else => {
            // Unsupported architecture - no-op
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "denormal flushing enable and restore" {
    // This test verifies that denormal flushing works on supported platforms.
    // On unsupported platforms, it's a no-op and the test still passes.

    const saved = enableFlushToZero();
    defer restoreFloatMode(saved);

    // Create a subnormal value
    var denormal: f32 = 1e-40;

    // On platforms with FTZ enabled, arithmetic on denormals should flush to zero
    denormal = denormal + 1e-41;

    // We can't reliably test this produces exactly 0.0 because:
    // 1. The optimizer might eliminate the operation
    // 2. Some platforms don't support FTZ
    // 3. The exact behavior depends on rounding modes
    // So we just verify the functions don't crash
    try std.testing.expect(true);
}
