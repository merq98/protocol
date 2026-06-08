#!/usr/bin/env bash
# check-universal-traffic.sh — Show/reset VPS-2 universal gateway traffic by client.
#
# Usage:
#   ./check-universal-traffic.sh status
#   ./check-universal-traffic.sh reset
#
# The counters are collected on VPS-2, where universal clients have separate
# UUID/email entries. VPS-1 still sees one upstream gateway user.

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray-mobile/config.json}"
GATEWAY_ENV="${GATEWAY_ENV:-/usr/local/etc/xray-mobile/gateway.env}"
XRAY_API="${XRAY_API:-127.0.0.1:10086}"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

load_gateway_env() {
  if [[ -f "$GATEWAY_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$GATEWAY_ENV"
    XRAY_API="${XRAY_API:-127.0.0.1:10086}"
  fi
}

require_config() {
  [[ -f "$XRAY_CONFIG" ]] || die "Config not found: $XRAY_CONFIG"
}

get_emails() {
  jq -r '[.inbounds[]? | select(.tag == "mobile-in")][0].settings.clients[]?.email // empty' "$XRAY_CONFIG"
}

get_user_traffic() {
  local email="$1"
  local direction="$2"
  local result
  result=$("$XRAY_BIN" api stats --server="$XRAY_API" -name "user>>>$email>>>traffic>>>$direction" 2>/dev/null | grep '"value"' | grep -o '[0-9]*' || echo "0")
  printf '%s\n' "${result:-0}"
}

human_bytes() {
  local bytes="$1"
  if (( bytes >= 1073741824 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.2f GB", b / 1073741824 }'
  elif (( bytes >= 1048576 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.1f MB", b / 1048576 }'
  else
    printf '%d KB' "$(( bytes / 1024 ))"
  fi
}

cmd_status() {
  load_gateway_env
  require_config

  printf '%-24s %12s %12s %12s\n' "EMAIL" "DOWNLOAD" "UPLOAD" "TOTAL"
  printf '%-24s %12s %12s %12s\n' "----" "--------" "------" "-----"

  local emails
  emails="$(get_emails)"
  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    local down up total
    down="$(get_user_traffic "$email" "downlink")"
    up="$(get_user_traffic "$email" "uplink")"
    total=$(( down + up ))
    printf '%-24s %12s %12s %12s\n' \
      "$email" "$(human_bytes "$down")" "$(human_bytes "$up")" "$(human_bytes "$total")"
  done <<< "$emails"

  printf '\nXray API: %s\n' "$XRAY_API"
}

cmd_reset() {
  load_gateway_env
  require_config

  local emails
  emails="$(get_emails)"
  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    "$XRAY_BIN" api stats --server="$XRAY_API" -name "user>>>$email>>>traffic>>>downlink" -reset >/dev/null 2>&1 || true
    "$XRAY_BIN" api stats --server="$XRAY_API" -name "user>>>$email>>>traffic>>>uplink" -reset >/dev/null 2>&1 || true
  done <<< "$emails"

  log "Universal gateway counters reset"
}

case "${1:-}" in
  status)
    cmd_status
    ;;
  reset)
    cmd_reset
    ;;
  *)
    echo "Usage: $0 {status|reset}"
    exit 1
    ;;
esac
