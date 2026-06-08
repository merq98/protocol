#!/usr/bin/env bash
# set-ws-relay.sh — Store wsRelay URL in REALITY server config (metadata / CF flow).
# For self-hosted relay on VPS-2, clients are patched via set-v2rayn-ws-relay.ps1 instead.
#
# Usage:
#   sudo ./set-ws-relay.sh show
#   sudo ./set-ws-relay.sh set wss://reality-relay.USER.workers.dev
#   sudo ./set-ws-relay.sh clear
#
# After setting, generate CF client links:
#   WS_RELAY='wss://reality-relay.USER.workers.dev' sudo ./manage-clients.sh links

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo"
}

vless_idx() {
  jq -r '[.inbounds // [] | to_entries[] | select(.value.protocol == "vless")][0].key // empty' "$XRAY_CONFIG"
}

cmd_show() {
  local idx
  idx=$(vless_idx)
  [[ -n "$idx" ]] || die "No VLESS inbound in $XRAY_CONFIG"
  jq --argjson idx "$idx" '.inbounds[$idx].streamSettings.realitySettings | {wsRelay, target, serverNames}' "$XRAY_CONFIG"
}

apply_ws_relay() {
  local relay="$1"
  require_root
  [[ -f "$XRAY_CONFIG" ]] || die "Config not found: $XRAY_CONFIG"

  local idx
  idx=$(vless_idx)
  [[ -n "$idx" ]] || die "No VLESS inbound in $XRAY_CONFIG"

  cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak-$(date +%F-%H%M%S)"

  local tmp
  tmp=$(mktemp)
  if [[ -n "$relay" ]]; then
    jq --argjson idx "$idx" --arg relay "$relay" '
      .inbounds[$idx].streamSettings.realitySettings.wsRelay = $relay
    ' "$XRAY_CONFIG" > "$tmp"
  else
    jq --argjson idx "$idx" '
      .inbounds[$idx].streamSettings.realitySettings |= del(.wsRelay)
    ' "$XRAY_CONFIG" > "$tmp"
  fi
  mv "$tmp" "$XRAY_CONFIG"
  chmod 0644 "$XRAY_CONFIG"

  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
  systemctl restart xray
  systemctl status xray --no-pager
}

cmd_set() {
  local relay="${1:-}"
  [[ -n "$relay" ]] || die "Usage: $0 set wss://your-worker.workers.dev"
  [[ "$relay" == wss://* ]] || die "wsRelay must start with wss://"
  log "Setting wsRelay to: $relay"
  apply_ws_relay "$relay"
  log "Generate CF links:"
  printf '  WS_RELAY=%q sudo ./manage-clients.sh links\n' "$relay"
}

cmd_clear() {
  log "Removing wsRelay from server config"
  apply_ws_relay ""
  log "wsRelay cleared"
}

case "${1:-}" in
  show)
    cmd_show
    ;;
  set)
    [[ -n "${2:-}" ]] || die "Usage: $0 set wss://your-worker.workers.dev"
    cmd_set "$2"
    ;;
  clear)
    cmd_clear
    ;;
  *)
    cat <<EOF
Usage:
  $0 show
  $0 set wss://your-worker.workers.dev
  $0 clear
EOF
    exit 1
    ;;
esac
