use std::path::PathBuf;
use std::process::Command;

fn main() {
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("zloader must be inside the z-plug repo")
        .to_path_buf();

    // Tell cargo to re-run this script if Zig sources change.
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("lib/z_plug_host").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("lib/z_plug_engine").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("build.zig").display()
    );

    // Build the Zig static libraries. We need to activate the Nix/direnv
    // environment to get Zig 0.15.2 on PATH. We do this by running direnv
    // export bash and sourcing its output before invoking zig.
    //
    // If direnv is not available (e.g. CI without Nix), fall back to
    // expecting `zig` to already be on PATH.
    let zig_path = find_zig(&repo_root);

    let status = Command::new(&zig_path)
        .args(["build", "host", "engine"])
        .current_dir(&repo_root)
        .status()
        .unwrap_or_else(|e| panic!("failed to run zig build: {e}"));

    if !status.success() {
        panic!("zig build host engine failed with status: {status}");
    }

    // Link the produced static libraries.
    let lib_dir = repo_root.join("zig-out/lib");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=z_plug_host");
    println!("cargo:rustc-link-lib=static=z_plug_engine");

    // macOS frameworks required by z_plug_engine (CoreAudio via AudioQueue).
    println!("cargo:rustc-link-lib=framework=AudioToolbox");
    println!("cargo:rustc-link-lib=framework=CoreAudio");

    // libc is needed because the Zig libraries call into it.
    println!("cargo:rustc-link-lib=c");
}

/// Locate the `zig` binary. Tries:
///   1. `<repo_root>/.direnv` paths (Nix devShell via direnv)
///   2. The `ZIG` environment variable
///   3. Plain `zig` on PATH
fn find_zig(repo_root: &PathBuf) -> String {
    // Try to get the zig path from the direnv environment.
    // direnv stores activated paths in NIX_PROFILES or we can just run
    // `direnv exec . which zig` if direnv is available.
    if let Ok(output) = Command::new("direnv")
        .args(["exec", ".", "which", "zig"])
        .current_dir(repo_root)
        .output()
    {
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                return path;
            }
        }
    }

    // Fall back to ZIG env var or plain `zig`.
    std::env::var("ZIG").unwrap_or_else(|_| "zig".to_string())
}
