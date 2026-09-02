#!/usr/bin/env bash
#
# Build every Poltergeist target this host can build, and print one clear
# summary. The single local entry point; CI builds the same targets in
# .github/workflows/ci.yml and release.yml. Poltergeist has no server
# component, so unlike Séance's build.sh there are only client targets:
#
#   app    — Flutter desktop app for THIS host (linux/macos/windows); platform
#            folders are committed once the app is scaffolded. On Linux,
#            release builds are also packaged into installable artifacts
#            (.deb + AppImage) via
#            scripts/package-linux.sh → dist/
#   apk    — Android APK (needs flutter + an Android SDK)
#
# Usage:
#   scripts/build.sh                 # every target this host can build
#   scripts/build.sh app             # just this one (naming a target turns an
#                                    # infeasible target into an error, not a skip)
#   scripts/build.sh --debug app     # debug-mode Flutter builds
#   scripts/build.sh --install       # build the app for THIS host and install
#                                    # it (macOS: /Applications/Poltergeist.app;
#                                    # Linux: ~/.local/opt/poltergeist), then
#                                    # reveal the installed copy
#
# Every produced file (.app bundle, APK, …) is also copied into dist/ at the
# repo root — one folder with the final artifacts — and on macOS dist/ is
# opened in the Finder when anything landed there.
#
# Exit status is non-zero if any requested target fails to build. Targets that
# simply can't build on this host (no flutter, no Android SDK, app not yet
# scaffolded) are reported as skipped, and only fail the run when you named
# them explicitly.
set -uo pipefail

# Absolute path to this script — usage() must find it after the cd below, even
# when invoked via a relative path from a subdirectory.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

APP_DIR="app/poltergeist_app"
PROFILE="release"
INSTALL=false
declare -a REQUESTED=()
EXPLICIT=0

usage() {
  # Print the leading comment block (the file header), minus the shebang.
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SELF"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --debug) PROFILE="debug"; shift ;;
    --install) INSTALL=true; shift ;;
    app|apk) REQUESTED+=("$1"); EXPLICIT=1; shift ;;
    all) REQUESTED=(app apk); EXPLICIT=1; shift ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

# --install is about the host platform's app: with no explicit targets it
# builds just that (not the whole matrix), and with explicit targets it makes
# sure `app` is among them.
if $INSTALL; then
  if [[ ${#REQUESTED[@]} -eq 0 ]]; then
    REQUESTED=(app); EXPLICIT=1
  else
    found=0
    for t in "${REQUESTED[@]}"; do [[ "$t" == "app" ]] && found=1; done
    [[ $found -eq 0 ]] && REQUESTED+=(app)
  fi
fi

# Default to all targets; feasibility is decided per-target below.
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  REQUESTED=(app apk)
fi

case "$(uname -s)" in
  Darwin) HOST="macos" ;;
  Linux) HOST="linux" ;;
  MINGW*|MSYS*|CYGWIN*) HOST="windows" ;;
  *) HOST="unknown" ;;
esac

echo "Poltergeist build"
echo "  host:    $HOST ($(uname -s))"
echo "  profile: $PROFILE"
echo "  targets: ${REQUESTED[*]}"
echo

have() { command -v "$1" >/dev/null 2>&1; }

declare -a RESULTS=()
record() { RESULTS+=("$1"); }   # "app: built -> …" | "app: skipped (…)" | "apk: FAILED"

# Collect a finished artifact into dist/ (file or directory). The staged copy
# is what the summary points at — one folder with everything this run built.
DIST="$ROOT/dist"
STAGED=0
stage() {
  local src="$1" name="${2:-$(basename "$1")}"
  mkdir -p "$DIST"
  rm -rf "${DIST:?}/$name"
  cp -R "$src" "$DIST/$name" || return 1
  STAGED=$((STAGED + 1))
  echo "-- staged dist/$name"
}

# Was a given target explicitly named on the command line?
was_named() {
  [[ $EXPLICIT -eq 1 ]] || return 1
  local t
  for t in "${REQUESTED[@]}"; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

# Skip a target: a soft skip on a default run, a hard error when named.
skip_or_fail() {
  local target="$1" reason="$2"
  if was_named "$target"; then
    echo "!! $target: cannot build on this host — $reason" >&2
    record "$target: FAILED ($reason)"
    return 1
  fi
  echo ".. $target: skipped — $reason"
  record "$target: skipped ($reason)"
  return 0
}

# ---------------------------------------------------------------------------
# Platform folders carry identity, icons, and entitlements. Never replace a
# missing committed scaffold with Flutter's stock output.
ensure_platform() {
  local platform="$1"
  [[ -d "$APP_DIR/$platform" ]] && return 0

  echo "!! $APP_DIR/$platform platform scaffold is missing; restore it from git" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Linux installers (.deb + AppImage) for a just-built bundle. build.sh stays
# the orchestrator; the actual packaging logic lives in package-linux.sh.
package_linux() {
  # Debug builds aren't for distributing, and the .deb needs dpkg-deb.
  if [[ "$PROFILE" != "release" ]]; then
    record "packages: skipped (debug profile)"
    return 0
  fi
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo ".. packages: .deb unavailable without dpkg-deb — scripts/package-linux.sh builds the AppImage anyway"
    # No dpkg-deb → package-linux.sh itself falls back to AppImage-only.
  fi
  echo "== packages (deb + AppImage, via scripts/package-linux.sh) =="
  # best-effort AppImage: fetching appimagetool can fail on an offline host,
  # and the local path shouldn't hard-fail on that — CI runs the same script
  # in required mode and catches real breakage.
  if scripts/package-linux.sh --appimage=best-effort; then
    local f staged=""
    for f in dist/poltergeist_*.deb dist/poltergeist-linux-*.AppImage; do
      [[ -e "$f" ]] || continue
      record "packages: $(basename "$f") -> dist/"
      staged=1
    done
    [[ -n "$staged" ]] || record "packages: built (nothing staged?)"
  else
    echo "!! packages: package-linux.sh failed" >&2
    record "packages: FAILED"
    return 1
  fi
}

build_app() {
  echo "== app (Flutter desktop, this host) =="
  if [[ "$HOST" == "unknown" ]]; then
    skip_or_fail app "unrecognized host platform"; return
  fi
  if [[ ! -d "$APP_DIR" ]]; then
    skip_or_fail app "$APP_DIR not scaffolded yet (see docs/plan/)"; return
  fi
  if ! have flutter; then skip_or_fail app "Flutter SDK (flutter) not found"; return; fi
  if ! ensure_platform "$HOST"; then
    record "app: FAILED (platform scaffold missing)"; return 1
  fi
  local mode_flag=""
  [[ "$PROFILE" == "debug" ]] && mode_flag="--debug"
  echo "-- flutter build $HOST ${mode_flag}"
  if ( cd "$APP_DIR" && flutter pub get && flutter build "$HOST" $mode_flag ); then
    # Stage the final product; the nested output path differs per platform
    # (and per arch on linux), so glob for it. Poltergeist is ASCII, so no
    # post-sign rename is needed on macOS (Séance's accented name needs one).
    local cfg="Release" out=""
    [[ "$PROFILE" == "debug" ]] && cfg="Debug"
    case "$HOST" in
      macos)
        out=$(ls -d "$APP_DIR"/build/macos/Build/Products/"$cfg"/*.app 2>/dev/null | head -1)
        [[ -n "$out" ]] && stage "$out" "Poltergeist.app"
        ;;
      linux)
        out=$(ls -d "$APP_DIR"/build/linux/*/"$PROFILE"/bundle 2>/dev/null | head -1)
        [[ -n "$out" ]] && stage "$out" "poltergeist-linux"
        ;;
      windows)
        out=$(ls -d "$APP_DIR"/build/windows/*/runner/"$cfg" 2>/dev/null | head -1)
        [[ -n "$out" ]] && stage "$out" "poltergeist-windows"
        ;;
    esac
    if [[ -n "$out" ]]; then
      record "app: built ($HOST, $PROFILE) -> dist/"
    else
      record "app: built ($HOST, $PROFILE) — product not found to stage"
    fi
    # Propagate packaging failure to the exit status (FAILED is the global the
    # target loop reads) while still letting a subsequent --install proceed —
    # installing the freshly built bundle is independent of .deb/AppImage
    # packaging. Séance's build.sh drops this status; deliberate fix here.
    if [[ "$HOST" == "linux" ]]; then package_linux || FAILED=1; fi
    if $INSTALL; then
      if [[ -z "$out" ]]; then
        echo "!! app: nothing to install (product not found)" >&2
        record "app: install FAILED (product not found)"; return 1
      fi
      case "$HOST" in
        macos)
          echo "-- installing /Applications/Poltergeist.app"
          rm -rf "/Applications/Poltergeist.app"
          # ditto preserves the signature, resource forks, and permissions.
          if ditto "$out" "/Applications/Poltergeist.app"; then
            INSTALLED="/Applications/Poltergeist.app"
            record "app: installed -> /Applications/Poltergeist.app"
            # Replacing a bundle in place leaves LaunchServices with the OLD
            # registration for the path; it then refuses to open the app with
            # error -10810 even though the bundle runs fine. Force a
            # re-registration on every install.
            LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            if [[ -x "$LSREG" ]]; then
              "$LSREG" -f "$INSTALLED" >/dev/null 2>&1 || true
            fi
            # Post-install sanity: surface the known "can't be opened" causes
            # here, instead of leaving Finder's generic refusal as the only
            # signal.
            if ! codesign --verify --deep --strict "$INSTALLED" 2>/dev/null; then
              echo "!! app: $INSTALLED fails codesign verification — it will not launch." >&2
              record "app: WARNING — installed app fails codesign verify"
            fi
            if codesign -d --entitlements - "$INSTALLED" 2>/dev/null \
                | grep -q keychain-access-groups; then
              echo "!! app: the installed build still carries the restricted" >&2
              echo "   keychain-access-groups entitlement, which blocks ad-hoc-signed" >&2
              echo "   launches — the checkout or build is stale. Fix with:" >&2
              echo "     git pull && (cd $APP_DIR && flutter clean) && scripts/build.sh --install" >&2
              record "app: WARNING — stale build with keychain-access-groups"
            fi
          else
            record "app: install FAILED (ditto)"; return 1
          fi
          ;;
        linux)
          echo "-- installing $HOME/.local/opt/poltergeist"
          rm -rf "$HOME/.local/opt/poltergeist" && mkdir -p "$HOME/.local/opt"
          if cp -R "$out" "$HOME/.local/opt/poltergeist"; then
            INSTALLED="$HOME/.local/opt/poltergeist"
            record "app: installed -> ~/.local/opt/poltergeist (binary: poltergeist)"
          else
            record "app: install FAILED (copy)"; return 1
          fi
          ;;
        *)
          echo "!! app: --install is not supported on $HOST" >&2
          record "app: install FAILED (unsupported on $HOST)"; return 1
          ;;
      esac
    fi
  else
    echo "!! app: flutter build $HOST failed" >&2
    record "app: FAILED (flutter build $HOST)"; return 1
  fi
}

# ---------------------------------------------------------------------------
# An installed Android SDK is what separates "can build the APK" from a long
# doomed Gradle run; probe the usual locations like `flutter doctor` does.
detect_android_sdk() {
  local c
  for c in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
           "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [[ -n "$c" && -d "$c/platforms" ]] && { echo "$c"; return 0; }
  done
  return 1
}

build_apk() {
  echo "== apk (Android) =="
  if [[ ! -d "$APP_DIR" ]]; then
    skip_or_fail apk "$APP_DIR not scaffolded yet (see docs/plan/)"; return
  fi
  if ! have flutter; then skip_or_fail apk "Flutter SDK (flutter) not found"; return; fi
  local sdk
  if ! sdk="$(detect_android_sdk)"; then
    skip_or_fail apk "no Android SDK found (set ANDROID_SDK_ROOT, or install one via Android Studio)"; return
  fi
  echo "-- Android SDK: $sdk"
  if ! ensure_platform android; then
    record "apk: FAILED (platform scaffold missing)"; return 1
  fi
  local mode_flag=""
  [[ "$PROFILE" == "debug" ]] && mode_flag="--debug"
  echo "-- flutter build apk ${mode_flag}"
  if ( cd "$APP_DIR" && flutter pub get && flutter build apk $mode_flag ); then
    local apk
    apk="$(ls "$APP_DIR"/build/app/outputs/flutter-apk/*.apk 2>/dev/null | head -1)"
    [[ -n "$apk" ]] && stage "$apk" "poltergeist.apk"
    record "apk: built ($PROFILE)${apk:+ -> dist/poltergeist.apk}"
  else
    echo "!! apk: flutter build apk failed" >&2
    record "apk: FAILED (flutter build apk)"; return 1
  fi
}

# ---------------------------------------------------------------------------
FAILED=0
INSTALLED=""
for target in "${REQUESTED[@]}"; do
  case "$target" in
    app)    build_app    || FAILED=1 ;;
    apk)    build_apk    || FAILED=1 ;;
  esac
  echo
done

echo "Summary"
for line in "${RESULTS[@]}"; do echo "  $line"; done

# Reveal the result: the installed copy when --install ran, else the dist/
# folder with everything this run produced (macOS only — elsewhere the paths
# in the summary are the deliverable).
if [[ -n "$INSTALLED" ]]; then
  echo "  installed: $INSTALLED"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    open -R "$INSTALLED"          # Finder, with the app selected
  elif have xdg-open; then
    xdg-open "$INSTALLED" >/dev/null 2>&1 || true
  fi
elif [[ "$STAGED" -gt 0 ]]; then
  echo "  artifacts: $DIST"
  if [[ "$(uname -s)" == "Darwin" ]]; then open "$DIST"; fi
fi

exit "$FAILED"
