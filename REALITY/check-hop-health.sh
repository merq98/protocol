#!/usr/bin/env bash
# check-hop-health.sh — Restart xray-mobile-gateway only when the FR→DE hop is stuck.
#
# VPS-2 only. Does not touch Caddy or VPS-1 xray.
# Does not restart because Instagram dipped, WS count, cubic, or load.
#
# Restart when:
#   - the gateway unit is not active, or
#   - clients are ESTAB on :9443 but hop to ORIGIN:443 has zero ESTAB
#     for two consecutive runs, or
#   - sum of Send-Q on hop sockets exceeds 200 KB for two consecutive runs
#
# Cooldown: 45 minutes after a restart. Timer: every 2 minutes.
#
# Usage:
#   sudo ./check-hop-health.sh
#   sudo ./check-hop-health.sh status

set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-xray-mobile-gateway}"
GATEWAY_ENV="${GATEWAY_ENV:-/usr/local/etc/xray-mobile/gateway.env}"
STATE_DIR="${STATE_DIR:-/var/lib/xray-mobile}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/hop-health.state}"
LAST_RESTART_FILE="${LAST_RESTART_FILE:-$STATE_DIR/last-restart}"
CLIENT_PORT="${CLIENT_PORT:-9443}"
SENDQ_LIMIT="${SENDQ_LIMIT:-204800}"
COOLDOWN_SEC="${COOLDOWN_SEC:-2700}"
ORIGIN="${ORIGIN:-37.220.83.19:443}"

log() { printf '%s\n' "$*"; }

load_gateway_env() {
  if [[ -f "$GATEWAY_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$GATEWAY_ENV"
  fi
  ORIGIN="${ORIGIN:-37.220.83.19:443}"
}

origin_host() { printf '%s\n' "${ORIGIN%:*}"; }
origin_port() { printf '%s\n' "${ORIGIN##*:}"; }

count_lines() {
  wc -l | tr -d ' '
}

client_estab() {
  ss -H -tn state established "( sport = :${CLIENT_PORT} or dport = :${CLIENT_PORT} )" 2>/dev/null | count_lines
}

hop_estab() {
  ss -H -tn state established "dst $(origin_host) and dport = :$(origin_port)" 2>/dev/null | count_lines
}

hop_sendq() {
  ss -H -tn state established "dst $(origin_host) and dport = :$(origin_port)" 2>/dev/null \
    | awk '{s += $3} END {printf "%d", s+0}'
}

unit_active() {
  systemctl is-active --quiet "$SERVICE_NAME"
}

read_state() {
  prev_missing=0
  prev_sendq=0
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

write_state() {
  mkdir -p "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF
prev_missing=$1
prev_sendq=$2
EOF
}

cooldown_left() {
  if [[ ! -f "$LAST_RESTART_FILE" ]]; then
    printf '0\n'
    return
  fi
  local ts now left
  ts="$(awk 'NR==1 {print $1}' "$LAST_RESTART_FILE")"
  [[ "$ts" =~ ^[0-9]+$ ]] || { printf '0\n'; return; }
  now="$(date +%s)"
  left=$((ts + COOLDOWN_SEC - now))
  if (( left < 0 )); then
    printf '0\n'
  else
    printf '%s\n' "$left"
  fi
}

record_restart() {
  mkdir -p "$STATE_DIR"
  printf '%s %s\n' "$(date +%s)" "$1" > "$LAST_RESTART_FILE"
}

restart_gateway() {
  local reason="$1"
  local left
  left="$(cooldown_left)"
  if (( left > 0 )); then
    log "hop-health: $reason, cooldown ${left}s left, skip restart"
    return
  fi
  log "hop-health: restarting $SERVICE_NAME ($reason)"
  record_restart "$reason"
  write_state 0 0
  systemctl restart "$SERVICE_NAME"
}

cmd_status() {
  load_gateway_env
  local clients hop sendq
  clients="$(client_estab)"
  hop="$(hop_estab)"
  sendq="$(hop_sendq)"
  printf 'service=%s active=%s\n' "$SERVICE_NAME" "$(systemctl is-active "$SERVICE_NAME" || true)"
  printf 'origin=%s clients_9443=%s hop_estab=%s hop_sendq=%s limit=%s\n' \
    "$ORIGIN" "$clients" "$hop" "$sendq" "$SENDQ_LIMIT"
  if [[ -f "$LAST_RESTART_FILE" ]]; then
    printf 'last-restart: %s (cooldown_left=%ss)\n' "$(tr -d '\n' < "$LAST_RESTART_FILE")" "$(cooldown_left)"
  else
    printf 'last-restart: none\n'
  fi
  if [[ -f "$STATE_FILE" ]]; then
    printf 'state: %s\n' "$(tr '\n' ' ' < "$STATE_FILE")"
  fi
}

cmd_check() {
  load_gateway_env
  mkdir -p "$STATE_DIR"

  if ! unit_active; then
    restart_gateway "unit-inactive"
    return
  fi

  local clients hop sendq missing high_sendq
  clients="$(client_estab)"
  hop="$(hop_estab)"
  sendq="$(hop_sendq)"
  missing=0
  high_sendq=0
  if (( clients > 0 && hop == 0 )); then
    missing=1
  fi
  if (( sendq > SENDQ_LIMIT )); then
    high_sendq=1
  fi

  read_state
  log "hop-health: clients=${clients} hop=${hop} sendq=${sendq} missing=${missing}/${prev_missing} sendq_high=${high_sendq}/${prev_sendq}"

  if (( missing == 1 && prev_missing == 1 )); then
    restart_gateway "missing-hop clients=${clients}"
    return
  fi
  if (( high_sendq == 1 && prev_sendq == 1 )); then
    restart_gateway "high-sendq ${sendq}"
    return
  fi

  write_state "$missing" "$high_sendq"
}

case "${1:-check}" in
  status) cmd_status ;;
  check|"") cmd_check ;;
  *)
    printf 'Usage: %s [check|status]\n' "$0" >&2
    exit 1
    ;;
esac
