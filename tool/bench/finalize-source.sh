#!/usr/bin/env bash
set -euo pipefail

readonly bench_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly package_command="${POLTERGEIST_M0_PACKAGE_COMMAND:-}"
readonly source_file="${POLTERGEIST_M0_SOURCE_FILE:-$bench_dir/bench-shard.json}"
readonly output_file="$bench_dir/bench-results.json"
readonly attempts_file="$output_file.attempts.json"
readonly dart_binary="${DART_BIN:-dart}"
readonly usage_exit_status=2

if [[ "$#" -ne 1 || ! "$1" =~ ^[0-9]+$ || "$1" -gt 255 ]]; then
  echo 'usage: finalize-source.sh EXIT_STATUS' >&2
  exit "$usage_exit_status"
fi

readonly lifecycle_status="$1"
readonly arguments=(
  finish
  --output "$source_file"
  --exit-status "$lifecycle_status"
  --rows "$output_file"
  --attempts "$attempts_file"
)

if [[ -n "$package_command" ]]; then
  "$package_command" "${arguments[@]}"
  exit
fi

cd "$bench_dir"
"$dart_binary" run bin/package_source.dart "${arguments[@]}"
