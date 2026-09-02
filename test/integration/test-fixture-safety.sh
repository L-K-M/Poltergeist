#!/usr/bin/env bash
set -euo pipefail

readonly integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly checker="$integration_dir/check_config.dart"
readonly dart_binary="${DART_BIN:-dart}"

render() {
  UNSAFE_PORT=2201 docker compose --file "$1" config --format json
}

expect_rejected() {
  case_file="$1"
  rendered_config="$(render "$case_file")"

  if printf '%s\n' "$rendered_config" \
    | "$dart_binary" run "$checker" >/dev/null 2>&1; then
    echo "unsafe case passed: $case_file" >&2
    exit 1
  fi
}

render "$integration_dir/safety-cases/safe-loopback.yml" \
  | "$dart_binary" run "$checker" >/dev/null

expect_rejected "$integration_dir/safety-cases/unsafe-bare.yml"
expect_rejected "$integration_dir/safety-cases/unsafe-quoted.yml"
expect_rejected "$integration_dir/safety-cases/unsafe-interpolated.yml"
expect_rejected "$integration_dir/safety-cases/unsafe-long.yml"
expect_rejected "$integration_dir/safety-cases/unsafe-host-network.yml"
