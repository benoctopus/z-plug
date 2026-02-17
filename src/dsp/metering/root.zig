// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Audio metering utilities for real-time peak, RMS, and LUFS measurement.
///
/// This module provides real-time-safe metering tools conforming to industry
/// standards (ITU-R BS.1770-4 / EBU R128). All meters use pre-allocated
/// fixed-size buffers with no heap allocations at runtime.
pub const Biquad = @import("biquad.zig").Biquad;
pub const PeakMeter = @import("peak.zig").PeakMeter;
pub const RmsMeter = @import("rms.zig").RmsMeter;
pub const TruePeakMeter = @import("true_peak.zig").TruePeakMeter;
pub const LufsMeter = @import("lufs.zig").LufsMeter;
pub const max_lufs_channels = @import("lufs.zig").max_lufs_channels;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
