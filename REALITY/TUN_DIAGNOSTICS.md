# TUN / v2rayN — результаты диагностики

Базовый снимок с ПК пользователя (v2rayN **выключен**, порт 10808 не слушает).

## Windows (2026-06-08)

| Проверка | Результат | Вывод |
|----------|-----------|-------|
| `curl https://api.ipify.org` | `178.70.68.187` | Прямой канал работает, домашний IP |
| `curl --socks5 127.0.0.1:10808` | connection refused | v2rayN не запущен / порт закрыт |
| `Resolve-DnsName youtube.com` | OK (Google IPs) | DNS без v2rayN работает |
| Ранее: SOCKS при включённом v2rayN | timeout | Outbound REALITY нестабилен |
| SOCKS/HTTP после отключения Fragment | `37.220.83.19` | Direct REALITY работает, проблема была в Fragment/dialerProxy-цепочке |
| VPS journalctl после отключения Fragment | `accepted tcp:api.ipify.org:443 [direct]` | Запросы с ПК доходят до VPS |
| Ранее: TUN + 2ip | IP VPS не показывался | TUN route/DNS или мёртвый outbound |
| Ранее: лог v2rayN | `net_io_readfailure` | Обрыв до `37.220.83.19:443` |
| Ранее: raw TCP :443 | Connected, hang | IP не заблокирован на TCP, проблема выше TLS |

## Классификация

1. **Fragment/dialerProxy** — подтверждённый подозреваемый: с Fragment SOCKS/HTTP зависали, без Fragment вернули IP VPS.
2. **TUN route/DNS** — следующий этап: SOCKS уже показывает VPS IP, теперь можно включать TUN и проверять маршруты.
3. **UDP/443 reject** — ломает YouTube QUIC даже при рабочем туннеле (`XudpProxyUDP443=reject`, sing-box `udp:443 -> reject`).
4. **IP-level block** — не подтверждён как основная причина: прямой REALITY без Fragment доходит до VPS.

## Порядок исправления

```text
1. socks-test preset + проверка SOCKS
2. если SOCKS=VPS -> tun-system / tun-gvisor / tun-relaxed
3. если после включения Fragment снова timeout -> держать Fragment off или чинить fragment path отдельно
4. -FixSingboxUdp443 для YouTube
5. финал: curl без SOCKS при TUN = VPS IP, 2ip.ru = VPS IP
```

## Команды

```powershell
# Диагностика (3 прогона: v2ray off / on TUN off / on TUN on)
.\REALITY\diagnose-v2rayn.ps1 -OutFile "$HOME\Desktop\v2rayn-diag.txt"

# Пресеты (v2rayN закрыт)
.\REALITY\generate-v2rayn-tun-profile.ps1 -Preset socks-test
.\REALITY\generate-v2rayn-tun-profile.ps1 -Preset tun-system -FixSingboxUdp443
.\REALITY\generate-v2rayn-tun-profile.ps1 -Preset tun-gvisor -FixSingboxUdp443
.\REALITY\generate-v2rayn-tun-profile.ps1 -Preset tun-relaxed -FixSingboxUdp443
```

На VPS во время теста SOCKS:

```bash
sudo journalctl -u xray -f --no-pager
```
