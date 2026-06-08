# Self-hosted WSS Relay (вариант 2B)

Используй, если **прямой** профиль `37.220.83.19:443` даёт timeout после `SOCKS5 request granted`, а Cloudflare Workers недоступен (нужна карта / нет аккаунта).

Схема:

```text
Windows v2rayN/Xray
  -> wss://relay.<domain>/ws
VPS-2 (Caddy TLS + wsrelay-server)
  -> tcp://37.220.83.19:443
VPS-1 (Xray REALITY)
```

Клиент подключается к **домену на VPS-2**, relay прозрачно пересылает байты на основной REALITY-сервер. UUID, public key, shortId, SNI остаются от VPS-1.

## Что нужно

- VPS-1: текущий REALITY сервер `37.220.83.19:443`
- VPS-2: отдельная машина с публичным IP
- Домен: поддомен `relay.<domain>`
- DNS: `A relay.<domain> -> IP_VPS_2`

## 1. DNS

В панели регистратора домена:

| Type | Name  | Value        |
|------|-------|--------------|
| A    | relay | IP_VPS_2     |

Проверка с Windows:

```powershell
Resolve-DnsName relay.<domain>
```

## 2. Установка relay на VPS-2

На VPS-2:

```bash
cd ~/protocol
git pull
cd REALITY
chmod +x deploy-wsrelay-vps.sh

sudo ./deploy-wsrelay-vps.sh install \
  --origin 37.220.83.19:443 \
  --domain relay.<domain>
```

Скрипт:

- соберёт `tools/wsrelay-server` в `/usr/local/bin/wsrelay-server`
- поднимет systemd `wsrelay-server` на `127.0.0.1:10080`
- установит Caddy и добавит TLS для `relay.<domain>`
- выдаст client URL: `wss://relay.<domain>/ws`

Проверка на VPS-2:

```bash
sudo ./deploy-wsrelay-vps.sh status
curl -I https://relay.<domain>/ws
```

TLS должен проходить. Ответ `426` или ошибка upgrade — нормально для обычного HTTP GET без WebSocket.

## 3. Настроить Windows-клиент

Закрой v2rayN полностью.

```powershell
cd C:\Users\Stas\Documents\Projects\protocol\REALITY
.\set-v2rayn-ws-relay.ps1 -WsRelayUrl "wss://relay.<domain>/ws" -ApplySafePreset
```

Скрипт:

- добавит `wsRelay` в `binConfigs\config.json` outbound `proxy`
- применит безопасный `socks-test` пресет (TUN off, Fragment off)
- сделает backup

Запусти v2rayN, выбери `laptop-direct`, **без TUN**.

## 4. Проверка

```powershell
curl.exe --max-time 20 --connect-timeout 10 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org -v
```

Ожидаемо: IP VPS `37.220.83.19` или другой egress, но **не timeout**.

Только после стабильного SOCKS:

```powershell
C:\Users\Stas\Documents\v2rayN-windows-64\standalone-singbox-tun\start-singbox-tun.ps1
curl.exe https://api.ipify.org
```

## 5. Откат на direct

Windows:

```powershell
.\set-v2rayn-ws-relay.ps1 -Clear
```

VPS-2:

```bash
sudo ./deploy-wsrelay-vps.sh uninstall
```

## 6. Отличие от Cloudflare Worker

| | Cloudflare Worker | Self-hosted VPS-2 |
|---|---|---|
| Нужен CF аккаунт | Да | Нет |
| Нужна вторая VPS | Нет | Да |
| Client URL | `wss://*.workers.dev` | `wss://relay.<domain>/ws` |
| Серверный `set-ws-relay.sh` | Опционально | Не нужен |
| Client `wsRelay` в config.json | Обязательно | Обязательно |

`REALITY/set-ws-relay.sh` пишет `wsRelay` в **серверный** config. Для self-hosted relay поле должно быть в **клиентском** `binConfigs/config.json` — для этого есть `set-v2rayn-ws-relay.ps1`.

## 7. Файлы в репозитории

- `tools/wsrelay-server/main.go` — relay binary
- `REALITY/deploy-wsrelay-vps.sh` — установка на VPS-2
- `REALITY/set-v2rayn-ws-relay.ps1` — патч клиентского v2rayN config
- `tools/wsrelay-server/caddy/Caddyfile.example` — пример Caddy
- `tools/wsrelay-server/systemd/wsrelay-server.service` — пример systemd unit
