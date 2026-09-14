#!/usr/bin/env bash
# Legacy compatibility entrypoint: forwards to the relocated harness at
# packages/poltergeist_bench (07 §3.4). Arguments and environment hooks pass
# through unchanged; results land next to the harness.
set -euo pipefail

readonly bench_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$bench_dir/../.." && pwd)"

exec "$repo_root/packages/poltergeist_bench/run.sh" "$@"
