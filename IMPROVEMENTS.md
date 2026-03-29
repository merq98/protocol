# REALITY Improvements Roadmap

Улучшения протокола REALITY для противодействия DPI-детектированию.

## Статус

| # | Улучшение | Вектор | Статус |
|---|-----------|--------|--------|
| 1 | Авто-подбор target по GeoIP/ASN | SNI ≠ GeoIP | ✅ Готово |
| 2 | Ротация target'ов | Active probing | ✅ Готово |
| 3 | Мульти-SNI на одном сервере | Паттерн одного клиента | ✅ Готово |
| 4 | Pre-built mode (кэш ответов target'а) | Active probing + timing | ✅ Готово |
| 5 | Короткие ротируемые соединения | Статистика потоков | ✅ Готово |
| 6 | Padding до типичных размеров HTTP/2 | Статистика потоков | ✅ Готово |
| 7 | Timing normalization | Active probing | ✅ Готово |
| 8 | CDN relay (Cloudflare Workers) | Блокировка IP | ✅ Готово |
| 9 | OTA fingerprint update для uTLS | uTLS fingerprint | ⬜ Не начато |

---

## 1. Авто-подбор target по GeoIP/ASN

**Вектор атаки:** РКН видит, что клиент идёт к IP в Германии с SNI `dl.google.com`, а настоящий `dl.google.com` резолвится в IP Google CDN. Несоответствие → блокировка.

**Решение:** Утилита/модуль, который:
1. Определяет ASN и геолокацию VPS
2. Проверяет список известных сайтов с TLS 1.3 + H2
3. Резолвит их домены и сравнивает ASN/геолокацию
4. Фильтрует: поддержка TLS 1.3, H2, не-редирект, OCSP Stapling
5. Возвращает отсортированный список рекомендованных target'ов

**Файл:** `tools/autotarget/autotarget.go`

---

## 2. Ротация target'ов

**Вектор атаки:** Active probing: РКН подключается повторно и видит всегда один и тот же target.

**Решение:** Пул target'ов с переключением по времени/соединению.

---

## 3. Мульти-SNI на одном сервере

**Вектор атаки:** Один клиент ходит на один IP 24/7 с одним SNI.

**Решение:** Сервер принимает несколько SNI, проксирует к разным target'ам. Выглядит как CDN/reverse proxy.

---

## 4. Pre-built mode (кэш ответов target'а)

**Вектор атаки:** Active probing: RTT удваивается из-за проксирования к target.

**Решение:** Заранее собрать Server Hello, сертификаты, OCSP от target'а. Отдавать из кэша мгновенно для не-авторизованных клиентов.

---

## 5. Короткие ротируемые соединения

**Вектор атаки:** Одно соединение живёт часами с огромным объёмом данных.

**Решение:** Клиент открывает 3-6 параллельных соединений, каждое живёт 30-120 сек, данные распределяются.

---

## 6. Padding до типичных размеров HTTP/2

**Вектор атаки:** Размеры TLS-записей VPN-трафика отличаются от типичного HTTP/2.

**Решение:** Padding application data записей до размеров, характерных для HTTP/2 фреймов target-сайта.

---

## 7. Timing normalization ✅ Готово

**Вектор атаки:** Timing авторизованных vs не-авторизованных клиентов отличается.

**Решение:** Нормализация задержек: буферизация + выравнивание RTT.

**Реализация:**
- `timing_normalizer.go` — `TimingNormalizer` с EMA target-RTT, адаптивный delay + jitter
- Goroutine 2 в `Server()` измеряет RTT до target'а (первый `target.Read()`)
- После `hs.readClientFinished()` (auth path) — `Sleep()` нормализует время до target-RTT
- Jitter ±15 % для маскировки фиксированных задержек

---

## 8. CDN relay (Cloudflare Workers) ✅ Готово

**Вектор атаки:** Блокировка IP VPS.

**Решение:** Cloudflare Workers как relay-слой. Трафик идёт к IP Cloudflare.

**Реализация:**
- `worker/relay.js` — Worker: WS↔TCP relay через `cloudflare:sockets` connect()
- `worker/wrangler.toml` — конфиг деплоя, `ORIGIN` = адрес VPS
- `ws_conn.go` — `WSConn` (реализует `net.Conn` поверх WebSocket)
- `DialWS(ctx, url)` — клиент подключается к relay, получает обычный `net.Conn`
- Cloudflare не видит содержимое: REALITY handshake проходит внутри WS-туннеля
- Free plan: 100k req/day, WS-сообщения после upgrade не тарифицируются

---

## 9. OTA fingerprint update для uTLS

**Вектор атаки:** uTLS эмулирует устаревший fingerprint Chrome.

**Решение:** Сервер передаёт клиенту актуальный шаблон ClientHello при подключении.
