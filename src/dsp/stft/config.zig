// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// STFT configuration types.

/// STFT processor configuration (comptime).
pub const StftConfig = struct {
    fft_size: comptime_int = 1024,
    hop_size: comptime_int = 256,
    max_channels: comptime_int = 2,
};

/// Spectral processing context passed to effect callbacks.
pub const SpectralContext = struct {
    sample_rate: f32,
    fft_size: usize,
    hop_size: usize,
    num_bins: usize,
};
