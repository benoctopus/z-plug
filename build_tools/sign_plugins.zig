const std = @import("std");
const builtin = @import("builtin");

const Color = enum {
    red,
    green,
    yellow,
    none,

    fn code(self: Color) []const u8 {
        return switch (self) {
            .red => "\x1b[0;31m",
            .green => "\x1b[0;32m",
            .yellow => "\x1b[1;33m",
            .none => "\x1b[0m",
        };
    }

    fn print(self: Color, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("{s}" ++ fmt ++ "{s}", .{self.code()} ++ args ++ .{Color.none.code()});
    }
};

fn signPlugins(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .macos) {
        Color.yellow.print("Code signing is only supported on macOS\n", .{});
        return error.UnsupportedOS;
    }
    
    const plugin_dir = "zig-out/plugins";
    
    Color.yellow.print("Signing plugins with ad-hoc signature...\n\n", .{});
    
    // Check if plugins directory exists
    var dir = std.fs.cwd().openDir(plugin_dir, .{ .iterate = true }) catch {
        Color.red.print("Error: Plugin directory '{s}' not found\n", .{plugin_dir});
        std.debug.print("Run 'zig build' first to build the plugins\n", .{});
        return error.NoBuildDir;
    };
    defer dir.close();
    
    // Sign CLAP plugins
    std.debug.print("Signing CLAP plugins...\n", .{});
    var clap_count: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".clap")) {
            Color.green.print("  → Signing {s}\n", .{entry.name});
            
            const plugin_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_dir, entry.name });
            defer allocator.free(plugin_path);
            
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "codesign", "--force", "--deep", "--sign", "-", plugin_path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            
            if (result.term.Exited != 0) {
                Color.red.print("  ✗ Failed to sign {s}\n", .{entry.name});
                if (result.stderr.len > 0) {
                    std.debug.print("     {s}\n", .{result.stderr});
                }
            } else {
                clap_count += 1;
            }
        }
    }
    
    if (clap_count == 0) {
        Color.yellow.print("  No CLAP plugins found\n", .{});
    }
    
    // Sign VST3 plugins
    std.debug.print("\nSigning VST3 plugins...\n", .{});
    var vst3_count: u32 = 0;
    
    // Reset iterator
    dir.close();
    dir = try std.fs.cwd().openDir(plugin_dir, .{ .iterate = true });
    iter = dir.iterate();
    
    while (try iter.next()) |entry| {
        if (entry.kind == .directory and std.mem.endsWith(u8, entry.name, ".vst3")) {
            Color.green.print("  → Signing {s}\n", .{entry.name});
            
            const plugin_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_dir, entry.name });
            defer allocator.free(plugin_path);
            
            // Sign the binary first
            const binary_dir = try std.fmt.allocPrint(allocator, "{s}/Contents/MacOS", .{plugin_path});
            defer allocator.free(binary_dir);
            
            var macos_dir = std.fs.cwd().openDir(binary_dir, .{ .iterate = true }) catch |err| {
                Color.yellow.print("  Warning: Could not open MacOS directory: {s}\n", .{@errorName(err)});
                continue;
            };
            defer macos_dir.close();
            
            var binary_iter = macos_dir.iterate();
            while (try binary_iter.next()) |binary_entry| {
                if (binary_entry.kind == .file) {
                    const binary_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ binary_dir, binary_entry.name });
                    defer allocator.free(binary_path);
                    
                    _ = try std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "codesign", "--force", "--sign", "-", binary_path },
                    });
                }
            }
            
            // Sign the bundle
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "codesign", "--force", "--deep", "--sign", "-", plugin_path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            
            if (result.term.Exited != 0) {
                Color.red.print("  ✗ Failed to sign {s}\n", .{entry.name});
                if (result.stderr.len > 0) {
                    std.debug.print("     {s}\n", .{result.stderr});
                }
                continue;
            }
            
            // Verify signature
            Color.green.print("  → Verifying signature...\n", .{});
            const verify_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "codesign", "--verify", "--deep", "--strict", plugin_path },
            });
            defer allocator.free(verify_result.stdout);
            defer allocator.free(verify_result.stderr);
            
            if (verify_result.term.Exited == 0) {
                Color.green.print("  ✓ Signature valid\n", .{});
                vst3_count += 1;
            } else {
                Color.red.print("  ✗ Signature verification failed\n", .{});
            }
        }
    }
    
    if (vst3_count == 0) {
        Color.yellow.print("  No VST3 plugins found\n", .{});
    }
    
    // Summary
    std.debug.print("\n", .{});
    Color.green.print("═══════════════════════════════════════\n", .{});
    if (clap_count + vst3_count == 0) {
        Color.yellow.print("No plugins were signed\n", .{});
        std.debug.print("Make sure to build the plugins first with 'zig build'\n", .{});
        return error.NoPlugins;
    } else {
        Color.green.print("Signing complete!\n", .{});
        std.debug.print("Signed {d} CLAP + {d} VST3 plugin(s)\n\n", .{ clap_count, vst3_count });
        Color.yellow.print("Note: Plugins are signed with ad-hoc signature\n", .{});
        std.debug.print("This works for local testing but not for distribution\n\n", .{});
        std.debug.print("Run 'zig build install-plugins' to install the signed plugins\n", .{});
    }
    Color.green.print("═══════════════════════════════════════\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try signPlugins(allocator);
}
