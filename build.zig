const std = @import("std");

/// Plugin format options.
pub const PluginFormat = struct {
    clap: bool = false,
    vst3: bool = false,
};

/// Plugin build options for external consumers.
pub const PluginOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    formats: PluginFormat,
};

/// Add a plugin build target (for external plugin repos).
///
/// This is the main entry point for external repositories consuming z_plug as a dependency.
/// Pass the dependency object obtained from `b.dependency("z_plug", ...)`.
///
/// Example:
/// ```zig
/// const z_plug = @import("z_plug");
/// const dep = b.dependency("z_plug", .{ .target = target, .optimize = optimize });
/// z_plug.addPlugin(b, dep, .{
///     .name = "MyPlugin",
///     .root_source_file = b.path("src/plugin.zig"),
///     .target = target,
///     .optimize = optimize,
///     .formats = .{ .clap = true, .vst3 = true },
/// });
/// ```
pub fn addPlugin(
    b: *std.Build,
    dep: *std.Build.Dependency,
    options: PluginOptions,
) void {
    addPluginWithModule(b, dep.module("z_plug"), options);
}

/// Add a plugin build target with a direct module reference (internal/advanced use).
///
/// This lower-level function accepts a *Module directly instead of a dependency.
/// Used internally by the z_plug build system to build examples.
pub fn addPluginWithModule(
    b: *std.Build,
    z_plug_mod: *std.Build.Module,
    options: PluginOptions,
) void {
    
    // Build CLAP plugin
    if (options.formats.clap) {
        const clap_lib = b.addLibrary(.{
            .name = options.name,
            .root_module = b.createModule(.{
                .root_source_file = options.root_source_file,
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "z_plug", .module = z_plug_mod },
                },
            }),
            .linkage = .dynamic,
        });
        
        // Install as .clap
        const install_clap = b.addInstallArtifact(clap_lib, .{
            .dest_dir = .{ .override = .{ .custom = "plugins" } },
        });
        
        // Rename to .clap extension
        const clap_rename = b.addInstallFile(
            clap_lib.getEmittedBin(),
            b.fmt("plugins/{s}.clap", .{options.name}),
        );
        clap_rename.step.dependOn(&install_clap.step);
        
        b.getInstallStep().dependOn(&clap_rename.step);
    }
    
    // Build VST3 plugin
    if (options.formats.vst3) {
        const vst3_lib = b.addLibrary(.{
            .name = options.name,
            .root_module = b.createModule(.{
                .root_source_file = options.root_source_file,
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "z_plug", .module = z_plug_mod },
                },
            }),
            .linkage = .dynamic,
        });
        
        // Install as VST3 bundle
        const target_info = options.target.result;
        if (target_info.os.tag == .macos) {
            // macOS bundle structure: MyPlugin.vst3/Contents/MacOS/MyPlugin
            const bundle_dir = b.fmt("plugins/{s}.vst3/Contents/MacOS", .{options.name});
            const install_vst3 = b.addInstallArtifact(vst3_lib, .{
                .dest_dir = .{ .override = .{ .custom = bundle_dir } },
            });
            
            // Rename libZigGain.dylib to ZigGain (macOS bundle executable)
            const rename_binary = b.addInstallFile(
                vst3_lib.getEmittedBin(),
                b.fmt("plugins/{s}.vst3/Contents/MacOS/{s}", .{options.name, options.name}),
            );
            rename_binary.step.dependOn(&install_vst3.step);
            
            // Generate Info.plist
            const info_plist_content = b.fmt(
                \\<?xml version="1.0" encoding="UTF-8"?>
                \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                \\<plist version="1.0">
                \\  <dict>
                \\    <key>CFBundleExecutable</key>
                \\    <string>{s}</string>
                \\    <key>CFBundleIdentifier</key>
                \\    <string>com.zplugin.{s}</string>
                \\    <key>CFBundleName</key>
                \\    <string>{s}</string>
                \\    <key>CFBundlePackageType</key>
                \\    <string>BNDL</string>
                \\    <key>CFBundleSignature</key>
                \\    <string>????</string>
                \\    <key>CFBundleVersion</key>
                \\    <string>1.0.0</string>
                \\    <key>NSHighResolutionCapable</key>
                \\    <true/>
                \\  </dict>
                \\</plist>
                \\
            , .{options.name, options.name, options.name});
            
            const write_files = b.addWriteFiles();
            const info_plist_file = write_files.add("Info.plist", info_plist_content);
            const pkginfo_file = write_files.add("PkgInfo", "BNDL????");
            
            const info_plist_path = b.fmt("plugins/{s}.vst3/Contents/Info.plist", .{options.name});
            const install_info_plist = b.addInstallFile(info_plist_file, info_plist_path);
            
            const pkginfo_path = b.fmt("plugins/{s}.vst3/Contents/PkgInfo", .{options.name});
            const install_pkginfo = b.addInstallFile(pkginfo_file, pkginfo_path);
            
            b.getInstallStep().dependOn(&rename_binary.step);
            b.getInstallStep().dependOn(&install_info_plist.step);
            b.getInstallStep().dependOn(&install_pkginfo.step);
        } else {
            // Linux/Windows: just install as .vst3
            const install_vst3 = b.addInstallArtifact(vst3_lib, .{
                .dest_dir = .{ .override = .{ .custom = "plugins" } },
            });
            
            const vst3_rename = b.addInstallFile(
                vst3_lib.getEmittedBin(),
                b.fmt("plugins/{s}.vst3", .{options.name}),
            );
            vst3_rename.step.dependOn(&install_vst3.step);
            
            b.getInstallStep().dependOn(&vst3_rename.step);
        }
    }
}

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // Low-level bindings modules for CLAP and VST3
    const clap_bindings = b.addModule("clap-bindings", .{
        .root_source_file = b.path("lib/z_plug/bindings/clap/main.zig"),
        .target = target,
    });

    // -----------------------------------------------------------------------
    // z_plug_host — CLAP plugin host library
    // -----------------------------------------------------------------------
    const z_plug_host_mod = b.addModule("z_plug_host", .{
        .root_source_file = b.path("lib/z_plug_host/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clap-bindings", .module = clap_bindings },
        },
    });

    // Static library for C/Rust FFI consumers
    const z_plug_host_lib = b.addLibrary(.{
        .name = "z_plug_host",
        .root_module = z_plug_host_mod,
        .linkage = .static,
    });
    z_plug_host_lib.linkLibC();

    const host_step = b.step("host", "Build the z_plug_host static library");
    host_step.dependOn(&b.addInstallArtifact(z_plug_host_lib, .{}).step);

    // Host library tests
    const host_tests = b.addTest(.{
        .root_module = z_plug_host_mod,
    });

    // -----------------------------------------------------------------------
    // z_plug_engine — CoreAudio audio engine library (macOS only)
    // -----------------------------------------------------------------------
    const z_plug_engine_mod = b.addModule("z_plug_engine", .{
        .root_source_file = b.path("lib/z_plug_engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "z_plug_host", .module = z_plug_host_mod },
            .{ .name = "clap-bindings", .module = clap_bindings },
        },
    });

    // Static library for C/Rust FFI consumers
    const z_plug_engine_lib = b.addLibrary(.{
        .name = "z_plug_engine",
        .root_module = z_plug_engine_mod,
        .linkage = .static,
    });
    z_plug_engine_lib.linkLibC();

    // Link CoreAudio frameworks on macOS.
    // When building under Nix, the SDK root may not be in the default search
    // path, so we add it explicitly via the SDKROOT environment variable.
    // We also clear NIX_CFLAGS_COMPILE to avoid Zig treating Nix's
    // -fmacro-prefix-map flags as errors.
    if (target.result.os.tag == .macos) {
        if (std.process.getEnvVarOwned(b.allocator, "SDKROOT") catch null) |sdk_root| {
            defer b.allocator.free(sdk_root);
            const frameworks_path = b.pathJoin(&.{ sdk_root, "System/Library/Frameworks" });
            z_plug_engine_lib.addFrameworkPath(.{ .cwd_relative = frameworks_path });
        }
        z_plug_engine_lib.linkFramework("AudioToolbox");
        z_plug_engine_lib.linkFramework("CoreAudio");
    }

    const engine_step = b.step("engine", "Build the z_plug_engine static library");
    engine_step.dependOn(&b.addInstallArtifact(z_plug_engine_lib, .{}).step);

    // Engine library tests
    const engine_tests = b.addTest(.{
        .root_module = z_plug_engine_mod,
    });

    const vst3_bindings = b.addModule("vst3-bindings", .{
        .root_source_file = b.path("lib/z_plug/bindings/vst3/root.zig"),
        .target = target,
    });

    // Main framework module
    const mod = b.addModule("z_plug", .{
        .root_source_file = b.path("lib/z_plug/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "clap-bindings", .module = clap_bindings },
            .{ .name = "vst3-bindings", .module = vst3_bindings },
        },
    });

    // KissFFT C library (BSD-3-Clause, vendored)
    // Used by STFT module for real-valued FFT operations
    const kissfft_lib = b.addLibrary(.{
        .name = "kissfft",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    kissfft_lib.addCSourceFiles(.{
        .files = &.{
            "vendor/kissfft/kiss_fft.c",
            "vendor/kissfft/kiss_fftr.c",
        },
        .flags = &.{"-DNDEBUG"}, // Disable KissFFT debug logging
    });
    kissfft_lib.addIncludePath(b.path("vendor/kissfft"));
    kissfft_lib.linkLibC();

    // Link KissFFT to the z_plug module so STFT can use it
    mod.addIncludePath(b.path("vendor/kissfft"));
    mod.linkLibrary(kissfft_lib);

    // Build example gain plugin
    addPluginWithModule(b, mod, .{
        .name = "ZigGain",
        .root_source_file = b.path("examples/gain/src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .formats = .{ .clap = true, .vst3 = true },
    });

    // Build example super gain plugin (feature showcase)
    addPluginWithModule(b, mod, .{
        .name = "ZigSuperGain",
        .root_source_file = b.path("examples/super_gain/src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .formats = .{ .clap = true, .vst3 = true },
    });

    // Build example polyphonic synth plugin (MIDI + voice management showcase)
    addPluginWithModule(b, mod, .{
        .name = "ZigPolySynth",
        .root_source_file = b.path("examples/poly_synth/src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .formats = .{ .clap = true, .vst3 = true },
    });

    // Build example spectral processing plugin (STFT + spectral gate)
    addPluginWithModule(b, mod, .{
        .name = "ZigSpectral",
        .root_source_file = b.path("examples/spectral/src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .formats = .{ .clap = true, .vst3 = true },
    });

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // Test the CLAP bindings
    const clap_tests = b.addTest(.{
        .root_module = clap_bindings,
    });

    // Test the VST3 bindings
    const vst3_tests = b.addTest(.{
        .root_module = vst3_bindings,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_clap_tests = b.addRunArtifact(clap_tests);
    const run_vst3_tests = b.addRunArtifact(vst3_tests);

    const run_host_tests = b.addRunArtifact(host_tests);
    const run_engine_tests = b.addRunArtifact(engine_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_clap_tests.step);
    test_step.dependOn(&run_vst3_tests.step);
    test_step.dependOn(&run_host_tests.step);
    test_step.dependOn(&run_engine_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.

    // Plugin management steps
    setupPluginManagementSteps(b, target);
}

/// Setup plugin installation, uninstallation, and signing build steps.
fn setupPluginManagementSteps(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const install_system = b.option(bool, "system", "Install to system directories (requires sudo on macOS/Linux)") orelse false;

    // Install plugins step
    const install_plugins_step = b.step("install-plugins", "Install built plugins to OS-standard plugin directories");
    const install_cmd = b.addSystemCommand(&[_][]const u8{"echo"});
    install_cmd.addArg("Installing plugins...");
    install_cmd.step.dependOn(b.getInstallStep());
    
    const install_run = b.addRunArtifact(b.addExecutable(.{
        .name = "install_plugins",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build_tools/install_plugins.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    }));
    
    if (install_system) {
        install_run.addArg("--system");
    } else {
        install_run.addArg("--user");
    }
    install_run.step.dependOn(&install_cmd.step);
    install_plugins_step.dependOn(&install_run.step);

    // Uninstall plugins step
    const uninstall_plugins_step = b.step("uninstall-plugins", "Uninstall plugins from OS-standard plugin directories");
    const uninstall_run = b.addRunArtifact(b.addExecutable(.{
        .name = "uninstall_plugins",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build_tools/uninstall_plugins.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    }));
    
    if (install_system) {
        uninstall_run.addArg("--system");
    } else {
        uninstall_run.addArg("--user");
    }
    uninstall_plugins_step.dependOn(&uninstall_run.step);

    // Sign plugins step (macOS only)
    if (target.result.os.tag == .macos) {
        const sign_plugins_step = b.step("sign-plugins", "Code-sign plugins with ad-hoc signature (macOS only)");
        const sign_cmd = b.addSystemCommand(&[_][]const u8{"echo"});
        sign_cmd.addArg("Signing plugins...");
        sign_cmd.step.dependOn(b.getInstallStep());
        
        const sign_run = b.addRunArtifact(b.addExecutable(.{
            .name = "sign_plugins",
            .root_module = b.createModule(.{
                .root_source_file = b.path("build_tools/sign_plugins.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }),
        }));
        sign_run.step.dependOn(&sign_cmd.step);
        sign_plugins_step.dependOn(&sign_run.step);
    }
}
