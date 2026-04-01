# Быстрый деплой Xray + REALITY на VPS

Эта инструкция рассчитана на сервер со следующими параметрами:

- IP VPS: 45.144.30.147
- SSH-порт: 22
- Пользователь: merq
- ОС: Ubuntu 24.04.3 LTS
- Repo: /home/merq/protocol
- Пул target-доменов: использовать из WHITE_LIST_SITES_2026.json
- Hardened mode: выключен
- Клиент: Windows

Для первого запуска используются:

- serverName 1: rg.ru
- serverName 2: aif.ru
- bootstrap target: rg.ru:443
- shortId: 0123456789abcdef

## Шаг 1. Подключиться к VPS

```bash
ssh merq@45.144.30.147
```

## Автоматический вариант: один скрипт

Если не хочешь вводить всё руками, запусти один скрипт из репозитория:

```bash
bash /home/merq/protocol/REALITY/deploy_vps.sh
```

Что сделает скрипт:

- проверит Go: если уже стоит `1.26.1`, переустанавливать не будет; если версия другая, заменит на нужную
- установит системные пакеты через `apt install -y`; если они уже стоят, просто пропустит лишнее
- соберёт `/usr/local/bin/xray`
- если `UUID`, `SERVER_PRIVATE_KEY` и `SERVER_PUBLIC_KEY` уже переданы через окружение, возьмёт их; иначе сам сгенерирует `UUID`, `Private key` и `Public key`
- создаст `/usr/local/etc/xray/config.json`
- скопирует `WHITE_LIST_SITES_2026.json`
- создаст systemd unit и запустит сервис
- сохранит готовые параметры в обычные текстовые файлы:
  - `$HOME/xray-reality/server-values.env`
  - `$HOME/xray-reality/client-reality.txt`

Если нужно поменять домены, short id или путь к репозиторию, можно перед запуском передать свои значения:

```bash
SERVER_NAME_1='rg.ru' SERVER_NAME_2='aif.ru' TARGET_DEST='rg.ru:443' SHORT_ID='0123456789abcdef' PROTOCOL_ROOT='/home/merq/protocol' bash /home/merq/protocol/REALITY/deploy_vps.sh
```

Если хочешь использовать уже готовые `UUID` и ключи, можно передать их так:

```bash
UUID='your-uuid' SERVER_PRIVATE_KEY='your-private-key' SERVER_PUBLIC_KEY='your-public-key' bash /home/merq/protocol/REALITY/deploy_vps.sh
```

## Шаг 2. Установить пакеты и собрать Xray

```bash
sudo apt update
sudo apt install -y git curl unzip build-essential jq ufw

cd /tmp
curl -LO https://go.dev/dl/go1.26.1.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.26.1.linux-amd64.tar.gz
echo 'export PATH=/usr/local/go/bin:$PATH' >> ~/.profile
export PATH=/usr/local/go/bin:$PATH
hash -r
go version

cd /home/merq/protocol/Xray-core
go mod tidy
go build -trimpath -ldflags='-s -w' -o /tmp/xray ./main

sudo install -m 0755 /tmp/xray /usr/local/bin/xray
/usr/local/bin/xray version
```

## Шаг 3. Сгенерировать ключи и UUID

```bash
/usr/local/bin/xray x25519
/usr/local/bin/xray uuid
```

Что даст команда `/usr/local/bin/xray x25519`:

- `Private key: ...`  это приватный ключ сервера, его нужно подставить в поле `privateKey` в серверном конфиге
- `Public key: ...`  это публичный ключ сервера, его нужно подставить в Windows-клиент в поле `Public Key`

Что даст команда `/usr/local/bin/xray uuid`:

- UUID  это идентификатор клиента, его нужно подставить и в серверный конфиг, и в Windows-клиент

Сохрани себе в обычный текстовый файл или на бумажку:

- Private key
- Public key
- UUID
- Short ID: 0123456789abcdef

## Шаг 4. Подставить значения в переменные окружения

Вставь свои реальные значения вместо заглушек:

```bash
export UUID='PASTE_UUID_HERE'
export SERVER_PRIVATE_KEY='PASTE_PRIVATE_KEY_HERE'
export SERVER_PUBLIC_KEY='PASTE_PUBLIC_KEY_HERE'
export SHORT_ID='0123456789abcdef'

export SERVER_NAME_1='rg.ru'
export SERVER_NAME_2='aif.ru'
export TARGET_DEST='rg.ru:443'

export PROTOCOL_ROOT='/home/merq/protocol'
export XRAY_CONFIG_DIR='/usr/local/etc/xray'
export XRAY_CONFIG_FILE='/usr/local/etc/xray/config.json'
export XRAY_BIN='/usr/local/bin/xray'
```

Откуда брать каждую переменную:

- `UUID`  из вывода команды `/usr/local/bin/xray uuid`
- `SERVER_PRIVATE_KEY`  из строки `Private key:` из вывода команды `/usr/local/bin/xray x25519`
- `SERVER_PUBLIC_KEY`  из строки `Public key:` из вывода команды `/usr/local/bin/xray x25519`; в серверном конфиге она не используется напрямую, но понадобится для настройки клиента Windows
- `SHORT_ID`  можно оставить как в инструкции: `0123456789abcdef`
- `SERVER_NAME_1`  домен-маскировка для REALITY; для первого запуска оставляем `rg.ru`
- `SERVER_NAME_2`  второй домен-маскировка; для первого запуска оставляем `aif.ru`
- `TARGET_DEST`  основной target для первого запуска; оставляем `rg.ru:443`
- `PROTOCOL_ROOT`  путь до репозитория на сервере; у тебя это `/home/merq/protocol`
- `XRAY_CONFIG_DIR`  директория, где будет лежать конфиг Xray; оставляем `/usr/local/etc/xray`
- `XRAY_CONFIG_FILE`  полный путь до файла конфига; оставляем `/usr/local/etc/xray/config.json`
- `XRAY_BIN`  путь до собранного бинарника; оставляем `/usr/local/bin/xray`

Если не хочешь использовать переменные окружения, значения можно просто подставить руками прямо в JSON-конфиг ниже.

## Шаг 5. Скопировать JSON с target-доменами

```bash
sudo mkdir -p "$XRAY_CONFIG_DIR"
sudo cp "$PROTOCOL_ROOT/REALITY/WHITE_LIST_SITES_2026.json" "$XRAY_CONFIG_DIR/WHITE_LIST_SITES_2026.json"
sudo chown root:root "$XRAY_CONFIG_DIR/WHITE_LIST_SITES_2026.json"
sudo chmod 0644 "$XRAY_CONFIG_DIR/WHITE_LIST_SITES_2026.json"
```

## Шаг 6. Создать конфиг сервера

```bash
sudo tee "$XRAY_CONFIG_FILE" > /dev/null <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
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
          "targetsFile": "/usr/local/etc/xray/WHITE_LIST_SITES_2026.json",
          "targetsRotateSeconds": 300,
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
  ]
}
EOF
```

## Шаг 7. Проверить конфиг

```bash
"$XRAY_BIN" run -test -config "$XRAY_CONFIG_FILE"
```

Если команда завершилась без ошибки, можно идти дальше.

## Шаг 8. Открыть порт 443

```bash
sudo ufw allow 22/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status
```

## Шаг 9. Создать systemd unit

```bash
sudo tee /etc/systemd/system/xray.service > /dev/null <<'EOF'
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
```

## Шаг 10. Запустить Xray

```bash
sudo systemctl daemon-reload
sudo systemctl enable xray
sudo systemctl restart xray
sudo systemctl status xray --no-pager
sudo journalctl -u xray -n 100 --no-pager
```

## Шаг 11. Проверить, что порт слушается

```bash
sudo ss -ltnp | grep :443
```

## Параметры для Windows-клиента

Используй следующие значения в клиенте:

- Address: 45.144.30.147
- Port: 443
- UUID: тот же UUID, который выдала команда `/usr/local/bin/xray uuid`
- Flow: xtls-rprx-vision
- Public Key: значение `Public key:` из вывода `/usr/local/bin/xray x25519`
- Short ID: 0123456789abcdef
- Server Name: rg.ru
- Fingerprint: chrome

Короткая памятка:

- в сервер идут `UUID`, `Private key`, `Short ID`
- в клиент идут `UUID`, `Public key`, `Short ID`, `Server Name`, IP сервера и порт `443`

## Если что-то не стартует

Проверь по порядку:

```bash
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager
sudo journalctl -u xray -n 100 --no-pager
sudo ss -ltnp | grep :443
```

Если ошибка останется, пришли вывод этих четырёх команд.