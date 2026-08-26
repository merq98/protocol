#!/usr/bin/env bash
# deploy-wsrelay-vps.sh — Install self-hosted WS relay on VPS-2.
#
# Prerequisites:
#   - Ubuntu/Debian VPS-2 with public IP
#   - DNS A record: relay.<domain> -> VPS-2 IP
#   - Outbound TCP from VPS-2 to REALITY VPS:443 allowed
#
# Usage:
#   sudo ./deploy-wsrelay-vps.sh install \
#     --origin 37.220.83.19:443 \
#     --domain relay.example.com
#
#   sudo ./deploy-wsrelay-vps.sh status
#   sudo ./deploy-wsrelay-vps.sh uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTOCOL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_SRC="$PROTOCOL_ROOT/tools/wsrelay-server"
INSTALL_BIN="/usr/local/bin/wsrelay-server"
SERVICE_NAME="wsrelay-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CADDY_FILE="/etc/caddy/Caddyfile"

ORIGIN="37.220.83.19:443"
DOMAIN=""
LISTEN="127.0.0.1:10080"
WS_PATH="/ws"

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --origin) ORIGIN="${2:-}"; shift 2 ;;
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --listen) LISTEN="${2:-}"; shift 2 ;;
      --path)   WS_PATH="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
}

install_build_tools() {
  if command -v go >/dev/null 2>&1; then
    return
  fi
  log "Installing Go build toolchain"
  apt-get update
  apt-get install -y golang-go
}

build_binary() {
  [[ -d "$RELAY_SRC" ]] || die "Relay source not found: $RELAY_SRC"
  install_build_tools
  log "Building wsrelay-server"
  (
    cd "$RELAY_SRC"
    go mod tidy
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /tmp/wsrelay-server .
  )
  install -m 0755 /tmp/wsrelay-server "$INSTALL_BIN"
  rm -f /tmp/wsrelay-server
  log "Installed $INSTALL_BIN"
}

write_systemd_unit() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=REALITY WebSocket to TCP relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_BIN -listen $LISTEN -origin $ORIGIN -path $WS_PATH
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl status "$SERVICE_NAME" --no-pager
}

install_caddy() {
  [[ -n "$DOMAIN" ]] || die "--domain is required for Caddy TLS setup"

  if ! command -v caddy >/dev/null 2>&1; then
    log "Installing Caddy"
    apt-get update
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  fi

  local relay_url="wss://${DOMAIN}${WS_PATH}"
  if [[ -f "$CADDY_FILE" ]] && grep -q "$DOMAIN" "$CADDY_FILE"; then
    log "Caddyfile already contains $DOMAIN"
  else
    log "Writing Caddy site block for $DOMAIN"
    {
      printf '\n%s {\n' "$DOMAIN"
      printf '    reverse_proxy %s {\n' "$LISTEN"
      printf '        flush_interval -1\n'
      printf '        transport http {\n'
      printf '            versions 1.1\n'
      printf '            read_timeout 0\n'
      printf '            write_timeout 0\n'
      printf '            dial_timeout 10s\n'
      printf '        }\n'
      printf '    }\n'
      printf '}\n'
    } >> "$CADDY_FILE"
  fi

  systemctl enable --now caddy
  systemctl reload caddy || systemctl restart caddy
  systemctl status caddy --no-pager

  log "Relay URL for clients: $relay_url"
  printf '\nNext on Windows (v2rayN closed):\n'
  printf '  .\\set-v2rayn-ws-relay.ps1 -WsRelayUrl %q\n' "$relay_url"
}

cmd_install() {
  require_root
  shift || true
  parse_args "$@"
  build_binary
  write_systemd_unit
  install_caddy
}

cmd_status() {
  systemctl status "$SERVICE_NAME" --no-pager || true
  systemctl status caddy --no-pager || true
  ss -lntp | grep -E '(:443|:10080)' || true
}

cmd_uninstall() {
  require_root
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$INSTALL_BIN"
  systemctl daemon-reload
  log "Removed $SERVICE_NAME"
}

case "${1:-}" in
  install)   cmd_install "$@" ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
  *)
    cat <<EOF
Usage:
  sudo $0 install --origin 37.220.83.19:443 --domain relay.example.com
  sudo $0 status
  sudo $0 uninstall
EOF
    exit 1
    ;;
esac
