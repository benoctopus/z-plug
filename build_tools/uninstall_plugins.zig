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

const PluginDirs = struct {
    clap: []const u8,
    vst3: []const u8,
};

fn getPluginDirs(allocator: std.mem.Allocator, system: bool) !PluginDirs {
    const os_tag = builtin.os.tag;
    
    if (system) {
        return switch (os_tag) {
            .macos => PluginDirs{
                .clap = "/Library/Audio/Plug-Ins/CLAP",
                .vst3 = "/Library/Audio/Plug-Ins/VST3",
            },
            .linux => PluginDirs{
                .clap = "/usr/lib/clap",
                .vst3 = "/usr/lib/vst3",
            },
            .windows => PluginDirs{
                .clap = "C:\\Program Files\\Common Files\\CLAP",
                .vst3 = "C:\\Program Files\\Common Files\\VST3",
            },
            else => error.UnsupportedOS,
        };
    } else {
        // User directories
        const home = std.posix.getenv("HOME") orelse std.posix.getenv("USERPROFILE") orelse return error.NoHomeDir;
        
        return switch (os_tag) {
            .macos => PluginDirs{
                .clap = try std.fmt.allocPrint(allocator, "{s}/Library/Audio/Plug-Ins/CLAP", .{home}),
                .vst3 = try std.fmt.allocPrint(allocator, "{s}/Library/Audio/Plug-Ins/VST3", .{home}),
            },
            .linux => PluginDirs{
                .clap = try std.fmt.allocPrint(allocator, "{s}/.clap", .{home}),
                .vst3 = try std.fmt.allocPrint(allocator, "{s}/.vst3", .{home}),
            },
            .windows => blk: {
                const appdata = std.posix.getenv("APPDATA") orelse return error.NoAppData;
                break :blk PluginDirs{
                    .clap = try std.fmt.allocPrint(allocator, "{s}\\CLAP", .{appdata}),
                    .vst3 = try std.fmt.allocPrint(allocator, "{s}\\VST3", .{appdata}),
                };
            },
            else => error.UnsupportedOS,
        };
    }
}

fn uninstallPlugins(allocator: std.mem.Allocator, system: bool) !void {
    const dirs = try getPluginDirs(allocator, system);
    const plugin_build_dir = "zig-out/plugins";
    
    if (system) {
        Color.green.print("Removing from SYSTEM directories (requires sudo on macOS/Linux)\n", .{});
    } else {
        Color.green.print("Removing from USER directories\n", .{});
    }
    std.debug.print("\n", .{});
    
    var removed_count: u32 = 0;
    
    // Check if build directory exists to get list of plugins
    var build_dir = std.fs.cwd().openDir(plugin_build_dir, .{ .iterate = true }) catch {
        Color.yellow.print("Warning: Build directory '{s}' not found\n", .{plugin_build_dir});
        Color.yellow.print("Will only remove plugins that match known patterns\n\n", .{});
        return error.NoBuildDir;
    };
    defer build_dir.close();
    
    // Remove CLAP plugins
    std.debug.print("Checking CLAP directory: {s}\n", .{dirs.clap});
    if (std.fs.cwd().openDir(dirs.clap, .{ .iterate = true })) |mut_clap_dir| {
        var clap_dir = mut_clap_dir;
        defer clap_dir.close();
        
        var iter = build_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".clap")) {
                const target_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dirs.clap, entry.name });
                defer allocator.free(target_path);
                
                std.fs.cwd().deleteFile(target_path) catch |err| {
                    if (err != error.FileNotFound) {
                        Color.yellow.print("  Warning: Could not remove {s}: {s}\n", .{ entry.name, @errorName(err) });
                        continue;
                    }
                    continue;
                };
                
                Color.red.print("  ✗ Removing {s}\n", .{entry.name});
                removed_count += 1;
            }
        }
    } else |err| {
        if (err == error.FileNotFound) {
            Color.yellow.print("  CLAP directory does not exist\n", .{});
        } else {
            Color.red.print("  Error accessing CLAP directory: {s}\n", .{@errorName(err)});
        }
    }
    
    // Remove VST3 plugins
    std.debug.print("Checking VST3 directory: {s}\n", .{dirs.vst3});
    if (std.fs.cwd().openDir(dirs.vst3, .{ .iterate = true })) |mut_vst3_dir| {
        var vst3_dir = mut_vst3_dir;
        defer vst3_dir.close();
        
        // Reset build dir iterator
        build_dir.close();
        build_dir = try std.fs.cwd().openDir(plugin_build_dir, .{ .iterate = true });
        
        var iter = build_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory and std.mem.endsWith(u8, entry.name, ".vst3")) {
                const target_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dirs.vst3, entry.name });
                defer allocator.free(target_path);
                
                std.fs.cwd().deleteTree(target_path) catch |err| {
                    if (err != error.FileNotFound) {
                        Color.yellow.print("  Warning: Could not remove {s}: {s}\n", .{ entry.name, @errorName(err) });
                        continue;
                    }
                    continue;
                };
                
                Color.red.print("  ✗ Removing {s}\n", .{entry.name});
                removed_count += 1;
            }
        }
    } else |err| {
        if (err == error.FileNotFound) {
            Color.yellow.print("  VST3 directory does not exist\n", .{});
        } else {
            Color.red.print("  Error accessing VST3 directory: {s}\n", .{@errorName(err)});
        }
    }
    
    // Summary
    std.debug.print("\n", .{});
    Color.green.print("═══════════════════════════════════════\n", .{});
    if (removed_count == 0) {
        Color.yellow.print("No zig-plug plugins found to remove\n", .{});
    } else {
        Color.green.print("Uninstallation complete!\n", .{});
        std.debug.print("Removed {d} plugin(s)\n\n", .{removed_count});
        std.debug.print("Restart your DAW and rescan plugins to complete removal\n", .{});
    }
    Color.green.print("═══════════════════════════════════════\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    
    _ = args.skip(); // Skip program name
    
    var system = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--system")) {
            system = true;
        } else if (std.mem.eql(u8, arg, "--user")) {
            system = false;
        }
    }
    
    try uninstallPlugins(allocator, system);
}
