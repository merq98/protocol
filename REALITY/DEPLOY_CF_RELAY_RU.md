# Cloudflare WS Relay — обход блокировки IP VPS

Используй, если **прямой** профиль `laptop-direct` (`37.220.83.19:443`) даёт таймауты или `-1 ms`, а TCP до порта 443 открывается.

Клиент подключается к **Cloudflare Workers**, Worker прозрачно ретранслирует байты на VPS. DPI видит WebSocket к `*.workers.dev`, а не прямой IP VPS.

## 1. Деплой Worker (один раз)

На ПК с Node.js:

```bash
cd protocol/worker
npm install -g wrangler   # или: npx wrangler deploy
```

Проверь `worker/wrangler.toml`:

```toml
[vars]
ORIGIN = "37.220.83.19:443"
```

Деплой:

```bash
npx wrangler deploy
```

После деплоя wrangler покажет URL, например:

```text
https://reality-relay.USER.workers.dev
```

Для клиента нужен **WSS**:

```text
wss://reality-relay.USER.workers.dev
```

## 2. Прописать wsRelay на VPS

```bash
cd ~/protocol/REALITY
git pull
chmod +x set-ws-relay.sh

sudo ./set-ws-relay.sh set wss://reality-relay.USER.workers.dev
```

Проверка:

```bash
sudo ./set-ws-relay.sh show
```

## 3. Сгенерировать Cloudflare-ссылки для клиентов

```bash
WS_RELAY='wss://reality-relay.USER.workers.dev' sudo ./manage-clients.sh links
```

Импортируй строку **`Cloudflare:`** (не `Direct:`) в v2rayN / Happ.

## 4. Проверка на Windows

1. v2rayN **выключен** → примени пресет SOCKS (если нужно):
   ```powershell
   cd C:\Users\Stas\Documents\Projects\protocol\REALITY
   .\generate-v2rayn-tun-profile.ps1 -Preset socks-test
   ```
2. Запусти v2rayN, выбери профиль **`*-cf`** / Cloudflare-ссылку.
3. Тест:
   ```powershell
   .\diagnose-v2rayn.ps1
   ```
   SOCKS должен вернуть IP (может быть IP Cloudflare egress, не VPS — это нормально для relay).
4. Только после стабильного SOCKS включай TUN:
   ```powershell
   .\generate-v2rayn-tun-profile.ps1 -Preset tun-system -FixSingboxUdp443
   ```

## 5. Лимиты Cloudflare Free

- ~100k HTTP-запросов/день на Worker.
- **WebSocket после upgrade** в long-lived туннель обычно не считается как отдельный запрос на каждый пакет.
- При превышении лимита ломается **только CF-профиль**, direct-профиль не затрагивается.

## 6. Откат

```bash
sudo ./set-ws-relay.sh clear
```

Клиенты снова используют `Direct:` ссылки из `manage-clients.sh links`.
