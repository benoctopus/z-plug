{
  description = "Zig and Rust development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        rustToolchain = pkgs.rust-bin.stable."1.93.0".default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
            "clippy"
            "rustfmt"
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Zig tooling
            zvm

            # Rust toolchain (pinned — update version here when upgrading)
            rustToolchain

            # Debugging tools
            lldb

            # Build tools
            pkg-config
            openssl

            # Additional useful tools
            cargo-watch
            cargo-edit
            cargo-expand
            bacon
            go-task
            ripgrep
            fzf
          ];

          shellHook = ''
            # Zig setup
            if ! $(zvm list | grep -q 0.15.2); then
              echo "Installing Zig 0.15.2 via zvm..."
              zvm install 0.15.2 --zls --full &> /dev/null
            fi

            zvm use 0.15.2 &> /dev/null

            # Rust setup
            export RUST_SRC_PATH="${rustToolchain}/lib/rustlib/src/rust/library"
            export RUST_BACKTRACE=1

            # Status messages
            echo "Dev environment loaded"
            echo "  Zig:   $(zig version)"
            echo "  Rust:  $(rustc --version)"
            echo "  Cargo: $(cargo --version)"
          '';

          RUST_LOG = "info";
        };
      }
    );
}
