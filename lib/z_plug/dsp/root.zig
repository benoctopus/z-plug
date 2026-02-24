// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// DSP building blocks namespace.
///
/// Contains utility functions, metering tools, and spectral processing (STFT) for plugin authors.
pub const util = @import("util/root.zig");
pub const metering = @import("metering/root.zig");
pub const stft = @import("stft/root.zig");
