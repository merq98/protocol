# REALITY Hardened Mode External Config Plumbing

This repository contains the REALITY library changes for hardened mode through `Config.RequireMldsa65`.

If you use REALITY through Xray-core or another JSON/protobuf-driven wrapper, you need one extra config field in that wrapper so operators can turn hardened mode on from external config.

## Exact runtime behavior

- `requireMldsa65 = false`:
  - current legacy behavior remains unchanged
  - REALITY authenticated path still works with only `privateKey`
- `requireMldsa65 = true` and `mldsa65Seed` configured on server:
  - REALITY authenticated path requires the independent ML-DSA-65 proof
  - clients must set `mldsa65Verify`
- `requireMldsa65 = true` but `mldsa65Seed` missing on server:
  - REALITY authenticated path is disabled and the connection falls back to the real target path

## Exact JSON config

Server-side `realitySettings`:

```json5
{
  "target": "example.com:443",
  "serverNames": ["example.com", "www.example.com"],
  "privateKey": "<x25519-private-key>",
  "shortIds": ["0123456789abcdef"],
  "mldsa65Seed": "<mldsa65-seed>",
  "requireMldsa65": true
}
```

Client-side `realitySettings`:

```json5
{
  "fingerprint": "chrome",
  "serverName": "example.com",
  "password": "<x25519-public-key>",
  "shortId": "0123456789abcdef",
  "mldsa65Verify": "<mldsa65-public-verify-key>"
}
```

## Xray-core plumbing changes

These are the exact places that need to be updated in Xray-core.

### 1. JSON layer: infra/conf/transport_internet.go

Add a new field to `REALITYConfig` next to `Mldsa65Seed`:

```go
RequireMldsa65 bool `json:"requireMldsa65"`
```

Then in `func (c *REALITYConfig) Build() (proto.Message, error)` set the generated config field:

```go
config.RequireMldsa65 = c.RequireMldsa65
```

Recommended validation in the server branch:

```go
if c.RequireMldsa65 && c.Mldsa65Seed == "" {
	return nil, errors.New(`empty "mldsa65Seed" when "requireMldsa65" is enabled`)
}
```

### 2. Proto layer: transport/internet/reality/config.proto

Add a new boolean to the REALITY protobuf message:

```proto
bool require_mldsa65 = <next_free_field_number>;
```

Use the next free field number in your current proto definition. After that, regenerate the protobuf outputs.

### 3. Runtime bridge: transport/internet/reality/config.go

Thread the protobuf field into the library config:

```go
config := &reality.Config{
	DialContext: dialer.DialContext,

	Show: c.Show,
	Type: c.Type,
	Dest: c.Dest,
	Xver: byte(c.Xver),

	PrivateKey:     c.PrivateKey,
	MinClientVer:   c.MinClientVer,
	MaxClientVer:   c.MaxClientVer,
	MaxTimeDiff:    time.Duration(c.MaxTimeDiff) * time.Millisecond,
	RequireMldsa65: c.RequireMldsa65,

	NextProtos:             nil,
	SessionTicketsDisabled: true,
	KeyLogWriter:           KeyLogWriterFromConfig(c),
}
```

### 4. Rollout order

1. Generate and deploy `mldsa65Seed` on the server.
2. Distribute the matching `mldsa65Verify` to all REALITY clients.
3. Only after that, enable `requireMldsa65: true` on the server.

This order avoids breaking older clients during migration.