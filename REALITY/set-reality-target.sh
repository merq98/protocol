#!/usr/bin/env bash
# set-reality-target.sh — View, verify, and update REALITY target on a running Xray server.
#
# Usage:
#   ./set-reality-target.sh show
#   ./set-reality-target.sh verify <host[:port]>
#   ./set-reality-target.sh set <host[:port]> [--name sni1] [--name sni2] [--keep-pool]
#   ./set-reality-target.sh pool [--rotate-seconds 300]
#
# Examples:
#   sudo ./set-reality-target.sh verify www.google.com
#   sudo ./set-reality-target.sh set www.google.com
#   sudo ./set-reality-target.sh set dl.google.com --name dl.google.com
#   sudo ./set-reality-target.sh pool
#
# Environment:
#   XRAY_BIN=/usr/local/bin/xray
#   XRAY_CONFIG=/usr/local/etc/xray/config.json
#   TARGETS_JSON_SOURCE=.../WHITE_LIST_SITES_2026.json
#   TARGETS_JSON_DEST=/usr/local/etc/xray/WHITE_LIST_SITES_2026.json

set -euo pipefail

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
PROTOCOL_ROOT="${PROTOCOL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TARGETS_JSON_SOURCE="${TARGETS_JSON_SOURCE:-$PROTOCOL_ROOT/REALITY/WHITE_LIST_SITES_2026.json}"
TARGETS_JSON_DEST="${TARGETS_JSON_DEST:-/usr/local/etc/xray/WHITE_LIST_SITES_2026.json}"
TARGETS_ROTATE_SECONDS="${TARGETS_ROTATE_SECONDS:-300}"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run with sudo"
  fi
}

require_tools() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  [[ -f "$XRAY_CONFIG" ]] || die "Config not found: $XRAY_CONFIG"
  [[ -x "$XRAY_BIN" ]] || die "Xray binary not found: $XRAY_BIN"
}

vless_reality_jq_path() {
  printf '%s' '.inbounds[] | select(.protocol == "vless") | .streamSettings.realitySettings'
}

normalize_target() {
  local value="$1"
  [[ -n "$value" ]] || die "Target host is required"

  if [[ "$value" != *:* ]]; then
    value="${value}:443"
  fi

  local host="${value%:*}"
  local port="${value##*:}"

  [[ -n "$host" && -n "$port" ]] || die "Invalid target format: use host or host:port"
  printf '%s:%s' "$host" "$port"
}

target_host() {
  local target="$1"
  printf '%s' "${target%:*}"
}

cmd_show() {
  require_tools
  jq "$(vless_reality_jq_path()) | {target, serverNames, targetsFile, targetsRotateSeconds}" "$XRAY_CONFIG"
}

cmd_verify() {
  local raw_target="${1:-}"
  [[ -n "$raw_target" ]] || die "Usage: $0 verify <host[:port]>"

  local target host port
  target=$(normalize_target "$raw_target")
  host=$(target_host "$target")
  port="${target##*:}"

  log "Checking reachability of $target from this server"

  if ! curl -4 -sI --max-time 10 "https://${host}/" | head -n 1 | grep -qE 'HTTP/[12]'; then
    die "HTTPS check failed for https://${host}/ — target may be unreachable from this VPS"
  fi
  log "HTTPS responds"

  if command -v openssl >/dev/null 2>&1; then
    local tls_info
    tls_info=$(echo | openssl s_client -connect "${host}:${port}" -servername "$host" -alpn h2 2>/dev/null | grep -E 'Protocol|ALPN' || true)
    if [[ -n "$tls_info" ]]; then
      printf '%s\n' "$tls_info"
    else
      log "OpenSSL check returned no protocol info"
    fi
  else
    log "openssl not installed — skipped TLS/ALPN check"
  fi

  log "Target looks reachable from this VPS"
}

apply_and_restart() {
  require_root
  require_tools

  local jq_filter="$1"
  shift

  cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak-$(date +%F-%H%M%S)"

  local tmp
  tmp=$(mktemp)
  jq "$jq_filter" "$@" "$XRAY_CONFIG" > "$tmp"
  mv "$tmp" "$XRAY_CONFIG"
  chmod 0644 "$XRAY_CONFIG"

  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"

  systemctl restart xray
  systemctl status xray --no-pager
}

cmd_set() {
  [[ -n "${1:-}" ]] || die "Usage: $0 set <host[:port]> [--name sni] [--keep-pool]"

  local raw_target="$1"
  shift

  local target keep_pool=0
  local -a server_names=()

  target=$(normalize_target "$raw_target")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ -n "${2:-}" ]] || die "--name requires a value"
        server_names+=("$2")
        shift 2
        ;;
      --keep-pool)
        keep_pool=1
        shift
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  if [[ ${#server_names[@]} -eq 0 ]]; then
    server_names=("$(target_host "$target")")
  fi

  local names_json
  names_json=$(printf '%s\n' "${server_names[@]}" | jq -R . | jq -s .)

  log "Setting REALITY target to: $target"
  log "serverNames: $(printf '%s ' "${server_names[@]}")"

  if [[ "${VERIFY_TARGET:-1}" != "0" ]]; then
    cmd_verify "$target"
  fi

  local jq_filter
  if [[ "$keep_pool" -eq 1 ]]; then
    jq_filter=$(printf '%s' "$(vless_reality_jq_path()) |= . + {target: \$target, serverNames: \$names}")
    apply_and_restart "$jq_filter" --arg target "$target" --argjson names "$names_json"
  else
    jq_filter=$(printf '%s' "$(vless_reality_jq_path()) |= (. + {target: \$target, serverNames: \$names} | del(.targetsFile, .targetsRotateSeconds))")
    apply_and_restart "$jq_filter" --arg target "$target" --argjson names "$names_json"
  fi

  log "Update complete"
  printf '\nUpdate clients: set serverName / SNI to one of:\n'
  printf '  - %s\n' "${server_names[@]}"
  printf '\nRe-import client link:\n'
  printf '  sudo ./manage-clients.sh links\n'
}

cmd_pool() {
  local rotate_seconds="$TARGETS_ROTATE_SECONDS"
  if [[ "${1:-}" == "--rotate-seconds" ]]; then
    [[ -n "${2:-}" ]] || die "--rotate-seconds requires a value"
    rotate_seconds="$2"
  fi

  [[ -f "$TARGETS_JSON_SOURCE" ]] || die "Targets pool file not found: $TARGETS_JSON_SOURCE"

  require_root
  require_tools

  log "Restoring target pool from $TARGETS_JSON_SOURCE"
  cp "$TARGETS_JSON_SOURCE" "$TARGETS_JSON_DEST"
  chown root:root "$TARGETS_JSON_DEST"
  chmod 0644 "$TARGETS_JSON_DEST"

  local jq_filter
  jq_filter=$(printf '%s' "$(vless_reality_jq_path()) |= . + {targetsFile: \$pool, targetsRotateSeconds: \$rotate} | del(.target)")
  apply_and_restart "$jq_filter" --arg pool "$TARGETS_JSON_DEST" --argjson rotate "$rotate_seconds"

  log "Target pool enabled (rotate every ${rotate_seconds}s)"
}

case "${1:-}" in
  show)
    cmd_show
    ;;
  verify)
    [[ -n "${2:-}" ]] || die "Usage: $0 verify <host[:port]>"
    cmd_verify "$2"
    ;;
  set)
    shift
    [[ $# -gt 0 ]] || die "Usage: $0 set <host[:port]> [--name sni] [--keep-pool]"
    cmd_set "$@"
    ;;
  pool)
    shift
    cmd_pool "$@"
    ;;
  *)
    cat <<EOF
Usage:
  $0 show
  $0 verify <host[:port]>
  $0 set <host[:port]> [--name sni] [--name sni2] [--keep-pool]
  $0 pool [--rotate-seconds 300]

Examples:
  sudo $0 verify www.google.com
  sudo $0 set www.google.com
  sudo $0 set dl.google.com --name dl.google.com
  sudo $0 pool
EOF
    exit 1
    ;;
esac
