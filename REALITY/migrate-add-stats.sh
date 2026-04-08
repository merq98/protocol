#!/usr/bin/env bash
# migrate-add-stats.sh — Add Stats API to existing Xray config without losing clients.
#
# Usage:
#   sudo bash migrate-add-stats.sh
#
# Idempotent: safe to run multiple times.

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -f "$XRAY_CONFIG" ]] || die "Config not found: $XRAY_CONFIG"

# Backup
BACKUP="${XRAY_CONFIG}.bak.$(date +%s)"
cp "$XRAY_CONFIG" "$BACKUP"
log "Backup saved: $BACKUP"

tmp=$(mktemp)

# 1. Add stats, api, policy if missing
if jq -e '.stats' "$XRAY_CONFIG" > /dev/null 2>&1; then
  log "stats already present, skipping"
  cp "$XRAY_CONFIG" "$tmp"
else
  log "Adding stats, api, policy sections"
  jq '. + {"stats": {}, "api": {"tag": "api", "services": ["StatsService"]}, "policy": {"levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}}, "system": {"statsInboundUplink": true, "statsInboundDownlink": true}}}' "$XRAY_CONFIG" > "$tmp"
  mv "$tmp" "$XRAY_CONFIG"
  tmp=$(mktemp)
fi

# 2. Add API inbound if missing
if jq -e '.inbounds[] | select(.tag == "api")' "$XRAY_CONFIG" > /dev/null 2>&1; then
  log "API inbound already present, skipping"
else
  log "Adding API inbound (127.0.0.1:10085)"
  jq '.inbounds = [{"listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}, "tag": "api"}] + .inbounds' "$XRAY_CONFIG" > "$tmp"
  mv "$tmp" "$XRAY_CONFIG"
  tmp=$(mktemp)
fi

# 3. Add tag to VLESS inbound if missing
if jq -e '[.inbounds[] | select(.protocol == "vless")][0].tag' "$XRAY_CONFIG" | grep -q 'null'; then
  log "Adding tag 'vless-in' to VLESS inbound"
  jq '(.inbounds[] | select(.protocol == "vless")).tag = "vless-in"' "$XRAY_CONFIG" > "$tmp"
  mv "$tmp" "$XRAY_CONFIG"
  tmp=$(mktemp)
else
  log "VLESS inbound tag already set"
fi

# 4. Add email to clients that don't have one
log "Ensuring all clients have email field"
LABELS_FILE="/usr/local/etc/xray/client-labels.txt"
count=$(jq '[.inbounds[] | select(.protocol == "vless")][0].settings.clients | length' "$XRAY_CONFIG")
changed=false
for (( i=0; i<count; i++ )); do
  email=$(jq -r "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[$i].email // \"\"" "$XRAY_CONFIG")
  if [[ -z "$email" ]]; then
    uuid=$(jq -r "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[$i].id" "$XRAY_CONFIG")
    # Try to find label
    label=""
    if [[ -f "$LABELS_FILE" ]]; then
      label=$(grep "^${uuid}=" "$LABELS_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi
    new_email="${label:-${uuid:0:8}}"
    log "  Client $uuid -> email=$new_email"
    jq "([.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[$i]).email = \"$new_email\"" "$XRAY_CONFIG" > "$tmp"
    mv "$tmp" "$XRAY_CONFIG"
    tmp=$(mktemp)
    changed=true
  fi
done

# 5. Add routing rule for API if missing
if jq -e '.routing.rules[] | select(.outboundTag == "api")' "$XRAY_CONFIG" > /dev/null 2>&1; then
  log "API routing rule already present"
else
  log "Adding API routing rule"
  if jq -e '.routing' "$XRAY_CONFIG" > /dev/null 2>&1; then
    jq '.routing.rules += [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"}]' "$XRAY_CONFIG" > "$tmp"
  else
    jq '. + {"routing": {"rules": [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"}]}}' "$XRAY_CONFIG" > "$tmp"
  fi
  mv "$tmp" "$XRAY_CONFIG"
fi

chmod 0644 "$XRAY_CONFIG"

# Validate
log "Validating config"
"$XRAY_BIN" run -test -config "$XRAY_CONFIG" || { log "VALIDATION FAILED — restoring backup"; cp "$BACKUP" "$XRAY_CONFIG"; die "Migration aborted"; }

log "Restarting Xray"
systemctl restart xray
systemctl status xray --no-pager

log "Migration complete! Stats API available at 127.0.0.1:10085"
rm -f "$tmp"
