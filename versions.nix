# Denial build pins — the single source of truth for the versions and hashes
# that cannot be derived from this source tree itself: the official prebuilt
# release artifacts and the hashes of files inside the prebuilt Flutter fork
# toolchain.
#
# The Flutter fork version/revision (3.44.7 / c8894357...) is read at eval
# time from packaging/arch/ui-development/manifest.json, so it never drifts
# from the source tree. When a new Denial release ships, run
#
#     nix run .#update-check
#
# it prints every field below that needs changing, with freshly computed
# hashes.
{
  # Official prebuilt release packages. Using these skips Nix-side Rust/Dart
  # builds entirely: the Denial shell bundle, Settings app, compositor, and
  # release Flutter engine all come from upstream artifacts.
  release = {
    version = "0.4.2";
    denial = {
      url = "https://github.com/denialwm/denial/releases/download/v0.4.2/denial-0.4.2-1-x86_64.pkg.tar.zst";
      sha256 = "sha256-/3D5iEisYnf9xlQo0op1UX0CJjyTEmOGTQ4gC3hFcs0=";
    };
    engine = {
      version = "1.0.4.2";
      url = "https://github.com/denialwm/denial/releases/download/v0.4.2/denial-flutter-engine-1.0.4.2-1-x86_64.pkg.tar.zst";
      sha256 = "sha256-igouZPHzfdUCbPXK/qOq4V8j/69VcFbFWB6S+acNMnA=";
    };
  };

  # Prebuilt fork Flutter toolchain (denial-ui-development release package),
  # used to compile the Dart shell AOT bundle and as the live UI development
  # toolchain.
  uiDev = {
    version = "0.4.2";
    url = "https://github.com/denialwm/denial/releases/download/v0.4.2/denial-ui-development-0.4.2-1-x86_64.pkg.tar.zst";
    sha256 = "sha256-TJx/i7opMQSqtmgymmcgxHgFaW1ax5ME9weBPIL2E6k=";
  };

  # The UI development archive intentionally omits flutter_tools/bin. The GTK
  # settings runner still calls these two files, so they are fetched from the
  # Denial Flutter fork revision recorded in
  # packaging/arch/ui-development/manifest.json. If a new release bumps that
  # revision, these hashes must be recomputed (denial-update-check does it).
  flutterToolBackend = {
    shell = "sha256-L5JsHTKVrhWOfCZ8D14i71R6ms4MkBoR/UUVvTir2uU=";
    dart = "sha256-WggtMwfa3gH19ojRC5c1Sv5mfmQT1VaYkd8us5UAJXo=";
  };

  # Fixed-output hashes for the git dependencies of compositor/Cargo.lock.
  # smithay and smithay-drm-extras are pinned to the same smithay.git
  # revision, so they share one hash. When compositor/Cargo.lock changes a
  # git pin, update these (a build with a stale hash reports the correct
  # "got:" value in its error output).
  cargoOutputHashes = {
    "smithay-0.7.0" = "sha256-Dov9wh6qGuciLMTwOXM/eRA/Uo4jSvhcCqwJFdB2Vbg=";
    "smithay-drm-extras-0.1.0" = "sha256-Dov9wh6qGuciLMTwOXM/eRA/Uo4jSvhcCqwJFdB2Vbg=";
  };

  # flatc must match protocol/FLATBUFFERS_VERSION (verified at eval time).
  flatc = {
    version = "25.9.23";
    url = "https://github.com/google/flatbuffers/releases/download/v25.9.23/Linux.flatc.binary.g%2B%2B-13.zip";
    sha256 = "de0c6ad114a5a686ecf64322528c602c7d4512446a93f290f54f00ee5abea487";
  };
}
