#!/usr/bin/env bash
set -euo pipefail

readonly bench_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$bench_dir/../.." && pwd)"
readonly profile_script="${POLTERGEIST_M0_PROFILE_SCRIPT:-$repo_root/test/integration/network-profile.sh}"
readonly bench_command="${POLTERGEIST_M0_BENCH_COMMAND:-}"
readonly package_command="${POLTERGEIST_M0_PACKAGE_COMMAND:-}"
readonly output_file="$bench_dir/bench-results.json"
readonly attempts_file="$output_file.attempts.json"
readonly source_file="${POLTERGEIST_M0_SOURCE_FILE:-$bench_dir/bench-shard.json}"
readonly fixture_root="$repo_root/test/integration/runtime/data"
readonly upload_root="$repo_root/test/integration/runtime/uploads"
readonly dart_binary="${DART_BIN:-dart}"
readonly deadline_start_ms="${POLTERGEIST_M0_STARTED_AT_EPOCH_MS:-}"
readonly deadline_start_monotonic_us="${POLTERGEIST_M0_STARTED_AT_MONOTONIC_US:-}"
readonly reset_output='reset'
readonly append_output='append'
readonly usage_exit_status=2
readonly lan_profile='lan'
readonly shaped_profile='rtt100'
readonly full_shard='full'
readonly standard_shard='standard'
readonly isolated_shard_pattern='^rtt100-1gb-(download|upload)-(dart-hash-on|dart-hash-off|openssh)-r(1|2)$'
readonly full_throughput='full'
readonly standard_throughput='without-shaped-1gb'
readonly active_state='active'
readonly inactive_state='inactive'
readonly tool_finalization_owner='tool'
readonly lifecycle_finalization_owner='lifecycle'
readonly finalization_owner="${POLTERGEIST_M0_FINALIZATION_OWNER:-$tool_finalization_owner}"

network_profile_state="$inactive_state"
source_package_state="$inactive_state"

run_bench() {
  # Tests replace the driver so shard routing runs without Docker or SFTP.
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

run_source_package() {
  if [[ -n "$package_command" ]]; then
    "$package_command" "$@"
    return
  fi

  (
    cd "$bench_dir"
    "$dart_binary" run bin/package_source.dart "$@"
  )
}

run_cancellation_regression() {
  if [[ -n "$bench_command" ]]; then
    "$bench_command" cancellation-regression
    return
  fi

  (
    cd "$bench_dir"
    "$dart_binary" test --concurrency=1 \
      test/integration/isolate_cancellation_test.dart
  )
}

clear_network_profile() {
  local clear_status=0

  "$profile_script" "$lan_profile" || clear_status="$?"
  if [[ "$clear_status" -eq 0 ]]; then
    network_profile_state="$inactive_state"
  fi

  return "$clear_status"
}

finish_run() {
  local run_status="$?"
  local cleanup_status=0
  local effective_status
  local package_status=0

  trap - EXIT
  set +e

  if [[ "$network_profile_state" == "$active_state" ]]; then
    clear_network_profile
    cleanup_status="$?"
  fi

  effective_status="$run_status"
  if [[ "$effective_status" -eq 0 ]]; then
    effective_status="$cleanup_status"
  fi

  if [[ "$source_package_state" == "$active_state" ]]; then
    run_source_package finish \
      --output "$source_file" \
      --exit-status "$effective_status" \
      --rows "$output_file" \
      --attempts "$attempts_file"
    package_status="$?"
  fi

  if [[ "$effective_status" -ne 0 ]]; then
    exit "$effective_status"
  fi

  exit "$package_status"
}

prepare_source_package() {
  local shard_id="$1"

  # CI starts the failure envelope before fixture setup; local runs start here.
  if [[ ! -e "$source_file" ]]; then
    run_source_package start --output "$source_file" --shard "$shard_id"
  fi
  if [[ "$finalization_owner" == "$lifecycle_finalization_owner" ]]; then
    return
  fi
  source_package_state="$active_state"
}

run_rtt_bench() {
  local args=("$@")
  local measured_rtt_json
  local run_status=0
  local clear_status=0

  "$profile_script" "$lan_profile"
  network_profile_state="$active_state"
  "$profile_script" "$shaped_profile" || {
    run_status="$?"
    clear_network_profile || true
    return "$run_status"
  }
  measured_rtt_json="$("$profile_script" measure-rtt-json)" || {
    run_status="$?"
    clear_network_profile || true
    return "$run_status"
  }

  # The seven raw handshakes identify the shaped profile used by this call.
  run_bench "${args[@]}" --rtt-evidence="$measured_rtt_json" || run_status="$?"
  clear_network_profile || clear_status="$?"
  if [[ "$run_status" -ne 0 ]]; then
    return "$run_status"
  fi

  return "$clear_status"
}

run_throughput_leg() {
  local link_name="$1"
  local output_mode="$2"
  local throughput_slice="$3"
  local args=(
    throughput
    --link="$link_name"
    --fixture-root="$fixture_root"
    --upload-root="$upload_root"
  )

  if [[ "$throughput_slice" != "$full_throughput" ]]; then
    args+=(--throughput-slice="$throughput_slice")
  fi
  if [[ "$output_mode" == "$reset_output" ]]; then
    args+=(--reset)
  fi

  if [[ "$link_name" == "$shaped_profile" ]]; then
    run_rtt_bench "${args[@]}"
    return
  fi

  "$profile_script" "$lan_profile"
  run_bench "${args[@]}"
}

run_primary_suite() {
  local shaped_throughput="$1"

  # Prove isolate cancellation before the long throughput cells run.
  "$profile_script" "$lan_profile"
  run_cancellation_regression
  run_bench isolate --reset

  run_throughput_leg "$lan_profile" "$append_output" "$full_throughput"

  "$profile_script" "$lan_profile"
  run_bench pipeline
  run_bench algorithms

  run_throughput_leg "$shaped_profile" "$append_output" "$shaped_throughput"
  run_rtt_bench pipeline --link="$shaped_profile"

}

run_isolated_sample() {
  local shard_id="$1"

  if [[ -z "$deadline_start_ms" ]]; then
    echo 'POLTERGEIST_M0_STARTED_AT_EPOCH_MS is required.' >&2
    return "$usage_exit_status"
  fi
  if [[ -z "$deadline_start_monotonic_us" ]]; then
    echo 'POLTERGEIST_M0_STARTED_AT_MONOTONIC_US is required.' >&2
    return "$usage_exit_status"
  fi

  run_rtt_bench \
    throughput \
    --throughput-sample="$shard_id" \
    --link="$shaped_profile" \
    --deadline-start-ms="$deadline_start_ms" \
    --deadline-start-monotonic-us="$deadline_start_monotonic_us" \
    --fixture-root="$fixture_root" \
    --upload-root="$upload_root" \
    --reset
}

usage() {
  echo 'usage: run.sh [full|standard|rtt100-1gb-<direction>-<variant>-r<replicate>]' >&2
}

trap finish_run EXIT

if [[ "$#" -gt 1 ]]; then
  usage
  exit "$usage_exit_status"
fi

readonly shard="${1:-$full_shard}"

if [[ "$finalization_owner" != "$tool_finalization_owner" &&
      "$finalization_owner" != "$lifecycle_finalization_owner" ]]; then
  echo 'POLTERGEIST_M0_FINALIZATION_OWNER must be tool or lifecycle.' >&2
  exit "$usage_exit_status"
fi

case "$shard" in
  "$full_shard")
    run_primary_suite "$full_throughput"
    ;;
  "$standard_shard")
    prepare_source_package "$shard"
    run_primary_suite "$standard_throughput"
    ;;
  *)
    if [[ ! "$shard" =~ $isolated_shard_pattern ]]; then
      usage
      exit "$usage_exit_status"
    fi

    prepare_source_package "$shard"
    run_isolated_sample "$shard"
    ;;
esac

printf 'M0 %s results: %s\n' "$shard" "$output_file"
