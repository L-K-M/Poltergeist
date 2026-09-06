#!/usr/bin/env bash
# Parse imports and resolved dependencies; grep cannot classify plugins.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_config="$repo_root/.dart_tool/package_config.json"
if [ ! -f "$package_config" ]; then
  echo "error: missing $package_config; run dart pub get" >&2
  exit 2
fi

exec dart --packages="$package_config" \
  "$repo_root/tool/import_guard/bin/check.dart" "$repo_root"
