#!/usr/bin/env bash
# deploy-mobile-gateway-vps.sh — Install Xray universal gateway on VPS-2.
#
# Clients (Windows v2rayN / Happ Plus / iOS) connect with standard VLESS+WS+TLS to VPS-2.
# VPS-2 forwards traffic to VPS-1 through VLESS+REALITY using one upstream UUID.
#
# Prerequisites:
#   - Ubuntu/Debian VPS-2 with Caddy TLS for the domain
#   - Existing wsrelay-server on /ws is optional but supported side-by-side
#   - Upstream client UUID created on VPS-1 (e.g. universal-gateway)
#
# Usage:
#   sudo ./deploy-mobile-gateway-vps.sh install \
#     --domain mythicquality.com \
#     --path /universal \
#     --origin 37.220.83.19:443 \
#     --upstream-uuid '<UUID_FROM_VPS1>' \
#     --server-name '<REALITY_SNI>' \
#     --public-key '<REALITY_PUBLIC_KEY>' \
#     --short-id '<REALITY_SHORT_ID>'
#
#   sudo ./deploy-mobile-gateway-vps.sh status
#   sudo ./deploy-mobile-gateway-vps.sh uninstall

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTOCOL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_VERSION="${XRAY_VERSION:-}"
CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/xray-mobile}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.json}"
GATEWAY_ENV="${GATEWAY_ENV:-$CONFIG_DIR/gateway.env}"
LABELS_FILE="${LABELS_FILE:-$CONFIG_DIR/client-labels.txt}"
SERVICE_NAME="${SERVICE_NAME:-xray-mobile-gateway}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CADDY_FILE="${CADDY_FILE:-/etc/caddy/Caddyfile}"
WSRELAY_LISTEN="${WSRELAY_LISTEN:-127.0.0.1:10080}"
XRAY_API_LISTEN="${XRAY_API_LISTEN:-127.0.0.1:10086}"

DOMAIN=""
MOBILE_PATH="/universal"
LISTEN="127.0.0.1:10081"
ORIGIN="37.220.83.19:443"
UPSTREAM_UUID=""
SERVER_NAME=""
PUBLIC_KEY=""
SHORT_ID=""

die()  { printf 'Error: %s\n' "$1" >&2; exit 1; }
log()  { printf '==> %s\n' "$1"; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)        DOMAIN="${2:-}"; shift 2 ;;
      --path)          MOBILE_PATH="${2:-}"; shift 2 ;;
      --listen)        LISTEN="${2:-}"; shift 2 ;;
      --origin)        ORIGIN="${2:-}"; shift 2 ;;
      --upstream-uuid) UPSTREAM_UUID="${2:-}"; shift 2 ;;
      --server-name)   SERVER_NAME="${2:-}"; shift 2 ;;
      --public-key)    PUBLIC_KEY="${2:-}"; shift 2 ;;
      --short-id)      SHORT_ID="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
}

normalize_mobile_path() {
  if [[ -z "$MOBILE_PATH" ]]; then
    MOBILE_PATH="/universal"
  fi
  if [[ "$MOBILE_PATH" != /* ]]; then
    MOBILE_PATH="/$MOBILE_PATH"
  fi
}

validate_install_args() {
  [[ -n "$DOMAIN" ]] || die "--domain is required"
  [[ -n "$UPSTREAM_UUID" ]] || die "--upstream-uuid is required"
  [[ -n "$SERVER_NAME" ]] || die "--server-name is required"
  [[ -n "$PUBLIC_KEY" ]] || die "--public-key is required"
  [[ -n "$SHORT_ID" ]] || die "--short-id is required"
  [[ "$ORIGIN" == *:* ]] || die "--origin must be host:port"
}

split_origin() {
  ORIGIN_HOST="${ORIGIN%:*}"
  ORIGIN_PORT="${ORIGIN##*:}"
  [[ -n "$ORIGIN_HOST" && -n "$ORIGIN_PORT" ]] || die "Invalid --origin: $ORIGIN"
}

install_xray() {
  if [[ -x "$XRAY_BIN" ]]; then
    log "Xray already installed: $($XRAY_BIN version | head -n 1)"
    return
  fi

  log "Installing Xray release binary"
  apt-get update
  apt-get install -y curl unzip jq

  local arch asset version url tmp_dir
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  asset="linux-64" ;;
    aarch64) asset="linux-arm64-v8a" ;;
    *) die "Unsupported architecture: $arch" ;;
  esac

  if [[ -z "$XRAY_VERSION" ]]; then
    version="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
    [[ -n "$version" && "$version" != "null" ]] || die "Failed to resolve latest Xray version"
  else
    version="$XRAY_VERSION"
  fi

  url="https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-${asset}.zip"
  tmp_dir="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp_dir/xray.zip"
  unzip -qo "$tmp_dir/xray.zip" -d "$tmp_dir"
  install -m 0755 "$tmp_dir/xray" "$XRAY_BIN"
  rm -rf "$tmp_dir"
  log "Installed $XRAY_BIN ($("$XRAY_BIN" version | head -n 1))"
}

preserve_existing_clients() {
  if [[ -f "$CONFIG_FILE" ]]; then
    jq -c '[.inbounds[]? | select(.tag == "mobile-in")][0].settings.clients // []' "$CONFIG_FILE"
    return
  fi
  printf '[]'
}

write_gateway_env() {
  mkdir -p "$CONFIG_DIR"
  cat > "$GATEWAY_ENV" <<EOF
DOMAIN=$DOMAIN
MOBILE_PATH=$MOBILE_PATH
MOBILE_LISTEN=$LISTEN
ORIGIN=$ORIGIN
XRAY_API=$XRAY_API_LISTEN
EOF
  chmod 0644 "$GATEWAY_ENV"
  touch "$LABELS_FILE"
  chmod 0644 "$LABELS_FILE"
}

write_xray_config() {
  local clients_json
  clients_json="$(preserve_existing_clients)"
  mkdir -p "$CONFIG_DIR"

  jq -n \
    --arg listen_host "${LISTEN%:*}" \
    --argjson listen_port "${LISTEN##*:}" \
    --arg api_host "${XRAY_API_LISTEN%:*}" \
    --argjson api_port "${XRAY_API_LISTEN##*:}" \
    --arg mobile_path "$MOBILE_PATH" \
    --argjson clients "$clients_json" \
    --arg origin_host "$ORIGIN_HOST" \
    --argjson origin_port "$ORIGIN_PORT" \
    --arg upstream_uuid "$UPSTREAM_UUID" \
    --arg server_name "$SERVER_NAME" \
    --arg public_key "$PUBLIC_KEY" \
    --arg short_id "$SHORT_ID" \
    '{
      log: { loglevel: "warning" },
      api: {
        tag: "api",
        services: ["StatsService"]
      },
      stats: {},
      policy: {
        levels: {
          "0": {
            statsUserUplink: true,
            statsUserDownlink: true
          }
        },
        system: {
          statsInboundUplink: true,
          statsInboundDownlink: true,
          statsOutboundUplink: true,
          statsOutboundDownlink: true
        }
      },
      inbounds: [
        {
          listen: $api_host,
          port: $api_port,
          protocol: "dokodemo-door",
          tag: "api",
          settings: {
            address: $api_host
          }
        },
        {
          listen: $listen_host,
          port: $listen_port,
          protocol: "vless",
          tag: "mobile-in",
          settings: {
            clients: $clients,
            decryption: "none"
          },
          streamSettings: {
            network: "ws",
            security: "none",
            wsSettings: { path: $mobile_path }
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"]
          }
        }
      ],
      outbounds: [
        {
          protocol: "vless",
          tag: "proxy",
          settings: {
            vnext: [
              {
                address: $origin_host,
                port: $origin_port,
                users: [
                  {
                    id: $upstream_uuid,
                    encryption: "none",
                    flow: "xtls-rprx-vision"
                  }
                ]
              }
            ]
          },
          streamSettings: {
            network: "raw",
            security: "reality",
            realitySettings: {
              serverName: $server_name,
              fingerprint: "chrome",
              publicKey: $public_key,
              shortId: $short_id
            }
          }
        },
        {
          protocol: "freedom",
          tag: "direct"
        }
      ],
      routing: {
        domainStrategy: "AsIs",
        rules: [
          {
            type: "field",
            inboundTag: ["api"],
            outboundTag: "api"
          },
          {
            type: "field",
            inboundTag: ["mobile-in"],
            outboundTag: "proxy"
          }
        ]
      }
    }' > "$CONFIG_FILE"

  chmod 0644 "$CONFIG_FILE"
  "$XRAY_BIN" run -test -config "$CONFIG_FILE"
  log "Wrote $CONFIG_FILE"
}

write_systemd_unit() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Universal Gateway (VPS-2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  systemctl status "$SERVICE_NAME" --no-pager
}

update_caddy_routes() {
  command -v caddy >/dev/null 2>&1 || die "Caddy is not installed. Install wsrelay first or install Caddy manually."
  [[ -f "$CADDY_FILE" ]] || die "Caddyfile not found: $CADDY_FILE"

  python3 - "$CADDY_FILE" "$DOMAIN" "$MOBILE_PATH" "$LISTEN" "$WSRELAY_LISTEN" <<'PY'
import pathlib
import sys

caddy_file, domain, mobile_path, mobile_listen, wsrelay_listen = sys.argv[1:6]
path = pathlib.Path(caddy_file)
text = path.read_text(encoding="utf-8")

site_block = f"""{domain} {{
    handle {mobile_path}* {{
        reverse_proxy {mobile_listen}
    }}
    handle /ws* {{
        reverse_proxy {wsrelay_listen}
    }}
    handle {{
        respond "protocol gateway" 200
    }}
}}"""

def find_site_block(source, site):
    marker = f"{site} {{"
    start = source.find(marker)
    if start == -1:
        return None
    brace = source.find("{", start)
    if brace == -1:
        return None
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return start, index + 1
    raise SystemExit(f"Malformed Caddyfile: unclosed site block for {site}")

block_range = find_site_block(text, domain)
if block_range:
    start, end = block_range
    text = text[:start].rstrip() + "\n\n" + site_block + "\n" + text[end:].lstrip()
else:
    text = text.rstrip() + "\n\n" + site_block + "\n"

path.write_text(text, encoding="utf-8")
print(f"Updated Caddy site block for {domain}")
PY

  systemctl enable --now caddy
  caddy fmt --overwrite "$CADDY_FILE" >/dev/null 2>&1 || true
  systemctl reload caddy || systemctl restart caddy
  systemctl status caddy --no-pager
}

cmd_install() {
  require_root
  shift || true
  parse_args "$@"
  normalize_mobile_path
  validate_install_args
  split_origin

  if ! command -v jq >/dev/null 2>&1; then
    apt-get update
    apt-get install -y jq
  fi

  install_xray
  write_gateway_env
  write_xray_config
  write_systemd_unit
  update_caddy_routes

  log "Universal gateway installed"
  printf '\nNext:\n'
  printf '  sudo %s/manage-mobile-clients.sh add windows-stas\n' "$SCRIPT_DIR"
  printf '  sudo %s/manage-mobile-clients.sh add iphone-stas\n' "$SCRIPT_DIR"
  printf '\nCheck:\n'
  printf '  curl -I https://%s%s\n' "$DOMAIN" "$MOBILE_PATH"
  printf '  sudo %s/check-universal-traffic.sh status\n' "$SCRIPT_DIR"
  printf '  sudo systemctl status %s --no-pager\n' "$SERVICE_NAME"
}

cmd_status() {
  systemctl status "$SERVICE_NAME" --no-pager || true
  systemctl status wsrelay-server --no-pager || true
  systemctl status caddy --no-pager || true
  ss -lntp | grep -E '(:443|:10080|:10081|:10086)' || true
  if [[ -f "$CONFIG_FILE" ]]; then
    "$XRAY_BIN" run -test -config "$CONFIG_FILE" || true
  fi
}

cmd_uninstall() {
  require_root
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  log "Removed $SERVICE_NAME"
  log "Caddy routes and $CONFIG_DIR were left intact for manual cleanup"
}

case "${1:-}" in
  install)   cmd_install "$@" ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
  *)
    cat <<EOF
Usage:
  sudo $0 install \\
    --domain mythicquality.com \\
    --path /universal \\
    --origin 37.220.83.19:443 \\
    --upstream-uuid '<UUID_FROM_VPS1>' \\
    --server-name '<REALITY_SNI>' \\
    --public-key '<REALITY_PUBLIC_KEY>' \\
    --short-id '<REALITY_SHORT_ID>'

  sudo $0 status
  sudo $0 uninstall
EOF
    exit 1
    ;;
esac
