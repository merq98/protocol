package reality

import (
	"encoding/json"
	"sync"
	"time"
)

// FingerprintSpec describes the TLS ClientHello fingerprint observed
// from a real browser connection to the REALITY server.  The
// authenticated client can use this to configure uTLS so its
// ClientHello matches a real, up‑to‑date browser.
type FingerprintSpec struct {
	// TLS version advertised in the record layer.
	Version uint16 `json:"version"`

	// Cipher suites in the order they appeared.
	CipherSuites []uint16 `json:"cipher_suites"`

	// Extension IDs in the exact order they appeared.
	Extensions []uint16 `json:"extensions"`

	// Supported elliptic curves / named groups.
	SupportedCurves []CurveID `json:"supported_curves"`

	// EC point formats.
	SupportedPoints []uint8 `json:"supported_points"`

	// Signature algorithms.
	SignatureAlgorithms []SignatureScheme `json:"signature_algorithms"`

	// Supported TLS versions (from supported_versions extension).
	SupportedVersions []uint16 `json:"supported_versions"`

	// ALPN protocols (e.g. ["h2", "http/1.1"]).
	ALPNProtocols []string `json:"alpn_protocols"`

	// Key share groups offered (just the group IDs, not the keys).
	KeyShareGroups []CurveID `json:"key_share_groups"`

	// PSK modes (e.g. psk_dhe_ke).
	PSKModes []uint8 `json:"psk_modes,omitempty"`

	// Whether the ECH extension was present.
	ECH bool `json:"ech,omitempty"`

	// Compression methods.
	CompressionMethods []uint8 `json:"compression_methods"`

	// When this fingerprint was captured.
	CapturedAt time.Time `json:"captured_at"`
}

// ExtractFingerprint builds a FingerprintSpec from a parsed ClientHello.
func ExtractFingerprint(ch *clientHelloMsg) *FingerprintSpec {
	if ch == nil {
		return nil
	}
	fp := &FingerprintSpec{
		Version:            ch.vers,
		CipherSuites:       cloneSlice(ch.cipherSuites),
		Extensions:         cloneSlice(ch.extensions),
		SupportedCurves:    cloneSlice(ch.supportedCurves),
		SupportedPoints:    cloneSlice(ch.supportedPoints),
		SignatureAlgorithms: cloneSlice(ch.supportedSignatureAlgorithms),
		SupportedVersions:  cloneSlice(ch.supportedVersions),
		ALPNProtocols:      cloneSlice(ch.alpnProtocols),
		CompressionMethods: cloneSlice(ch.compressionMethods),
		PSKModes:           cloneSlice(ch.pskModes),
		ECH:                len(ch.encryptedClientHello) > 0,
		CapturedAt:         time.Now(),
	}
	for _, ks := range ch.keyShares {
		fp.KeyShareGroups = append(fp.KeyShareGroups, ks.group)
	}
	return fp
}

// Marshal serializes the fingerprint to JSON.
func (fp *FingerprintSpec) Marshal() ([]byte, error) {
	return json.Marshal(fp)
}

// UnmarshalFingerprint deserializes a fingerprint from JSON.
func UnmarshalFingerprint(data []byte) (*FingerprintSpec, error) {
	var fp FingerprintSpec
	if err := json.Unmarshal(data, &fp); err != nil {
		return nil, err
	}
	return &fp, nil
}

// FingerprintStore collects fingerprints from real browser connections
// and provides the most recent one for OTA delivery to auth clients.
//
// Thread-safe.
type FingerprintStore struct {
	mu          sync.RWMutex
	fingerprint *FingerprintSpec
	// maxAge controls how long a captured fingerprint stays valid.
	// After this duration, Latest() returns nil until a fresh one
	// is captured. Default: 24h.
	maxAge time.Duration
}

// NewFingerprintStore creates a store with the given max age.
func NewFingerprintStore(maxAge time.Duration) *FingerprintStore {
	if maxAge <= 0 {
		maxAge = 24 * time.Hour
	}
	return &FingerprintStore{maxAge: maxAge}
}

// Record stores a new fingerprint, replacing the previous one.
// Only non-auth ClientHellos should be recorded (they come from
// real browsers / DPI probers and have genuine fingerprints).
func (s *FingerprintStore) Record(ch *clientHelloMsg) {
	fp := ExtractFingerprint(ch)
	if fp == nil || len(fp.Extensions) == 0 {
		return
	}
	s.mu.Lock()
	s.fingerprint = fp
	s.mu.Unlock()
}

// Latest returns the most recent fingerprint, or nil if none
// is available or it has expired.
func (s *FingerprintStore) Latest() *FingerprintSpec {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.fingerprint == nil {
		return nil
	}
	if time.Since(s.fingerprint.CapturedAt) > s.maxAge {
		return nil
	}
	return s.fingerprint
}

// LatestJSON returns the latest fingerprint serialized as JSON,
// ready to be sent over the encrypted channel to the client.
// Returns nil if no valid fingerprint is available.
func (s *FingerprintStore) LatestJSON() []byte {
	fp := s.Latest()
	if fp == nil {
		return nil
	}
	data, err := fp.Marshal()
	if err != nil {
		return nil
	}
	return data
}

func cloneSlice[T any](s []T) []T {
	if s == nil {
		return nil
	}
	c := make([]T, len(s))
	copy(c, s)
	return c
}
