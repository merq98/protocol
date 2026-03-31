# Развертывание VLESS + Xray-core на текущей REALITY сборке

Этот guide нужен для сценария, когда у тебя уже есть Linux VPS, и ты хочешь:

1. Поднять VLESS + Xray-core на своей сборке REALITY из этого repo.
2. Минимизировать риск блокировки со стороны ТСПУ/РКН.
3. Подключаться с Windows/macOS/Linux, Android и iPhone через существующие клиенты, поддерживающие VLESS + REALITY.

Сразу важное ограничение: никакой конфиг не даёт гарантии "не блокироваться". Можно только уменьшать вероятность детекта и удешевлять миграцию при бане.

## Что именно разворачиваем

В этом repo нет готового VPN-сервера. Здесь библиотека REALITY.

Поэтому рабочая схема такая:

1. Используем Xray-core, который лежит внутри этого же repo.
2. Подменяем в нём зависимость `github.com/xtls/reality` на текущую REALITY из этого repo.
3. Добавляем внешнее plumbing для `requireMldsa65` по [EXTERNAL_CONFIG_PLUMBING.md](EXTERNAL_CONFIG_PLUMBING.md).
4. Собираем свой бинарник `xray`.
5. Запускаем его на VPS с inbound `vless` + `reality`.

## Подход к блокировкам

Для ТСПУ важны не лозунги, а практические свойства сервера:

1. REALITY должен выглядеть как нормальный TLS 1.3 трафик к выбранному target.
2. Target должен быть правдоподобным и стабильным.
3. Сервер не должен светить панельные артефакты, кривой fallback, странный timing или массово повторяющийся конфиг.
4. При включении hardened mode одной утечки `privateKey` будет недостаточно для воспроизведения auth-path.

## Что подготовить заранее

Перед началом заполни для себя эти значения:

```text
VPS_IP=...
VPS_SSH_PORT=22
VPS_USER=root

XRAY_LISTEN_PORT=443
SERVER_NAME_1=...
SERVER_NAME_2=...
TARGET_DEST=example.com:443
SHORT_ID=0123456789abcdef

UUID=...
```

Рекомендации:

1. `TARGET_DEST` выбирай среди живых TLS 1.3 + H2 сайтов без агрессивных редиректов.
2. `serverNames` должны соответствовать реальному target-профилю.
3. `SHORT_ID` делай не пустым.
4. Если есть свой домен, он не обязателен для REALITY, но может упростить операционку вокруг сервера.

## Шаг 1. Подготовить VPS

Ниже пример для Ubuntu 22.04/24.04.

Подключись к серверу:

```bash
ssh root@YOUR_VPS_IP
```

Обнови систему и поставь базовые пакеты:

```bash
apt update
apt upgrade -y
apt install -y git curl unzip build-essential jq ufw
```

Поставь Go, если его ещё нет:

```bash
cd /usr/local
curl -LO https://go.dev/dl/go1.24.2.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go1.24.2.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >/etc/profile.d/go.sh
source /etc/profile.d/go.sh
go version
```

Открой нужные порты:

```bash
ufw allow 22/tcp
ufw allow 443/tcp
ufw --force enable
ufw status
```

## Шаг 2. Забрать исходники protocol

Создай рабочую директорию:

```bash
mkdir -p /opt/src
cd /opt/src
```

Клонируй этот repo с твоей REALITY:

```bash
git clone YOUR_REALITY_REPO_URL protocol
```

Проверь, что библиотека лежит в:

```text
/opt/src/protocol/REALITY
```

И что Xray-core лежит в этом же дереве:

```text
/opt/src/protocol/Xray-core
```

Если папки `Xray-core` в твоём clone нет, значит ты забрал не тот remote или не ту ветку. В текущей модели `protocol` хранит REALITY и Xray-core в одном repo, без отдельного вложенного `.git` внутри `Xray-core`.

## Шаг 3. Подключить твою REALITY к Xray-core

В `go.mod` Xray-core добавь replace:

```go
replace github.com/xtls/reality => /opt/src/protocol/REALITY
```

После этого Xray-core будет собираться уже на твоей библиотеке.

## Шаг 4. Добавить external plumbing для requireMldsa65

Сделай изменения из [EXTERNAL_CONFIG_PLUMBING.md](EXTERNAL_CONFIG_PLUMBING.md):

1. Добавь `requireMldsa65` в JSON config layer Xray-core.
2. Добавь `require_mldsa65` в protobuf config.
3. Пробрось поле в runtime config `reality.Config`.

Если hardened mode пока не нужен, этот шаг можно временно пропустить и собрать сервер без `requireMldsa65`.

## Шаг 5. Собрать свой xray

Внутри Xray-core:

```bash
cd /opt/src/protocol/Xray-core
go mod tidy
go build -trimpath -ldflags='-s -w' -o /usr/local/bin/xray ./main
/usr/local/bin/xray version
```

Если сборка падает, сначала проверь:

1. что `replace` указывает именно на `/opt/src/protocol/REALITY`
2. что protobuf/plumbing для `requireMldsa65` согласованы
3. что `go mod tidy` не подтянул обратно upstream `github.com/xtls/reality`

## Шаг 6. Сгенерировать ключи и идентификаторы

Сгенерируй X25519 ключи:

```bash
xray x25519
```

Сохрани:

```text
Private key: SERVER_PRIVATE_KEY
Public key: SERVER_PUBLIC_KEY
```

Сгенерируй UUID для VLESS:

```bash
xray uuid
```

Сгенерируй ML-DSA-65 ключи для hardened mode:

```bash
xray mldsa65
```

Сохрани:

```text
Seed: MLDSA65_SEED
Verify: MLDSA65_VERIFY
```

Если hardened mode не нужен на первом этапе, `mldsa65Seed` и `mldsa65Verify` можно не использовать.

## Шаг 7. Подготовить server config

Создай каталог конфигов:

```bash
mkdir -p /usr/local/etc/xray
```

Базовый server config:

```json
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
            "id": "YOUR_UUID",
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
          "target": "YOUR_TARGET_DEST",
          "xver": 0,
          "serverNames": [
            "YOUR_SERVER_NAME_1",
            "YOUR_SERVER_NAME_2"
          ],
          "privateKey": "YOUR_SERVER_PRIVATE_KEY",
          "shortIds": [
            "YOUR_SHORT_ID"
          ],
          "mldsa65Seed": "YOUR_MLDSA65_SEED",
          "requireMldsa65": true
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
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
```

Сохрани как:

```text
/usr/local/etc/xray/config.json
```

Если хочешь сначала запуститься без hardened mode, используй:

1. удали `requireMldsa65`
2. удали `mldsa65Seed`
3. на клиентах не указывай `mldsa65Verify`

## Шаг 8. Создать systemd unit

Создай файл:

```text
/etc/systemd/system/xray.service
```

С таким содержимым:

```ini
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
```

Запусти сервис:

```bash
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
systemctl status xray --no-pager
journalctl -u xray -n 100 --no-pager
```

## Шаг 9. Проверить сервер с VPS

Проверь, что порт слушается:

```bash
ss -ltnp | grep :443
```

Если Xray не стартует:

1. проверь JSON на синтаксис
2. проверь, что `target` и `serverNames` заполнены
3. проверь длину `shortIds`
4. если включён `requireMldsa65`, проверь что в конфиге есть `mldsa65Seed`

## Шаг 10. Подготовить client config

Общий client config для VLESS + REALITY выглядит так:

```json
{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "YOUR_VPS_IP_OR_DOMAIN",
            "port": 443,
            "users": [
              {
                "id": "YOUR_UUID",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "YOUR_SERVER_NAME_1",
          "publicKey": "YOUR_SERVER_PUBLIC_KEY",
          "shortId": "YOUR_SHORT_ID",
          "mldsa65Verify": "YOUR_MLDSA65_VERIFY",
          "spiderX": "/"
        }
      }
    }
  ]
}
```

Если сервер пока без hardened mode, убери `mldsa65Verify`.

## Шаг 11. Подключение с ПК

Для Windows чаще всего удобно использовать клиент уровня `v2rayN` или другой клиент, который поддерживает:

1. VLESS
2. REALITY
3. `xtls-rprx-vision`
4. при необходимости `mldsa65Verify`

Для Linux/macOS логика та же: нужен клиент с поддержкой VLESS + REALITY.

Заполняемые поля в GUI-клиенте:

1. Address: IP или домен VPS
2. Port: `443`
3. UUID: твой `UUID`
4. Flow: `xtls-rprx-vision`
5. TLS/REALITY Public Key: `SERVER_PUBLIC_KEY`
6. Short ID: `SHORT_ID`
7. Server Name / SNI: один из `serverNames`
8. Fingerprint: `chrome`
9. ML-DSA Verify: `MLDSA65_VERIFY`, если включён hardened mode

## Шаг 12. Подключение с Android

На Android нужен клиент с поддержкой VLESS + REALITY. Практически это обычно Xray-based или sing-box-based клиент.

Поля те же:

1. Address
2. Port
3. UUID
4. Flow
5. SNI
6. Public Key
7. Short ID
8. Fingerprint
9. `mldsa65Verify`, если сервер в hardened mode

Перед постоянным использованием проверь:

1. открываются обычные HTTPS сайты
2. не рвётся соединение при смене сети Wi-Fi/LTE
3. нет handshake error на старте

## Шаг 13. Подключение с iPhone

На iPhone важен не бренд клиента, а поддержка нужных полей. Клиент должен уметь:

1. VLESS
2. REALITY
3. Vision flow
4. Public Key / Short ID / Fingerprint
5. `mldsa65Verify`, если hardened mode включён

Если клиент не умеет `mldsa65Verify`, то с сервером в режиме `requireMldsa65: true` он не сможет работать.

Поэтому rollout такой:

1. сначала убедись, что выбранный iPhone-клиент поддерживает REALITY полностью
2. только потом включай hardened mode на сервере

## Шаг 14. Что делать, чтобы снижать риск блокировки ТСПУ

Это не даёт гарантий, но даёт наилучшие шансы.

### Target и SNI

1. Не используй заведомо массово заезженные target'ы.
2. Не используй домены с явными редиректами или нестабильным TLS-профилем.
3. Держи `serverNames` в рамках реального target-профиля.

### Порт и протокол

1. Держи сервер на `443/tcp`.
2. Не включай лишние inbound'ы рядом на экзотических портах без необходимости.
3. Не добавляй panel-style API и публичные web-панели на тот же VPS.

### Конфиг и клиенты

1. Используй `xtls-rprx-vision`.
2. Не оставляй пустой `shortId`, если нет причины.
3. На всех клиентах ставь правдоподобный `fingerprint`, обычно `chrome`.
4. Если используешь текущую hardened сборку, раскатывай `mldsa65Verify` на все клиенты до включения `requireMldsa65`.

### Операционка

1. Не держи verbose debug-логи постоянно.
2. Не раздавай один и тот же конфиг слишком широко.
3. Держи запасной VPS и запасной target заранее.
4. Если IP уже попал в deny-list, конфигом это не лечится, нужна миграция.

## Шаг 15. Рекомендуемый rollout без боли

Самая практичная последовательность:

1. Подними сервер без `requireMldsa65`.
2. Проверь подключение с Windows.
3. Проверь Android.
4. Проверь iPhone.
5. Если все клиенты поддерживают ML-DSA verify, сгенерируй `mldsa65Seed` и раздай `mldsa65Verify`.
6. Только после этого включи `requireMldsa65: true`.

## Чек-лист готовности

Сервер считается готовым, если:

1. `systemctl status xray` без ошибок
2. порт `443/tcp` слушается
3. Windows-клиент подключается и открывает сайты
4. Android-клиент подключается через мобильную сеть
5. iPhone-клиент подключается и не падает на handshake
6. в логах нет постоянных `invalid user`, `handshake`, `reality` ошибок

## Когда лучше не усложнять себе жизнь

Если тебе нужен просто быстрый старт, делай в два этапа:

1. сначала stock Xray-core + обычный REALITY
2. потом уже свой билд на этой библиотеке и hardened mode

Это резко уменьшает количество переменных при первом запуске.

## Что можно настроить под твои данные дальше

Если хочешь, на следующем шаге можно подготовить уже не шаблон, а готовые файлы под твой VPS:

1. `config.json` сервера
2. `xray.service`
3. client profile для Windows
4. client profile для Android
5. client profile для iPhone

Для этого нужны только:

1. дистрибутив VPS
2. IP или домен VPS
3. выбранный target
4. нужен ли hardened mode сразу
5. какие именно клиенты на Windows/Android/iPhone ты собираешься использовать