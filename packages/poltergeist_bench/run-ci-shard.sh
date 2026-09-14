#!/usr/bin/env bash
set -euo pipefail

readonly bench_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$bench_dir/../.." && pwd)"
readonly lifecycle_command="${POLTERGEIST_M0_LIFECYCLE_COMMAND:-}"
readonly finalizer_command="${POLTERGEIST_M0_FINALIZER_COMMAND:-$bench_dir/finalize-source.sh}"
readonly usage_exit_status=2

run_lifecycle() {
  local shard_id="$1"

  if [[ -n "$lifecycle_command" ]]; then
    "$lifecycle_command" "$shard_id"
    return
  fi

  "$repo_root/test/integration/run.sh" --lifecycle-only -- \
    "$bench_dir/run.sh" "$shard_id"
}

if [[ "$#" -ne 1 ]]; then
  echo 'usage: run-ci-shard.sh SHARD' >&2
  exit "$usage_exit_status"
fi

readonly shard="$1"

# The outer finalizer terminalizes failures before the benchmark child starts.
export POLTERGEIST_M0_STARTED_AT_EPOCH_MS="${POLTERGEIST_M0_STARTED_AT_EPOCH_MS:-$(date +%s%3N)}"
export POLTERGEIST_M0_FINALIZATION_OWNER='lifecycle'
export POLTERGEIST_INTEGRATION_LIFECYCLE_FINALIZER="$finalizer_command"

set +e
run_lifecycle "$shard"
lifecycle_status="$?"
"$finalizer_command" "$lifecycle_status"
finalizer_status="$?"
set -e

if [[ "$lifecycle_status" -ne 0 ]]; then
  exit "$lifecycle_status"
fi

exit "$finalizer_status"
