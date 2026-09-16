# denial-flake

Nix packaging for [Denial](https://github.com/denialwm/denial), a
Flutter-native Wayland compositor.

This repository contains **only packaging files** — the Denial source tree
(compositor, `dart_shell`, `settings_app`, packaging metadata, etc.) is not
vendored here. All source references point at the upstream
`github:denialwm/denial` flake input, so the packages build against whatever
revision is pinned in `flake.lock` / `flake.nix`.

## Quick start

```sh
# Official prebuilt release (recommended — no Rust/Dart compilation)
nix run .#officialRelease

# Source-built compositor + Dart shell profile AOT bundle
nix build .#sourceProfile

# Release check: print what to bump when a new Denial release ships
nix run .#update-check
```

Default package (`nix build .`) is `officialRelease`.

## NixOS module

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    denial.url = "github:yigexuanmu/denial-flake";
  };

  outputs = { self, nixpkgs, denial, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ denial.nixosModules.default ./configuration.nix ];
    };
  };
}
```

```nix
# configuration.nix
{
  services.denial = {
    enable = true;
    user = "youruser";          # must already exist; added to video/input/render/seat
    # useOfficialRelease = false;  # build Rust + Dart shell from source
    # settings.enable = true;      # standalone Settings app
    # uiDevelopment.enable = true; # live Flutter UI development tools
  };
}
```

## Updating the source pin

Denial source and release pins are managed separately:

- Source pin: `nix flake update denial-src` (or edit the revision in
  `flake.lock`). The source input feeds `package.nix`'s `denial` parameter.
- Release pins (`versions.nix`): run `nix run .#update-check`. It compares
  against the latest upstream release and prints the fields (including newly
  computed hashes) that need updating.

See also `FLAKE.md` for a full parameter reference of the NixOS module.

## Files

- `flake.nix` — inputs (`nixpkgs`, `denial-src`, `rust-overlay`), packages,
  NixOS module
- `package.nix` — packaging implementation (official prebuilt release, source
  profile, settings app, update-check)
- `module.nix` — NixOS module
- `versions.nix` — pinned release artifact versions/hashes
- `update-check.sh` — release updater script template
- `LICENSE` — GPL-3.0-or-later
