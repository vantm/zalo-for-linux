{
  description = "Zalo for Linux — Nix development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        shells = import ./nix/devshell.nix { inherit pkgs; };
      in
      {
        # `nix fmt` formats the flake files.
        formatter = pkgs.nixfmt;

        # Runnable FHS wrapper — `nix run .#fhs -- -c '<cmd>'`. This is the way
        # to run one-off commands inside the sandbox, because `nix develop -c`
        # is swallowed by the FHS init `exec`.
        packages = {
          default = shells.fhsRun;
          fhs = shells.fhsRun;
        };

        apps = {
          default = {
            type = "app";
            program = "${shells.fhsRun}/bin/zalo-dev-fhs";
          };
          fhs = {
            type = "app";
            program = "${shells.fhsRun}/bin/zalo-dev-fhs";
          };
        };

        devShells = {
          # Full environment: an FHS sandbox so the prebuilt Electron 22 /
          # electron-builder / appimagetool binaries run on NixOS, with 32-bit
          # multilib and wine available for the call bridge.
          default = shells.fhs;

          # Lightweight shell without the FHS sandbox. Good for editing,
          # Rust/cargo work and native addon builds; Electron and the
          # AppImage packaging step will not run here.
          light = shells.light;
        };
      }
    );
}
