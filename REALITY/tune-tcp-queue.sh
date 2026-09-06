#!/usr/bin/env bash
# tune-tcp-queue.sh — BBR + fq on the public NIC (VPS-1 egress and VPS-2 gateway).
#
# BBR needs fq for pacing. fq_codel in default_qdisc is not enough:
# virtio/netplan often leaves the live NIC on pfifo_fast.
#
# Usage:
#   sudo ./tune-tcp-queue.sh apply
#   sudo ./tune-tcp-queue.sh status
#   sudo ./tune-tcp-queue.sh revert
#
# Does not restart Xray/Caddy. Existing TCP sockets keep cubic until they
# reconnect; new hop sockets pick up BBR.

set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-bbr-fq.conf"
MODULES_FILE="/etc/modules-load.d/bbr-fq.conf"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo"
}

public_ifaces() {
  ip -o link show | awk -F': ' '{print $2}' | awk -F'@' '{print $1}' | while read -r iface; do
    case "$iface" in
      lo|wg-*|docker*|br-*|veth*|tun*|tap*) continue ;;
    esac
    printf '%s\n' "$iface"
  done
}

write_persist() {
  cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  cat > "$MODULES_FILE" <<'EOF'
tcp_bbr
sch_fq
EOF
}

load_modules() {
  modprobe tcp_bbr || die "tcp_bbr module not available"
  modprobe sch_fq || die "sch_fq module not available"
}

cmd_apply() {
  require_root
  load_modules
  write_persist
  sysctl -p "$SYSCTL_FILE"

  local iface
  while read -r iface; do
    [[ -z "$iface" ]] && continue
    log "qdisc replace $iface root fq"
    tc qdisc replace dev "$iface" root fq
  done < <(public_ifaces)

  cmd_status
}

cmd_status() {
  sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control net.core.default_qdisc
  local iface
  while read -r iface; do
    [[ -z "$iface" ]] && continue
    printf 'qdisc %s: ' "$iface"
    tc qdisc show dev "$iface" | head -1
  done < <(public_ifaces)
}

cmd_revert() {
  require_root
  rm -f "$SYSCTL_FILE" "$MODULES_FILE"
  sysctl -w net.ipv4.tcp_congestion_control=cubic
  sysctl -w net.core.default_qdisc=fq_codel

  local iface
  while read -r iface; do
    [[ -z "$iface" ]] && continue
    log "qdisc replace $iface root fq_codel"
    tc qdisc replace dev "$iface" root fq_codel
  done < <(public_ifaces)

  cmd_status
}

case "${1:-}" in
  apply)  cmd_apply ;;
  status) cmd_status ;;
  revert) cmd_revert ;;
  *)
    printf 'Usage: sudo %s {apply|status|revert}\n' "$0" >&2
    exit 1
    ;;
esac
