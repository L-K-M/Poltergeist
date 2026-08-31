#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture.sh"

readonly profile="${1:-}"
readonly service="${2:-sshd-modern}"

case "$profile" in
  lan|rtt100)
    compose exec -T "$service" /usr/local/bin/netem-profile "$profile"
    ;;
  measure-rtt-ms)
    service_port="$(resolve_service_port "$service")"
    "$dart_binary" run "$integration_dir/measure_rtt.dart" \
      127.0.0.1 "$service_port"
    ;;
  *)
    echo 'usage: network-profile.sh lan|rtt100|measure-rtt-ms [SERVICE]' >&2
    exit 2
    ;;
esac
