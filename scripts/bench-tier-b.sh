#!/usr/bin/env bash
# D12 tier-B collector driver (08 §6/§8): runs the profile-mode UI
# benchmarks (P1/P2/P6 — app/poltergeist_app/integration_test/perf/) under
# Xvfb on Linux and merges their per-scenario documents — together with
# any per-scenario documents tier A already produced — into the single
# bench-results.json the job hands to test/benchmarks/check.dart.
#
# Mirrors scripts/bench-tier-a.sh's contract: every scenario runs even
# after a sibling fails (a failed drive still leaves whatever partial
# rows plus error rows the suite published), a scenario that produced no
# results file is flagged, and the script exits non-zero if any leg
# failed — the job reddens honestly instead of grading a silent subset.
#
# Unlike tier A this leg needs the Flutter toolchain and a display: the
# bench job installs the GTK toolchain and xvfb first. Local iteration
# can point XVFB_RUN at a wrapper (e.g. a pinned xkbdir) or set it to a
# pass-through such as `env` when a display already exists — a bare
# no-op like `true` would silently discard the whole flutter invocation.
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$script_dir/.." && pwd)"
readonly app_dir="$repo_root/app/poltergeist_app"
readonly flutter_binary="${FLUTTER_BIN:-flutter}"
readonly dart_binary="${DART_BIN:-dart}"
readonly xvfb_prefix="${XVFB_RUN:-xvfb-run -a}"
readonly fixture_root="$(mktemp -d /tmp/poltergeist-bench-b.XXXXXX)"

trap 'rm -rf -- "$fixture_root"' EXIT

cd "$repo_root"

# A drive run that dies before writing must surface as a missing file,
# never as a stale document from an earlier invocation — and a stale
# merged file must not mask a failed collection either.
rm -f -- "$repo_root"/bench-results.json \
         "$repo_root"/bench-results-p1.json \
         "$repo_root"/bench-results-p2.json \
         "$repo_root"/bench-results-p6.json

# Fail fast on a missing toolchain before touching 110 000 files.
command -v "$flutter_binary" >/dev/null || {
  echo "flutter binary not found: $flutter_binary" >&2
  exit 127
}
command -v "$dart_binary" >/dev/null || {
  echo "dart binary not found: $dart_binary" >&2
  exit 127
}

# Local filesystem fixtures only (08 §6): flat directories of empty
# entries. One touch per 5 000 names keeps ARG_MAX and fork count out of
# the measurement's way; the dirs live under a per-run temp root.
mkdir -p "$fixture_root/entries-10000" "$fixture_root/entries-100000"
seq -f "$fixture_root/entries-10000/entry-%06g" 10000 | xargs -n 5000 touch
seq -f "$fixture_root/entries-100000/entry-%06g" 100000 | xargs -n 5000 touch

# The flutterVersion fingerprint axis cannot be detected from inside the
# app — stamp the toolchain's own report. An unparsed value stays empty;
# the harness then records a null axis instead of a guess.
flutter_version="$(
  "$flutter_binary" --version --machine 2>/dev/null \
    | sed -n 's/.*"flutterVersion": *"\([^"]*\)".*/\1/p' || true
)"

defines=(
  "--dart-define=POLTERGEIST_BENCH_FIXTURE_ROOT=$fixture_root"
  "--dart-define=POLTERGEIST_BENCH_RUNNER_IMAGE=${POLTERGEIST_BENCH_RUNNER_IMAGE:-local}"
  "--dart-define=POLTERGEIST_BENCH_FLUTTER_VERSION=$flutter_version"
)
if [[ -n "${POLTERGEIST_BENCH_CPU_MODEL:-}" ]]; then
  defines+=(
    "--dart-define=POLTERGEIST_BENCH_CPU_MODEL=$POLTERGEIST_BENCH_CPU_MODEL"
  )
fi

status=0
run_scenario() {
  local scenario="$1" target="$2"
  # shellcheck disable=SC2086 # XVFB_RUN intentionally carries args.
  (cd "$app_dir" && $xvfb_prefix "$flutter_binary" drive \
    --driver=test_driver/integration_test.dart \
    --target="integration_test/perf/$target" \
    --device-id linux --profile \
    "--dart-define=POLTERGEIST_BENCH_OUTPUT=$repo_root/bench-results-$scenario.json" \
    "${defines[@]}") \
    || {
      local rc=$?
      echo "scenario $scenario drive failed (exit $rc)" >&2
      status="$rc"
    }
}

run_scenario p1 p1_first_paint_test.dart
run_scenario p2 p2_first_paint_test.dart
run_scenario p6 p6_scroll_test.dart

# Merge every per-scenario document present — tier A's included — into
# the one results file the checker reads (08 §6: one job, one file).
inputs=()
for scenario in p1 p2 p6 p3 p5 p7; do
  results_file="$repo_root/bench-results-$scenario.json"
  if [[ -f "$results_file" ]]; then
    inputs+=("$results_file")
  elif [[ "$scenario" == p1 || "$scenario" == p2 || "$scenario" == p6 ]]; then
    echo "scenario $scenario produced no results file" >&2
    status=1
  fi
done

if [[ "${#inputs[@]}" -gt 0 ]]; then
  "$dart_binary" run "$script_dir/merge_bench_results.dart" \
    --output "$repo_root/bench-results.json" "${inputs[@]}" || status="$?"
fi

if [[ "$status" -ne 0 ]]; then
  echo "tier-B collection incomplete (status $status); merging and " >&2
  echo "grading still ran on whatever the suites published" >&2
fi
exit "$status"
