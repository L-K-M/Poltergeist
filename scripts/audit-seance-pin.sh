#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
dart_executable="${DART_EXECUTABLE:-dart}"

exec "$dart_executable" run "$repo_root/tool/seance_pin_audit/bin/audit.dart" \
  --root "$repo_root" "$@"
