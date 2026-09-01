#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture.sh"

readonly profile="${1:-}"
readonly service="${2:-sshd-modern}"

case "$profile" in
  lan|rtt100)
    compose exec -T "$service" /usr/local/bin/netem-profile "$profile"
    ;;
  measure-rtt-ms|measure-rtt-json)
    service_port="$(resolve_service_port "$service")"
    rtt_arguments=()
    if [[ "$profile" == 'measure-rtt-json' ]]; then
      rtt_arguments+=(--json)
    fi

    "$dart_binary" run "$integration_dir/measure_rtt.dart" \
      "${rtt_arguments[@]}" 127.0.0.1 "$service_port"
    ;;
  *)
    echo 'usage: network-profile.sh lan|rtt100|measure-rtt-ms|measure-rtt-json [SERVICE]' >&2
    exit 2
    ;;
esac
