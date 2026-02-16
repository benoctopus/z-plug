// VST3 C API Bindings - GUID/TUID Parsing and Manipulation
// Based on SuperElectric blog and steinbergmedia/vst3_c_api

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const TUID = types.TUID;

/// Parse a GUID string at comptime into a TUID
/// Format: "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
/// Example: "00000000-0000-0000-C000-000000000046" (IUnknown)
pub fn parseGuid(comptime str: []const u8) TUID {
    var result: TUID = undefined;
    var nibble_opt: ?u8 = null;
    var idx: usize = 0;

    for (str) |char| {
        const nibble: u8 = if (char >= 'A' and char <= 'F')
            char - 'A' + 10
        else if (char >= 'a' and char <= 'f')
            char - 'a' + 10
        else if (char >= '0' and char <= '9')
            char - '0'
        else
            continue; // Skip dashes and other non-hex chars

        if (nibble_opt) |prev_nibble| {
            result[idx] = (prev_nibble << 4) | nibble;
            idx += 1;
            nibble_opt = null;
        } else {
            nibble_opt = nibble;
        }
    }

    // Non-COM: straight pass-through (works for both platforms for now)
    return result;
}

/// Construct a TUID from four 32-bit values (matches SMTG_INLINE_UID macro)
pub fn inlineUid(l1: u32, l2: u32, l3: u32, l4: u32) TUID {
    if (builtin.os.tag == .windows) {
        // Windows COM-compatible byte order
        return .{
            @truncate(l1 & 0x000000FF),
            @truncate((l1 & 0x0000FF00) >> 8),
            @truncate((l1 & 0x00FF0000) >> 16),
            @truncate((l1 & 0xFF000000) >> 24),
            @truncate((l2 & 0x00FF0000) >> 16),
            @truncate((l2 & 0xFF000000) >> 24),
            @truncate(l2 & 0x000000FF),
            @truncate((l2 & 0x0000FF00) >> 8),
            @truncate((l3 & 0xFF000000) >> 24),
            @truncate((l3 & 0x00FF0000) >> 16),
            @truncate((l3 & 0x0000FF00) >> 8),
            @truncate(l3 & 0x000000FF),
            @truncate((l4 & 0xFF000000) >> 24),
            @truncate((l4 & 0x00FF0000) >> 16),
            @truncate((l4 & 0x0000FF00) >> 8),
            @truncate(l4 & 0x000000FF),
        };
    } else {
        // Non-COM: big-endian byte order
        return .{
            @truncate((l1 & 0xFF000000) >> 24),
            @truncate((l1 & 0x00FF0000) >> 16),
            @truncate((l1 & 0x0000FF00) >> 8),
            @truncate(l1 & 0x000000FF),
            @truncate((l2 & 0xFF000000) >> 24),
            @truncate((l2 & 0x00FF0000) >> 16),
            @truncate((l2 & 0x0000FF00) >> 8),
            @truncate(l2 & 0x000000FF),
            @truncate((l3 & 0xFF000000) >> 24),
            @truncate((l3 & 0x00FF0000) >> 16),
            @truncate((l3 & 0x0000FF00) >> 8),
            @truncate(l3 & 0x000000FF),
            @truncate((l4 & 0xFF000000) >> 24),
            @truncate((l4 & 0x00FF0000) >> 16),
            @truncate((l4 & 0x0000FF00) >> 8),
            @truncate(l4 & 0x000000FF),
        };
    }
}

/// Compare two TUIDs for equality
pub fn eql(a: TUID, b: TUID) bool {
    return std.mem.eql(u8, &a, &b);
}

// Known VST3 interface GUIDs for testing
pub const IID_FUnknown = parseGuid("00000000-0000-0000-C000-000000000046");
pub const IID_IPluginBase = parseGuid("22888DDB-156E-45AE-8358-B34808190625");
pub const IID_IPluginFactory = parseGuid("7A4D811C-5211-4A1F-AED9-D2EE0B43BF9F");
pub const IID_IComponent = parseGuid("E831FF31-F2D5-4301-928E-BBEE25697802");
pub const IID_IAudioProcessor = parseGuid("42043F99-B7DA-453C-A569-E79D9AAEC33D");
pub const IID_IEditController = parseGuid("DCD7BBE3-7742-448D-A874-AACC979C759E");

test "parseGuid compiles" {
    const testing = std.testing;
    const guid = parseGuid("00000000-0000-0000-C000-000000000046");
    try testing.expectEqual(@as(usize, 16), guid.len);
}

test "inlineUid compiles" {
    const testing = std.testing;
    const guid = inlineUid(0x00000000, 0x00000000, 0xC0000000, 0x00000046);
    try testing.expectEqual(@as(usize, 16), guid.len);
}

test "eql compares correctly" {
    const testing = std.testing;
    const guid1 = parseGuid("00000000-0000-0000-C000-000000000046");
    const guid2 = parseGuid("00000000-0000-0000-C000-000000000046");
    const guid3 = parseGuid("22888DDB-156E-45AE-8358-B34808190625");
    
    try testing.expect(eql(guid1, guid2));
    try testing.expect(!eql(guid1, guid3));
}

test "known interface IDs" {
    const testing = std.testing;
    // Just verify they compile
    try testing.expectEqual(@as(usize, 16), IID_FUnknown.len);
    try testing.expectEqual(@as(usize, 16), IID_IPluginBase.len);
    try testing.expectEqual(@as(usize, 16), IID_IPluginFactory.len);
}
