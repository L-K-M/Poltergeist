#!/usr/bin/env bash
set -euo pipefail

readonly bench_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$bench_dir/../.." && pwd)"
readonly profile_script="$repo_root/test/integration/network-profile.sh"
readonly output_file="$bench_dir/bench-results.json"
readonly dart_binary="${DART_BIN:-dart}"
readonly reset_output='reset'
readonly append_output='append'

run_bench() {
  (
    cd "$bench_dir"
    "$dart_binary" run bin/bench.dart "$@" \
      --host "$POLTERGEIST_SSHD" \
      --port "$POLTERGEIST_SSHD_MODERN" \
      --user "$POLTERGEIST_SSHD_USER" \
      --password "$POLTERGEIST_SSHD_PASSWORD" \
      --remote-root "$POLTERGEIST_SSHD_REMOTE_ROOT" \
      --identity "$POLTERGEIST_SSHD_KEY" \
      --output "$output_file"
  )
}

run_throughput_leg() {
  local link_name="$1"
  local output_mode="$2"
  local args=(throughput --link "$link_name")

  "$profile_script" lan
  if [[ "$link_name" != 'lan' ]]; then
    "$profile_script" rtt100
    local measured_rtt_ms
    measured_rtt_ms="$("$profile_script" measure-rtt-ms)"
    args+=(--rtt-ms "$measured_rtt_ms")
  fi
  if [[ "$output_mode" == "$reset_output" ]]; then
    args+=(--reset)
  fi

  run_bench "${args[@]}"
}

run_throughput_leg lan "$reset_output"

"$profile_script" lan
run_bench pipeline
run_bench algorithms

run_throughput_leg rtt100 "$append_output"

"$profile_script" lan
"$profile_script" rtt100
readonly pipeline_rtt_ms="$("$profile_script" measure-rtt-ms)"
run_bench pipeline --link rtt100 --rtt-ms "$pipeline_rtt_ms"

"$profile_script" lan
run_bench isolate

printf 'M0 results: %s\n' "$output_file"
