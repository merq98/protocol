#!/usr/bin/env bash
# manage-clients.sh — Add/remove/list VLESS clients on a running Xray server.
#
# Usage:
#   ./manage-clients.sh list
#   ./manage-clients.sh add [label]       # generates UUID, prints client config
#   Label universal-gateway* is the VPS-2 hop: no xtls-rprx-vision.
#   ./manage-clients.sh add-uuid <uuid> [label]
#   ./manage-clients.sh remove <uuid>
#   ./manage-clients.sh links          # prints VLESS share links for all clients
#   ./manage-clients.sh unlimited list
#   ./manage-clients.sh unlimited add <email>
#   ./manage-clients.sh unlimited remove <email>
#
# The script modifies /usr/local/etc/xray/config.json in place and restarts xray.

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
LABELS_FILE="${LABELS_FILE:-/usr/local/etc/xray/client-labels.txt}"
CLIENTS_LOG="${CLIENTS_LOG:-/usr/local/etc/xray/clients.txt}"
EXEMPT_FILE="${EXEMPT_FILE:-/usr/local/etc/xray/unlimited-clients.json}"
WS_RELAY="${WS_RELAY:-}"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

ensure_json_array_file() {
  local path="$1"
  [[ -f "$path" ]] || echo '[]' > "$path"
}

json_array_contains() {
  local path="$1"
  local value="$2"
  [[ -f "$path" ]] && jq -e --arg value "$value" '.[] | select(. == $value)' "$path" > /dev/null 2>&1
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run with sudo"
  fi
}

vless_inbound_idx() {
  jq -r '[.inbounds // [] | to_entries[] | select(.value.protocol == "vless")][0].key // empty' "$XRAY_CONFIG"
}

require_vless_inbound() {
  [[ -f "$XRAY_CONFIG" ]] || die "Config not found: $XRAY_CONFIG"
  local idx
  idx=$(vless_inbound_idx)
  [[ -n "$idx" ]] || die "No VLESS inbound found in $XRAY_CONFIG"
  printf '%s' "$idx"
}

get_server_info() {
  local idx private_key
  idx=$(require_vless_inbound)
  SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"

  private_key=$(jq -r --argjson idx "$idx" '.inbounds[$idx].streamSettings.realitySettings.privateKey // empty' "$XRAY_CONFIG")
  [[ -n "$private_key" ]] || die "REALITY privateKey missing in $XRAY_CONFIG"

  PUBLIC_KEY=$("$XRAY_BIN" x25519 -i "$private_key" | grep 'Password (PublicKey):' | awk '{print $NF}')
  [[ -n "$PUBLIC_KEY" ]] || die "Failed to derive REALITY public key"

  SHORT_ID=$(jq -r --argjson idx "$idx" '.inbounds[$idx].streamSettings.realitySettings.shortIds[0] // empty' "$XRAY_CONFIG")
  SERVER_NAME=$(jq -r --argjson idx "$idx" '.inbounds[$idx].streamSettings.realitySettings.serverNames[0] // empty' "$XRAY_CONFIG")
  [[ -n "$SHORT_ID" && -n "$SERVER_NAME" ]] || die "REALITY shortIds/serverNames missing in $XRAY_CONFIG"
}

is_gateway_label() {
  [[ "${1:-}" == universal-gateway* ]]
}

install_xray_config() {
  local tmp="$1"
  "$XRAY_BIN" run -test -config "$tmp" || { rm -f "$tmp"; die "Config validation failed"; }
  install -m 0644 "$tmp" "$XRAY_CONFIG"
  rm -f "$tmp"
}

# Generate VLESS link for a client
make_vless_link() {
  local uuid="$1" label="$2" suffix="${3:-}" flow="${4:-}"
  local tag="${label:-reality}" flow_q=""
  [[ -n "$suffix" ]] && tag="${tag}-${suffix}"
  if [[ -n "$flow" ]]; then
    flow_q="&flow=${flow}"
  fi
  printf 'vless://%s@%s:443?encryption=none%s&type=raw&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s' \
    "$uuid" "$SERVER_IP" "$flow_q" "$SERVER_NAME" "$PUBLIC_KEY" "$SHORT_ID" "$tag"
}

# Save client record to clients.txt log
save_client_record() {
  local uuid="$1" label="$2" flow="${3:-}" date_added
  date_added=$(date '+%Y-%m-%d %H:%M')

  get_server_info
  local direct_link cf_link
  direct_link=$(make_vless_link "$uuid" "$label" "direct" "$flow")
  cf_link=""
  if [[ -n "$WS_RELAY" ]]; then
    cf_link=$(make_vless_link "$uuid" "$label" "cf" "$flow")
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
  local idx count
  idx=$(require_vless_inbound)
  log "Current clients in $XRAY_CONFIG:"
  count=$(jq --argjson idx "$idx" '.inbounds[$idx].settings.clients // [] | length' "$XRAY_CONFIG")
  for (( i=0; i<count; i++ )); do
    local uuid flow
    uuid=$(jq -r --argjson idx "$idx" --argjson i "$i" '.inbounds[$idx].settings.clients[$i].id' "$XRAY_CONFIG")
    flow=$(jq -r --argjson idx "$idx" --argjson i "$i" '.inbounds[$idx].settings.clients[$i].flow // ""' "$XRAY_CONFIG")
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
  local idx uuid="${1:-$("$XRAY_BIN" uuid | tail -n 1 | tr -d '\r')}" label="${2:-}"

  idx=$(require_vless_inbound)

  # Check if UUID already exists
  local existing
  existing=$(jq -r --argjson idx "$idx" --arg uuid "$uuid" '
    .inbounds[$idx].settings.clients // []
    | map(select(.id == $uuid)) | .[0].id // empty
  ' "$XRAY_CONFIG")
  if [[ -n "$existing" ]]; then
    die "UUID $uuid already exists in config"
  fi

  log "Adding client: $uuid"

  # Use label as email, fallback to uuid prefix
  local email="${label:-${uuid:0:8}}"
  local flow=""
  if ! is_gateway_label "$email" && ! is_gateway_label "$label"; then
    flow="xtls-rprx-vision"
  fi

  local email_exists
  email_exists=$(jq -r --argjson idx "$idx" --arg email "$email" '
    .inbounds[$idx].settings.clients // []
    | map(select(.email == $email)) | .[0].email // empty
  ' "$XRAY_CONFIG")
  if [[ -n "$email_exists" ]]; then
    die "Email '$email' already exists. Use a unique label (Xray rejects duplicate emails)."
  fi

  local tmp
  tmp=$(mktemp --suffix=.json)
  jq --argjson idx "$idx" --arg uuid "$uuid" --arg email "$email" --arg flow "$flow" '
    .inbounds[$idx].settings.clients = ((.inbounds[$idx].settings.clients // []) + [
      (if $flow == "" then {id: $uuid, email: $email} else {id: $uuid, flow: $flow, email: $email} end)
    ])
  ' "$XRAY_CONFIG" > "$tmp"
  install_xray_config "$tmp"

  # Save label
  if [[ -n "$label" ]]; then
    echo "${uuid}=${label}" >> "$LABELS_FILE"
  fi

  # Restart
  systemctl restart xray
  log "Xray restarted"

  # Print client info
  get_server_info
  printf '\n--- Client config for v2rayN ---\n'
  printf 'Address:    %s\n' "$SERVER_IP"
  printf 'Port:       443\n'
  printf 'UUID:       %s\n' "$uuid"
  printf 'Flow:       %s\n' "${flow:-<none, gateway hop>}"
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
  direct_link=$(make_vless_link "$uuid" "$label" "direct" "$flow")
  printf '\n--- VLESS links ---\n'
  printf 'Direct:     %s\n' "$direct_link"
  if [[ -n "$WS_RELAY" ]]; then
    local cf_link
    cf_link=$(make_vless_link "$uuid" "$label" "cf" "$flow")
    printf 'Cloudflare: %s\n' "$cf_link"
    printf '  (add "wsRelay": "%s" to realitySettings)\n' "$WS_RELAY"
  fi

  # Save to clients log
  save_client_record "$uuid" "$label" "$flow"
  log "Client saved to $CLIENTS_LOG"
}

cmd_remove() {
  require_root
  local idx uuid="$1"

  idx=$(require_vless_inbound)

  local existing
  existing=$(jq -r --argjson idx "$idx" --arg uuid "$uuid" '
    .inbounds[$idx].settings.clients // []
    | map(select(.id == $uuid)) | .[0].id // empty
  ' "$XRAY_CONFIG")
  if [[ -z "$existing" ]]; then
    die "UUID $uuid not found in config"
  fi

  local count
  count=$(jq --argjson idx "$idx" '.inbounds[$idx].settings.clients // [] | length' "$XRAY_CONFIG")
  if [[ "$count" -le 1 ]]; then
    die "Cannot remove the last client. At least one must remain."
  fi

  log "Removing client: $uuid"
  local tmp
  tmp=$(mktemp --suffix=.json)
  jq --argjson idx "$idx" --arg uuid "$uuid" '
    .inbounds[$idx].settings.clients |= map(select(.id != $uuid))
  ' "$XRAY_CONFIG" > "$tmp"
  install_xray_config "$tmp"

  # Remove label
  if [[ -f "$LABELS_FILE" ]]; then
    sed -i "/^${uuid}=/d" "$LABELS_FILE"
  fi

  systemctl restart xray
  log "Client removed, Xray restarted"
}

cmd_links() {
  local idx count
  idx=$(require_vless_inbound)
  get_server_info
  count=$(jq --argjson idx "$idx" '.inbounds[$idx].settings.clients // [] | length' "$XRAY_CONFIG")
  for (( i=0; i<count; i++ )); do
    local uuid
    uuid=$(jq -r --argjson idx "$idx" --argjson i "$i" '.inbounds[$idx].settings.clients[$i].id' "$XRAY_CONFIG")
    local label=""
    if [[ -f "$LABELS_FILE" ]]; then
      label=$(grep "^${uuid}=" "$LABELS_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi
    local tag="${label:-${uuid:0:8}}"
    local flow
    flow=$(jq -r --argjson idx "$idx" --argjson i "$i" '.inbounds[$idx].settings.clients[$i].flow // ""' "$XRAY_CONFIG")
    printf '\n[%s]\n' "$tag"
    printf '  Direct:     %s\n' "$(make_vless_link "$uuid" "$label" "direct" "$flow")"
    if [[ -n "$WS_RELAY" ]]; then
      printf '  Cloudflare: %s\n' "$(make_vless_link "$uuid" "$label" "cf" "$flow")"
    fi
  done
  printf '\nTotal: %d client(s)\n' "$count"
  if [[ -n "$WS_RELAY" ]]; then
    printf 'WS Relay: %s\n' "$WS_RELAY"
  fi
}

cmd_unlimited_list() {
  ensure_json_array_file "$EXEMPT_FILE"
  printf 'Unlimited users file: %s\n' "$EXEMPT_FILE"
  jq -r '.[]' "$EXEMPT_FILE"
}

cmd_unlimited_add() {
  require_root
  local email="$1"
  [[ -n "$email" ]] || die "Usage: $0 unlimited add <email>"
  ensure_json_array_file "$EXEMPT_FILE"

  local idx
  idx=$(require_vless_inbound)
  if ! jq -e --argjson idx "$idx" --arg email "$email" '
    .inbounds[$idx].settings.clients // []
    | map(select(.email == $email)) | length > 0
  ' "$XRAY_CONFIG" > /dev/null 2>&1; then
    die "User with email '$email' not found in $XRAY_CONFIG"
  fi

  if json_array_contains "$EXEMPT_FILE" "$email"; then
    log "User already unlimited: $email"
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  jq --arg email "$email" '. += [$email]' "$EXEMPT_FILE" > "$tmp"
  mv "$tmp" "$EXEMPT_FILE"
  chmod 0644 "$EXEMPT_FILE"
  log "Removed daily limit for: $email"
}

cmd_unlimited_remove() {
  require_root
  local email="$1"
  [[ -n "$email" ]] || die "Usage: $0 unlimited remove <email>"
  ensure_json_array_file "$EXEMPT_FILE"

  if ! json_array_contains "$EXEMPT_FILE" "$email"; then
    log "User is not in unlimited list: $email"
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  jq --arg email "$email" '[.[] | select(. != $email)]' "$EXEMPT_FILE" > "$tmp"
  mv "$tmp" "$EXEMPT_FILE"
  chmod 0644 "$EXEMPT_FILE"
  log "Restored daily limit for: $email"
}

# --- Main ---
case "${1:-}" in
  list)
    cmd_list
    ;;
  links)
    cmd_links
    ;;
  unlimited)
    case "${2:-}" in
      list)
        cmd_unlimited_list
        ;;
      add)
        [[ -n "${3:-}" ]] || die "Usage: $0 unlimited add <email>"
        cmd_unlimited_add "$3"
        ;;
      remove)
        [[ -n "${3:-}" ]] || die "Usage: $0 unlimited remove <email>"
        cmd_unlimited_remove "$3"
        ;;
      *)
        die "Usage: $0 unlimited {list|add <email>|remove <email>}"
        ;;
    esac
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
    echo "Usage: $0 {list|add [label]|add-uuid <uuid> [label]|remove <uuid>|links|unlimited {list|add <email>|remove <email>}}"
    echo ""
    echo "Environment:"
    echo "  WS_RELAY=wss://your-worker.workers.dev  — enables Cloudflare links"
    exit 1
    ;;
esac
