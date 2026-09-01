#!/usr/bin/env bash
set -euo pipefail

readonly bench_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$bench_dir/../.." && pwd)"
readonly profile_script="${POLTERGEIST_M0_PROFILE_SCRIPT:-$repo_root/test/integration/network-profile.sh}"
readonly bench_command="${POLTERGEIST_M0_BENCH_COMMAND:-}"
readonly output_file="$bench_dir/bench-results.json"
readonly dart_binary="${DART_BIN:-dart}"
readonly reset_output='reset'
readonly append_output='append'
readonly full_shard='full'
readonly standard_shard='standard'
readonly slow_shard='rtt100-1gb-upload'
readonly full_throughput='full'
readonly standard_throughput='without-1gb-upload'
readonly slow_throughput='only-1gb-upload'

run_bench() {
  # Tests replace both drivers so shard routing runs without Docker or SFTP.
  if [[ -n "$bench_command" ]]; then
    "$bench_command" "$@"
    return
  fi

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
  local throughput_slice="$3"
  local args=(throughput --link "$link_name")

  if [[ "$throughput_slice" != "$full_throughput" ]]; then
    args+=("--throughput-slice=$throughput_slice")
  fi
  if [[ "$output_mode" == "$reset_output" ]]; then
    args+=(--reset)
  fi

  if [[ "$link_name" == 'rtt100' ]]; then
    run_rtt_bench "${args[@]}"
    return
  fi

  "$profile_script" lan
  run_bench "${args[@]}"
}

run_rtt_bench() {
  local args=("$@")
  local measured_rtt_ms
  local run_status=0
  local clear_status=0

  "$profile_script" lan
  "$profile_script" rtt100 || {
    run_status="$?"
    "$profile_script" lan || true
    return "$run_status"
  }
  measured_rtt_ms="$("$profile_script" measure-rtt-ms)" || {
    run_status="$?"
    "$profile_script" lan || true
    return "$run_status"
  }

  # One measured qdisc covers every warmup and timed trial in this call.
  run_bench "${args[@]}" --rtt-ms "$measured_rtt_ms" || run_status="$?"
  "$profile_script" lan || clear_status="$?"
  if [[ "$run_status" -ne 0 ]]; then
    return "$run_status"
  fi

  return "$clear_status"
}

run_primary_suite() {
  local shaped_throughput="$1"

  run_throughput_leg lan "$reset_output" "$full_throughput"

  "$profile_script" lan
  run_bench pipeline
  run_bench algorithms

  run_throughput_leg rtt100 "$append_output" "$shaped_throughput"
  run_rtt_bench pipeline --link rtt100

  "$profile_script" lan
  run_bench isolate
}

usage() {
  echo "usage: run.sh [$full_shard|$standard_shard|$slow_shard]" >&2
}

if [[ "$#" -gt 1 ]]; then
  usage
  exit 2
fi

readonly shard="${1:-$full_shard}"

case "$shard" in
  "$full_shard")
    run_primary_suite "$full_throughput"
    ;;
  "$standard_shard")
    run_primary_suite "$standard_throughput"
    ;;
  "$slow_shard")
    run_throughput_leg rtt100 "$reset_output" "$slow_throughput"
    ;;
  *)
    usage
    exit 2
    ;;
esac

printf 'M0 %s results: %s\n' "$shard" "$output_file"
