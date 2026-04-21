#!/usr/bin/env bash
# check-traffic.sh — Monitor and enforce daily traffic limits per user.
#
# Usage:
#   ./check-traffic.sh status              # show traffic for all users
#   ./check-traffic.sh enforce             # disable users over limit, re-enable under
#   ./check-traffic.sh reset               # reset all counters (called by daily cron)
#
# Environment:
#   DAILY_LIMIT_GB=33   — daily limit in GB (default: 33)
#   XRAY_API=127.0.0.1:10085 — Xray Stats API address
#   EXEMPT_FILE=/usr/local/etc/xray/unlimited-clients.json — emails without daily limit

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
XRAY_API="${XRAY_API:-127.0.0.1:10085}"
DAILY_LIMIT_GB="${DAILY_LIMIT_GB:-33}"
DISABLED_FILE="${DISABLED_FILE:-/usr/local/etc/xray/disabled-clients.json}"
EXEMPT_FILE="${EXEMPT_FILE:-/usr/local/etc/xray/unlimited-clients.json}"

DAILY_LIMIT_BYTES=$(( DAILY_LIMIT_GB * 1024 * 1024 * 1024 ))

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run with sudo"
  fi
}

ensure_json_array_file() {
  local path="$1"
  [[ -f "$path" ]] || echo '[]' > "$path"
}

json_array_contains() {
  local path="$1"
  local value="$2"
  [[ -f "$path" ]] && jq -e --arg value "$value" '.[] | select(. == $value)' "$path" > /dev/null 2>&1
}

is_exempt_email() {
  local email="$1"
  json_array_contains "$EXEMPT_FILE" "$email"
}

is_disabled_email() {
  local email="$1"
  json_array_contains "$DISABLED_FILE" "$email"
}

disabled_backup_path() {
  local email="$1"
  printf '/usr/local/etc/xray/disabled-client-%s.json' "$email"
}

remove_from_json_array() {
  local path="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)
  jq --arg value "$value" '[.[] | select(. != $value)]' "$path" > "$tmp"
  mv "$tmp" "$path"
}

reenable_client() {
  local email="$1"
  local backup
  backup=$(disabled_backup_path "$email")
  [[ -f "$backup" ]] || return 1

  local client_json tmp
  client_json=$(cat "$backup")
  tmp=$(mktemp)
  jq "(.inbounds[] | select(.protocol == \"vless\")).settings.clients += [$client_json]" "$XRAY_CONFIG" > "$tmp"
  mv "$tmp" "$XRAY_CONFIG"
  chmod 0644 "$XRAY_CONFIG"
  rm -f "$backup"

  if [[ -f "$DISABLED_FILE" ]]; then
    remove_from_json_array "$DISABLED_FILE" "$email"
  fi

  return 0
}

# Get list of emails from config
get_emails() {
  jq -r '[.inbounds[] | select(.protocol == "vless")][0].settings.clients[].email // empty' "$XRAY_CONFIG"
}

# Query traffic stats for a user (returns bytes)
get_user_traffic() {
  local email="$1"
  local direction="$2"  # uplink or downlink
  local result
  result=$("$XRAY_BIN" api stats --server="$XRAY_API" -name "user>>>$email>>>traffic>>>$direction" 2>/dev/null | grep '"value"' | grep -o '[0-9]*' || echo "0")
  echo "${result:-0}"
}

# Format bytes to human-readable
human_bytes() {
  local bytes=$1
  if (( bytes >= 1073741824 )); then
    printf '%.2f GB' "$(echo "scale=2; $bytes / 1073741824" | bc)"
  elif (( bytes >= 1048576 )); then
    printf '%.1f MB' "$(echo "scale=1; $bytes / 1048576" | bc)"
  else
    printf '%d KB' "$(( bytes / 1024 ))"
  fi
}

cmd_status() {
  printf '%-20s %12s %12s %12s %8s  %s\n' "EMAIL" "DOWNLOAD" "UPLOAD" "TOTAL" "LIMIT%" "STATUS"
  printf '%-20s %12s %12s %12s %8s  %s\n' "----" "--------" "------" "-----" "------" "------"

  local emails
  emails=$(get_emails)

  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    local down up total pct status pct_display
    down=$(get_user_traffic "$email" "downlink")
    up=$(get_user_traffic "$email" "uplink")
    total=$(( down + up ))
    pct=$(( total * 100 / DAILY_LIMIT_BYTES ))
    pct_display="${pct}%"

    if is_exempt_email "$email"; then
      status="EXEMPT"
      pct_display="∞"
    elif is_disabled_email "$email"; then
      status="DISABLED"
    elif (( total >= DAILY_LIMIT_BYTES )); then
      status="OVER LIMIT"
    else
      status="OK"
    fi

    printf '%-20s %12s %12s %12s %8s  %s\n' \
      "$email" "$(human_bytes "$down")" "$(human_bytes "$up")" "$(human_bytes "$total")" "$pct_display" "$status"
  done <<< "$emails"

  printf '\nDaily limit: %d GB\n' "$DAILY_LIMIT_GB"
  printf 'Exempt users file: %s\n' "$EXEMPT_FILE"
}

cmd_enforce() {
  log "Enforcing daily limit of ${DAILY_LIMIT_GB} GB..."

  # Initialize disabled file if needed
  ensure_json_array_file "$DISABLED_FILE"
  ensure_json_array_file "$EXEMPT_FILE"

  local emails changed=false
  emails=$(get_emails)

  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    local down up total
    down=$(get_user_traffic "$email" "downlink")
    up=$(get_user_traffic "$email" "uplink")
    total=$(( down + up ))

    local is_disabled=false
    if is_disabled_email "$email"; then
      is_disabled=true
    fi

    if is_exempt_email "$email"; then
      if [[ "$is_disabled" == "true" ]] && reenable_client "$email"; then
        log "Re-enabled exempt user: $email"
        changed=true
      fi
      continue
    fi

    if (( total >= DAILY_LIMIT_BYTES )) && [[ "$is_disabled" == "false" ]]; then
      # Find UUID for this email and remove from config
      local uuid
      uuid=$(jq -r "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[] | select(.email == \"$email\") | .id" "$XRAY_CONFIG")
      if [[ -n "$uuid" ]]; then
        log "DISABLING $email ($(human_bytes "$total") used) — UUID: $uuid"

        # Save to disabled list with full client info
        local tmp
        tmp=$(mktemp)
        jq --arg email "$email" '. += [$email]' "$DISABLED_FILE" > "$tmp"
        mv "$tmp" "$DISABLED_FILE"

        # Save client object for re-enabling
        jq "[.inbounds[] | select(.protocol == \"vless\")][0].settings.clients[] | select(.email == \"$email\")" "$XRAY_CONFIG" \
          > "$(disabled_backup_path "$email")"

        # Remove from config
        tmp=$(mktemp)
        jq "del((.inbounds[] | select(.protocol == \"vless\")).settings.clients[] | select(.email == \"$email\"))" "$XRAY_CONFIG" > "$tmp"
        mv "$tmp" "$XRAY_CONFIG"
        chmod 0644 "$XRAY_CONFIG"
        changed=true
      fi
    fi
  done <<< "$emails"

  if [[ "$changed" == "true" ]]; then
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG" || die "Config validation failed!"
    systemctl restart xray
    log "Xray restarted with updated config"
  else
    log "No changes needed"
  fi
}

cmd_reset() {
  log "Resetting daily traffic counters and re-enabling disabled clients..."

  # Re-enable disabled clients
  if [[ -f "$DISABLED_FILE" ]]; then
    ensure_json_array_file "$EXEMPT_FILE"
    local disabled_emails
    disabled_emails=$(jq -r '.[]' "$DISABLED_FILE" 2>/dev/null || true)
    local changed=false

    while IFS= read -r email; do
      [[ -z "$email" ]] && continue
      if is_exempt_email "$email"; then
        continue
      fi
      local backup
      backup=$(disabled_backup_path "$email")
      if [[ -f "$backup" ]]; then
        log "Re-enabling: $email"
        reenable_client "$email"
        changed=true
      fi
    done <<< "$disabled_emails"

    # Clear disabled list after re-enable cycle.
    echo '[]' > "$DISABLED_FILE"

    if [[ "$changed" == "true" ]]; then
      "$XRAY_BIN" run -test -config "$XRAY_CONFIG" || die "Config validation failed!"
      systemctl restart xray
      log "Xray restarted with re-enabled clients"
    fi
  fi

  # Reset stats counters
  local all_emails
  all_emails=$(get_emails)
  while IFS= read -r email; do
    [[ -z "$email" ]] && continue
    "$XRAY_BIN" api stats --server="$XRAY_API" -name "user>>>$email>>>traffic>>>downlink" -reset 2>/dev/null || true
    "$XRAY_BIN" api stats --server="$XRAY_API" -name "user>>>$email>>>traffic>>>uplink" -reset 2>/dev/null || true
  done <<< "$all_emails"

  log "All counters reset"
}

# --- Main ---
case "${1:-}" in
  status)
    cmd_status
    ;;
  enforce)
    require_root
    cmd_enforce
    ;;
  reset)
    require_root
    cmd_reset
    ;;
  *)
    echo "Usage: $0 {status|enforce|reset}"
    echo ""
    echo "  status   — show traffic usage for all users"
    echo "  enforce  — disable users who exceeded daily limit (${DAILY_LIMIT_GB} GB)"
    echo "  reset    — reset counters and re-enable disabled users (daily cron)"
    echo "  exempt users are taken from: $EXEMPT_FILE"
    exit 1
    ;;
esac
