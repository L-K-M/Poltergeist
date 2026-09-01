#!/usr/bin/env bash
set -euo pipefail

readonly integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly data_dir="$integration_dir/runtime/data"
readonly fixture_version='2'
readonly one_mb_bytes='1000000'
readonly hundred_mb_bytes='100000000'
readonly one_gb_bytes='1000000000'
readonly large_listing_count='10000'
readonly sibling_directory_count='8'
readonly sibling_entry_count='100'

has_expected_data() {
  [[ -f "$data_dir/.fixture-version" ]] || return 1
  [[ "$(<"$data_dir/.fixture-version")" == "$fixture_version" ]] || return 1
  [[ "$(stat -c %s "$data_dir/payload-1mb.bin")" == "$one_mb_bytes" ]] || return 1
  [[ "$(stat -c %s "$data_dir/payload-100mb.bin")" == "$hundred_mb_bytes" ]] || return 1
  [[ "$(stat -c %s "$data_dir/payload-1gb.bin")" == "$one_gb_bytes" ]] || return 1
  [[ "$(find "$data_dir/entries-10000" -maxdepth 1 -type f | wc -l)" == "$large_listing_count" ]] || return 1

  for ((directory_index = 0; directory_index < sibling_directory_count; directory_index++)); do
    directory_name="$(printf 'readdir-%02d' "$directory_index")"
    [[ "$(find "$data_dir/$directory_name" -maxdepth 1 -type f | wc -l)" == "$sibling_entry_count" ]] || return 1
  done
}

if has_expected_data 2>/dev/null; then
  exit 0
fi

rm -rf -- "$data_dir"
mkdir -p "$data_dir/entries-10000"

# Sparse zero-filled files retain exact logical transfer sizes without blobs.
truncate -s "$one_mb_bytes" "$data_dir/payload-1mb.bin"
truncate -s "$hundred_mb_bytes" "$data_dir/payload-100mb.bin"
truncate -s "$one_gb_bytes" "$data_dir/payload-1gb.bin"

for ((entry_index = 0; entry_index < large_listing_count; entry_index++)); do
  entry_name="$(printf 'entry-%05d.txt' "$entry_index")"
  printf '%s\n' "$entry_name" >"$data_dir/entries-10000/$entry_name"
done

for ((directory_index = 0; directory_index < sibling_directory_count; directory_index++)); do
  directory_name="$(printf 'readdir-%02d' "$directory_index")"
  mkdir -p "$data_dir/$directory_name"

  for ((entry_index = 0; entry_index < sibling_entry_count; entry_index++)); do
    entry_name="$(printf '%s-entry-%03d.txt' "$directory_name" "$entry_index")"
    printf '%s/%s\n' "$directory_name" "$entry_name" \
      >"$data_dir/$directory_name/$entry_name"
  done
done

printf '%s\n' "$fixture_version" >"$data_dir/.fixture-version"
