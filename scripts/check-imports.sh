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

# Deterministic grep behavior regardless of the runner's locale — character
# ranges like [_a-z0-9] must mean the same thing everywhere.
export LC_ALL=C

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

for d in "$repo_root/packages" "$repo_root/app"; do
  if [ ! -d "$d" ]; then
    echo "error: expected directory missing: $d" >&2
    exit 1
  fi
done

# Comment stripping is deliberately coarse but one-sided safe: pure
# line/doc comments are dropped; a whole-line block comment is dropped
# too, while `/* note */ import …` on one line stays visible (its import
# is real code). The pattern grep reads its whole input (no `-q`): under
# `pipefail`, `-q`'s early exit SIGPIPEs the stripping grep and the
# pipeline reports "no match" on exactly the violations that matter.
strip_comments() {
  grep -vE '^[[:space:]]*(//|\*|/\*.*\*/[[:space:]]*$)'
}

# Grep exit codes: 0 match, 1 no match, 2 error. A scan error must fail
# closed — under a plain `if`, exit 2 would read as "compliant". The
# comment strip is checked separately so its failures cannot be masked
# either.
_violation() {
  local pattern="$1" file="$2" rc=0 stripped
  # grep -v exits 1 when every line is stripped (an all-comment file) —
  # that is a successful strip, not a scan error; only 2+ fails.
  stripped="$(strip_comments "$file" || rc=$?)"
  if [ "$rc" -ge 2 ]; then
    echo "error: could not scan $file (comment strip failed)" >&2
    exit 2
  fi
  rc=0
  printf '%s\n' "$stripped" | grep -E "$pattern" > /dev/null || rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "error: could not scan $file (grep exit $rc)" >&2
    exit 2
  fi
  return "$rc"
}

dartssh2_violation() {
  _violation 'package:dartssh2/' "$1"
}

# find failures inside a process substitution are invisible (its exit
# status is discarded); materialize the file lists and fail hard instead.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

find "$repo_root/packages" "$repo_root/app" -name '*.dart' \
  -not -path '*/.dart_tool/*' -not -path '*/build/*' \
  -not -path '*/.symlinks/*' -not -path '*/ephemeral/*' -type f \
  > "$tmpdir/dartssh2_scan.txt" || exit 1

while IFS= read -r file; do
  if dartssh2_violation "$file"; then
    case "$file" in
      "$repo_root"/packages/poltergeist_core/lib/src/connection/*) ;;
      *)
        echo "error: dartssh2 reference outside poltergeist_core/lib/src/connection (import, export, or string/trailing-comment mention): $file" >&2
        status=1
        ;;
    esac
  fi
done < "$tmpdir/dartssh2_scan.txt"

# Pure-Dart packages stay Flutter-free (their tests run under dart test) —
# Flutter's libraries, its test libs, and dart:ui / dart:ui_web alike.
flutter_violation() {
  _violation "(package:(flutter[_a-z0-9]*|integration_test)/|dart:ui(_[a-z0-9_]+)?([^a-z0-9_]|\$))" "$1"
}

find "$repo_root/packages" -name '*.dart' \
  -not -path '*/.dart_tool/*' -not -path '*/build/*' \
  -not -path '*/.symlinks/*' -not -path '*/ephemeral/*' -type f \
  > "$tmpdir/flutter_scan.txt" || exit 1

while IFS= read -r file; do
  if flutter_violation "$file"; then
    echo "error: Flutter reference in a pure-Dart package (import, export, or string/trailing-comment mention): $file" >&2
    status=1
  fi
done < "$tmpdir/flutter_scan.txt"

# Close the declaration gap: a pure-Dart package that declares a Flutter
# SDK dependency fails even before any import exists (its tests could not
# run under dart test anyway — fail at the boundary instead).
for pubspec in "$repo_root/packages"/*/pubspec.yaml; do
  if grep -qE 'sdk:[[:space:]]*flutter' "$pubspec"; then
    echo "error: Flutter SDK dependency declared in a pure-Dart package: $pubspec" >&2
    status=1
  fi
done

exit "$status"
