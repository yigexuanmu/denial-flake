# Denial — a Flutter-native Wayland compositor — nix flake packaging.
#
# This flake lives inside the denialwm/denial source tree, so it takes no
# source input: the compositor, dart shell, and packaging metadata all come
# from `self`. Only the toolchain inputs are external.
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

    # Pinned Rust toolchain for the compositor (matches rust-toolchain.toml).
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs =
    { self, nixpkgs, rust-overlay }:
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
          denial = self;
          inherit rust-overlay;
        }
      );

      nixosModules.denial = args@{ config, lib, pkgs, ... }:
        import ./module.nix (args // { flake = self; inherit rust-overlay; });
      nixosModules.default = self.nixosModules.denial;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
