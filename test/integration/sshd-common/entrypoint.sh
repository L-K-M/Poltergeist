#!/bin/sh
set -eu

readonly fixture_user='poltergeist'
readonly fixture_uid='1000'
readonly fixture_password="${FIXTURE_PASSWORD:-poltergeist-test-only}"
readonly fixture_mode="${FIXTURE_MODE:-normal}"
readonly user_key='/run/fixture-user/id_ed25519.pub'
readonly mounted_host_keys='/fixture-hostkeys'
readonly active_host_keys='/run/sshd-hostkeys'

create_user() {
  user_name="$1"
  user_home="$2"

  if [ -f /etc/alpine-release ]; then
    adduser -D -u "$fixture_uid" -h "$user_home" -s /bin/sh "$user_name"
    return
  fi

  useradd --create-home --user-group --uid "$fixture_uid" --home-dir "$user_home" \
    --shell /bin/sh "$user_name"
}

create_auxiliary_user() {
  user_name="$1"
  user_uid="$2"

  if [ -f /etc/alpine-release ]; then
    adduser -D -u "$user_uid" -h "/home/$user_name" -s /bin/sh "$user_name"
    return
  fi

  useradd --create-home --user-group --uid "$user_uid" --home-dir "/home/$user_name" \
    --shell /bin/sh "$user_name"
}

install_authorized_key() {
  user_home="$1"
  install -d -m 0700 -o "$fixture_user" -g "$fixture_user" \
    "$user_home/.ssh"
  install -m 0600 -o "$fixture_user" -g "$fixture_user" \
    "$user_key" "$user_home/.ssh/authorized_keys"
}

prepare_host_keys() {
  install -d -m 0700 "$active_host_keys"

  # Git cannot retain 0600; copy immutable mounts before sshd validates them.
  for key_name in ssh_host_ed25519_key ssh_host_rsa_key ssh_host_ed25519_key_swap; do
    install -m 0600 "$mounted_host_keys/$key_name" \
      "$active_host_keys/$key_name"
  done
}

prepare_normal_home() {
  readonly normal_home="/home/$fixture_user"
  create_user "$fixture_user" "$normal_home"
  install -d -m 0755 -o "$fixture_user" -g "$fixture_user" \
    "$normal_home/bench" "$normal_home/bench/uploads"
  install_authorized_key "$normal_home"
}

prepare_chroot_home() {
  readonly chroot_root='/srv/sftp'
  readonly chroot_home="$chroot_root/home/$fixture_user"

  install -d -m 0755 -o root -g root "$chroot_root" "$chroot_root/home"
  create_user "$fixture_user" "$chroot_home"
  install -d -m 0755 -o "$fixture_user" -g "$fixture_user" \
    "$chroot_home" "$chroot_home/bench" "$chroot_home/bench/uploads"
  install_authorized_key "$chroot_home"
}

prepare_auth_matrix() {
  prepare_normal_home

  create_auxiliary_user password-only 1001
  create_auxiliary_user keyboard-only 1002
  create_auxiliary_user rejected-key 1003

  for user_name in password-only keyboard-only rejected-key; do
    printf '%s:%s\n' "$user_name" "$fixture_password" | chpasswd
  done
}

if [ ! -s "$user_key" ]; then
  echo "missing runtime user key: $user_key" >&2
  exit 1
fi

prepare_host_keys
mkdir -p /run/sshd

case "$fixture_mode" in
  normal)
    prepare_normal_home
    ;;
  chroot)
    prepare_chroot_home
    ;;
  authmatrix)
    prepare_auth_matrix
    ;;
  *)
    echo "unknown fixture mode: $fixture_mode" >&2
    exit 2
    ;;
esac

printf '%s:%s\n' "$fixture_user" "$fixture_password" | chpasswd
printf 'root:%s\n' "$fixture_password" | chpasswd

if [ "$#" -ne 1 ]; then
  echo 'expected one sshd config path' >&2
  exit 2
fi

sshd_binary='/usr/sbin/sshd'
if [ -x /usr/sbin/sshd.pam ]; then
  sshd_binary='/usr/sbin/sshd.pam'
fi

"$sshd_binary" -t -f "$1"
exec "$sshd_binary" -D -e -f "$1"
