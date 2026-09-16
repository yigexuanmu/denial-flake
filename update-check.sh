#!/usr/bin/env bash
# denial-update-check — check the pinned Denial release (versions.nix) against
# upstream and print every field that needs changing (including freshly
# computed hashes), so you never have to compute them by hand.
#
# The "@...@" placeholders are replaced at build time from versions.nix (see
# package.nix). Run with --json for machine output.
#
# To update the flake's source pin after a new release, change the
# `denial-src` input in flake.nix (or its revision in flake.lock).
# `nix flake update denial-src` also refreshes it.
set -euo pipefail

JSON="${DENIAL_UPDATE_CHECK_JSON:-0}"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --force) FORCE=1 ;;
    -h | --help)
      echo "usage: denial-update-check [--json] [--force]"
      echo "  --json   machine-readable output"
      echo "  --force  compute the new hashes even when there is no update"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ===== current pins (injected at build time from versions.nix) =====
RELEASE_VERSION='@release_version@'
RELEASE_DENIAL_URL='@release_denial_url@'
RELEASE_DENIAL_SHA256='@release_denial_sha256@'
RELEASE_ENGINE_VERSION='@release_engine_version@'
RELEASE_ENGINE_URL='@release_engine_url@'
RELEASE_ENGINE_SHA256='@release_engine_sha256@'
UI_DEV_VERSION='@uiDev_version@'
UI_DEV_URL='@uiDev_url@'
UI_DEV_SHA256='@uiDev_sha256@'
FLUTTER_VERSION='@flutterVersion@'
FLUTTER_FRAMEWORK_REPOSITORY='@flutterFramework_repository@'
FLUTTER_FRAMEWORK_REVISION='@flutterFramework_revision@'
FLUTTER_TOOL_BACKEND_SHELL_SHA256='@flutterToolBackend_shell@'
FLUTTER_TOOL_BACKEND_DART_SHA256='@flutterToolBackend_dart@'

UPSTREAM_OWNER="denialwm"
UPSTREAM_REPO="denial"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }; }
need curl; need jq; need git

latest_release_tag() { # owner repo -> latest release tag (or "" on failure)
  # /releases/latest 404s when every release is a prerelease (Denial is
  # public-beta), so list releases and take the newest non-draft one.
  curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$1/$2/releases?per_page=1" 2>/dev/null \
    | jq -r 'map(select(.draft == false)) | .[0].tag_name // empty'
}
latest_main_rev() { # owner repo -> HEAD revision of the default branch
  git ls-remote "https://github.com/$1/$2.git" HEAD 2>/dev/null | awk '{print $1}'
}
sha256_sri() { # url -> sha256-<base64>
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  if command -v nix >/dev/null 2>&1; then
    nix store prefetch-file --json "$1" 2>/dev/null | jq -r .hash
    return
  fi
  curl -fsSL "$1" -o "$tmp"
  local hex
  hex="$(sha256sum "$tmp" | awk '{print $1}')"
  printf 'sha256-%s' "$(printf '%s' "$hex" | xxd -r -p | base64 -w0)"
}
manifest_for_tag() { # owner repo tag -> manifest json
  curl -fsSL "https://raw.githubusercontent.com/$1/$2/$3/packaging/arch/ui-development/manifest.json" 2>/dev/null
}

LATEST_TAG="$(latest_release_tag "$UPSTREAM_OWNER" "$UPSTREAM_REPO")"
LATEST_REV="$(latest_main_rev "$UPSTREAM_OWNER" "$UPSTREAM_REPO")"

new_tag="$LATEST_TAG"
has_update=0
if [[ -n "$new_tag" && "$new_tag" != "v$RELEASE_VERSION" ]]; then has_update=1; fi

# ---- compute what would change ----
NEW_RELEASE_VERSION="${new_tag#v}"
NEW_RELEASE_DENIAL_URL=""
NEW_RELEASE_DENIAL_SHA256=""
NEW_RELEASE_ENGINE_VERSION=""
NEW_RELEASE_ENGINE_URL=""
NEW_RELEASE_ENGINE_SHA256=""
NEW_UI_DEV_VERSION="$NEW_RELEASE_VERSION"
NEW_UI_DEV_URL=""
NEW_UI_DEV_SHA256=""
NEW_FLUTTER_VERSION=""
NEW_FLUTTER_FRAMEWORK_REPOSITORY=""
NEW_FLUTTER_FRAMEWORK_REVISION=""
NEW_FLUTTER_TOOL_BACKEND_SHELL_SHA256=""
NEW_FLUTTER_TOOL_BACKEND_DART_SHA256=""
if [[ "$has_update" == 1 ]] || [[ "$FORCE" == 1 ]]; then
  if [[ -n "$new_tag" ]]; then
    NEW_RELEASE_DENIAL_URL="https://github.com/denialwm/denial/releases/download/${new_tag}/denial-${NEW_RELEASE_VERSION}-1-x86_64.pkg.tar.zst"
    NEW_RELEASE_ENGINE_VERSION="1.${NEW_RELEASE_VERSION}"
    NEW_RELEASE_ENGINE_URL="https://github.com/denialwm/denial/releases/download/${new_tag}/denial-flutter-engine-${NEW_RELEASE_ENGINE_VERSION}-1-x86_64.pkg.tar.zst"
    NEW_UI_DEV_URL="https://github.com/denialwm/denial/releases/download/${new_tag}/denial-ui-development-${NEW_UI_DEV_VERSION}-1-x86_64.pkg.tar.zst"
    echo "computing sha256 for official denial release (${NEW_RELEASE_VERSION})..." >&2
    NEW_RELEASE_DENIAL_SHA256="$(sha256_sri "$NEW_RELEASE_DENIAL_URL")"
    echo "computing sha256 for official flutter engine (${NEW_RELEASE_ENGINE_VERSION})..." >&2
    NEW_RELEASE_ENGINE_SHA256="$(sha256_sri "$NEW_RELEASE_ENGINE_URL")"
    echo "computing sha256 for ui-development (${NEW_UI_DEV_VERSION})..." >&2
    NEW_UI_DEV_SHA256="$(sha256_sri "$NEW_UI_DEV_URL")"
    manifest="$(manifest_for_tag "$UPSTREAM_OWNER" "$UPSTREAM_REPO" "$new_tag" || true)"
    if [[ -n "$manifest" ]]; then
      NEW_FLUTTER_VERSION="$(jq -r '.sources.flutter_version // empty' <<<"$manifest")"
      NEW_FLUTTER_FRAMEWORK_REPOSITORY="$(jq -r '.sources.flutter_repository // empty' <<<"$manifest")"
      NEW_FLUTTER_FRAMEWORK_REPOSITORY="${NEW_FLUTTER_FRAMEWORK_REPOSITORY%.git}"
      NEW_FLUTTER_FRAMEWORK_REVISION="$(jq -r '.sources.flutter_fork_revision // empty' <<<"$manifest")"
      if [[ -n "$NEW_FLUTTER_FRAMEWORK_REPOSITORY" && -n "$NEW_FLUTTER_FRAMEWORK_REVISION" ]]; then
        echo "computing sha256 for flutter tool_backend files (${NEW_FLUTTER_FRAMEWORK_REVISION})..." >&2
        NEW_FLUTTER_TOOL_BACKEND_SHELL_SHA256="$(sha256_sri "${NEW_FLUTTER_FRAMEWORK_REPOSITORY}/raw/${NEW_FLUTTER_FRAMEWORK_REVISION}/packages/flutter_tools/bin/tool_backend.sh")"
        NEW_FLUTTER_TOOL_BACKEND_DART_SHA256="$(sha256_sri "${NEW_FLUTTER_FRAMEWORK_REPOSITORY}/raw/${NEW_FLUTTER_FRAMEWORK_REVISION}/packages/flutter_tools/bin/tool_backend.dart")"
      fi
    fi
  fi
fi

# ===== output =====
if [[ "$JSON" == 1 ]]; then
  jq -n \
    --arg currentRef "v$RELEASE_VERSION" \
    --arg latestTag "$LATEST_TAG" \
    --arg latestRev "$LATEST_REV" \
    --arg releaseVersion "$RELEASE_VERSION" \
    --arg releaseDenialUrl "$RELEASE_DENIAL_URL" \
    --arg releaseDenialSha256 "$RELEASE_DENIAL_SHA256" \
    --arg releaseEngineVersion "$RELEASE_ENGINE_VERSION" \
    --arg releaseEngineUrl "$RELEASE_ENGINE_URL" \
    --arg releaseEngineSha256 "$RELEASE_ENGINE_SHA256" \
    --arg uiDevVersion "$UI_DEV_VERSION" \
    --arg uiDevUrl "$UI_DEV_URL" \
    --arg uiDevSha256 "$UI_DEV_SHA256" \
    --arg newReleaseVersion "$NEW_RELEASE_VERSION" \
    --arg newReleaseDenialUrl "$NEW_RELEASE_DENIAL_URL" \
    --arg newReleaseDenialSha256 "$NEW_RELEASE_DENIAL_SHA256" \
    --arg newReleaseEngineVersion "$NEW_RELEASE_ENGINE_VERSION" \
    --arg newReleaseEngineUrl "$NEW_RELEASE_ENGINE_URL" \
    --arg newReleaseEngineSha256 "$NEW_RELEASE_ENGINE_SHA256" \
    --arg newUiDevVersion "$NEW_UI_DEV_VERSION" \
    --arg newUiDevUrl "$NEW_UI_DEV_URL" \
    --arg newUiDevSha256 "$NEW_UI_DEV_SHA256" \
    --arg flutterVersion "$FLUTTER_VERSION" \
    --arg newFlutterVersion "$NEW_FLUTTER_VERSION" \
    --arg flutterFrameworkRepository "$FLUTTER_FRAMEWORK_REPOSITORY" \
    --arg newFlutterFrameworkRepository "$NEW_FLUTTER_FRAMEWORK_REPOSITORY" \
    --arg flutterFrameworkRevision "$FLUTTER_FRAMEWORK_REVISION" \
    --arg newFlutterFrameworkRevision "$NEW_FLUTTER_FRAMEWORK_REVISION" \
    --arg flutterToolBackendShellSha256 "$FLUTTER_TOOL_BACKEND_SHELL_SHA256" \
    --arg newFlutterToolBackendShellSha256 "$NEW_FLUTTER_TOOL_BACKEND_SHELL_SHA256" \
    --arg flutterToolBackendDartSha256 "$FLUTTER_TOOL_BACKEND_DART_SHA256" \
    --arg newFlutterToolBackendDartSha256 "$NEW_FLUTTER_TOOL_BACKEND_DART_SHA256" \
    --argjson hasUpdate "$has_update" \
    '{ has_update: $hasUpdate,
       upstream: { latest_tag: $latestTag, latest_rev: $latestRev },
       fields: {
         "versions.nix release.version":    { current: $releaseVersion, next: $newReleaseVersion },
         "versions.nix release.denial.url": { current: $releaseDenialUrl, next: $newReleaseDenialUrl },
         "versions.nix release.denial.sha256": { current: $releaseDenialSha256, next: $newReleaseDenialSha256 },
         "versions.nix release.engine.version": { current: $releaseEngineVersion, next: $newReleaseEngineVersion },
         "versions.nix release.engine.url": { current: $releaseEngineUrl, next: $newReleaseEngineUrl },
         "versions.nix release.engine.sha256": { current: $releaseEngineSha256, next: $newReleaseEngineSha256 },
         "versions.nix uiDev.version":      { current: $uiDevVersion, next: $newUiDevVersion },
         "versions.nix uiDev.url":          { current: $uiDevUrl, next: $newUiDevUrl },
         "versions.nix uiDev.sha256":       { current: $uiDevSha256, next: $newUiDevSha256 },
         "flutter version (manifest)":      { current: $flutterVersion, next: $newFlutterVersion },
         "flutter fork revision (manifest)": { current: $flutterFrameworkRevision, next: $newFlutterFrameworkRevision },
         "versions.nix flutterToolBackend.shell": { current: $flutterToolBackendShellSha256, next: $newFlutterToolBackendShellSha256 },
         "versions.nix flutterToolBackend.dart": { current: $flutterToolBackendDartSha256, next: $newFlutterToolBackendDartSha256 }
       } }'
  exit 0
fi

echo "== Denial update check =="
echo "latest release    : ${LATEST_TAG:-(unavailable)}"
if [[ -n "$LATEST_REV" ]]; then
  echo "latest main rev   : $LATEST_REV"
fi
echo

if [[ "$has_update" == 0 ]]; then
  echo "Up to date: the current pin matches the latest release (${new_tag:-unknown})."
  if [[ "$FORCE" == 0 ]]; then
    echo "(use --force to recompute the current field values anyway)"
    exit 0
  fi
  echo "(--force: recomputed values for the current release)"
fi

echo "Fields to update (versions.nix):"
echo "  release.version      : $RELEASE_VERSION -> ${NEW_RELEASE_VERSION:-?}"
echo "  release.denial.url   : $RELEASE_DENIAL_URL"
echo "                         -> ${NEW_RELEASE_DENIAL_URL:-?}"
echo "  release.denial.sha256: $RELEASE_DENIAL_SHA256 -> ${NEW_RELEASE_DENIAL_SHA256:-?}"
echo "  release.engine.version: $RELEASE_ENGINE_VERSION -> ${NEW_RELEASE_ENGINE_VERSION:-?}"
echo "  release.engine.url   : $RELEASE_ENGINE_URL"
echo "                         -> ${NEW_RELEASE_ENGINE_URL:-?}"
echo "  release.engine.sha256: $RELEASE_ENGINE_SHA256 -> ${NEW_RELEASE_ENGINE_SHA256:-?}"
echo "  uiDev.version        : $UI_DEV_VERSION -> ${NEW_UI_DEV_VERSION:-?}"
echo "  uiDev.url            : $UI_DEV_URL"
echo "                         -> ${NEW_UI_DEV_URL:-?}"
echo "  uiDev.sha256         : $UI_DEV_SHA256 -> ${NEW_UI_DEV_SHA256:-?}"
echo "  flutter version      : $FLUTTER_VERSION -> ${NEW_FLUTTER_VERSION:-?}   (from the new release's manifest)"
echo "  flutter fork revision: $FLUTTER_FRAMEWORK_REVISION -> ${NEW_FLUTTER_FRAMEWORK_REVISION:-?}"
echo "  flutterToolBackend.shell: $FLUTTER_TOOL_BACKEND_SHELL_SHA256 -> ${NEW_FLUTTER_TOOL_BACKEND_SHELL_SHA256:-?}"
echo "  flutterToolBackend.dart : $FLUTTER_TOOL_BACKEND_DART_SHA256 -> ${NEW_FLUTTER_TOOL_BACKEND_DART_SHA256:-?}"
echo
echo "Update the denial-src flake input to the new upstream rev:"
echo "  nix flake update denial-src"
echo "Then update"
echo "  versions.nix cargoOutputHashes   if compositor/Cargo.lock changed git pins"
echo "  versions.nix flatc               if protocol/FLATBUFFERS_VERSION changed"
echo
echo "After editing:"
echo "  nix flake check && nix build"
