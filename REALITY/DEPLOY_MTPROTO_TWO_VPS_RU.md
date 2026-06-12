# MTProto Proxy Через Два VPS

Этот guide поднимает Telegram MTProto Proxy через два VPS:

```text
Telegram client
  -> VPS1 public TCP relay :443
  -> WireGuard tunnel
  -> VPS2 MTProto backend
  -> Telegram
```

VPS1 виден клиентам Telegram. VPS2 держит настоящий MTProto proxy и не публикует backend-порт в интернет.

## Что Используется

- WireGuard между VPS1 и VPS2.
- HAProxy на VPS1 как TCP relay.
- Официальный Docker image `telegrammessenger/proxy:latest` на VPS2.
- `ufw` firewall на обоих серверах.

Assumption: оба сервера на Ubuntu/Debian и команды выполняются от root или через `sudo`.

## Параметры

Скопируй пример env на оба VPS:

```bash
cd ~/protocol/REALITY
cp mtproto-two-vps.env.example /root/mtproto-two-vps.env
chmod 600 /root/mtproto-two-vps.env
```

Заполни минимум:

```bash
# На обоих VPS
WG_PORT=51821
WG_VPS1_IP=10.77.0.1
WG_VPS2_IP=10.77.0.2
PUBLIC_PORT=443
MTPROTO_BACKEND_PORT=8443

# На VPS1
PUBLIC_HOST=YOUR_VPS1_IP_OR_DOMAIN
WG_ENDPOINT_HOST=YOUR_VPS2_PUBLIC_IP
WG_PEER_PUBLIC_KEY=PUBLIC_KEY_FROM_VPS2

# На VPS2
PUBLIC_HOST=YOUR_VPS1_IP_OR_DOMAIN
VPS1_PUBLIC_IP=YOUR_VPS1_PUBLIC_IP
WG_PEER_PUBLIC_KEY=PUBLIC_KEY_FROM_VPS1
```

Не коммить реальные env-файлы, WireGuard private keys и MTProto secret.

## 1. Подготовить Ключи WireGuard

На VPS1:

```bash
cd ~/protocol/REALITY
chmod +x deploy-mtproto-two-vps.sh
sudo MTPROTO_ENV=/root/mtproto-two-vps.env ./deploy-mtproto-two-vps.sh prepare
```

На VPS2:

```bash
cd ~/protocol/REALITY
chmod +x deploy-mtproto-two-vps.sh
sudo MTPROTO_ENV=/root/mtproto-two-vps.env ./deploy-mtproto-two-vps.sh prepare
```

После этого обменяй public keys:

- public key с VPS1 вставь в `/root/mtproto-two-vps.env` на VPS2 как `WG_PEER_PUBLIC_KEY`;
- public key с VPS2 вставь в `/root/mtproto-two-vps.env` на VPS1 как `WG_PEER_PUBLIC_KEY`.

## 2. Установить Backend На VPS2

Сначала ставим VPS2, потому что VPS1 relay должен знать, куда прокидывать TCP.

```bash
cd ~/protocol/REALITY
sudo MTPROTO_ENV=/root/mtproto-two-vps.env ./deploy-mtproto-two-vps.sh install-vps2
```

Скрипт:

- создаст `/etc/wireguard/wg-mtproto.conf`;
- поднимет `wg-quick@wg-mtproto`;
- установит Docker, если его нет;
- создаст systemd service `mtproto-proxy`, завязанный на Docker и WireGuard;
- запустит `telegrammessenger/proxy:latest` через этот service;
- привяжет контейнер только к `10.77.0.2:8443`;
- сгенерирует MTProto secret, если `MTPROTO_SECRET` не задан;
- сохранит ссылки в `/usr/local/etc/mtproto-two-vps/client-links.txt`.

Показать ссылки:

```bash
sudo ./deploy-mtproto-two-vps.sh links
```

## 3. Установить Public Relay На VPS1

На VPS1:

```bash
cd ~/protocol/REALITY
sudo MTPROTO_ENV=/root/mtproto-two-vps.env ./deploy-mtproto-two-vps.sh install-vps1
```

Скрипт:

- создаст `/etc/wireguard/wg-mtproto.conf`;
- поднимет WireGuard до VPS2;
- установит HAProxy;
- настроит `0.0.0.0:443 -> 10.77.0.2:8443`;
- откроет firewall для SSH и `PUBLIC_PORT`.

## Firewall Модель

VPS1:

```text
allow SSH_PORT/tcp
allow PUBLIC_PORT/tcp
WireGuard outbound to VPS2:WG_PORT/udp
```

VPS2:

```text
allow SSH_PORT/tcp
allow WG_PORT/udp from VPS1_PUBLIC_IP
do not allow MTPROTO_BACKEND_PORT from public internet
```

Backend MTProto порт слушает только WireGuard IP, поэтому даже при ошибке firewall он не должен висеть на `0.0.0.0`.

## Проверка

На VPS2:

```bash
sudo ./deploy-mtproto-two-vps.sh status-vps2
sudo systemctl status mtproto-proxy --no-pager
sudo docker logs --tail 100 mtproto-proxy
sudo ss -lntp | grep 8443
```

Ожидаемо:

```text
10.77.0.2:8443
```

Не ожидаемо:

```text
0.0.0.0:8443
```

На VPS1:

```bash
sudo ./deploy-mtproto-two-vps.sh status-vps1
sudo ss -lntp | grep ':443'
```

Проверка WireGuard:

```bash
ping -c 3 10.77.0.2   # с VPS1
ping -c 3 10.77.0.1   # с VPS2
```

## Подключение Telegram

Возьми ссылку с VPS2:

```bash
sudo ./deploy-mtproto-two-vps.sh links
```

Импортируй в Telegram:

```text
tg://proxy?server=YOUR_VPS1_IP_OR_DOMAIN&port=443&secret=...
```

Telegram должен видеть только VPS1. VPS2 остается backend-сервером за WireGuard.

## Эксплуатация

Restart VPS1 relay:

```bash
sudo systemctl restart wg-quick@wg-mtproto
sudo systemctl restart haproxy
```

Restart VPS2 backend:

```bash
sudo systemctl restart wg-quick@wg-mtproto
sudo systemctl restart mtproto-proxy
```

Logs:

```bash
sudo journalctl -u wg-quick@wg-mtproto -n 100 --no-pager
sudo journalctl -u haproxy -n 100 --no-pager
sudo journalctl -u mtproto-proxy -n 100 --no-pager
sudo docker logs --tail 100 mtproto-proxy
```

Rotate MTProto secret:

```bash
sudo systemctl stop haproxy              # optional short maintenance window on VPS1
sudo systemctl stop mtproto-proxy        # on VPS2
sudo rm -f /usr/local/etc/mtproto-two-vps/mtproto.env
sudo MTPROTO_ENV=/root/mtproto-two-vps.env ./deploy-mtproto-two-vps.sh install-vps2
sudo ./deploy-mtproto-two-vps.sh links
sudo systemctl restart haproxy           # on VPS1
```

После ротации secret старые Telegram-ссылки перестанут работать.

## Что Не Настраивается

- Балансировка на несколько MTProto backend-серверов.
- Регистрация proxy через Telegram bot и ad tag.
- Смешивание MTProto с VLESS/REALITY в одном процессе.
