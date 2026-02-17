// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// STFT (Short-Time Fourier Transform) processing module.
///
/// Provides a comptime-parameterized STFT engine that handles all the boilerplate
/// (ring buffers, windowing, FFT, overlap-add) while allowing plugin authors to
/// focus solely on the spectral processing logic.
pub const StftProcessor = @import("processor.zig").StftProcessor;
pub const StftConfig = @import("config.zig").StftConfig;
pub const SpectralContext = @import("config.zig").SpectralContext;
pub const Complex = @import("fft.zig").Complex;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
