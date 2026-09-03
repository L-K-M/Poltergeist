#!/usr/bin/env bash
# 03 §1 dependency rules, checked mechanically:
#   - dartssh2 may be imported only inside poltergeist_core/lib/src/connection/
#     (the "UI never sees dartssh2" boundary, extended one level per the plan)
#   - the pure-Dart packages (packages/*) never import Flutter or plugins
# A stray import here reliably decays if only review enforces it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

# dartssh2 containment over every Dart source in the monorepo.
while IFS= read -r file; do
  if grep -qE "^[^/]*(import|export)\s+['\"]package:dartssh2/" "$file"; then
    case "$file" in
      "$repo_root"/packages/poltergeist_core/lib/src/connection/*) ;;
      *)
        echo "error: dartssh2 import outside poltergeist_core/lib/src/connection: $file" >&2
        status=1
        ;;
    esac
  fi
done < <(find "$repo_root/packages" "$repo_root/app" -name '*.dart' -not -path '*/.dart_tool/*' -type f)

# Pure-Dart packages stay Flutter-free (their tests run under dart test).
while IFS= read -r file; do
  if grep -qE "^[^/]*(import|export)\s+['\"]package:flutter/" "$file"; then
    echo "error: Flutter import in a pure-Dart package: $file" >&2
    status=1
  fi
done < <(find "$repo_root/packages" -name '*.dart' -not -path '*/.dart_tool/*' -type f)

exit "$status"
