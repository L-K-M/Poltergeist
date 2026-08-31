#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture.sh"

readonly runtime_dir="$integration_dir/runtime"
readonly user_key="$runtime_dir/id_ed25519"
readonly full_mode='full'
readonly lifecycle_mode='lifecycle-only'
readonly services=(
  sshd-modern
  sshd-legacy
  sshd-chroot
  sshd-restricted
  sshd-authmatrix
  sshd-rsa
  sshd-chacha
  sshd-ed25519
)

down() {
  compose --profile audit --profile keyswap down --remove-orphans
}

on_exit() {
  test_status="$?"
  trap - EXIT

  cleanup_status=0
  down || cleanup_status="$?"
  if [[ "$test_status" -ne 0 ]]; then
    exit "$test_status"
  fi

  exit "$cleanup_status"
}

run_mode="$full_mode"
if [[ "${1:-}" == '--lifecycle-only' ]]; then
  run_mode="$lifecycle_mode"
  shift

  if [[ "${1:-}" != '--' ]]; then
    echo 'usage: run.sh [--lifecycle-only -- COMMAND...]' >&2
    exit 2
  fi
  shift

  if [[ "$#" -eq 0 ]]; then
    echo 'lifecycle-only mode requires a command' >&2
    exit 2
  fi
elif [[ "$#" -ne 0 ]]; then
  echo 'usage: run.sh [--lifecycle-only -- COMMAND...]' >&2
  exit 2
fi

command -v docker >/dev/null
command -v ssh-keygen >/dev/null
command -v sftp >/dev/null
command -v "$dart_binary" >/dev/null
docker compose version >/dev/null

trap on_exit EXIT

down
"$integration_dir/test-fixture-safety.sh"
check_rendered_config
"$integration_dir/assert-private-keys-scoped.sh"
"$integration_dir/generate-data.sh"

mkdir -p "$runtime_dir"
rm -f -- "$user_key" "$user_key.pub"
ssh-keygen -q -t ed25519 -N '' -C 'poltergeist integration user' \
  -f "$user_key"

compose --profile audit up --detach --build

for service_name in "${services[@]}"; do
  wait_for_service "$service_name"
done

export POLTERGEIST_SSHD='127.0.0.1'
export POLTERGEIST_SSHD_MODERN='2201'
export POLTERGEIST_SSHD_LEGACY='2202'
export POLTERGEIST_SSHD_CHROOT='2203'
export POLTERGEIST_SSHD_RESTRICTED='2204'
export POLTERGEIST_SSHD_AUTHMATRIX='2205'
export POLTERGEIST_SSHD_RSA='2211'
export POLTERGEIST_SSHD_CHACHA='2212'
export POLTERGEIST_SSHD_ED25519='2213'
export POLTERGEIST_SSHD_USER='poltergeist'
export POLTERGEIST_SSHD_KEY="$user_key"
export POLTERGEIST_SSHD_PASSWORD='poltergeist-test-only'
export POLTERGEIST_SSHD_REMOTE_ROOT='/home/poltergeist/bench'

cd "$repo_root"

"$integration_dir/smoke.sh"

if [[ "$run_mode" == "$lifecycle_mode" ]]; then
  "$@"
  exit
fi

for package_name in poltergeist_core poltergeist_sync; do
  package_path="$repo_root/packages/$package_name"
  [[ -d "$package_path/test/integration" ]] || continue

  "$dart_binary" test --concurrency=1 -t integration "$package_path"
done
