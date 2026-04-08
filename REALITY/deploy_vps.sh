#!/usr/bin/env bash
# deploy_vps.sh — First-time VPS setup or update for Xray REALITY.
#
# First-time install (as root):
#   DEPLOY_USER_PASSWORD='YourPass!' bash deploy_vps.sh
#
# Update xray binary without touching config/clients:
#   bash deploy_vps.sh update
#
# Or as an existing sudo user (skips user creation):
#   bash deploy_vps.sh

set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-merq}"
DEPLOY_USER_PASSWORD="${DEPLOY_USER_PASSWORD:-}"
GO_VERSION="${GO_VERSION:-1.26.1}"
SERVER_IP="${SERVER_IP:-45.144.30.147}"
SSH_PORT="${SSH_PORT:-22}"
PROTOCOL_ROOT="${PROTOCOL_ROOT:-/home/${DEPLOY_USER}/protocol}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
XRAY_CONFIG_FILE="${XRAY_CONFIG_FILE:-$XRAY_CONFIG_DIR/config.json}"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_SERVICE_FILE="${XRAY_SERVICE_FILE:-/etc/systemd/system/xray.service}"
TARGETS_JSON_SOURCE="${TARGETS_JSON_SOURCE:-$PROTOCOL_ROOT/REALITY/WHITE_LIST_SITES_2026.json}"
TARGETS_JSON_DEST="${TARGETS_JSON_DEST:-$XRAY_CONFIG_DIR/WHITE_LIST_SITES_2026.json}"
TARGETS_ROTATE_SECONDS="${TARGETS_ROTATE_SECONDS:-300}"
SERVER_NAME_1="${SERVER_NAME_1:-rg.ru}"
SERVER_NAME_2="${SERVER_NAME_2:-aif.ru}"
TARGET_DEST="${TARGET_DEST:-rg.ru:443}"
SHORT_ID="${SHORT_ID:-0123456789abcdef}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/xray-reality}"
UUID="${UUID:-}"
SERVER_PRIVATE_KEY="${SERVER_PRIVATE_KEY:-}"
SERVER_PUBLIC_KEY="${SERVER_PUBLIC_KEY:-}"

log() {
  printf '\n==> %s\n' "$1"
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    printf 'Missing required file: %s\n' "$path" >&2
    exit 1
  fi
}

parse_value() {
  local content="$1"
  local regex="$2"
  printf '%s\n' "$content" | sed -n "$regex" | head -n 1 | tr -d '\r'
}

ensure_go_on_path() {
  if [[ -d /usr/local/go/bin ]]; then
    export PATH=/usr/local/go/bin:$PATH
    hash -r
  fi
}

current_go_version() {
  if command -v go >/dev/null 2>&1; then
    go version | awk '{print $3}'
    return 0
  fi
  return 1
}

install_go() {
  log "Installing Go ${GO_VERSION}"
  cd /tmp
  rm -f "go${GO_VERSION}.linux-amd64.tar.gz"
  curl -LO "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
  if ! grep -Fq 'export PATH=/usr/local/go/bin:$PATH' "$HOME/.profile" 2>/dev/null; then
    echo 'export PATH=/usr/local/go/bin:$PATH' >> "$HOME/.profile"
  fi
  ensure_go_on_path
}

REPO_DIR="${PROTOCOL_ROOT}"

DEPLOY_MODE="${1:-install}"

log "Installing system packages"
sudo apt update
sudo apt install -y git curl unzip build-essential jq ufw

# --- Create deploy user if running as root ---
if [[ "$(whoami)" == "root" ]]; then
  if id "$DEPLOY_USER" &>/dev/null; then
    log "User '$DEPLOY_USER' already exists"
  else
    if [[ -z "$DEPLOY_USER_PASSWORD" ]]; then
      printf 'Error: DEPLOY_USER_PASSWORD is required when running as root.\n' >&2
      printf 'Usage: DEPLOY_USER_PASSWORD="YourPass!" bash %s\n' "$0" >&2
      exit 1
    fi
    log "Creating user '$DEPLOY_USER' with sudo access"
    useradd -m -s /bin/bash "$DEPLOY_USER"
    echo "${DEPLOY_USER}:${DEPLOY_USER_PASSWORD}" | chpasswd
    usermod -aG sudo "$DEPLOY_USER"
  fi

  # Allow passwordless sudo for deploy user (needed for non-interactive script)
  echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEPLOY_USER}"
  chmod 0440 "/etc/sudoers.d/${DEPLOY_USER}"

  # Set up SSH key auth if root has authorized_keys
  DEPLOY_USER_HOME="/home/${DEPLOY_USER}"
  if [[ -f /root/.ssh/authorized_keys ]] && [[ ! -f "${DEPLOY_USER_HOME}/.ssh/authorized_keys" ]]; then
    log "Copying SSH keys to '$DEPLOY_USER'"
    mkdir -p "${DEPLOY_USER_HOME}/.ssh"
    cp /root/.ssh/authorized_keys "${DEPLOY_USER_HOME}/.ssh/authorized_keys"
    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_USER_HOME}/.ssh"
    chmod 700 "${DEPLOY_USER_HOME}/.ssh"
    chmod 600 "${DEPLOY_USER_HOME}/.ssh/authorized_keys"
  fi

  # Clone repo if not present
  if [[ ! -d "$PROTOCOL_ROOT" ]]; then
    log "Cloning protocol repo"
    sudo -u "$DEPLOY_USER" git clone https://github.com/merq98/protocol.git "$PROTOCOL_ROOT"
  else
    log "Updating protocol repo"
    sudo -u "$DEPLOY_USER" git -C "$PROTOCOL_ROOT" pull --ff-only || true
  fi

  # Re-run as the deploy user via env file (avoids bash -c quoting issues)
  log "Switching to user '$DEPLOY_USER' to continue setup"
  ENV_FILE=$(mktemp /tmp/deploy-env.XXXXXX)
  cat > "$ENV_FILE" <<ENVEOF
export GO_VERSION='$GO_VERSION'
export SERVER_IP='$SERVER_IP'
export SSH_PORT='$SSH_PORT'
export PROTOCOL_ROOT='$PROTOCOL_ROOT'
export XRAY_CONFIG_DIR='$XRAY_CONFIG_DIR'
export XRAY_CONFIG_FILE='$XRAY_CONFIG_FILE'
export XRAY_BIN='$XRAY_BIN'
export XRAY_SERVICE_FILE='$XRAY_SERVICE_FILE'
export TARGETS_JSON_SOURCE='$TARGETS_JSON_SOURCE'
export TARGETS_JSON_DEST='$TARGETS_JSON_DEST'
export TARGETS_ROTATE_SECONDS='$TARGETS_ROTATE_SECONDS'
export SERVER_NAME_1='$SERVER_NAME_1'
export SERVER_NAME_2='$SERVER_NAME_2'
export TARGET_DEST='$TARGET_DEST'
export SHORT_ID='$SHORT_ID'
export UUID='$UUID'
export SERVER_PRIVATE_KEY='$SERVER_PRIVATE_KEY'
export SERVER_PUBLIC_KEY='$SERVER_PUBLIC_KEY'
export DEPLOY_USER='$DEPLOY_USER'
export OUTPUT_DIR='/home/$DEPLOY_USER/xray-reality'
ENVEOF
  chmod 644 "$ENV_FILE"

  # Write a wrapper script that sources env and runs deploy
  WRAPPER=$(mktemp /tmp/deploy-run.XXXXXX.sh)
  cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
set -euo pipefail
source '$ENV_FILE'
exec bash "\$PROTOCOL_ROOT/REALITY/deploy_vps.sh" '$DEPLOY_MODE'
WRAPEOF
  chmod 755 "$WRAPPER"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$WRAPPER"

  sudo -u "$DEPLOY_USER" bash "$WRAPPER"
  rm -f "$ENV_FILE" "$WRAPPER"
  exit 0
fi

ensure_go_on_path
CURRENT_GO="$(current_go_version || true)"
if [[ "$CURRENT_GO" == "go${GO_VERSION}" ]]; then
  log "Go ${GO_VERSION} is already installed, skipping reinstall"
else
  if [[ -n "$CURRENT_GO" ]]; then
    log "Go version mismatch: found ${CURRENT_GO}, need go${GO_VERSION}"
  else
    log "Go is not installed"
  fi
  install_go
fi
go version

require_file "$PROTOCOL_ROOT/Xray-core/go.mod"
require_file "$TARGETS_JSON_SOURCE"

log "Building Xray"
cd "$PROTOCOL_ROOT/Xray-core"
go mod tidy
go build -trimpath -ldflags='-s -w' -o /tmp/xray ./main
sudo install -m 0755 /tmp/xray "$XRAY_BIN"
"$XRAY_BIN" version

# --- UPDATE mode: rebuild binary + update targets, keep config/clients ---
if [[ "$DEPLOY_MODE" == "update" ]]; then
  log "Update mode: refreshing targets file"
  sudo cp "$TARGETS_JSON_SOURCE" "$TARGETS_JSON_DEST"
  sudo chown root:root "$TARGETS_JSON_DEST"
  sudo chmod 0644 "$TARGETS_JSON_DEST"

  # Set up cron if not present
  if ! crontab -l 2>/dev/null | grep -q check-traffic; then
    log "Installing traffic monitoring cron jobs"
    TRAFFIC_SCRIPT="$REPO_DIR/REALITY/check-traffic.sh"
    chmod +x "$TRAFFIC_SCRIPT"
    (crontab -l 2>/dev/null || true; \
     echo "*/10 * * * * sudo $TRAFFIC_SCRIPT enforce >> /var/log/xray-traffic.log 2>&1"; \
     echo "0 0 * * * sudo $TRAFFIC_SCRIPT reset >> /var/log/xray-traffic.log 2>&1" \
    ) | crontab -
  fi

  log "Restarting Xray"
  sudo systemctl restart xray
  sudo systemctl status xray --no-pager
  log "Update complete — config and clients unchanged"
  exit 0
fi

if [[ -n "$UUID" && -n "$SERVER_PRIVATE_KEY" && -n "$SERVER_PUBLIC_KEY" ]]; then
  log "Using UUID and REALITY keys from environment"
else
  log "Generating REALITY keys and UUID"
  KEY_OUTPUT="$($XRAY_BIN x25519)"
  UUID="${UUID:-$($XRAY_BIN uuid | tail -n 1 | tr -d '\r')}"

  SERVER_PRIVATE_KEY="${SERVER_PRIVATE_KEY:-$(parse_value "$KEY_OUTPUT" 's/^PrivateKey:[[:space:]]*//p; s/^Private key:[[:space:]]*//p')}"
  SERVER_PUBLIC_KEY="${SERVER_PUBLIC_KEY:-$(parse_value "$KEY_OUTPUT" 's/^Password (PublicKey):[[:space:]]*//p; s/^PublicKey:[[:space:]]*//p; s/^Public key:[[:space:]]*//p')}"
fi

if [[ -z "$SERVER_PRIVATE_KEY" || -z "$SERVER_PUBLIC_KEY" || -z "$UUID" ]]; then
  printf 'Failed to parse generated keys or UUID.\n' >&2
  if [[ -n "${KEY_OUTPUT:-}" ]]; then
    printf '%s\n' "$KEY_OUTPUT" >&2
  fi
  exit 1
fi

log "Writing server files"
sudo mkdir -p "$XRAY_CONFIG_DIR"
sudo cp "$TARGETS_JSON_SOURCE" "$TARGETS_JSON_DEST"
sudo chown root:root "$TARGETS_JSON_DEST"
sudo chmod 0644 "$TARGETS_JSON_DEST"

sudo tee "$XRAY_CONFIG_FILE" > /dev/null <<EOF
{
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    },
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "tag": "vless-in",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "email": "admin"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$TARGET_DEST",
          "targetsFile": "$TARGETS_JSON_DEST",
          "targetsRotateSeconds": $TARGETS_ROTATE_SECONDS,
          "xver": 0,
          "serverNames": [
            "$SERVER_NAME_1",
            "$SERVER_NAME_2"
          ],
          "privateKey": "$SERVER_PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
EOF

"$XRAY_BIN" run -test -config "$XRAY_CONFIG_FILE"

log "Configuring firewall"
sudo ufw allow "${SSH_PORT}/tcp"
sudo ufw allow 443/tcp
sudo ufw --force enable

log "Installing systemd unit"
sudo tee "$XRAY_SERVICE_FILE" > /dev/null <<'EOF'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

log "Starting Xray"
sudo systemctl daemon-reload
sudo systemctl enable xray
sudo systemctl restart xray
sudo systemctl status xray --no-pager

log "Saving generated values"
umask 077
mkdir -p "$OUTPUT_DIR"

SERVER_VALUES_FILE="$OUTPUT_DIR/server-values.env"
CLIENT_VALUES_FILE="$OUTPUT_DIR/client-reality.txt"

cat > "$SERVER_VALUES_FILE" <<EOF
UUID='$UUID'
SERVER_PRIVATE_KEY='$SERVER_PRIVATE_KEY'
SERVER_PUBLIC_KEY='$SERVER_PUBLIC_KEY'
SHORT_ID='$SHORT_ID'
SERVER_NAME_1='$SERVER_NAME_1'
SERVER_NAME_2='$SERVER_NAME_2'
TARGET_DEST='$TARGET_DEST'
SERVER_IP='$SERVER_IP'
XRAY_CONFIG_FILE='$XRAY_CONFIG_FILE'
EOF

cat > "$CLIENT_VALUES_FILE" <<EOF
Address: $SERVER_IP
Port: 443
UUID: $UUID
Flow: xtls-rprx-vision
Public Key: $SERVER_PUBLIC_KEY
Short ID: $SHORT_ID
Server Name: $SERVER_NAME_1
Fingerprint: chrome
EOF

log "Done"
printf 'Server values saved to: %s\n' "$SERVER_VALUES_FILE"
printf 'Client values saved to: %s\n' "$CLIENT_VALUES_FILE"
printf '\nClient parameters:\n'
cat "$CLIENT_VALUES_FILE"

# --- Traffic limit cron ---
log "Setting up traffic monitoring cron jobs"
TRAFFIC_SCRIPT="$REPO_DIR/REALITY/check-traffic.sh"
chmod +x "$TRAFFIC_SCRIPT"

# Enforce every 10 minutes, reset daily at midnight
(crontab -l 2>/dev/null | grep -v check-traffic || true; \
 echo "*/10 * * * * sudo $TRAFFIC_SCRIPT enforce >> /var/log/xray-traffic.log 2>&1"; \
 echo "0 0 * * * sudo $TRAFFIC_SCRIPT reset >> /var/log/xray-traffic.log 2>&1" \
) | crontab -
log "Cron jobs installed (enforce every 10 min, reset at midnight)"