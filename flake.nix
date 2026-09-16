# Denial — a Flutter-native Wayland compositor — nix flake packaging.
#
# This is a standalone packaging flake. All source code (compositor, dart
# shell, packaging metadata) comes from the upstream denialwm/denial
# repository via the `denial-src` input. Only the toolchain and packaging
# files live in this repository.
#
# Quick start:
#
#   nix run .                       # official prebuilt release (recommended)
#   nix build .#sourceProfile       # build the Rust compositor + dart shell from source
#   nix run .#update-check          # print what to bump when a new release ships
#
# For NixOS, see module.nix and FLAKE.md.
{
  description = "Denial, a Flutter-native Wayland compositor — nix flake packaging";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Upstream Denial source tree — the compositor, dart shell, packaging
    # metadata, and all build-time file reads (manifest.json, pubspec.yaml,
    # rust-toolchain.toml, Cargo.lock, etc.) come from here.
    #
    # The upstream repo does not ship a flake.nix, so we fetch it as a plain
    # source tree (flake=false).  The resulting store path is identical in
    # layout to a regular git checkout, and ${denial-src} resolves to the
    # repository root — exactly what package.nix's `denial` parameter needs.
    denial-src.url = "github:denialwm/denial";
    denial-src.flake = false;

    # Pinned Rust toolchain for the compositor (matches rust-toolchain.toml).
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs =
    { self, nixpkgs, denial-src, rust-overlay }:
    let
      # Upstream publishes x86_64 prebuilt artifacts only, and the dart shell
      # is compiled with the prebuilt fork toolchain, so packaging is
      # x86_64-linux only.
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        import ./package.nix {
          pkgs = import nixpkgs { inherit system; };
          denial = denial-src;
          inherit rust-overlay;
        }
      );

      nixosModules.denial = args@{ config, lib, pkgs, ... }:
        import ./module.nix (args // { flake = denial-src; inherit rust-overlay; });
      nixosModules.default = self.nixosModules.denial;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
