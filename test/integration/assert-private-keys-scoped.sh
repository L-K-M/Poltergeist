#!/usr/bin/env bash
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly openssh_header="BEGIN OPENSSH"' PRIVATE KEY'
readonly rsa_header="BEGIN RSA"' PRIVATE KEY'
readonly ec_header="BEGIN EC"' PRIVATE KEY'
readonly pkcs8_header="BEGIN"' PRIVATE KEY'
readonly allowed_ed25519='test/integration/keys/ssh_host_ed25519_key'
readonly allowed_rsa='test/integration/keys/ssh_host_rsa_key'
readonly allowed_swap='test/integration/keys/ssh_host_ed25519_key_swap'

mapfile -t detected < <(
  cd "$repo_root"
  find . \
    \( -path './.git' -o -path '*/.dart_tool' -o -path './test/integration/runtime' \) \
    -prune -o -type f -exec grep -Il \
    -e "$openssh_header" \
    -e "$rsa_header" \
    -e "$ec_header" \
    -e "$pkcs8_header" \
    -- {} + \
    | sed 's#^\./##' \
    | sort
)

expected=("$allowed_ed25519" "$allowed_rsa" "$allowed_swap")
mapfile -t expected < <(printf '%s\n' "${expected[@]}" | sort)

if [[ "${detected[*]}" == "${expected[*]}" ]]; then
  exit 0
fi

echo 'private-key scope mismatch' >&2
printf 'expected: %s\n' "${expected[*]}" >&2
printf 'detected: %s\n' "${detected[*]}" >&2
exit 1
