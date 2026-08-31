#!/bin/sh
set -eu

readonly network_interface="${NETEM_INTERFACE:-eth0}"
readonly ingress_interface='ifb0'
readonly one_way_delay='50ms'
readonly jitter='25ms'
readonly deterministic_seed='20260831'

clear_profile() {
  tc qdisc del dev "$ingress_interface" root 2>/dev/null || true
  tc qdisc del dev "$network_interface" ingress 2>/dev/null || true
  tc qdisc del dev "$network_interface" root 2>/dev/null || true
  ip link delete "$ingress_interface" 2>/dev/null || true
}

apply_rtt_profile() {
  clear_profile

  # client -> ifb0 -> sshd and sshd -> eth0 -> client: 50 ms each way.
  ip link add "$ingress_interface" type ifb
  ip link set dev "$ingress_interface" up
  tc qdisc add dev "$network_interface" handle ffff: ingress
  tc filter add dev "$network_interface" parent ffff: protocol all u32 \
    match u32 0 0 action mirred egress redirect dev "$ingress_interface"
  tc qdisc add dev "$ingress_interface" root netem \
    delay "$one_way_delay" "$jitter" distribution normal \
    seed "$deterministic_seed"
  tc qdisc add dev "$network_interface" root netem \
    delay "$one_way_delay" "$jitter" distribution normal \
    seed "$deterministic_seed"
}

case "${1:-}" in
  lan)
    clear_profile
    ;;
  rtt100)
    apply_rtt_profile
    ;;
  *)
    echo 'usage: netem-profile lan|rtt100' >&2
    exit 2
    ;;
esac
