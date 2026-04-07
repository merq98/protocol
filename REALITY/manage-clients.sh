#!/usr/bin/env bash
# manage-clients.sh — Add/remove/list VLESS clients on a running Xray server.
#
# Usage:
#   ./manage-clients.sh list
#   ./manage-clients.sh add [label]       # generates UUID, prints client config
#   ./manage-clients.sh add-uuid <uuid> [label]
#   ./manage-clients.sh remove <uuid>
#
# The script modifies /usr/local/etc/xray/config.json in place and restarts xray.

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
LABELS_FILE="${LABELS_FILE:-/usr/local/etc/xray/client-labels.txt}"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run with sudo"
  fi
}

get_server_info() {
  SERVER_IP=$(hostname -I | awk '{print $1}')
  PUBLIC_KEY=$("$XRAY_BIN" x25519 -i "$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")" | grep 'Password (PublicKey):' | awk '{print $NF}')
  SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
  SERVER_NAME=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
}

cmd_list() {
  log "Current clients in $XRAY_CONFIG:"
  local count
  count=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONFIG")
  for (( i=0; i<count; i++ )); do
    local uuid flow
    uuid=$(jq -r ".inbounds[0].settings.clients[$i].id" "$XRAY_CONFIG")
    flow=$(jq -r ".inbounds[0].settings.clients[$i].flow // \"\"" "$XRAY_CONFIG")
    local label=""
    if [[ -f "$LABELS_FILE" ]]; then
      label=$(grep "^${uuid}=" "$LABELS_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi
    printf '  %d. %s  flow=%s' $((i+1)) "$uuid" "$flow"
    if [[ -n "$label" ]]; then
      printf '  (%s)' "$label"
    fi
    printf '\n'
  done
  printf '\nTotal: %d client(s)\n' "$count"
}

cmd_add() {
  require_root
  local uuid="${1:-$("$XRAY_BIN" uuid | tail -n 1 | tr -d '\r')}"
  local label="${2:-}"

  # Check if UUID already exists
  local existing
  existing=$(jq -r ".inbounds[0].settings.clients[] | select(.id == \"$uuid\") | .id" "$XRAY_CONFIG")
  if [[ -n "$existing" ]]; then
    die "UUID $uuid already exists in config"
  fi

  log "Adding client: $uuid"

  # Add to config
  local tmp
  tmp=$(mktemp)
  jq ".inbounds[0].settings.clients += [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"}]" "$XRAY_CONFIG" > "$tmp"
  mv "$tmp" "$XRAY_CONFIG"
  chmod 0644 "$XRAY_CONFIG"

  # Save label
  if [[ -n "$label" ]]; then
    echo "${uuid}=${label}" >> "$LABELS_FILE"
  fi

  # Validate
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG" || die "Config validation failed!"

  # Restart
  systemctl restart xray
  log "Xray restarted"

  # Print client info
  get_server_info
  printf '\n--- Client config for v2rayN ---\n'
  printf 'Address:    %s\n' "$SERVER_IP"
  printf 'Port:       443\n'
  printf 'UUID:       %s\n' "$uuid"
  printf 'Flow:       xtls-rprx-vision\n'
  printf 'Encryption: none\n'
  printf 'Network:    raw\n'
  printf 'Security:   reality\n'
  printf 'SNI:        %s\n' "$SERVER_NAME"
  printf 'Fingerprint: chrome\n'
  printf 'Public Key: %s\n' "$PUBLIC_KEY"
  printf 'Short ID:   %s\n' "$SHORT_ID"
  if [[ -n "$label" ]]; then
    printf 'Label:      %s\n' "$label"
  fi

  # Print VLESS share link
  printf '\nvless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&type=raw&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' \
    "$uuid" "$SERVER_IP" "$SERVER_NAME" "$PUBLIC_KEY" "$SHORT_ID" "${label:-reality}"
}

cmd_remove() {
  require_root
  local uuid="$1"

  local existing
  existing=$(jq -r ".inbounds[0].settings.clients[] | select(.id == \"$uuid\") | .id" "$XRAY_CONFIG")
  if [[ -z "$existing" ]]; then
    die "UUID $uuid not found in config"
  fi

  local count
  count=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONFIG")
  if [[ "$count" -le 1 ]]; then
    die "Cannot remove the last client. At least one must remain."
  fi

  log "Removing client: $uuid"
  local tmp
  tmp=$(mktemp)
  jq "del(.inbounds[0].settings.clients[] | select(.id == \"$uuid\"))" "$XRAY_CONFIG" > "$tmp"
  mv "$tmp" "$XRAY_CONFIG"
  chmod 0644 "$XRAY_CONFIG"

  # Remove label
  if [[ -f "$LABELS_FILE" ]]; then
    sed -i "/^${uuid}=/d" "$LABELS_FILE"
  fi

  "$XRAY_BIN" run -test -config "$XRAY_CONFIG" || die "Config validation failed!"
  systemctl restart xray
  log "Client removed, Xray restarted"
}

# --- Main ---
case "${1:-}" in
  list)
    cmd_list
    ;;
  add)
    cmd_add "" "${2:-}"
    ;;
  add-uuid)
    [[ -z "${2:-}" ]] && die "Usage: $0 add-uuid <uuid> [label]"
    cmd_add "$2" "${3:-}"
    ;;
  remove)
    [[ -z "${2:-}" ]] && die "Usage: $0 remove <uuid>"
    cmd_remove "$2"
    ;;
  *)
    echo "Usage: $0 {list|add [label]|add-uuid <uuid> [label]|remove <uuid>}"
    exit 1
    ;;
esac
