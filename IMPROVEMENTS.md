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
| 9 | OTA fingerprint update для uTLS | uTLS fingerprint | ✅ Готово |

---

## 1. Авто-подбор target по GeoIP/ASN

**Вектор атаки:** РКН видит, что клиент идёт к IP в Германии с SNI `dl.google.com`, а настоящий `dl.google.com` резолвится в IP Google CDN. Несоответствие → блокировка.

**Решение:** CLI-утилита для автоматического подбора оптимальных target'ов.

**Реализация:** `tools/autotarget/main.go`

- `IPInfo` — GeoIP-данные: ASN, страна, город, IP
- `TargetCandidate` — кандидат с рейтингом: Domain, IP, ASN, Country, Score, флаги TLS13/H2/OCSPStapl/NonRedir
- `lookupSelfInfo(ctx)` — запрашивает ipinfo.io для определения ASN/geo VPS
- `lookupDomainInfo(ctx, domain)` — резолвит домен, получает GeoIP
- `validateTarget(ctx, domain)` — проверяет TLS 1.3, HTTP/2, OCSP Stapling, отсутствие редиректов
- `scoreCandidate(ourASN, targetASN, targetCountry)` — рейтинг: совпадение ASN (+100), страна (+50), город (+25)
- `main()` — валидирует 50+ доменов, сортирует по Score, выводит JSON для конфига сервера

---

## 2. Ротация target'ов

**Вектор атаки:** Active probing: РКН подключается повторно и видит всегда один и тот же target.

**Решение:** Пул target'ов с round-robin или time-based ротацией.

**Реализация:** `REALITY/target_pool.go`

- `Target` — Dest (`host:port`), ServerNames (`map[string]bool`)
- `TargetPool` — пул targets с атомарным счётчиком и таймером ротации
- `NewTargetPool(targets, rotateInterval)` — создать пул; если `rotateInterval > 0`, ротация по времени, иначе round-robin
- `Pick(sni)` → `*Target` — приоритет: точное совпадение SNI → ротация
- `PickRandom()` → `*Target` — случайный target (для первого dial в multi-SNI)
- `PickBySNI(sni)` → `*Target` — точный поиск по SNI
- `AllServerNames()` → `map[string]bool` — все SNI всех targets
- `AllDests()` → `[]string` — все уникальные адреса

**Интеграция:**
- `Config.Targets *TargetPool` — переопределяет `Config.Dest`/`Config.ServerNames`
- В `Server()`: `multiSNI = config.Targets != nil && config.Targets.Len() > 0`
- `record_detect.go` — итерирует все targets из TargetPool через `destSNI` pairs

---

## 3. Мульти-SNI на одном сервере

**Вектор атаки:** Один клиент ходит на один IP 24/7 с одним SNI.

**Решение:** Сервер принимает несколько SNI, проксирует к разным target'ам. Выглядит как CDN/reverse proxy.

**Реализация:** `REALITY/tls.go` (расширение `MirrorConn` + `Server()`)

- `MirrorConn` — расширена полями:
  - `targetPending bool` — режим буферизации до определения правильного target'а
  - `pendingBuf []byte` — буфер ClientHello
  - `ReplaceTarget(newConn)` — заменяет target, отправляет `pendingBuf` в новый
  - `FinalizePending()` — отправляет буфер в текущий target
- `targetReady chan struct{}` — синхронизация goroutine 1 (клиент→target) с goroutine 2 (target→клиент)

**Интеграция в `Server()`:**

1. Multi-SNI включён: `effectiveServerNames = AllServerNames()`, dial к `PickRandom()` (временный)
2. Goroutine 1: после `readClientHello` → `PickBySNI(hs.clientHello.serverName)` → если другой dest → `config.DialContext()` → `mc.ReplaceTarget(newTarget)` → `close(targetReady)`
3. Goroutine 2: ждёт `<-targetReady`, затем читает с правильного target'а

---

## 4. Pre-built mode (кэш ответов target'а)

**Вектор атаки:** Active probing: RTT удваивается из-за проксирования к target.

**Решение:** Заранее собрать Server Hello + сертификаты от target'а. Отдавать из кэша мгновенно.

**Реализация:** `REALITY/prebuilt_cache.go`

- `PrebuiltResponse` — кэшированный handshake:
  - `RawRecords []byte` — Server Hello + CCS + Encrypted Extensions + Cert + CertVerify + Finished + NST
  - `Hello *serverHelloMsg` — распарсенный Server Hello (для проверки совместимости)
  - `CapturedAt time.Time`
- `PrebuiltCache` — потокобезопасный кэш:
  - `entries map[string]*PrebuiltResponse` — ключ `"dest sni"`
  - `RefreshInterval` (default 10m), `MaxAge` (default 30m)
- `Get(dest, sni)` → `*PrebuiltResponse` — достаёт из кэша, проверяет `MaxAge`
- `Warm(networkType, dest, sni)` — uTLS handshake к target, захват сырых TLS records через `captureConn`
- `WarmAll(config)` — прогрев всех targets параллельно через `sync.WaitGroup`
- `StartRefresh(config)` — фоновый goroutine, периодическое обновление

**Интеграция:**
- `Config.Prebuilt *PrebuiltCache`
- `Server()` goroutine 2: `config.Prebuilt.Get()` → seed `s2cSaved` → пропуск первого `target.Read()`
- Результат: RTT для non-auth = ~0, неотличим от auth path

---

## 5. Короткие ротируемые соединения

**Вектор атаки:** Одно соединение живёт часами с огромным объёмом данных.

**Решение:** Враппер с ограничением по возрасту/трафику + менеджер сессий.

**Реализация:** `REALITY/conn_rotator.go`

- `RotationPolicy` — настройки:
  - `MaxLifetime` (default 60s) — макс возраст соединения
  - `MaxBytes` (default 5MB) — макс трафика до ротации
  - `MinLifetime` (default 10s) — минимальное время жизни
  - `Jitter` (default 15s) — случайное смещение deadline'а
- `RotatedConn` — враппер `net.Conn`:
  - Отслеживает `bytesIn`/`bytesOut` (atomic int64), `deadline`, `createdAt`
  - `ShouldRotate() bool` — `now > deadline` или `bytes > MaxBytes`
  - `OnRotate(fn)` — callback при необходимости ротации
  - `Read()`/`Write()` — проксируют с подсчётом трафика
- `SessionManager` — группирует ротированные conn'ы одного клиента (ключ: `ClientShortId` hex)
- `Session` — мультиплексирует Read через channel, Write в активный conn

**Интеграция:**
- `Config.Rotation *RotationPolicy`, `Config.Sessions *SessionManager`
- `Server()`: после `isHandshakeComplete` оборачивает conn в `RotatedConn`, привязывает к `SessionManager` по `ClientShortId`

---

## 6. Padding до типичных размеров HTTP/2

**Вектор атаки:** Размеры TLS-записей VPN-трафика отличаются от типичного HTTP/2.

**Решение:** Padding application data до размеров HTTP/2 фреймов (RFC 8446 §5.4 — нулевые байты).

**Реализация:** `REALITY/h2_padding.go` + `REALITY/conn.go`

- `H2Padder` — паддер записей:
  - `FrameSizes []int` — целевые размеры: `[18, 22, 50, 165, 490, 1250, 4105, 8210, 16393]`
  - `SmallFrameChance float64` (default 0.05) — вероятность эмиссии маленького control-frame
  - `PadSize(payloadLen) int` — ближайший размер из `FrameSizes` (≥ payload)
  - `PaddingBytes(payloadLen) int` — количество нулевых байт для дополнения
  - `SetEnabled(bool)` — вкл/выкл в runtime
- В `conn.go`, метод `halfConn.encrypt()`:
  - Поле `h2Padder *H2Padder` добавлено в `halfConn`
  - Для `recordTypeApplicationData`: `h2pad := hc.h2Padder.PaddingBytes(plainLen)` → append нулей
  - Совместимо с RFC 8446 §5.4 (TLS 1.3 content type после padding)

**Интеграция:**
- `Config.H2Padding *H2Padder`
- `Server()`: после `isHandshakeComplete` — `hs.c.out.h2Padder = config.H2Padding`

---

## 7. Timing normalization

**Вектор атаки:** Timing авторизованных vs не-авторизованных клиентов отличается.

**Решение:** Нормализация задержек: выравнивание auth path до target RTT.

**Реализация:** `REALITY/timing_normalizer.go`

- `TimingNormalizer` — выравниватель хронометража handshake:
  - `avgTargetRTT` — экспоненциальное скользящее среднее (EMA) RTT до target'а
  - `alpha float64` (default 0.3) — фактор сглаживания EMA
  - `minSamples int` (default 3) — минимум замеров перед включением
  - `jitter float64` (default 0.15) — ±15% от `avgTargetRTT`
  - `BaseDelay` — фиксированный минимальный delay
- `RecordTargetRTT(rtt)` — обновить EMA после каждого proxy round-trip
- `Delay(elapsed) time.Duration` — сколько ждать: `max(0, targetRTT ± jitter - elapsed)`
- `Sleep(elapsed)` — блокирует на `Delay(elapsed)`

**Интеграция:**
- `Config.Timing *TimingNormalizer`
- `Server()` goroutine 2: после первого `target.Read()` — `config.Timing.RecordTargetRTT(firstResponseTime - readStart)`
- `Server()` goroutine 2 (auth path): после `hs.readClientFinished()` — `config.Timing.Sleep(time.Since(targetReadStart))`

---

## 8. CDN relay (Cloudflare Workers)

**Вектор атаки:** Блокировка IP VPS.

**Решение:** Cloudflare Workers как WS↔TCP relay. Клиент видит IP Cloudflare, а не VPS.

**Реализация:**

*Серверная часть (Worker):* `worker/relay.js` + `worker/wrangler.toml`

- Worker слушает WebSocket upgrade на `fetch()`
- Открывает TCP к `env.ORIGIN` (VPS) через `cloudflare:sockets` `connect()`
- Bidirectional relay: WS messages ↔ TCP bytes, прозрачно
- REALITY handshake проходит внутри WS-туннеля — Cloudflare видит только бинарные WS-фреймы
- `wrangler.toml`: `ORIGIN = "YOUR_VPS_IP:443"`, деплой через `npx wrangler deploy`
- Free plan: 100k req/day, WS messages после upgrade не тарифицируются

*Клиентская часть:* `REALITY/ws_conn.go`

- `WSConn` — реализует `net.Conn` поверх WebSocket (`nhooyr.io/websocket`):
  - `ws *websocket.Conn` — WebSocket-соединение
  - `reader io.Reader` — буфер для конвертации message-oriented → stream
  - `Read(b)` — читает WS messages, преобразует в поток
  - `Write(b)` — отправляет binary message
  - Полная поддержка deadline'ов через `context.WithDeadline`
- `DialWS(ctx, url) (net.Conn, error)` — устанавливает WS к relay, возвращает `*WSConn`

**Интеграция:** серверная сторона не требует изменений. Клиент использует `DialWS()` вместо `net.Dial()`.

---

## 9. OTA fingerprint update для uTLS

**Вектор атаки:** uTLS эмулирует устаревший fingerprint Chrome.

**Решение:** Сервер захватывает fingerprint реальных браузеров и передаёт auth-клиенту.

**Реализация:** `REALITY/fingerprint.go`

- `FingerprintSpec` — JSON-сериализуемый снимок ClientHello:
  - `CipherSuites []uint16` — cipher suites в порядке из ClientHello
  - `Extensions []uint16` — ID расширений в точном порядке (критично для JA3/JA4)
  - `SupportedCurves []CurveID` — named groups
  - `SupportedPoints []uint8` — EC point formats
  - `SignatureAlgorithms []SignatureScheme`
  - `SupportedVersions []uint16`
  - `ALPNProtocols []string` — `["h2", "http/1.1"]`
  - `KeyShareGroups []CurveID` — группы из key_share (не ключи)
  - `PSKModes []uint8`, `ECH bool`, `CompressionMethods []uint8`
  - `CapturedAt time.Time`
- `ExtractFingerprint(ch *clientHelloMsg)` → `*FingerprintSpec` — извлекает из распарсенного ClientHello
- `FingerprintStore` — потокобезопасное хранилище:
  - `maxAge time.Duration` (default 24h) — TTL fingerprint'а
  - `Record(ch)` — сохранить fingerprint от non-auth клиента (реальный браузер / DPI-проба)
  - `Latest()` → `*FingerprintSpec` — получить актуальный (или `nil` если истёк)
  - `LatestJSON()` → `[]byte` — JSON для передачи клиенту
- `Conn.PeerFingerprint *FingerprintSpec` — поле для получения fingerprint'а клиентом

**Интеграция:**
- `Config.Fingerprints *FingerprintStore`
- `Server()` non-auth path: `config.Fingerprints.Record(hs.clientHello)` — захват
- `Server()` auth path: `hs.c.PeerFingerprint = config.Fingerprints.Latest()` — доставка
- Клиент читает `conn.PeerFingerprint` после handshake и обновляет uTLS `ClientHelloSpec`

---

## Карта файлов

| Файл | Решение | Назначение |
|------|---------|------------|
| `tools/autotarget/main.go` | #1 | CLI: авто-подбор target по GeoIP/ASN |
| `REALITY/target_pool.go` | #2, #3 | Пул target'ов + SNI-маршрутизация |
| `REALITY/tls.go` | #2–#9 | `Server()`: MirrorConn, multi-SNI, prebuilt, timing, fingerprint |
| `REALITY/prebuilt_cache.go` | #4 | Кэш handshake-ответов target'а |
| `REALITY/conn_rotator.go` | #5 | Ротация соединений + сессии |
| `REALITY/h2_padding.go` | #6 | Padding до размеров HTTP/2 фреймов |
| `REALITY/conn.go` | #6, #9 | `halfConn.h2Padder`, `Conn.PeerFingerprint` |
| `REALITY/timing_normalizer.go` | #7 | EMA RTT + нормализация задержек |
| `REALITY/ws_conn.go` | #8 | `WSConn` — `net.Conn` поверх WebSocket |
| `worker/relay.js` | #8 | Cloudflare Worker: WS↔TCP relay |
| `worker/wrangler.toml` | #8 | Конфиг деплоя Worker |
| `REALITY/fingerprint.go` | #9 | OTA fingerprint: захват + доставка |
| `REALITY/common.go` | #2–#9 | `Config`: Targets, Prebuilt, Rotation, Sessions, H2Padding, Timing, Fingerprints |

## Поля Config (`common.go`)

Все компоненты опциональны и работают независимо.

```go
Targets      *TargetPool         // #2, #3: пул target'ов с multi-SNI
Prebuilt     *PrebuiltCache      // #4: кэш handshake-ответов
Rotation     *RotationPolicy     // #5: политика ротации соединений
Sessions     *SessionManager     // #5: менеджер сессий
H2Padding    *H2Padder           // #6: padding до HTTP/2 фреймов
Timing       *TimingNormalizer   // #7: нормализация тайминга
Fingerprints *FingerprintStore   // #9: OTA fingerprint store
```
