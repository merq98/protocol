#!/usr/bin/env bash
# manage-clients.sh — Add/remove/list VLESS clients on a running Xray server.
#
# Usage:
#   ./manage-clients.sh list
#   ./manage-clients.sh add [label]       # generates UUID, prints client config
#   ./manage-clients.sh add-uuid <uuid> [label]
#   ./manage-clients.sh remove <uuid>
#   ./manage-clients.sh links          # prints VLESS share links for all clients
#
# The script modifies /usr/local/etc/xray/config.json in place and restarts xray.

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
LABELS_FILE="${LABELS_FILE:-/usr/local/etc/xray/client-labels.txt}"
CLIENTS_LOG="${CLIENTS_LOG:-/usr/local/etc/xray/clients.txt}"
WS_RELAY="${WS_RELAY:-}"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run with sudo"
  fi
}

get_server_info() {
  SERVER_IP=$(hostname -I | awk '{print $1}')
  PUBLIC_KEY=$("$XRAY_BIN" x25519 -i "$(jq -r '[.inbounds[] | select(.protocol == "vless")][0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")" | grep 'Password (PublicKey):' | awk '{print $NF}')
  SHORT_ID=$(jq -r '[.inbounds[] | select(.protocol == "vless")][0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
  SERVER_NAME=$(jq -r '[.inbounds[] | select(.protocol == "vless")][0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
}

# Generate VLESS link for a client
make_vless_link() {
  local uuid="$1" label="$2" suffix="${3:-}"
  local tag="${label:-reality}"
  [[ -n "$suffix" ]] && tag="${tag}-${suffix}"
  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&type=raw&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s' \
    "$uuid" "$SERVER_IP" "$SERVER_NAME" "$PUBLIC_KEY" "$SHORT_ID" "$tag"
}

# Save client record to clients.txt log
save_client_record() {
  local uuid="$1" label="$2" date_added
  date_added=$(date '+%Y-%m-%d %H:%M')

  get_server_info
  local direct_link cf_link
  direct_link=$(make_vless_link "$uuid" "$label" "direct")
  cf_link=""
  if [[ -n "$WS_RELAY" ]]; then
    cf_link=$(make_vless_link "$uuid" "$label" "cf")
  fi

  {
    printf '\n========================================\n'
    printf 'Date:       %s\n' "$date_added"
    printf 'UUID:       %s\n' "$uuid"
    printf 'Label:      %s\n' "${label:--}"
    printf 'Email:      %s\n' "${label:-${uuid:0:8}}"
    printf '\nDirect link:\n%s\n' "$direct_link"
    if [[ -n "$cf_link" ]]; then
      printf '\nCloudflare link:\n'
      printf '  wsRelay: %s\n' "$WS_RELAY"
      printf '  link:    %s\n' "$cf_link"
    fi
    printf '========================================\n'
  } >> "$CLIENTS_LOG"
}

cmd_list() {
  log "Current clients in $XRAY_CONFIG:"
  local count
  count=$(jq '[.inbounds[] | select(.protocol == "vless")][0].settings.clients | length' "$XRAY_CONFIG")
  for (( i=0; i<count; i++ )); do
    local uuid flow
    uuid=$(jq -r "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[$i].id" "$XRAY_CONFIG")
    flow=$(jq -r "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[$i].flow // \"\"" "$XRAY_CONFIG")
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
  existing=$(jq -r "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[] | select(.id == \"$uuid\") | .id" "$XRAY_CONFIG")
  if [[ -n "$existing" ]]; then
    die "UUID $uuid already exists in config"
  fi

  log "Adding client: $uuid"

  # Use label as email, fallback to uuid prefix
  local email="${label:-${uuid:0:8}}"

  # Add to config
  local tmp
  tmp=$(mktemp)
  jq "(.inbounds[] | select(.protocol == \"vless\")).settings.clients += [{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\", \"email\": \"$email\"}]" "$XRAY_CONFIG" > "$tmp"
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

  # Print VLESS share links
  local direct_link
  direct_link=$(make_vless_link "$uuid" "$label" "direct")
  printf '\n--- VLESS links ---\n'
  printf 'Direct:     %s\n' "$direct_link"
  if [[ -n "$WS_RELAY" ]]; then
    local cf_link
    cf_link=$(make_vless_link "$uuid" "$label" "cf")
    printf 'Cloudflare: %s\n' "$cf_link"
    printf '  (add "wsRelay": "%s" to realitySettings)\n' "$WS_RELAY"
  fi

  # Save to clients log
  save_client_record "$uuid" "$label"
  log "Client saved to $CLIENTS_LOG"
}

cmd_remove() {
  require_root
  local uuid="$1"

  local existing
  existing=$(jq -r "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[] | select(.id == \"$uuid\") | .id" "$XRAY_CONFIG")
  if [[ -z "$existing" ]]; then
    die "UUID $uuid not found in config"
  fi

  local count
  count=$(jq '[.inbounds[] | select(.protocol == "vless")][0].settings.clients | length' "$XRAY_CONFIG")
  if [[ "$count" -le 1 ]]; then
    die "Cannot remove the last client. At least one must remain."
  fi

  log "Removing client: $uuid"
  local tmp
  tmp=$(mktemp)
  jq "del((.inbounds[] | select(.protocol == \"vless\")).settings.clients[] | select(.id == \"$uuid\"))" "$XRAY_CONFIG" > "$tmp"
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

cmd_links() {
  get_server_info
  local count
  count=$(jq '[.inbounds[] | select(.protocol == "vless")][0].settings.clients | length' "$XRAY_CONFIG")
  for (( i=0; i<count; i++ )); do
    local uuid
    uuid=$(jq -r "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[$i].id" "$XRAY_CONFIG")
    local label=""
    if [[ -f "$LABELS_FILE" ]]; then
      label=$(grep "^${uuid}=" "$LABELS_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi
    local tag="${label:-${uuid:0:8}}"
    printf '\n[%s]\n' "$tag"
    printf '  Direct:     %s\n' "$(make_vless_link "$uuid" "$label" "direct")"
    if [[ -n "$WS_RELAY" ]]; then
      printf '  Cloudflare: %s\n' "$(make_vless_link "$uuid" "$label" "cf")"
    fi
  done
  printf '\nTotal: %d client(s)\n' "$count"
  if [[ -n "$WS_RELAY" ]]; then
    printf 'WS Relay: %s\n' "$WS_RELAY"
  fi
}

# --- Main ---
case "${1:-}" in
  list)
    cmd_list
    ;;
  links)
    cmd_links
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
    echo "Usage: $0 {list|add [label]|add-uuid <uuid> [label]|remove <uuid>|links}"
    echo ""
    echo "Environment:"
    echo "  WS_RELAY=wss://your-worker.workers.dev  — enables Cloudflare links"
    exit 1
    ;;
esac
