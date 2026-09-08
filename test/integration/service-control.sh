#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixture.sh"

readonly action="${1:-}"
readonly service="${2:-sshd-modern}"
readonly shared_ssh_port='2201'

case "$action" in
  start)
    compose start "$service"
    wait_for_service "$service"
    ;;
  stop)
    service_port="$(resolve_service_port "$service")"
    compose stop "$service"
    wait_for_free_port "$service_port"
    ;;
  swap)
    modern_port="$(resolve_service_port sshd-modern)"
    compose stop sshd-modern
    wait_for_free_port "$modern_port"
    compose up --detach sshd-keyswap
    wait_for_service sshd-keyswap
    ;;
  restore-modern)
    # Reset both sides so cleanup can retry after any partial swap or restore.
    # The fixed Compose port remains known even when neither service runs.
    compose stop sshd-keyswap sshd-modern
    wait_for_free_port "$shared_ssh_port"
    compose up --detach sshd-modern
    wait_for_service sshd-modern
    ;;
  *)
    echo 'usage: service-control.sh start|stop [SERVICE] | swap | restore-modern' >&2
    exit 2
    ;;
esac
