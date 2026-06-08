# Universal Gateway На VPS-2

Используй как основной единый режим для Windows v2rayN и iOS / Happ Plus: стандартный `VLESS + WebSocket + TLS` до VPS-2, затем `VLESS + REALITY` до VPS-1.

В этом режиме Windows больше не требует кастомный `xray.exe` и `wsrelay.txt` как основной путь.

## Схема

```text
Windows v2rayN / iOS Happ Plus
  -> VLESS + WebSocket + TLS
  -> https://mythicquality.com/universal
VPS-2 (Caddy TLS + Xray universal inbound)
  -> VLESS + REALITY
  -> 37.220.83.19:443
VPS-1 (Xray REALITY)
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

На VPS-1:

```bash
cd ~/protocol/REALITY
sudo ./manage-clients.sh add universal-gateway
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
- обновит Caddy: `/universal*` -> Xray, `/ws*` -> `wsrelay-server`;
- включит Xray Stats API на `127.0.0.1:10086`;
- не трогает `wsrelay-server` и Windows `/ws`.

## 3. Создать ссылки для клиентов

На VPS-2:

```bash
sudo ./manage-mobile-clients.sh add windows-stas
sudo ./manage-mobile-clients.sh add iphone-stas
```

Пример ссылки:

```text
vless://<CLIENT_UUID>@mythicquality.com:443?encryption=none&type=ws&security=tls&host=mythicquality.com&sni=mythicquality.com&path=%2Funiversal#client-universal
```

Импортируй ссылку в Happ Plus или v2rayN.

## 4. Проверка

На VPS-2:

```bash
sudo ./deploy-mobile-gateway-vps.sh status
sudo journalctl -u xray-mobile-gateway -n 100 --no-pager
sudo journalctl -u wsrelay-server -n 50 --no-pager
sudo ./check-universal-traffic.sh status
curl -I https://mythicquality.com/universal
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

- `REALITY/deploy-mobile-gateway-vps.sh` — установка Xray gateway на VPS-2
- `REALITY/manage-mobile-clients.sh` — UUID и universal VLESS WS TLS ссылки
- `REALITY/check-universal-traffic.sh` — трафик по клиентам на VPS-2
- `REALITY/deploy-wsrelay-vps.sh` — Windows raw relay, не меняется
- `REALITY/DEPLOY_SELF_HOSTED_WS_RELAY_RU.md` — Windows `/ws` схема
