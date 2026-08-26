# Universal Gateway На VPS-2

Используй как основной единый режим для Windows v2rayN и iOS / Happ Plus: стандартный `VLESS + WebSocket + TLS` до VPS-2, затем `VLESS + REALITY` до VPS-1.

В этом режиме Windows больше не требует кастомный `xray.exe` и `wsrelay.txt` как основной путь.

Полная схема, порты, MTProto и причины настроек — в [README.md](../README.md) в корне репозитория.

## Схема

```text
Windows v2rayN / iOS Happ Plus
  -> VLESS + WebSocket + TLS
  -> https://<DOMAIN>:9443/universal
VPS-2 Caddy -> 127.0.0.1:10081 xray-mobile-gateway
  sniffing off, WS heartbeat 10s
  outbound REALITY без Vision, mux + UDP 443 allow
  -> <VPS1>:443
VPS-1 Xray REALITY
  email universal-gateway* без flow
  sniffing destOverride выключен
  -> Internet
```

Параллельно старый Windows raw relay может оставаться fallback:

```text
Windows custom Xray
  -> wss://mythicquality.com/ws
VPS-2 (wsrelay-server)
  -> tcp://37.220.83.19:443
VPS-1
```

## Чем `/universal` отличается от `/ws`

| | `/ws` legacy Windows relay | `/universal` universal gateway |
|---|---|---|
| Клиент | кастомный `xray.exe` + `wsrelay.txt` | v2rayN / Happ Plus / стандартный VLESS WS TLS |
| VPS-2 сервис | `wsrelay-server` | `xray-mobile-gateway` |
| Протокол до VPS-2 | raw WebSocket relay | VLESS + WebSocket + TLS |
| UUID клиента | не нужен на VPS-2 | хранится на VPS-2 inbound |
| UUID на VPS-1 | тот же, что у Windows | один общий `universal-gateway` |

Assumption: в базовом варианте VPS-1 видит весь universal-трафик как одного upstream-клиента `universal-gateway`. Отдельные люди и устройства различаются UUID на VPS-2.

## 1. Создать upstream-клиента на VPS-1

На VPS-1. Label **должен** начинаться с `universal-gateway`: скрипт тогда не ставит `xtls-rprx-vision`. Этот hop гоняет MTProto и UDP, Vision его клинит.

```bash
cd ~/protocol/REALITY
sudo ./manage-clients.sh add universal-gateway-fr
```

Из вывода сохрани:

- `UUID`
- `SNI / serverName`
- `Public Key`
- `Short ID`

Адрес origin: `37.220.83.19:443`

## 2. Установить universal gateway на VPS-2

На VPS-2:

```bash
cd ~/protocol
git pull
cd REALITY
chmod +x deploy-mobile-gateway-vps.sh manage-mobile-clients.sh check-universal-traffic.sh

sudo ./deploy-mobile-gateway-vps.sh install \
  --domain mythicquality.com \
  --public-address 89.208.113.41 \
  --public-port 9443 \
  --tls-pin-sha256 '<TLS_CA_SHA256>' \
  --path /universal \
  --origin 37.220.83.19:443 \
  --upstream-uuid '<UUID_FROM_VPS1>' \
  --server-name '<REALITY_SNI>' \
  --public-key '<REALITY_PUBLIC_KEY>' \
  --short-id '<REALITY_SHORT_ID>'
```

Скрипт:

- установит `xray`, если его ещё нет;
- создаст `/usr/local/etc/xray-mobile/config.json`;
- поднимет `xray-mobile-gateway` на `127.0.0.1:10081`;
- обновит Caddy (`443` и `:9443`): `/universal*` -> Xray, `/ws*` -> `wsrelay-server`, длинный WebSocket (`flush_interval -1`, без read/write timeout);
- выключит sniffing destOverride, не поставит Vision на outbound, включит mux и `xudpProxyUDP443=allow`;
- включит Xray Stats API на `127.0.0.1:10086`;
- не трогает `wsrelay-server` процесс. Windows `/ws` остаётся.

## 3. Создать ссылки для клиентов

На VPS-2:

```bash
sudo ./manage-mobile-clients.sh add windows-stas
sudo ./manage-mobile-clients.sh add iphone-stas
```

Пример ссылки:

```text
vless://<CLIENT_UUID>@89.208.113.41:9443?encryption=none&type=ws&security=tls&host=mythicquality.com&sni=mythicquality.com&path=%2Funiversal&pcs=<TLS_CA_SHA256>#client-universal
```

Импортируй ссылку в Happ Plus или v2rayN.

## 4. Проверка

На VPS-2:

```bash
sudo ./deploy-mobile-gateway-vps.sh status
sudo journalctl -u xray-mobile-gateway -n 100 --no-pager
sudo journalctl -u wsrelay-server -n 50 --no-pager
sudo ./check-universal-traffic.sh status
curl -I https://mythicquality.com:9443/universal
```

На VPS-1 после подключения клиента:

```bash
sudo journalctl -u xray -n 50 --no-pager
```

Ожидаемо:

- `xray-mobile-gateway` active;
- `wsrelay-server` active;
- на Windows/iOS `2ip.ru` показывает IP VPS-1;
- YouTube открывается.

## 5. Управление universal-клиентами

```bash
sudo ./manage-mobile-clients.sh list
sudo ./manage-mobile-clients.sh links
sudo ./manage-mobile-clients.sh add ipad-family
sudo ./manage-mobile-clients.sh remove <uuid>
sudo ./check-universal-traffic.sh status
sudo ./check-universal-traffic.sh reset
```

## 6. Откат только universal gateway

На VPS-2:

```bash
sudo ./deploy-mobile-gateway-vps.sh uninstall
```

Windows relay `/ws` при этом остаётся, если `wsrelay-server` не удалялся.

Чтобы полностью убрать universal route из Caddy, вручную отредактируй `/etc/caddy/Caddyfile` и оставь только блок для `/ws`, затем:

```bash
sudo systemctl reload caddy
```

## 7. Файлы в репозитории

- [README.md](../README.md) — схема, порты, нюансы, переезд
- `REALITY/deploy-mobile-gateway-vps.sh` — установка Xray gateway на VPS-2
- `REALITY/manage-mobile-clients.sh` — UUID и universal VLESS WS TLS ссылки
- `REALITY/check-universal-traffic.sh` — трафик по клиентам на VPS-2
- `REALITY/deploy-wsrelay-vps.sh` — Windows raw relay `/ws`
- `REALITY/deploy_vps.sh` — конечный REALITY на VPS-1
- `REALITY/manage-clients.sh` — клиенты VPS-1; `universal-gateway*` без Vision
- `REALITY/DEPLOY_SELF_HOSTED_WS_RELAY_RU.md` — Windows `/ws` схема
