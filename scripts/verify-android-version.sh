#!/usr/bin/env bash
set -euo pipefail

readonly repository_root="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
  pwd
)"
readonly app_root="$repository_root/app/poltergeist_app"
readonly pubspec="$app_root/pubspec.yaml"
readonly apk="$app_root/build/app/outputs/flutter-apk/app-release.apk"
readonly android_tools="${ANDROID_HOME:?ANDROID_HOME is required}/cmdline-tools/latest/bin"
readonly analyzer="$android_tools/apkanalyzer"

expected_code="$(sed -n 's/^version: [^+]*+//p' "$pubspec")"
if [[ ! "$expected_code" =~ ^[0-9]+$ ]]; then
  echo "app pubspec has no numeric version code" >&2
  exit 1
fi

actual_code="$("$analyzer" manifest version-code "$apk")"
if [[ "$actual_code" == "$expected_code" ]]; then
  exit 0
fi

echo "APK versionCode $actual_code, expected $expected_code" >&2
exit 1
