# Mobile Gateway На VPS-2

Используй, если на iOS / Happ Plus нужен тот же обход через VPS-2, что и на Windows, но **без кастомного Xray-core** и без `wsrelay.txt`.

## Схема

```text
iOS / Happ Plus
  -> VLESS + WebSocket + TLS
  -> https://mythicquality.com/mobile
VPS-2 (Caddy TLS + Xray mobile inbound)
  -> VLESS + REALITY
  -> 37.220.83.19:443
VPS-1 (Xray REALITY)
  -> Internet
```

Параллельно Windows может продолжать работать через raw relay:

```text
Windows custom Xray
  -> wss://mythicquality.com/ws
VPS-2 (wsrelay-server)
  -> tcp://37.220.83.19:443
VPS-1
```

## Чем `/mobile` отличается от `/ws`

| | `/ws` Windows relay | `/mobile` mobile gateway |
|---|---|---|
| Клиент | кастомный `xray.exe` + `wsrelay.txt` | Happ Plus / стандартный VLESS WS TLS |
| VPS-2 сервис | `wsrelay-server` | `xray-mobile-gateway` |
| Протокол до VPS-2 | raw WebSocket relay | VLESS + WebSocket + TLS |
| UUID телефона | не нужен на VPS-1 | хранится на VPS-2 inbound |
| UUID на VPS-1 | тот же, что у Windows | один общий `mobile-gateway` |

Assumption: в базовом варианте VPS-1 видит весь мобильный трафик как одного upstream-клиента `mobile-gateway`. Отдельные телефоны различаются UUID на VPS-2.

## 1. Создать upstream-клиента на VPS-1

На VPS-1:

```bash
cd ~/protocol/REALITY
sudo ./manage-clients.sh add mobile-gateway
```

Из вывода сохрани:

- `UUID`
- `SNI / serverName`
- `Public Key`
- `Short ID`

Адрес origin: `37.220.83.19:443`

## 2. Установить mobile gateway на VPS-2

На VPS-2:

```bash
cd ~/protocol
git pull
cd REALITY
chmod +x deploy-mobile-gateway-vps.sh manage-mobile-clients.sh

sudo ./deploy-mobile-gateway-vps.sh install \
  --domain mythicquality.com \
  --path /mobile \
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
- обновит Caddy: `/mobile*` -> Xray, `/ws*` -> `wsrelay-server`;
- не трогает `wsrelay-server` и Windows `/ws`.

## 3. Создать ссылку для телефона

На VPS-2:

```bash
sudo ./manage-mobile-clients.sh add iphone-stas
```

Пример ссылки:

```text
vless://<PHONE_UUID>@mythicquality.com:443?encryption=none&type=ws&security=tls&host=mythicquality.com&sni=mythicquality.com&path=%2Fmobile#iphone-stas-mobile
```

Импортируй ссылку в Happ Plus.

## 4. Проверка

На VPS-2:

```bash
sudo ./deploy-mobile-gateway-vps.sh status
sudo journalctl -u xray-mobile-gateway -n 100 --no-pager
sudo journalctl -u wsrelay-server -n 50 --no-pager
curl -I https://mythicquality.com/mobile
```

На VPS-1 после подключения телефона:

```bash
sudo journalctl -u xray -n 50 --no-pager
```

Ожидаемо:

- `xray-mobile-gateway` active;
- `wsrelay-server` active;
- на телефоне `2ip.ru` показывает IP VPS-1;
- YouTube открывается.

## 5. Управление mobile-клиентами

```bash
sudo ./manage-mobile-clients.sh list
sudo ./manage-mobile-clients.sh links
sudo ./manage-mobile-clients.sh add ipad-family
sudo ./manage-mobile-clients.sh remove <uuid>
```

## 6. Откат только mobile gateway

На VPS-2:

```bash
sudo ./deploy-mobile-gateway-vps.sh uninstall
```

Windows relay `/ws` при этом остаётся, если `wsrelay-server` не удалялся.

Чтобы полностью убрать mobile route из Caddy, вручную отредактируй `/etc/caddy/Caddyfile` и оставь только блок для `/ws`, затем:

```bash
sudo systemctl reload caddy
```

## 7. Файлы в репозитории

- `REALITY/deploy-mobile-gateway-vps.sh` — установка Xray gateway на VPS-2
- `REALITY/manage-mobile-clients.sh` — UUID и Happ Plus ссылки
- `REALITY/deploy-wsrelay-vps.sh` — Windows raw relay, не меняется
- `REALITY/DEPLOY_SELF_HOSTED_WS_RELAY_RU.md` — Windows `/ws` схема
