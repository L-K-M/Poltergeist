#!/usr/bin/env bash
set -euo pipefail

readonly repository_root="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
  pwd
)"
readonly app_root="$repository_root/app/poltergeist_app"
readonly pubspec="$app_root/pubspec.yaml"
readonly apk="$app_root/build/app/outputs/flutter-apk/app-release.apk"

if [[ ! -f "$pubspec" ]]; then
  echo "expected app pubspec not found: $pubspec" >&2
  exit 1
fi

analyzer=""
if [[ -n "${ANDROID_HOME:-}" ]]; then
  candidate="$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer"
  [[ -x "$candidate" ]] && analyzer="$candidate"
fi
if [[ -z "$analyzer" ]]; then
  analyzer="$(command -v apkanalyzer || true)"
fi
if [[ -z "$analyzer" ]]; then
  echo "apkanalyzer not found; set ANDROID_HOME or PATH" >&2
  exit 1
fi
readonly analyzer

expected_code="$(sed -n 's/^version: [^+]*+//p' "$pubspec")"
if [[ ! "$expected_code" =~ ^[0-9]+$ ]]; then
  echo "app pubspec has no numeric version code" >&2
  exit 1
fi

if [[ ! -f "$apk" ]]; then
  echo "expected APK not found: $apk" >&2
  exit 1
fi

actual_code="$("$analyzer" manifest version-code "$apk")"
if [[ "$actual_code" == "$expected_code" ]]; then
  exit 0
fi

echo "APK versionCode $actual_code, expected $expected_code" >&2
exit 1
