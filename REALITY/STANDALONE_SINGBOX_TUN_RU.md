# Отдельный sing-box TUN поверх v2rayN

Используй этот вариант, если:

- v2rayN без TUN работает;
- `curl --socks5-hostname 127.0.0.1:10808 https://api.ipify.org` возвращает IP VPS;
- встроенный TUN v2rayN даёт `dns: exchange failed` и `dial tcp 127.0.0.1:<port>: i/o timeout`.

Схема:

```text
Windows apps
  -> standalone sing-box TUN
  -> SOCKS 127.0.0.1:10808
  -> v2rayN / Xray / VLESS REALITY
  -> VPS
```

v2rayN в этой схеме **не поднимает TUN**. Он только держит рабочий VLESS/REALITY proxy на `10808`.

## 1. Подготовить файлы

Закрой v2rayN полностью, включая иконку в трее.

```powershell
cd C:\Users\Stas\Documents\Projects\protocol\REALITY
.\setup-standalone-singbox-tun.ps1
```

Скрипт:

- скачает `sing-box.exe` в `C:\Users\Stas\Documents\v2rayN-windows-64\standalone-singbox-tun`;
- создаст `config.json`;
- создаст `start-singbox-tun.ps1` и `stop-singbox-tun.ps1`;
- выключит встроенный TUN v2rayN;
- оставит v2rayN в режиме Global/System proxy для `127.0.0.1:10808`.

Если скачивание с GitHub API не сработает, скрипт попробует `winget` пакет `SagerNet.sing-box`.

Можно также заранее скачать `sing-box.exe` и передать путь явно:

```powershell
.\setup-standalone-singbox-tun.ps1 -SingBoxExe C:\path\to\sing-box.exe
```

## 2. Запустить v2rayN

Запусти v2rayN.

Важно:

- встроенный `VPN/TUN mode` в v2rayN выключен;
- выбран `laptop-direct`;
- Fragment выключен;
- Global/System proxy включён.

Проверка upstream:

```powershell
curl.exe --socks5-hostname 127.0.0.1:10808 https://api.ipify.org
```

Ожидаемо:

```text
37.220.83.19
```

## 3. Запустить standalone TUN

Открой PowerShell от администратора или просто запусти:

```powershell
C:\Users\Stas\Documents\v2rayN-windows-64\standalone-singbox-tun\start-singbox-tun.ps1
```

Скрипт сам попросит elevation, если не запущен от администратора.

## 4. Проверить полный VPN

В новом PowerShell:

```powershell
Resolve-DnsName api.ipify.org
curl.exe https://api.ipify.org
```

Ожидаемо:

```text
37.220.83.19
```

Если DNS работает, но `curl` зависает, попробуй конфигурацию без strict route:

```powershell
cd C:\Users\Stas\Documents\Projects\protocol\REALITY
.\setup-standalone-singbox-tun.ps1 -StrictRoute:$false
```

Потом снова запусти `start-singbox-tun.ps1`.

## 5. Остановить TUN

```powershell
C:\Users\Stas\Documents\v2rayN-windows-64\standalone-singbox-tun\stop-singbox-tun.ps1
```

Или закрыть окно, где работает `sing-box`.

## 6. Почему это лучше встроенного TUN v2rayN

Встроенный TUN v2rayN генерирует `configPre.json` заново и направляет DNS через внутренний bridge:

```text
sing-box TUN -> 127.0.0.1:<random> -> xray
```

На текущей машине этот bridge даёт:

```text
dns: exchange failed
dial tcp 127.0.0.1:<port>: i/o timeout
```

Standalone схема использует уже проверенный stable endpoint:

```text
127.0.0.1:10808
```

и не зависит от `configPre.json`, который v2rayN перегенерирует при каждом старте.
