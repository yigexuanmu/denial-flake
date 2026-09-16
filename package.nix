# Denial package set, built from this repository (the denialwm/denial source).
#
# Two packaging paths:
#   - officialRelease (default): unpacks Denial's official prebuilt release
#     artifacts (compositor + shell AOT bundle + Settings + engine). No Nix
#     compilation of Denial code.
#   - sourceProfile: builds the Rust compositor from this tree and compiles
#     the Dart shell profile AOT bundle using Denial's prebuilt fork Flutter
#     toolchain (denial-ui-development). The Flutter engine itself is never
#     compiled — the fork toolchain and engine come as prebuilt binaries.
#
# Packaging model adapted to 0.4.1 from
# github:BeyondtheApex/nixos-denial-compositor-flake-config (0.4.0) and
# github:YeFaDa/denial.nix.
{
  pkgs,
  # The denialwm/denial source tree this flake lives in (self).
  denial,
  # oxalica/rust-overlay flake input, for the rustc pinned in
  # rust-toolchain.toml.
  rust-overlay,
}:

let
  inherit (pkgs) lib;
  versions = import ./versions.nix;
  system = pkgs.stdenv.hostPlatform.system;

  # Flutter fork version/revision recorded by this source tree; the prebuilt
  # toolchain must match it.
  flutterManifest = builtins.fromJSON (
    builtins.readFile "${denial}/packaging/arch/ui-development/manifest.json"
  );
  flutterVersion = flutterManifest.sources.flutter_version;
  flutterFramework = {
    repository = lib.removeSuffix ".git" flutterManifest.sources.flutter_repository;
    revision = flutterManifest.sources.flutter_fork_revision;
  };

  # Guard: the pinned flatc must equal what protocol/FLATBUFFERS_VERSION asks
  # for, so the generated wire code cannot drift from the toolchain.
  flatbuffersVersion = builtins.readFile "${denial}/protocol/FLATBUFFERS_VERSION";
  flatcGuard =
    if lib.trim flatbuffersVersion == versions.flatc.version then
      null
    else
      throw "Denial's protocol/FLATBUFFERS_VERSION is ${lib.trim flatbuffersVersion}, but versions.nix pins flatc ${versions.flatc.version}. Update versions.nix.";

  # Guard: the pinned Flutter version must equal what the shell's pubspec asks
  # for, so the binary toolchain and the shell source cannot drift.
  denialPubspec = builtins.readFile "${denial}/dart_shell/pubspec.yaml";
  denialFlutterReq = let
    m = builtins.match ".*flutter:[ \t]*([0-9.]+).*" denialPubspec;
  in if m == null then null else builtins.head m;
  pubspecGuard =
    if (denialFlutterReq == null) || (denialFlutterReq == flutterVersion) then
      null
    else
      throw "Denial's dart_shell requires Flutter ${denialFlutterReq} (dart_shell/pubspec.yaml), but the pinned denial-ui-development toolchain is Flutter ${flutterVersion} (packaging/arch/ui-development/manifest.json).";

  # ---------------------------------------------------------------------------
  # Prebuilt fork Flutter toolchain (denial-ui-development release package).
  uiDev = pkgs.fetchurl {
    inherit (versions.uiDev) url sha256;
  };
  uiDevRoot = pkgs.stdenv.mkDerivation {
    pname = "denial-ui-development";
    inherit (versions.uiDev) version;
    src = uiDev;
    nativeBuildInputs = [ pkgs.zstd pkgs.gnutar pkgs.autoPatchelfHook ];
    # The prebuilt ELFs link against the standard glibc loader path; rewrite
    # them to the nix store. gtk3 covers the (unused) GTK engine's libs.
    buildInputs = [ pkgs.glibc pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.gtk3 ];
    dontUnpack = true;
    dontStrip = true;
    buildPhase = ''
      mkdir -p $out
      tar --zstd -xf $src -C $out \
        usr/bin/denial-ui \
        usr/lib/denial/ui-development \
        usr/share/denial/ui-development
      cp -r $out/usr/lib/denial/ui-development/. $out/
      mkdir -p $out/bin $out/share/denial/ui-development
      cp $out/usr/bin/denial-ui $out/bin/denial-ui
      cp -r $out/usr/share/denial/ui-development/. \
        $out/share/denial/ui-development/
      cp -r $out/usr/share/denial/ui-development/workspace $out/workspace
      rm -rf $out/usr
    '';
    installPhase = "true";
  };

  flutterToolBackendShell = pkgs.fetchurl {
    url = "${flutterFramework.repository}/raw/${flutterFramework.revision}/packages/flutter_tools/bin/tool_backend.sh";
    sha256 = versions.flutterToolBackend.shell;
  };
  flutterToolBackendDart = pkgs.fetchurl {
    url = "${flutterFramework.repository}/raw/${flutterFramework.revision}/packages/flutter_tools/bin/tool_backend.dart";
    sha256 = versions.flutterToolBackend.dart;
  };

  # The development package contains the prebuilt profile engine together
  # with the matching profile gen_snapshot. Keep both from this same release
  # package; do not mix it with the separate release engine package.
  engineSo = "${uiDevRoot}/profile/lib/libflutter_engine.so";

  # ---------------------------------------------------------------------------
  # Dart shell: built with Denial's prebuilt fork toolchain (no nixpkgs
  # flutter involved). The CLI (a native Rust client) validates the development
  # root (pub-cache marker) and resolves SDK / pub cache from env overrides, so
  # the whole prebuilt root is copied into a writable home. The toolchain ships
  # debug + profile artifacts only, so the shell is assembled in profile AOT
  # mode; it runs on the matching prebuilt profile engine from uiDevRoot.
  dartShell = pkgs.stdenv.mkDerivation {
    pname = "denial-dart-shell";
    inherit (versions.release) version;
    src = "${denial}";
    sourceRoot = "source/dart_shell";
    nativeBuildInputs = [ pkgs.git pkgs.which ];
    buildPhase = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export XDG_CACHE_HOME="$HOME/.cache"
      export DENIAL_UI_DEVELOPMENT_ROOT="$HOME/denial-ui-dev"
      cp -r ${uiDevRoot} "$HOME/denial-ui-dev"
      chmod -R u+w "$HOME/denial-ui-dev"
      export DENIAL_FLUTTER_SDK_ROOT="$HOME/denial-ui-dev/flutter"
      export DENIAL_UI_PUB_CACHE="$HOME/denial-ui-dev/pub-cache"
      FLUTTER_BIN="$DENIAL_FLUTTER_SDK_ROOT/bin/flutter"
      "$FLUTTER_BIN" pub get --offline
      "$FLUTTER_BIN" assemble --suppress-analytics --output=$TMPDIR/assembly \
        -dTargetFile=lib/main.dart -dBuildMode=profile -dTargetPlatform=linux-x64 \
        -dDartObfuscation=false -dTrackWidgetCreation=true -dTreeShakeIcons=true \
        profile_bundle_linux-x64_assets
    '';
    installPhase = ''
      export FLUTTER_ROOT="$DENIAL_FLUTTER_SDK_ROOT"
      mkdir -p $out/lib $out/data
      cp $TMPDIR/assembly/lib/libapp.so $out/lib/libapp.so
      cp "$FLUTTER_ROOT/bin/cache/artifacts/engine/linux-x64/icudtl.dat" $out/data/icudtl.dat
      cp -r $TMPDIR/assembly/flutter_assets/. $out/data/flutter_assets/
    '';
  };

  # ---------------------------------------------------------------------------
  # Compositor: built from source (the part nix compiles — Rust, not the
  # Flutter engine).
  flatc = pkgs.stdenv.mkDerivation {
    pname = "flatc";
    inherit (versions.flatc) version;
    src = pkgs.fetchurl {
      inherit (versions.flatc) url sha256;
    };
    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";
    unpackPhase = "unzip -q $src";
    installPhase = ''mkdir -p $out/bin; install -m755 flatc $out/bin/flatc'';
  };

  # rust-bin from rust-toolchain.toml (1.98.0) via rust-overlay.
  rustPkgs = import pkgs.path {
    inherit system;
    inherit (pkgs) config;
    overlays = [ rust-overlay.overlays.default ];
  };
  rustChannel = builtins.head (
    lib.match ".*channel = \"([^\"]+)\".*" (builtins.readFile "${denial}/rust-toolchain.toml")
  );
  rustPlatform = rustPkgs.makeRustPlatform {
    rustc = rustPkgs.rust-bin.stable.${rustChannel}.default;
    cargo = rustPkgs.rust-bin.stable.${rustChannel}.default;
  };

  # 0.4.1 builds deniald (kms) + denialctl (control) + denial-portal with the
  # "flutter" feature.
  compositor = rustPlatform.buildRustPackage {
    pname = "denial";
    inherit (versions.release) version;
    src = "${denial}";
    sourceRoot = "source/compositor";
    cargoLock = {
      lockFile = "${denial}/compositor/Cargo.lock";
      extraRegistries = {
        "https://github.com/rust-lang/crates.io-index" =
          "https://static.crates.io/crates";
      };
      outputHashes = versions.cargoOutputHashes;
    };
    # Upstream (tools/denial-pc) builds the root package with --features
    # flutter plus the separate denial-portal crate. Every bin target has
    # required-features, so without the feature no binaries are produced.
    # With two -p selections the feature must be package-qualified, which is
    # why this uses cargoBuildFlags instead of buildFeatures.
    cargoBuildFlags = [
      "-p" "denial"
      "-p" "denial-portal"
      "--features" "denial/flutter"
    ];
    nativeBuildInputs = [ pkgs.pkg-config flatc ];
    buildInputs = with pkgs; [
      libdrm
      libgbm
      mesa
      libglvnd
      libinput
      seatd
      udev
      libxkbcommon
      wayland
      libxcb
      libx11
      fontconfig
      freetype
      libpulseaudio
      ddcutil # dlopen()ed by deniald for external display brightness
      xwayland
      pam
    ];
    preBuild = ''
      # extraRegistries changes only the crate download endpoint. Remove the
      # duplicate source block it adds so Cargo keeps using the standard
      # crates-io name for the already-vendored sources.
      sed -i '\|^\[source\."https://github.com/rust-lang/crates.io-index"\]$|,+2d' \
        "$NIX_BUILD_TOP/.cargo/config.toml"
      chmod -R u+w "$PWD/.."
      (cd "$PWD/.." && bash tools/generate-denial-wire)
    '';
    doCheck = false;
  };

  # ---------------------------------------------------------------------------
  # Standalone GTK Settings application. It uses the same pinned Flutter fork
  # and profile GTK artifact as the shell, while remaining a separate optional
  # package at the NixOS module level. 0.4.1's Settings honours
  # DENIAL_CONTROL_TOOL / DENIAL_DEVELOPMENT_TOOL for the UI development
  # tools; the module sets those instead of patching the source.
  settingsApp = pkgs.stdenv.mkDerivation {
    pname = "denial-settings";
    inherit (versions.release) version;
    src = denial;
    nativeBuildInputs = [
      pkgs.clang
      pkgs.cmake
      pkgs.git
      pkgs.ninja
      pkgs.pkg-config
      pkgs.which
      pkgs.autoPatchelfHook
      pkgs.makeWrapper
    ];
    buildInputs = with pkgs; [
      glib
      gtk3
      libepoxy
      pango
      cairo
      atk
      gdk-pixbuf
      lerc
      libdeflate
      libffi
      libdatrie
      libjpeg
      libpng
      libselinux
      libsepol
      libsysprof-capture
      libthai
      libwebp
      libxau
      libxdmcp
      libxkbcommon
      libxtst
      pcre2
      systemdLibs
      util-linux
      xz
      zlib
      zstd
    ];
    dontStrip = true;
    dontConfigure = true;
    buildPhase = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export XDG_CACHE_HOME="$HOME/.cache"
      export DENIAL_UI_DEVELOPMENT_ROOT="$HOME/denial-ui-dev"
      cp -r ${uiDevRoot} "$HOME/denial-ui-dev"
      chmod -R u+w "$HOME/denial-ui-dev"
      export DENIAL_FLUTTER_SDK_ROOT="$HOME/denial-ui-dev/flutter"
      export DENIAL_UI_PUB_CACHE="$HOME/denial-ui-dev/pub-cache"
      mkdir -p "$DENIAL_FLUTTER_SDK_ROOT/packages/flutter_tools/bin"
      cp ${flutterToolBackendShell} \
        "$DENIAL_FLUTTER_SDK_ROOT/packages/flutter_tools/bin/tool_backend.sh"
      cp ${flutterToolBackendDart} \
        "$DENIAL_FLUTTER_SDK_ROOT/packages/flutter_tools/bin/tool_backend.dart"
      chmod +x "$DENIAL_FLUTTER_SDK_ROOT/packages/flutter_tools/bin/tool_backend.sh"
      patchShebangs "$DENIAL_FLUTTER_SDK_ROOT/packages/flutter_tools/bin/tool_backend.sh"
      cd settings_app
      "$DENIAL_FLUTTER_SDK_ROOT/bin/flutter" pub get --offline
      "$DENIAL_FLUTTER_SDK_ROOT/bin/flutter" build linux \
        --verbose \
        --profile \
        --build-number=0 \
        --target=lib/main.dart
    '';
    installPhase = ''
      mkdir -p $out/lib/denial/settings $out/bin $out/share/applications
      cp -r build/linux/x64/profile/bundle/. $out/lib/denial/settings/
      ln -s ../lib/denial/settings/denial-settings $out/bin/denial-settings
      cp ${denial}/packaging/arch/dev.denial.Settings.desktop \
        $out/share/applications/dev.denial.Settings.desktop
      substituteInPlace $out/share/applications/dev.denial.Settings.desktop \
        --replace-fail /usr/bin/denial-settings $out/bin/denial-settings
    '';
    postFixup = ''
      wrapProgram $out/bin/denial-settings \
        --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [
          pkgs.glib
          pkgs.gtk3
          pkgs.libepoxy
          pkgs.pango
          pkgs.cairo
          pkgs.atk
          pkgs.gdk-pixbuf
          pkgs.libglvnd
        ]}"
    '';
  };

  # ---------------------------------------------------------------------------
  # Official prebuilt release: the upstream artifacts, unpacked and patched
  # for the nix store. Skips Nix-side Rust/Dart builds entirely.
  officialDenialPackage = pkgs.fetchurl {
    inherit (versions.release.denial) url sha256;
  };
  officialEnginePackage = pkgs.fetchurl {
    inherit (versions.release.engine) url sha256;
  };

  officialRelease = pkgs.stdenv.mkDerivation {
    pname = "denial-official-release";
    inherit (versions.release) version;
    passthru.providedSessions = [ "denial" ];
    dontUnpack = true;
    dontStrip = true;
    nativeBuildInputs = [
      pkgs.zstd
      pkgs.gnutar
      pkgs.autoPatchelfHook
      pkgs.makeWrapper
    ];
    buildInputs = with pkgs; [
      glibc
      stdenv.cc.cc.lib
      glib
      gtk3
      libepoxy
      pango
      cairo
      atk
      gdk-pixbuf
      libdrm
      libgbm
      mesa
      libglvnd
      libinput
      seatd
      udev
      libxkbcommon
      wayland
      libxcb
      libx11
      fontconfig
      freetype
      libpulseaudio
      ddcutil # dlopen()ed by deniald for external display brightness
      pam
      lerc
      libdeflate
      libffi
      libdatrie
      libjpeg
      libpng
      libselinux
      libsepol
      libsysprof-capture
      libthai
      libwebp
      libxau
      libxdmcp
      libxtst
      pcre2
      xz
      zlib
      zstd
      systemdLibs
      util-linux
    ];
    buildPhase = ''
      mkdir -p $out
      tar --zstd -xf ${officialDenialPackage} -C $out usr etc
      tar --zstd -xf ${officialEnginePackage} -C $out usr/lib/denial/flutter usr/share/denial/flutter-engine
      cp -r $out/usr/. $out/
      rm -rf $out/usr
      patchShebangs $out/bin
      substituteInPlace $out/share/wayland-sessions/denial.desktop \
        --replace-fail /usr/bin/denial-session $out/bin/denial-session
      substituteInPlace $out/share/applications/dev.denial.Settings.desktop \
        --replace-fail /usr/bin/denial-settings $out/bin/denial-settings
      substituteInPlace $out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.denial.service \
        --replace-fail /usr/bin/denial-portal $out/bin/denial-portal
      substituteInPlace $out/lib/systemd/user/denial-portal.service \
        --replace-fail /usr/bin/denial-portal $out/bin/denial-portal
    '';
    installPhase = "true";
    postFixup = ''
      # The prebuilt engine and Denial's optional native PAM backend load these
      # libraries dynamically, so expose them and the active graphics driver
      # path through the session launcher.
      wrapProgram $out/bin/denial-session \
        --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.fontconfig pkgs.libglvnd pkgs.mesa pkgs.pam pkgs.ddcutil ]}:/run/opengl-driver/lib"
      wrapProgram $out/bin/denial-settings \
        --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [
          pkgs.glib
          pkgs.gtk3
          pkgs.libepoxy
          pkgs.pango
          pkgs.cairo
          pkgs.atk
          pkgs.gdk-pixbuf
          pkgs.libglvnd
        ]}"
    '';
  };

  # Real regular-file wrappers. denialctl deliberately rejects symlinks for
  # its helper tool, so these wrappers are used instead of PATH-only wiring.
  denialUiWrapper = pkgs.writeShellScriptBin "denial-ui" ''
    #!${pkgs.runtimeShell}
    set -eu
    cache_home="''${XDG_CACHE_HOME:-''${HOME:?HOME is required}/.cache}"
    export DENIAL_UI_DEVELOPMENT_ROOT="${uiDevRoot}"
    export DENIAL_FLUTTER_SDK_ROOT="''${DENIAL_FLUTTER_SDK_ROOT:-${uiDevRoot}/flutter}"
    export DENIAL_UI_DEBUG_ENGINE="''${DENIAL_UI_DEBUG_ENGINE:-${uiDevRoot}/lib/libflutter_engine.so}"
    export DENIAL_UI_PROFILE_ENGINE="''${DENIAL_UI_PROFILE_ENGINE:-${uiDevRoot}/profile/lib/libflutter_engine.so}"
    export DENIAL_UI_BUILD_ROOT="''${DENIAL_UI_BUILD_ROOT:-$cache_home/denial/ui-development}"
    export DENIAL_UI_PUB_CACHE="''${DENIAL_UI_PUB_CACHE:-$DENIAL_UI_BUILD_ROOT/pub-cache}"
    exec "${uiDevRoot}/bin/denial-ui" "$@"
  '';

  denialCtlWrapper = pkgs.writeShellScriptBin "denialctl" ''
    #!${pkgs.runtimeShell}
    set -eu
    export DENIAL_UI_TOOL="${denialUiWrapper}/bin/denial-ui"
    export DENIAL_UI_GIT="${pkgs.git}/bin/git"
    export DENIAL_UI_SOURCE_TEMPLATE="${uiDevRoot}/workspace"
    exec "${compositor}/bin/denialctl" "$@"
  '';

  officialDenialCtlWrapper = pkgs.writeShellScriptBin "denialctl" ''
    #!${pkgs.runtimeShell}
    set -eu
    export DENIAL_UI_TOOL="${denialUiWrapper}/bin/denial-ui"
    export DENIAL_UI_GIT="${pkgs.git}/bin/git"
    export DENIAL_UI_SOURCE_TEMPLATE="${uiDevRoot}/workspace"
    exec "${officialRelease}/bin/denialctl" "$@"
  '';

  officialDenialSessionWrapper = pkgs.writeShellScriptBin "denial-session" ''
    #!${pkgs.runtimeShell}
    set -eu
    cache_home="''${XDG_CACHE_HOME:-''${HOME:?HOME is required}/.cache}"
    debug_bundle="$cache_home/denial/ui-development/debug/bundle"
    export DENIAL_FLUTTER_DEBUG_BUNDLE="$debug_bundle"
    exec "${officialRelease}/bin/denial-session" "$@"
  '';

  officialReleaseWithUiDevelopmentBase = pkgs.stdenv.mkDerivation {
    pname = "denial-official-release-with-ui-development";
    inherit (versions.release) version;
    passthru.providedSessions = [ "denial" ];
    dontUnpack = true;
    buildPhase = ''
      mkdir -p $out
      cp -rL ${officialRelease}/. $out/
      chmod -R u+w $out
      cp ${denialUiWrapper}/bin/denial-ui $out/bin/denial-ui
      cp ${officialDenialCtlWrapper}/bin/denialctl $out/bin/denialctl
      cp ${officialDenialSessionWrapper}/bin/denial-session $out/bin/denial-session
      chmod +x $out/bin/*
    '';
    installPhase = "true";
  };

  officialSettingsWithUiDevelopment = pkgs.buildFHSEnv {
    name = "denial-settings";
    targetPkgs = _pkgs: [ officialReleaseWithUiDevelopmentBase ];
    runScript = "${officialReleaseWithUiDevelopmentBase}/lib/denial/settings/denial-settings";
  };

  officialReleaseWithUiDevelopment = pkgs.stdenv.mkDerivation {
    pname = "denial-official-release-with-ui-development";
    inherit (versions.release) version;
    passthru.providedSessions = [ "denial" ];
    dontUnpack = true;
    buildPhase = ''
      mkdir -p $out
      cp -rL ${officialReleaseWithUiDevelopmentBase}/. $out/
      chmod -R u+w $out
      cp ${officialSettingsWithUiDevelopment}/bin/denial-settings $out/bin/denial-settings
      substituteInPlace $out/share/applications/dev.denial.Settings.desktop \
        --replace-fail ${officialRelease}/bin/denial-settings $out/bin/denial-settings
      chmod +x $out/bin/*
    '';
    installPhase = "true";
  };

  # ---------------------------------------------------------------------------
  # Source-built profile: the Rust compositor from this tree plus the Dart
  # shell AOT bundle compiled with the prebuilt fork toolchain.
  sourceProfile = pkgs.stdenv.mkDerivation {
    pname = "denial";
    inherit (versions.release) version;
    passthru.providedSessions = [ "denial" ];
    dontUnpack = true;
    dontStrip = true;
    # Do not rewrite the prebuilt profile engine after copying it from
    # denial-ui-development. Its ELF must remain the paired artifact that
    # generated the profile AOT snapshot.
    dontPatchELF = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildPhase = ''
      mkdir -p $out/bin $out/lib/denial/flutter/lib $out/lib/denial/flutter/data \
        $out/lib/systemd/user $out/share/wayland-sessions \
        $out/share/xdg-desktop-portal/portals $out/share/dbus-1/services \
        $out/etc/xdg/xdg-desktop-portal-wlr
      cp -r ${compositor}/bin/. $out/bin/
      # dart shell: AOT libapp.so + assets (no engine from the flutter build)
      cp ${dartShell}/lib/libapp.so $out/lib/denial/flutter/lib/libapp.so
      cp ${dartShell}/data/icudtl.dat $out/lib/denial/flutter/data/icudtl.dat
      cp -r ${dartShell}/data/flutter_assets/. $out/lib/denial/flutter/data/flutter_assets/
      # Matching prebuilt profile engine from denial-ui-development.
      cp ${engineSo} $out/lib/denial/flutter/lib/libflutter_engine.so
      # Session launcher (must sit beside deniald/denialctl: package prefix is
      # derived from its own path) + systemd user target + Wayland entry
      cp ${denial}/packaging/arch/denial-session $out/bin/denial-session
      chmod +x $out/bin/*
      cp ${denial}/packaging/denial-session.target $out/lib/systemd/user/denial-session.target
      cp ${denial}/packaging/arch/denial.desktop $out/share/wayland-sessions/denial.desktop
      sed -i "s|/usr/bin/denial-session|$out/bin/denial-session|g" $out/share/wayland-sessions/denial.desktop
      # Portal backend shipped with the compositor workspace.
      cp ${denial}/packaging/arch/denial-portal.service $out/lib/systemd/user/denial-portal.service
      substituteInPlace $out/lib/systemd/user/denial-portal.service \
        --replace-fail /usr/bin/denial-portal $out/bin/denial-portal
      cp ${denial}/packaging/arch/denial.portal $out/share/xdg-desktop-portal/portals/denial.portal
      cp ${denial}/packaging/arch/denial-portals.conf $out/share/xdg-desktop-portal/denial-portals.conf
      cp ${denial}/packaging/arch/org.freedesktop.impl.portal.desktop.denial.service \
        $out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.denial.service
      substituteInPlace $out/share/dbus-1/services/org.freedesktop.impl.portal.desktop.denial.service \
        --replace-fail /usr/bin/denial-portal $out/bin/denial-portal
      cp ${denial}/packaging/arch/xdg-desktop-portal-wlr-Denial \
        $out/etc/xdg/xdg-desktop-portal-wlr/Denial
    '';
    installPhase = "true";
    postFixup = ''
      # The prebuilt engine and Denial's optional native PAM backend load these
      # libraries dynamically, so expose them and the active graphics driver
      # path through the session launcher.
      wrapProgram $out/bin/denial-session \
        --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.fontconfig pkgs.libglvnd pkgs.mesa pkgs.pam pkgs.ddcutil ]}:/run/opengl-driver/lib"
    '';
  };

  denialSessionWrapper = pkgs.writeShellScriptBin "denial-session" ''
    #!${pkgs.runtimeShell}
    set -eu
    cache_home="''${XDG_CACHE_HOME:-''${HOME:?HOME is required}/.cache}"
    debug_bundle="$cache_home/denial/ui-development/debug/bundle"
    export DENIAL_FLUTTER_DEBUG_BUNDLE="$debug_bundle"
    exec "${sourceProfile}/bin/denial-session" "$@"
  '';

  # Opt-in variant. The normal package does not retain the UI development
  # closure; this package adds regular-file wrappers when enabled.
  sourceProfileWithUiDevelopment = pkgs.stdenv.mkDerivation {
    pname = "denial-with-ui-development";
    inherit (versions.release) version;
    passthru.providedSessions = [ "denial" ];
    dontUnpack = true;
    buildPhase = ''
      mkdir -p $out
      # Dereference the default package's systemd directory link before the
      # generic fixup phase moves units into share/systemd/user again.
      cp -rL ${sourceProfile}/. $out/
      chmod -R u+w $out
      cp ${denialUiWrapper}/bin/denial-ui $out/bin/denial-ui
      cp ${denialCtlWrapper}/bin/denialctl $out/bin/denialctl
      cp ${denialSessionWrapper}/bin/denial-session $out/bin/denial-session
      chmod +x $out/bin/*
    '';
    installPhase = "true";
  };

  # ---------------------------------------------------------------------------
  # denial-update-check: a one-shot bin that checks the pinned release against
  # upstream and prints every field of versions.nix that needs updating,
  # including freshly computed hashes. Current pins are injected at build time
  # from versions.nix so the script never drifts from what the flake builds.
  update-check = pkgs.writeShellApplication {
    name = "denial-update-check";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.git pkgs.nix ];
    checkPhase = false;
    text = builtins.replaceStrings
      [
        "@release_version@"
        "@release_denial_url@"
        "@release_denial_sha256@"
        "@release_engine_version@"
        "@release_engine_url@"
        "@release_engine_sha256@"
        "@uiDev_version@"
        "@uiDev_url@"
        "@uiDev_sha256@"
        "@flutterVersion@"
        "@flutterFramework_repository@"
        "@flutterFramework_revision@"
        "@flutterToolBackend_shell@"
        "@flutterToolBackend_dart@"
      ]
      [
        versions.release.version
        versions.release.denial.url
        versions.release.denial.sha256
        versions.release.engine.version
        versions.release.engine.url
        versions.release.engine.sha256
        versions.uiDev.version
        versions.uiDev.url
        versions.uiDev.sha256
        flutterVersion
        flutterFramework.repository
        flutterFramework.revision
        versions.flutterToolBackend.shell
        versions.flutterToolBackend.dart
      ]
      (builtins.readFile ./update-check.sh);
  };
in
assert flatcGuard == null;
assert pubspecGuard == null;
{
  default = officialRelease;
  withUiDevelopment = officialReleaseWithUiDevelopment;

  inherit officialRelease officialReleaseWithUiDevelopment;
  inherit sourceProfile sourceProfileWithUiDevelopment update-check settingsApp;
  # Convenience: everything in one attrset, in case a host wants the pieces.
  inherit dartShell compositor uiDevRoot denialUiWrapper denialCtlWrapper;
}
