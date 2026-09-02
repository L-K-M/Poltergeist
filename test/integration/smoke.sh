#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture.sh"

readonly fixture_user='poltergeist'
readonly user_key="$integration_dir/runtime/id_ed25519"
readonly remote_payload='/home/poltergeist/bench/fixtures/payload-1mb.bin'
readonly local_payload="$integration_dir/runtime/data/payload-1mb.bin"
readonly smoke_services=(
  sshd-modern
  sshd-legacy
  sshd-chroot
  sshd-restricted
  sshd-authmatrix
  sshd-rsa
  sshd-chacha
  sshd-ed25519
)

readonly scratch_dir="$(mktemp -d)"
trap 'rm -rf -- "$scratch_dir"' EXIT

download_fixture() {
  service_name="$1"
  service_port="$(resolve_service_port "$service_name")"
  destination="$scratch_dir/$service_name.bin"

  printf 'get %s %s\n' "$remote_payload" "$destination" \
    | sftp -q -b - \
      -i "$user_key" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -P "$service_port" \
      "$fixture_user@127.0.0.1"

  cmp "$local_payload" "$destination"
}

for service_name in "${smoke_services[@]}"; do
  download_fixture "$service_name"
done

# Same host:port must present a different key, then restore the original.
baseline_key="$(ssh-keyscan -T 5 -t ed25519 -p 2201 127.0.0.1 2>/dev/null)"
"$integration_dir/service-control.sh" swap
swapped_key="$(ssh-keyscan -T 5 -t ed25519 -p 2201 127.0.0.1 2>/dev/null)"
if [[ "$baseline_key" == "$swapped_key" ]]; then
  echo 'keyswap server presented the baseline key' >&2
  exit 1
fi

"$integration_dir/service-control.sh" restore-modern
restored_key="$(ssh-keyscan -T 5 -t ed25519 -p 2201 127.0.0.1 2>/dev/null)"
if [[ "$baseline_key" != "$restored_key" ]]; then
  echo 'modern server did not restore its host key' >&2
  exit 1
fi

# The restricted server must accept bytes, then reject metadata writes.
restricted_port="$(resolve_service_port sshd-restricted)"
restricted_target='/home/poltergeist/bench/uploads/restricted-smoke.bin'
printf 'put %s %s\n' "$local_payload" "$restricted_target" \
  | sftp -q -b - \
    -i "$user_key" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -P "$restricted_port" \
    "$fixture_user@127.0.0.1" >/dev/null

if printf 'chmod 600 %s\n' "$restricted_target" \
  | sftp -q -b - \
  -i "$user_key" \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -P "$restricted_port" \
  "$fixture_user@127.0.0.1" >/dev/null 2>&1; then
  echo 'restricted server accepted setstat' >&2
  exit 1
fi

printf 'rm %s\n' "$restricted_target" \
  | sftp -q -b - \
    -i "$user_key" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -P "$restricted_port" \
    "$fixture_user@127.0.0.1" >/dev/null
