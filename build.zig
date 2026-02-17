const std = @import("std");

/// Plugin format options.
pub const PluginFormat = struct {
    clap: bool = false,
    vst3: bool = false,
};

/// Add a plugin build target.
///
/// This helper function creates shared library targets for the specified
/// plugin formats (CLAP and/or VST3).
pub fn addPlugin(
    b: *std.Build,
    options: struct {
        name: []const u8,
        root_source_file: std.Build.LazyPath,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        formats: PluginFormat,
    },
) void {
    // Get the z_plug module
    const z_plug = b.modules.get("z_plug") orelse {
        @panic("z_plug module not found. Make sure build() is called first.");
    };
    
    // Build CLAP plugin
    if (options.formats.clap) {
        const clap_lib = b.addLibrary(.{
            .name = options.name,
            .root_module = b.createModule(.{
                .root_source_file = options.root_source_file,
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{
                    .{ .name = "z_plug", .module = z_plug },
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
                    .{ .name = "z_plug", .module = z_plug },
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
        .root_source_file = b.path("src/bindings/clap/main.zig"),
        .target = target,
    });

    const vst3_bindings = b.addModule("vst3-bindings", .{
        .root_source_file = b.path("src/bindings/vst3/root.zig"),
        .target = target,
    });

    // Main framework module
    const mod = b.addModule("z_plug", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "clap-bindings", .module = clap_bindings },
            .{ .name = "vst3-bindings", .module = vst3_bindings },
        },
    });

    // Build example gain plugin
    addPlugin(b, .{
        .name = "ZigGain",
        .root_source_file = b.path("examples/gain.zig"),
        .target = target,
        .optimize = optimize,
        .formats = .{ .clap = true, .vst3 = true },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "z_plug",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "z_plug" is the name you will use in your source code to
                // import this module (e.g. `@import("z_plug")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "z_plug", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

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

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_clap_tests.step);
    test_step.dependOn(&run_vst3_tests.step);
    test_step.dependOn(&run_exe_tests.step);

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
