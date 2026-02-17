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

fn installPlugins(allocator: std.mem.Allocator, system: bool) !void {
    const dirs = try getPluginDirs(allocator, system);
    const plugin_build_dir = "zig-out/plugins";
    
    if (system) {
        Color.yellow.print("Installing to SYSTEM directories (requires sudo on macOS/Linux)\n", .{});
    } else {
        Color.green.print("Installing to USER directories\n", .{});
    }
    
    // Check if build directory exists
    var build_dir = std.fs.cwd().openDir(plugin_build_dir, .{ .iterate = true }) catch {
        Color.red.print("Error: Plugin directory '{s}' not found\n", .{plugin_build_dir});
        Color.none.print("Run 'zig build' first to build the plugins\n", .{});
        return error.NoBuildDir;
    };
    defer build_dir.close();
    
    // Sign plugins automatically on macOS before installing
    if (builtin.os.tag == .macos) {
        Color.yellow.print("\nSigning plugins with ad-hoc signature (macOS)...\n", .{});
        signPluginsInPlace(allocator, plugin_build_dir) catch |err| {
            Color.yellow.print("Warning: Failed to sign plugins: {s}\n", .{@errorName(err)});
            Color.yellow.print("Continuing with unsigned plugins (they may not load in some DAWs)\n\n", .{});
        };
    }
    
    // Create target directories
    std.debug.print("Creating target directories if needed...\n", .{});
    std.fs.cwd().makePath(dirs.clap) catch |err| {
        if (err != error.PathAlreadyExists) {
            Color.red.print("Failed to create CLAP directory: {s}\n", .{@errorName(err)});
            if (system) {
                Color.yellow.print("Hint: You may need to run with sudo on macOS/Linux\n", .{});
            }
            return err;
        }
    };
    std.fs.cwd().makePath(dirs.vst3) catch |err| {
        if (err != error.PathAlreadyExists) {
            Color.red.print("Failed to create VST3 directory: {s}\n", .{@errorName(err)});
            if (system) {
                Color.yellow.print("Hint: You may need to run with sudo on macOS/Linux\n", .{});
            }
            return err;
        }
    };
    
    // Install CLAP plugins
    std.debug.print("\nInstalling CLAP plugins...\n", .{});
    var clap_count: u32 = 0;
    var iter = build_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".clap")) {
            Color.green.print("  → Installing {s}\n", .{entry.name});
            
            const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_build_dir, entry.name });
            defer allocator.free(source_path);
            
            const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dirs.clap, entry.name });
            defer allocator.free(dest_path);
            
            try std.fs.cwd().copyFile(source_path, std.fs.cwd(), dest_path, .{});
            clap_count += 1;
        }
    }
    
    if (clap_count == 0) {
        Color.yellow.print("  No CLAP plugins found\n", .{});
    } else {
        Color.green.print("  ✓ Installed {d} CLAP plugin(s) to {s}\n", .{ clap_count, dirs.clap });
    }
    
    // Install VST3 plugins
    std.debug.print("\nInstalling VST3 plugins...\n", .{});
    var vst3_count: u32 = 0;
    
    // Reset iterator
    build_dir.close();
    build_dir = try std.fs.cwd().openDir(plugin_build_dir, .{ .iterate = true });
    iter = build_dir.iterate();
    
    while (try iter.next()) |entry| {
        if (entry.kind == .directory and std.mem.endsWith(u8, entry.name, ".vst3")) {
            Color.green.print("  → Installing {s}\n", .{entry.name});
            
            const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_build_dir, entry.name });
            defer allocator.free(source_path);
            
            const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dirs.vst3, entry.name });
            defer allocator.free(dest_path);
            
            // Remove existing installation if present
            std.fs.cwd().deleteTree(dest_path) catch |err| {
                if (err != error.FileNotFound) {
                    Color.yellow.print("  Warning: Could not remove existing {s}: {s}\n", .{ entry.name, @errorName(err) });
                }
            };
            
            // Copy directory recursively
            var source_dir = try std.fs.cwd().openDir(source_path, .{ .iterate = true });
            defer source_dir.close();
            
            try copyDirRecursive(allocator, source_dir, source_path, dest_path);
            vst3_count += 1;
        }
    }
    
    if (vst3_count == 0) {
        Color.yellow.print("  No VST3 plugins found\n", .{});
    } else {
        Color.green.print("  ✓ Installed {d} VST3 plugin(s) to {s}\n", .{ vst3_count, dirs.vst3 });
    }
    
    // Summary
    std.debug.print("\n", .{});
    Color.green.print("═══════════════════════════════════════\n", .{});
    if (clap_count + vst3_count == 0) {
        Color.yellow.print("No plugins were installed\n", .{});
        std.debug.print("Make sure to build the plugins first with 'zig build'\n", .{});
        return error.NoPlugins;
    } else {
        Color.green.print("Installation complete!\n", .{});
        std.debug.print("Installed {d} CLAP + {d} VST3 plugin(s)\n\n", .{ clap_count, vst3_count });
        std.debug.print("Restart your DAW to see the new plugins\n", .{});
    }
    Color.green.print("═══════════════════════════════════════\n", .{});
}

fn copyDirRecursive(allocator: std.mem.Allocator, source_dir: std.fs.Dir, source_path: []const u8, dest_path: []const u8) !void {
    // Create destination directory
    try std.fs.cwd().makePath(dest_path);
    
    var iter = source_dir.iterate();
    while (try iter.next()) |entry| {
        const source_entry = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_path, entry.name });
        defer allocator.free(source_entry);
        
        const dest_entry = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_path, entry.name });
        defer allocator.free(dest_entry);
        
        switch (entry.kind) {
            .file => {
                try std.fs.cwd().copyFile(source_entry, std.fs.cwd(), dest_entry, .{});
            },
            .directory => {
                var sub_dir = try std.fs.cwd().openDir(source_entry, .{ .iterate = true });
                defer sub_dir.close();
                try copyDirRecursive(allocator, sub_dir, source_entry, dest_entry);
            },
            else => {},
        }
    }
}

fn signPluginsInPlace(allocator: std.mem.Allocator, plugin_dir: []const u8) !void {
    var dir = try std.fs.cwd().openDir(plugin_dir, .{ .iterate = true });
    defer dir.close();
    
    var signed_count: u32 = 0;
    
    // Sign CLAP plugins
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
            
            if (result.term.Exited == 0) {
                signed_count += 1;
            } else {
                Color.yellow.print("  Warning: Failed to sign {s}\n", .{entry.name});
            }
        }
    }
    
    // Sign VST3 plugins
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
            
            var macos_dir = std.fs.cwd().openDir(binary_dir, .{ .iterate = true }) catch continue;
            defer macos_dir.close();
            
            var binary_iter = macos_dir.iterate();
            while (try binary_iter.next()) |binary_entry| {
                if (binary_entry.kind == .file) {
                    const binary_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ binary_dir, binary_entry.name });
                    defer allocator.free(binary_path);
                    
                    _ = std.process.Child.run(.{
                        .allocator = allocator,
                        .argv = &[_][]const u8{ "codesign", "--force", "--sign", "-", binary_path },
                    }) catch continue;
                }
            }
            
            // Sign the bundle
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "codesign", "--force", "--deep", "--sign", "-", plugin_path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            
            if (result.term.Exited == 0) {
                signed_count += 1;
            } else {
                Color.yellow.print("  Warning: Failed to sign {s}\n", .{entry.name});
            }
        }
    }
    
    if (signed_count > 0) {
        Color.green.print("  ✓ Signed {d} plugin(s)\n\n", .{signed_count});
    }
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
    
    try installPlugins(allocator, system);
}
