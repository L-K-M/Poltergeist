#!/usr/bin/env bash
# Parse imports and resolved dependencies; grep cannot classify plugins.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec dart --packages="$repo_root/.dart_tool/package_config.json" \
  "$repo_root/tool/import_guard/bin/check.dart" "$repo_root"
