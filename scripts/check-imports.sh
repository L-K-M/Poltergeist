#!/usr/bin/env bash
# 03 §1 dependency rules, checked mechanically:
#   - dartssh2 may be imported only inside poltergeist_core/lib/src/connection/
#     (the "UI never sees dartssh2" boundary, extended one level per the plan)
#   - the pure-Dart packages (packages/*) never import Flutter or its test
#     libraries (plugin imports such as path_provider are not yet detected
#     mechanically; a pubspec-driven allowlist would be needed for that)
#
# Scope is the product packages and app — tool/ (the M0 bench harness) is the
# plan-sanctioned dartssh2 consumer outside the connection module (07 §3.1)
# and is deliberately not scanned.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

for d in "$repo_root/packages" "$repo_root/app"; do
  if [ ! -d "$d" ]; then
    echo "error: expected directory missing: $d" >&2
    exit 1
  fi
done

# dartssh2 containment over the product's Dart sources. Both directives and
# both quote styles match — an `export` outside the connection module
# re-exposes dartssh2 just as much as an import.
while IFS= read -r file; do
  if grep -qE "^[^/]*(import|export)[[:space:]]+['\"]package:dartssh2/" "$file"; then
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
  if grep -qE "^[^/]*(import|export)[[:space:]]+['\"]package:flutter(_test|_localizations)?/" "$file"; then
    echo "error: Flutter import in a pure-Dart package: $file" >&2
    status=1
  fi
done < <(find "$repo_root/packages" -name '*.dart' -not -path '*/.dart_tool/*' -type f)

exit "$status"
