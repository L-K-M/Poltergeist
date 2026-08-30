#!/usr/bin/env bash
# Cuts a release: bumps the `version:` in every pubspec in lockstep (the
# packages + the app once it exists), keeps the app lockfile and the README
# version line in step, commits, tags "v<version>", and with --push pushes
# branch + tag — which triggers .github/workflows/release.yml to test, build
# the app clients (Android APK, Linux/macOS/Windows desktop bundles, unsigned
# iOS IPA), and publish the GitHub Release.
#
#   scripts/release.sh 0.2.0          # bump pubspecs + README, commit, tag v0.2.0
#   scripts/release.sh 0.2.0 --push   # …also push the commit + tag (CI then publishes)
#   scripts/release.sh                # tag the current committed version as-is
#
# Usage: scripts/release.sh [X.Y.Z] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export RELEASE_APP_NAME="Poltergeist"
export RELEASE_KIND="pubspec"

# The workspace packages, plus the app pubspec once the app is scaffolded —
# built dynamically so this stub needs no edit when packages or the app land.
PUBSPECS=""
for p in "$ROOT"/packages/*/pubspec.yaml "$ROOT"/app/poltergeist_app/pubspec.yaml; do
  [[ -f "$p" ]] || continue
  PUBSPECS+="${PUBSPECS:+ }${p#"$ROOT"/}"
done
[[ -n "$PUBSPECS" ]] || { echo "error: no pubspecs found to bump" >&2; exit 1; }
export RELEASE_PUBSPECS="$PUBSPECS"

# The app's committed lockfile pins the workspace packages' versions; keep it
# in step so the post-release `flutter pub get` is a no-op. The package list
# is derived from packages/*/ at run time (directory basename = package name,
# per this repo family's convention), mirroring the RELEASE_PUBSPECS glob, so
# a new workspace package needs no edit here either. Each lockfile entry's
# block ends at its `version:` line, so the range substitution touches
# exactly that line; a package absent from the lockfile makes its range a
# harmless no-op. The engine runs this via bash -c with RELEASE_NEW_VERSION
# exported — hence the single quotes — from the repo root on whatever host
# invoked the stub; probe GNU vs BSD sed exactly like the engine
# (`sed -i ""` is BSD-only syntax, and plain `sed -i` breaks macOS).
# ${RELEASE_NEW_VERSION} expands when the engine runs this, not here. A no-op
# until the app (and its lockfile) exist.
# shellcheck disable=SC2016
export RELEASE_POST_BUMP='
  LOCK=app/poltergeist_app/pubspec.lock
  if [ -f "$LOCK" ]; then
    if sed --version 2>/dev/null | head -n 1 | grep -q "GNU sed"; then
      SED_I=(sed -i)
    else
      SED_I=(sed -i "")
    fi
    SED_EXPRS=()
    for d in packages/*/; do
      pkg="$(basename "$d")"
      SED_EXPRS+=(-e "/^  ${pkg}:/,/^    version:/ s/^(    version: \")[^\"]*(\")/\1${RELEASE_NEW_VERSION}\2/")
    done
    if [ "${#SED_EXPRS[@]}" -gt 0 ]; then
      "${SED_I[@]}" -E "${SED_EXPRS[@]}" "$LOCK"
    fi
  fi'
export RELEASE_CI_NOTE="CI (release.yml) will now test, build the app clients (APK, Linux/macOS/Windows, iOS IPA), and publish the GitHub Release for <tag>."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
