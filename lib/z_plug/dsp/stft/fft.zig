// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Thin wrapper over KissFFT C API for real-valued FFTs.
const c = @cImport({
    @cInclude("kiss_fftr.h");
});

/// FFT plan handle for real-valued forward and inverse transforms.
pub const FftPlan = struct {
    fft_cfg: c.kiss_fftr_cfg,
    ifft_cfg: c.kiss_fftr_cfg,
    size: usize,

    /// Initialize forward and inverse FFT plans.
    /// Returns null if allocation fails.
    pub fn init(size: usize) ?FftPlan {
        const fft_cfg = c.kiss_fftr_alloc(@intCast(size), 0, null, null);
        if (fft_cfg == null) return null;

        const ifft_cfg = c.kiss_fftr_alloc(@intCast(size), 1, null, null);
        if (ifft_cfg == null) {
            c.kiss_fftr_free(fft_cfg);
            return null;
        }

        return FftPlan{
            .fft_cfg = fft_cfg,
            .ifft_cfg = ifft_cfg,
            .size = size,
        };
    }

    /// Free FFT plans.
    pub fn deinit(self: *FftPlan) void {
        c.kiss_fftr_free(self.fft_cfg);
        c.kiss_fftr_free(self.ifft_cfg);
    }

    /// Forward real FFT: time domain (f32) -> frequency domain (complex).
    /// `time_in` must be size samples, `freq_out` must be (size/2 + 1) bins.
    pub fn forward(self: *FftPlan, time_in: []const f32, freq_out: []c.kiss_fft_cpx) void {
        c.kiss_fftr(self.fft_cfg, time_in.ptr, freq_out.ptr);
    }

    /// Inverse real FFT: frequency domain (complex) -> time domain (f32).
    /// `freq_in` must be (size/2 + 1) bins, `time_out` must be size samples.
    pub fn inverse(self: *FftPlan, freq_in: []const c.kiss_fft_cpx, time_out: []f32) void {
        c.kiss_fftri(self.ifft_cfg, freq_in.ptr, time_out.ptr);
    }
};

/// Complex number type from KissFFT.
pub const Complex = c.kiss_fft_cpx;
