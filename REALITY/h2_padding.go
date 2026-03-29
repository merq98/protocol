package reality

import (
	"math/rand/v2"
	"sync"
)

// H2Padder pads TLS application data records to look like typical HTTP/2
// frame sizes. This defeats DPI that uses record-size distribution to
// distinguish VPN traffic from real HTTP/2 traffic.
//
// HTTP/2 has characteristic frame sizes:
//   - DATA frames: often exactly 16384 bytes (max default)
//   - HEADERS: 100-2000 bytes (varies)
//   - SETTINGS/WINDOW_UPDATE/PING: 9-50 bytes (control frames)
//   - GOAWAY/RST_STREAM/PRIORITY: small
//
// At the TLS record level, each HTTP/2 frame + 9-byte frame header is
// encrypted with AEAD overhead, producing recognizable record sizes.
type H2Padder struct {
	mu      sync.Mutex
	enabled bool

	// FrameSizes is the set of target payload sizes (before encryption)
	// that the padder will round up to. Records larger than the biggest
	// target are left as-is (they already look like full DATA frames).
	FrameSizes []int

	// SmallFrameChance is the probability [0.0, 1.0] that a record will
	// be padded to a small control-frame size instead of the next larger
	// frame size. This adds natural-looking small records to the mix.
	// Default: 0.05 (5%).
	SmallFrameChance float64
}

// Common HTTP/2 payload sizes at the TLS record level.
// These are frame payload + 9 byte HTTP/2 frame header.
var defaultH2FrameSizes = []int{
	18,    // SETTINGS (empty): 9 header + 0 payload, or PING: 9+8
	22,    // WINDOW_UPDATE: 9 header + 4 payload + padding
	50,    // Small HEADERS or SETTINGS with values
	165,   // Typical small HEADERS frame
	490,   // Medium HEADERS frame with cookies
	1250,  // Large HEADERS frame
	4105,  // Partial DATA frame (common in streaming)
	8210,  // Half-size DATA frame
	16393, // Full DATA frame: 9 header + 16384 payload
}

// NewH2Padder creates a padder with default HTTP/2 frame sizes.
func NewH2Padder() *H2Padder {
	sizes := make([]int, len(defaultH2FrameSizes))
	copy(sizes, defaultH2FrameSizes)
	return &H2Padder{
		enabled:          true,
		FrameSizes:       sizes,
		SmallFrameChance: 0.05,
	}
}

// PadSize returns the recommended padded payload size for a given
// plaintext payload length. The padding is added inside the TLS 1.3
// record (as zero bytes after ContentType), which is standard-compliant
// per RFC 8446 Section 5.4.
//
// Returns 0 if no padding should be applied (padder disabled or
// payload already matches a target size).
func (p *H2Padder) PadSize(payloadLen int) int {
	if !p.enabled || payloadLen <= 0 {
		return 0
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	// Occasionally emit a small control-frame-sized record
	if p.SmallFrameChance > 0 && payloadLen < 100 && rand.Float64() < p.SmallFrameChance {
		// Pick a random small frame size
		for _, sz := range p.FrameSizes {
			if sz >= payloadLen && sz < 100 {
				return sz
			}
		}
	}

	// Find the smallest target size >= payloadLen
	for _, sz := range p.FrameSizes {
		if sz >= payloadLen {
			return sz
		}
	}

	// Payload larger than biggest target — no padding needed,
	// it already looks like a full DATA frame.
	return 0
}

// PaddingBytes returns how many zero bytes to append for a given payload.
func (p *H2Padder) PaddingBytes(payloadLen int) int {
	target := p.PadSize(payloadLen)
	if target <= payloadLen {
		return 0
	}
	return target - payloadLen
}

// SetEnabled enables or disables the padder at runtime.
func (p *H2Padder) SetEnabled(enabled bool) {
	p.mu.Lock()
	p.enabled = enabled
	p.mu.Unlock()
}
