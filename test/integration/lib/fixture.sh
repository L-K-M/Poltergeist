#!/usr/bin/env bash

set -euo pipefail

readonly integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root="$(cd "$integration_dir/../.." && pwd)"
readonly compose_file="$integration_dir/docker-compose.yml"
readonly compose_project='poltergeist-m0'
readonly dart_binary="${DART_BIN:-dart}"

compose() {
  docker compose --project-name "$compose_project" --file "$compose_file" "$@"
}

all_profiles() {
  compose config --profiles | paste -sd, -
}

check_rendered_config() {
  profiles="$(all_profiles)"

  COMPOSE_PROFILES="$profiles" compose config --format json \
    | "$dart_binary" run "$integration_dir/check_config.dart"
}

resolve_service_port() {
  service_name="$1"
  published_address="$(compose port "$service_name" 22)"

  case "$published_address" in
    127.0.0.1:*)
      printf '%s\n' "${published_address##*:}"
      ;;
    *)
      echo "unsafe published address for $service_name: $published_address" >&2
      return 1
      ;;
  esac
}

wait_for_service() {
  service_name="$1"
  service_port="$(resolve_service_port "$service_name")"

  "$dart_binary" run "$integration_dir/wait_port.dart" \
    banner 127.0.0.1 "$service_port"
}

wait_for_free_port() {
  service_port="$1"

  "$dart_binary" run "$integration_dir/wait_port.dart" \
    free 127.0.0.1 "$service_port"
}
