#!/usr/bin/env bash
# manage-mobile-clients.sh — Add/remove/list universal clients on VPS-2 gateway.
#
# Usage:
#   ./manage-mobile-clients.sh list
#   ./manage-mobile-clients.sh add [label]
#   ./manage-mobile-clients.sh add-uuid <uuid> [label]
#   ./manage-mobile-clients.sh remove <uuid>
#   ./manage-mobile-clients.sh links
#
# The script modifies /usr/local/etc/xray-mobile/config.json and restarts
# xray-mobile-gateway.

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
CONFIG_FILE="${CONFIG_FILE:-/usr/local/etc/xray-mobile/config.json}"
GATEWAY_ENV="${GATEWAY_ENV:-/usr/local/etc/xray-mobile/gateway.env}"
LABELS_FILE="${LABELS_FILE:-/usr/local/etc/xray-mobile/client-labels.txt}"
SERVICE_NAME="${SERVICE_NAME:-xray-mobile-gateway}"

DOMAIN=""
PUBLIC_ADDRESS=""
MOBILE_PATH="/universal"
PUBLIC_PORT="443"
TLS_PINNED_PEER_CERT_SHA256=""

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo"
}

install_gateway_config() {
  local tmp="$1"
  "$XRAY_BIN" run -test -config "$tmp" || { rm -f "$tmp"; die "Config validation failed"; }
  install -m 0644 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

load_gateway_env() {
  [[ -f "$GATEWAY_ENV" ]] || die "Gateway env not found: $GATEWAY_ENV (run deploy-mobile-gateway-vps.sh install first)"
  # shellcheck disable=SC1090
  source "$GATEWAY_ENV"
  DOMAIN="${DOMAIN:-}"
  PUBLIC_ADDRESS="${PUBLIC_ADDRESS:-$DOMAIN}"
  MOBILE_PATH="${MOBILE_PATH:-/universal}"
  PUBLIC_PORT="${PUBLIC_PORT:-443}"
  TLS_PINNED_PEER_CERT_SHA256="${TLS_PINNED_PEER_CERT_SHA256:-}"
  [[ -n "$DOMAIN" ]] || die "DOMAIN missing in $GATEWAY_ENV"
  if [[ -n "$TLS_PINNED_PEER_CERT_SHA256" && ! "$TLS_PINNED_PEER_CERT_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    die "TLS_PINNED_PEER_CERT_SHA256 must be a 64-character SHA-256 hex string"
  fi
}

require_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE"
}

mobile_inbound_idx() {
  jq -r '[.inbounds // [] | to_entries[] | select(.value.tag == "mobile-in")][0].key // empty' "$CONFIG_FILE"
}

require_mobile_inbound() {
  require_config
  local idx
  idx="$(mobile_inbound_idx)"
  [[ -n "$idx" ]] || die "No mobile inbound found in $CONFIG_FILE"
  printf '%s' "$idx"
}

urlencode_path() {
  local path="$1"
  printf '%s' "$path" | jq -sRr @uri
}

make_mobile_vless_link() {
  local uuid="$1" label="$2"
  local encoded_path pcs_query tag
  encoded_path="$(urlencode_path "$MOBILE_PATH")"
  pcs_query=""
  if [[ -n "$TLS_PINNED_PEER_CERT_SHA256" ]]; then
    pcs_query="&pcs=${TLS_PINNED_PEER_CERT_SHA256}"
  fi
  tag="${label:-universal}"
  printf 'vless://%s@%s:%s?encryption=none&type=ws&security=tls&host=%s&sni=%s&path=%s%s#%s-universal' \
    "$uuid" "$PUBLIC_ADDRESS" "$PUBLIC_PORT" "$DOMAIN" "$DOMAIN" "$encoded_path" "$pcs_query" "$tag"
}

restart_gateway() {
  systemctl restart "$SERVICE_NAME"
  log "Restarted $SERVICE_NAME"
}

cmd_list() {
  local idx count
  idx="$(require_mobile_inbound)"
  log "Universal clients in $CONFIG_FILE:"
  count="$(jq --argjson idx "$idx" '.inbounds[$idx].settings.clients // [] | length' "$CONFIG_FILE")"
  for (( i=0; i<count; i++ )); do
    local uuid email
    uuid="$(jq -r --argjson idx "$idx" --argjson i "$i" '.inbounds[$idx].settings.clients[$i].id' "$CONFIG_FILE")"
    email="$(jq -r --argjson idx "$idx" --argjson i "$i" '.inbounds[$idx].settings.clients[$i].email // ""' "$CONFIG_FILE")"
    local label=""
    if [[ -f "$LABELS_FILE" ]]; then
      label="$(grep "^${uuid}=" "$LABELS_FILE" 2>/dev/null | cut -d= -f2- || true)"
    fi
    printf '  %d. %s' $((i+1)) "$uuid"
    if [[ -n "$email" ]]; then
      printf '  email=%s' "$email"
    fi
    if [[ -n "$label" ]]; then
      printf '  (%s)' "$label"
    fi
    printf '\n'
  done
  printf '\nTotal: %d client(s)\n' "$count"
}

cmd_add() {
  require_root
  load_gateway_env
  local idx uuid="${1:-$("$XRAY_BIN" uuid | tail -n 1 | tr -d '\r')}" label="${2:-}"
  idx="$(require_mobile_inbound)"

  local existing
  existing="$(jq -r --argjson idx "$idx" --arg uuid "$uuid" '
    .inbounds[$idx].settings.clients // []
    | map(select(.id == $uuid)) | .[0].id // empty
  ' "$CONFIG_FILE")"
  [[ -z "$existing" ]] || die "UUID $uuid already exists in config"

  local email="${label:-${uuid:0:8}}"
  local email_exists
  email_exists="$(jq -r --argjson idx "$idx" --arg email "$email" '
    .inbounds[$idx].settings.clients // []
    | map(select(.email == $email)) | .[0].email // empty
  ' "$CONFIG_FILE")"
  [[ -z "$email_exists" ]] || die "Email '$email' already exists. Use a unique label (Xray rejects duplicate emails)."

  log "Adding universal client: $uuid"

  local tmp
  tmp="$(mktemp --suffix=.json)"
  jq --argjson idx "$idx" --arg uuid "$uuid" --arg email "$email" '
    .inbounds[$idx].settings.clients = ((.inbounds[$idx].settings.clients // []) + [{
      "id": $uuid,
      "email": $email
    }])
  ' "$CONFIG_FILE" > "$tmp"
  install_gateway_config "$tmp"

  if [[ -n "$label" ]]; then
    echo "${uuid}=${label}" >> "$LABELS_FILE"
  fi

  restart_gateway

  printf '\n--- Universal VLESS WS TLS link ---\n'
  printf '%s\n' "$(make_mobile_vless_link "$uuid" "$label")"
}

cmd_remove() {
  require_root
  local idx uuid="$1"
  [[ -n "$uuid" ]] || die "Usage: $0 remove <uuid>"
  idx="$(require_mobile_inbound)"

  local existing
  existing="$(jq -r --argjson idx "$idx" --arg uuid "$uuid" '
    .inbounds[$idx].settings.clients // []
    | map(select(.id == $uuid)) | .[0].id // empty
  ' "$CONFIG_FILE")"
  [[ -n "$existing" ]] || die "UUID $uuid not found in config"

  log "Removing universal client: $uuid"
  local tmp
  tmp="$(mktemp --suffix=.json)"
  jq --argjson idx "$idx" --arg uuid "$uuid" '
    .inbounds[$idx].settings.clients |= map(select(.id != $uuid))
  ' "$CONFIG_FILE" > "$tmp"
  install_gateway_config "$tmp"

  if [[ -f "$LABELS_FILE" ]]; then
    sed -i "/^${uuid}=/d" "$LABELS_FILE"
  fi

  restart_gateway
  log "Universal client removed"
}

cmd_links() {
  load_gateway_env
  local idx count
  idx="$(require_mobile_inbound)"
  count="$(jq --argjson idx "$idx" '.inbounds[$idx].settings.clients // [] | length' "$CONFIG_FILE")"
  for (( i=0; i<count; i++ )); do
    local uuid
    uuid="$(jq -r --argjson idx "$idx" --argjson i "$i" '.inbounds[$idx].settings.clients[$i].id' "$CONFIG_FILE")"
    local label=""
    if [[ -f "$LABELS_FILE" ]]; then
      label="$(grep "^${uuid}=" "$LABELS_FILE" 2>/dev/null | cut -d= -f2- || true)"
    fi
    local tag="${label:-${uuid:0:8}}"
    printf '\n[%s]\n' "$tag"
    printf '  %s\n' "$(make_mobile_vless_link "$uuid" "$label")"
  done
  printf '\nTotal: %d client(s)\n' "$count"
  printf 'Gateway domain: %s\n' "$DOMAIN"
  printf 'Universal path: %s\n' "$MOBILE_PATH"
}

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
    exit 1
    ;;
esac
