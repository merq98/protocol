#!/usr/bin/env bash
# deploy-mtproto-two-vps.sh - Two-VPS Telegram MTProto proxy deployment.
#
# VPS1: public TCP relay on PUBLIC_PORT -> VPS2 WireGuard IP:MTPROTO_BACKEND_PORT.
# VPS2: WireGuard peer + official Telegram MTProto Docker proxy bound to WireGuard IP only.
#
# Usage:
#   sudo MTPROTO_ENV=/root/mtproto-two-vps.env ./deploy-mtproto-two-vps.sh prepare
#   sudo MTPROTO_ENV=/root/mtproto-two-vps.env ./deploy-mtproto-two-vps.sh install-vps2
#   sudo MTPROTO_ENV=/root/mtproto-two-vps.env ./deploy-mtproto-two-vps.sh install-vps1
#   sudo ./deploy-mtproto-two-vps.sh status-vps1
#   sudo ./deploy-mtproto-two-vps.sh status-vps2

set -euo pipefail

if [[ -n "${MTPROTO_ENV:-}" ]]; then
  [[ -f "$MTPROTO_ENV" ]] || {
    printf 'Error: MTPROTO_ENV file not found: %s\n' "$MTPROTO_ENV" >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source "$MTPROTO_ENV"
fi

WG_INTERFACE="${WG_INTERFACE:-wg-mtproto}"
WG_SUBNET_CIDR="${WG_SUBNET_CIDR:-10.77.0.0/24}"
WG_VPS1_ADDR="${WG_VPS1_ADDR:-10.77.0.1/24}"
WG_VPS2_ADDR="${WG_VPS2_ADDR:-10.77.0.2/24}"
WG_VPS1_IP="${WG_VPS1_IP:-10.77.0.1}"
WG_VPS2_IP="${WG_VPS2_IP:-10.77.0.2}"
WG_PORT="${WG_PORT:-51821}"
WG_PEER_PUBLIC_KEY="${WG_PEER_PUBLIC_KEY:-}"
WG_ENDPOINT_HOST="${WG_ENDPOINT_HOST:-}"
WG_PRIVATE_KEY="${WG_PRIVATE_KEY:-}"
VPS1_PUBLIC_IP="${VPS1_PUBLIC_IP:-}"

SSH_PORT="${SSH_PORT:-22}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_PORT="${PUBLIC_PORT:-443}"
MTPROTO_BACKEND_PORT="${MTPROTO_BACKEND_PORT:-8443}"
MTPROTO_SECRET="${MTPROTO_SECRET:-}"
MTPROTO_SECRET_DOMAIN="${MTPROTO_SECRET_DOMAIN:-www.cloudflare.com}"
MTPROTO_CONTAINER="${MTPROTO_CONTAINER:-mtproto-proxy}"
MTPROTO_SERVICE="${MTPROTO_SERVICE:-mtproto-proxy}"
MTPROTO_IMAGE="${MTPROTO_IMAGE:-telegrammessenger/proxy:latest}"
MTPROTO_DATA_DIR="${MTPROTO_DATA_DIR:-/var/lib/mtproto-proxy}"
MTPROTO_CONFIG_DIR="${MTPROTO_CONFIG_DIR:-/usr/local/etc/mtproto-two-vps}"
HAPROXY_SERVICE="${HAPROXY_SERVICE:-haproxy}"

WG_CONF="/etc/wireguard/${WG_INTERFACE}.conf"
WG_KEY_FILE="/etc/wireguard/${WG_INTERFACE}.private"
MTPROTO_ENV_FILE="${MTPROTO_CONFIG_DIR}/mtproto.env"
MTPROTO_LINKS_FILE="${MTPROTO_CONFIG_DIR}/client-links.txt"
MTPROTO_SERVICE_FILE="/etc/systemd/system/${MTPROTO_SERVICE}.service"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }
log() { printf '\n==> %s\n' "$1"; }
warn() { printf 'Warning: %s\n' "$1" >&2; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run with sudo or as root"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

install_packages() {
  local packages=("$@")
  apt-get update
  apt-get install -y "${packages[@]}"
}

ensure_wireguard_key() {
  mkdir -p /etc/wireguard
  chmod 0700 /etc/wireguard

  if [[ -n "$WG_PRIVATE_KEY" ]]; then
    printf '%s\n' "$WG_PRIVATE_KEY" > "$WG_KEY_FILE"
    chmod 0600 "$WG_KEY_FILE"
    return
  fi

  if [[ ! -f "$WG_KEY_FILE" ]]; then
    wg genkey > "$WG_KEY_FILE"
    chmod 0600 "$WG_KEY_FILE"
  fi

  WG_PRIVATE_KEY="$(<"$WG_KEY_FILE")"
}

wireguard_public_key() {
  printf '%s\n' "$WG_PRIVATE_KEY" | wg pubkey
}

validate_peer_key() {
  [[ -n "$WG_PEER_PUBLIC_KEY" ]] || die "WG_PEER_PUBLIC_KEY is required. Run prepare on both VPS and exchange public keys."
}

write_wireguard_vps1() {
  validate_peer_key
  [[ -n "$WG_ENDPOINT_HOST" ]] || die "WG_ENDPOINT_HOST is required on VPS1 and must point to VPS2 public IP/DNS"

  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_VPS1_ADDR}
PrivateKey = ${WG_PRIVATE_KEY}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
AllowedIPs = ${WG_VPS2_IP}/32
Endpoint = ${WG_ENDPOINT_HOST}:${WG_PORT}
PersistentKeepalive = 25
EOF
  chmod 0600 "$WG_CONF"
}

write_wireguard_vps2() {
  validate_peer_key

  cat > "$WG_CONF" <<EOF
[Interface]
Address = ${WG_VPS2_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${WG_PRIVATE_KEY}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
AllowedIPs = ${WG_VPS1_IP}/32
EOF
  chmod 0600 "$WG_CONF"
}

start_wireguard() {
  systemctl enable --now "wg-quick@${WG_INTERFACE}"
  systemctl restart "wg-quick@${WG_INTERFACE}"
  wg show "$WG_INTERFACE"
}

generate_mtproto_secret() {
  mkdir -p "$MTPROTO_CONFIG_DIR"
  chmod 0700 "$MTPROTO_CONFIG_DIR"

  if [[ -f "$MTPROTO_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$MTPROTO_ENV_FILE"
  fi

  if [[ -z "${MTPROTO_SECRET:-}" ]]; then
    MTPROTO_SECRET="$(openssl rand -hex 16)"
  fi

  if [[ ! "$MTPROTO_SECRET" =~ ^[0-9a-f]{32}$ ]]; then
    die "MTPROTO_SECRET must be exactly 32 lowercase hex characters"
  fi

  cat > "$MTPROTO_ENV_FILE" <<EOF
MTPROTO_SECRET='${MTPROTO_SECRET}'
MTPROTO_SECRET_DOMAIN='${MTPROTO_SECRET_DOMAIN}'
PUBLIC_HOST='${PUBLIC_HOST}'
PUBLIC_PORT='${PUBLIC_PORT}'
EOF
  chmod 0600 "$MTPROTO_ENV_FILE"
}

encode_domain_hex() {
  python3 - "$MTPROTO_SECRET_DOMAIN" <<'PY'
import sys
print(sys.argv[1].encode("utf-8").hex())
PY
}

write_mtproto_links() {
  [[ -n "$PUBLIC_HOST" ]] || {
    warn "PUBLIC_HOST is empty; generated links will use YOUR_VPS1_IP_OR_DOMAIN"
    PUBLIC_HOST="YOUR_VPS1_IP_OR_DOMAIN"
  }

  local domain_hex dd_secret
  domain_hex="$(encode_domain_hex)"
  dd_secret="dd${MTPROTO_SECRET}${domain_hex}"

  cat > "$MTPROTO_LINKS_FILE" <<EOF
Public host: ${PUBLIC_HOST}
Public port: ${PUBLIC_PORT}
Backend WireGuard endpoint: ${WG_VPS2_IP}:${MTPROTO_BACKEND_PORT}
Base MTProto secret: ${MTPROTO_SECRET}
TLS-style MTProto secret: ${dd_secret}

Base links:
tg://proxy?server=${PUBLIC_HOST}&port=${PUBLIC_PORT}&secret=${MTPROTO_SECRET}
https://t.me/proxy?server=${PUBLIC_HOST}&port=${PUBLIC_PORT}&secret=${MTPROTO_SECRET}

TLS-style links:
tg://proxy?server=${PUBLIC_HOST}&port=${PUBLIC_PORT}&secret=${dd_secret}
https://t.me/proxy?server=${PUBLIC_HOST}&port=${PUBLIC_PORT}&secret=${dd_secret}
EOF
  chmod 0600 "$MTPROTO_LINKS_FILE"
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi
  install_packages docker.io
  systemctl enable --now docker
}

write_mtproto_systemd_unit() {
  mkdir -p "$MTPROTO_DATA_DIR"
  chmod 0700 "$MTPROTO_DATA_DIR"

  docker pull "$MTPROTO_IMAGE"

  cat > "$MTPROTO_SERVICE_FILE" <<EOF
[Unit]
Description=Telegram MTProto Proxy Backend
After=docker.service wg-quick@${WG_INTERFACE}.service
Requires=docker.service wg-quick@${WG_INTERFACE}.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f ${MTPROTO_CONTAINER}
ExecStart=/usr/bin/docker run --rm \\
    --name "$MTPROTO_CONTAINER" \
    -p "${WG_VPS2_IP}:${MTPROTO_BACKEND_PORT}:443/tcp" \
    -v "${MTPROTO_DATA_DIR}:/data" \
    -e "SECRET=${MTPROTO_SECRET}" \
    "$MTPROTO_IMAGE"
ExecStop=/usr/bin/docker stop ${MTPROTO_CONTAINER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$MTPROTO_SERVICE"
  systemctl restart "$MTPROTO_SERVICE"
}

write_haproxy_config() {
  if [[ -f "$HAPROXY_CONFIG" ]]; then
    cp "$HAPROXY_CONFIG" "${HAPROXY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat > "$HAPROXY_CONFIG" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 4096

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend mtproto_public
    bind 0.0.0.0:${PUBLIC_PORT}
    default_backend mtproto_backend

backend mtproto_backend
    server mtproto_vps2 ${WG_VPS2_IP}:${MTPROTO_BACKEND_PORT} check
EOF
}

configure_firewall_vps1() {
  ufw allow "${SSH_PORT}/tcp"
  ufw allow "${PUBLIC_PORT}/tcp"
  ufw --force enable
  ufw status verbose
}

configure_firewall_vps2() {
  ufw allow "${SSH_PORT}/tcp"
  if [[ -n "$VPS1_PUBLIC_IP" ]]; then
    ufw allow from "$VPS1_PUBLIC_IP" to any port "$WG_PORT" proto udp
  else
    warn "VPS1_PUBLIC_IP is empty; allowing WireGuard UDP port from any source"
    ufw allow "${WG_PORT}/udp"
  fi
  ufw --force enable
  ufw status verbose
}

cmd_prepare() {
  require_root
  install_packages wireguard
  require_cmd wg
  ensure_wireguard_key
  log "WireGuard public key for this VPS"
  wireguard_public_key
  printf '\nSet this value as WG_PEER_PUBLIC_KEY on the other VPS.\n'
}

cmd_install_vps1() {
  require_root
  install_packages wireguard haproxy ufw iproute2
  require_cmd wg
  ensure_wireguard_key
  write_wireguard_vps1
  start_wireguard
  write_haproxy_config
  haproxy -c -f "$HAPROXY_CONFIG"
  systemctl enable --now "$HAPROXY_SERVICE"
  systemctl restart "$HAPROXY_SERVICE"
  configure_firewall_vps1
  log "VPS1 relay installed"
  printf 'Public relay: 0.0.0.0:%s -> %s:%s over WireGuard\n' "$PUBLIC_PORT" "$WG_VPS2_IP" "$MTPROTO_BACKEND_PORT"
}

cmd_install_vps2() {
  require_root
  install_packages wireguard ufw iproute2 openssl python3
  require_cmd wg
  ensure_wireguard_key
  write_wireguard_vps2
  start_wireguard
  install_docker_if_needed
  generate_mtproto_secret
  write_mtproto_systemd_unit
  write_mtproto_links
  configure_firewall_vps2
  log "VPS2 MTProto backend installed"
  printf 'Client links saved to: %s\n' "$MTPROTO_LINKS_FILE"
  printf 'Show links with: sudo %s links\n' "$0"
}

cmd_links() {
  if [[ -f "$MTPROTO_LINKS_FILE" ]]; then
    cat "$MTPROTO_LINKS_FILE"
    return
  fi
  die "Links file not found: $MTPROTO_LINKS_FILE"
}

cmd_status_vps1() {
  systemctl status "wg-quick@${WG_INTERFACE}" --no-pager || true
  wg show "$WG_INTERFACE" || true
  systemctl status "$HAPROXY_SERVICE" --no-pager || true
  ss -lntp | grep -E "(:${PUBLIC_PORT}\\b)" || true
  ufw status verbose || true
}

cmd_status_vps2() {
  systemctl status "wg-quick@${WG_INTERFACE}" --no-pager || true
  wg show "$WG_INTERFACE" || true
  systemctl status "$MTPROTO_SERVICE" --no-pager || true
  docker ps --filter "name=${MTPROTO_CONTAINER}" || true
  docker logs --tail 50 "$MTPROTO_CONTAINER" || true
  ss -lntp | grep -E "(${WG_VPS2_IP}:${MTPROTO_BACKEND_PORT}\\b|:${WG_PORT}\\b)" || true
  ufw status verbose || true
}

cmd_help() {
  cat <<EOF
Usage:
  sudo MTPROTO_ENV=/root/mtproto-two-vps.env $0 prepare
  sudo MTPROTO_ENV=/root/mtproto-two-vps.env $0 install-vps2
  sudo MTPROTO_ENV=/root/mtproto-two-vps.env $0 install-vps1
  sudo MTPROTO_ENV=/root/mtproto-two-vps.env $0 links
  sudo $0 status-vps1
  sudo $0 status-vps2

Commands:
  prepare       Install WireGuard and print this VPS public key.
  install-vps1  Configure WireGuard, HAProxy TCP relay, and firewall on public VPS1.
  install-vps2  Configure WireGuard, MTProto Docker backend, links, and firewall on VPS2.
  links         Print generated Telegram MTProto links on VPS2.
  status-vps1   Show relay, WireGuard, listening ports, and firewall status.
  status-vps2   Show backend, WireGuard, Docker logs, listening ports, and firewall status.
EOF
}

case "${1:-}" in
  prepare)      cmd_prepare ;;
  install-vps1) cmd_install_vps1 ;;
  install-vps2) cmd_install_vps2 ;;
  links)        cmd_links ;;
  status-vps1)  cmd_status_vps1 ;;
  status-vps2)  cmd_status_vps2 ;;
  -h|--help|help|"") cmd_help ;;
  *) die "Unknown command: $1" ;;
esac
