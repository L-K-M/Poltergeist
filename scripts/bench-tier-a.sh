#!/usr/bin/env bash
# D12 tier-A collector driver (08 §6/§8) — the bench job's child under
# `test/integration/run.sh --lifecycle-only`, which owns the compose
# lifecycle (up, banner-exchange readiness, POLTERGEIST_SSHD* exports,
# trap teardown); this script never brings the fixture up or down.
#
# Each collector is compiled AOT (`dart compile exe` — JIT numbers can
# never gate a budget, 08 §6), run against the loopback fixture, and its
# per-scenario document is merged into the single bench-results.json the
# job hands to test/benchmarks/check.dart. Every collector runs even
# after a sibling fails — a failed collector still publishes its partial
# rows plus an error row — and the script exits non-zero if any did, so
# the job reddens honestly instead of grading a silent subset.
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$script_dir/.." && pwd)"
readonly core_dir="$repo_root/packages/poltergeist_core"
readonly dart_binary="${DART_BIN:-dart}"
readonly remote_root="${POLTERGEIST_SSHD_REMOTE_ROOT:-/home/poltergeist/bench}"
readonly bin_dir="$(mktemp -d /tmp/poltergeist-bench-a.XXXXXX)"

trap 'rm -rf -- "$bin_dir"' EXIT

# The collectors resolve the committed fixture host key and write their
# outputs relative to the working directory; run.sh already cd'd here,
# but the script is runnable standalone, so anchor it explicitly.
cd "$repo_root"

command -v "$dart_binary" >/dev/null

"$dart_binary" compile exe \
  "$core_dir/benchmark/p3_listing_overhead.dart" -o "$bin_dir/p3"
"$dart_binary" compile exe \
  "$core_dir/benchmark/p5_drop_to_start.dart" -o "$bin_dir/p5"
"$dart_binary" compile exe \
  "$core_dir/benchmark/p7_scan_rate.dart" -o "$bin_dir/p7"

status=0
run_collector() {
  local scenario="$1"
  shift
  "$bin_dir/$scenario" --output "$repo_root/bench-results-$scenario.json" "$@" \
    || status="$?"
}

# Fixture paths per the collector READMEs: P3/P5 measure the committed
# 10 000-entry tree (P3 against the near-empty bench root as control);
# P7 scans the whole fixtures tree (≈ 10 800 entries).
run_collector p3 \
  --target "$remote_root/fixtures/entries-10000" \
  --control "$remote_root"
run_collector p5 \
  --target "$remote_root/fixtures/entries-10000"
run_collector p7 \
  --target "$remote_root/fixtures"

inputs=()
for scenario in p3 p5 p7; do
  results_file="$repo_root/bench-results-$scenario.json"
  if [[ -f "$results_file" ]]; then
    inputs+=("$results_file")
  else
    echo "collector $scenario produced no results file" >&2
    status=1
  fi
done

if [[ "${#inputs[@]}" -gt 0 ]]; then
  "$dart_binary" run "$script_dir/merge_bench_results.dart" \
    --output "$repo_root/bench-results.json" "${inputs[@]}" || status="$?"
fi

if [[ "$status" -ne 0 ]]; then
  echo "tier-A collection incomplete (status $status); merging and " >&2
  echo "grading still ran on whatever the collectors published" >&2
fi
exit "$status"
