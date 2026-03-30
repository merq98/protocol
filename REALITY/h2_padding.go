package reality

import (
	"math/rand/v2"
	"slices"
	"sync"
)

const maxTLS13InnerPlaintext = maxPlaintext + 1

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

	// FrameSizes holds anchor points used to derive padding windows.
	// The padder will pick a random target near the first anchor that can
	// accommodate the current plaintext instead of rounding to a fixed peak.
	FrameSizes []int

	// SmallFrameChance is the probability [0.0, 1.0] that a record will
	// be padded to a small control/header-like frame window instead of the
	// next larger data-oriented window. This adds natural-looking small
	// records to the mix.
	// Default: 0.05 (5%).
	SmallFrameChance float64

	// WindowJitter is the fraction of each anchor size used as a random
	// window around that anchor. Higher values spread records more widely
	// and reduce visible histogram spikes.
	WindowJitter float64

	// FullFrameChance is the probability [0.0, 1.0] of padding near a
	// full-size data frame once the payload is already large enough.
	FullFrameChance float64
}

// Common HTTP/2 payload sizes at the TLS record level.
// These are frame payload + 9 byte HTTP/2 frame header.
var defaultH2FrameSizes = []int{
	18,    // SETTINGS/PING-sized control frames
	22,    // WINDOW_UPDATE-sized frames
	50,    // Small HEADERS or SETTINGS with values
	165,   // Typical small HEADERS frame
	490,   // Medium HEADERS frame with cookies
	1250,  // Large HEADERS frame
	4105,  // Partial DATA frame (common in streaming)
	8210,  // Half-size DATA frame
	16385, // Max TLS 1.3 inner plaintext: 16384 + content type byte
}

// NewH2Padder creates a padder with default HTTP/2 frame sizes.
func NewH2Padder() *H2Padder {
	sizes := make([]int, len(defaultH2FrameSizes))
	copy(sizes, defaultH2FrameSizes)
	return &H2Padder{
		enabled:          true,
		FrameSizes:       sizes,
		SmallFrameChance: 0.05,
		WindowJitter:     0.12,
		FullFrameChance:  0.35,
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
	p.mu.Lock()
	defer p.mu.Unlock()

	if !p.enabled || payloadLen <= 0 {
		return 0
	}

	anchors := p.normalizedAnchorsLocked()
	if len(anchors) == 0 {
		return 0
	}

	limit := min(maxTLS13InnerPlaintext, anchors[len(anchors)-1])
	if payloadLen >= limit {
		return 0
	}

	targetIndex := p.pickAnchorIndexLocked(payloadLen, anchors)
	if targetIndex < 0 {
		return 0
	}

	target := p.pickTargetInWindowLocked(payloadLen, targetIndex, anchors, limit)
	if target <= payloadLen {
		return 0
	}

	return target
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

func (p *H2Padder) normalizedAnchorsLocked() []int {
	if len(p.FrameSizes) == 0 {
		return nil
	}

	anchors := slices.Clone(p.FrameSizes)
	slices.Sort(anchors)
	anchors = slices.Compact(anchors)

	filtered := anchors[:0]
	for _, anchor := range anchors {
		if anchor <= 0 {
			continue
		}
		if anchor > maxTLS13InnerPlaintext {
			anchor = maxTLS13InnerPlaintext
		}
		if len(filtered) == 0 || filtered[len(filtered)-1] != anchor {
			filtered = append(filtered, anchor)
		}
	}

	return filtered
}

func (p *H2Padder) pickAnchorIndexLocked(payloadLen int, anchors []int) int {
	firstFit := slices.IndexFunc(anchors, func(anchor int) bool {
		return anchor >= payloadLen
	})
	if firstFit < 0 {
		return -1
	}

	if payloadLen < 256 && p.SmallFrameChance > 0 && rand.Float64() < p.SmallFrameChance {
		smallCap := firstFit
		for smallCap+1 < len(anchors) && anchors[smallCap+1] <= 256 {
			smallCap++
		}
		if smallCap >= firstFit {
			return firstFit + rand.IntN(smallCap-firstFit+1)
		}
	}

	lastIndex := len(anchors) - 1
	if payloadLen >= 4096 && p.FullFrameChance > 0 && rand.Float64() < p.FullFrameChance {
		fullStart := max(firstFit, lastIndex-1)
		if fullStart <= lastIndex {
			return fullStart + rand.IntN(lastIndex-fullStart+1)
		}
	}

	span := min(3, len(anchors)-firstFit)
	if span <= 1 {
		return firstFit
	}

	return firstFit + rand.IntN(span)
}

func (p *H2Padder) pickTargetInWindowLocked(payloadLen, index int, anchors []int, limit int) int {
	anchor := anchors[index]
	prevAnchor := 0
	if index > 0 {
		prevAnchor = anchors[index-1]
	}
	nextAnchor := limit
	if index+1 < len(anchors) {
		nextAnchor = anchors[index+1]
	}

	jitterFraction := p.WindowJitter
	if jitterFraction <= 0 {
		jitterFraction = 0.08
	}
	jitter := max(4, int(float64(anchor)*jitterFraction))

	low := max(payloadLen, anchor-jitter)
	high := min(limit, anchor+jitter)
	if prevAnchor > 0 {
		low = max(low, prevAnchor+1)
	}
	if nextAnchor > anchor {
		high = min(high, nextAnchor-1)
	}
	if high <= payloadLen {
		return 0
	}
	if low > high {
		low = payloadLen + 1
		high = max(low, min(limit, anchor))
	}

	if payloadLen < 128 {
		step := smallPayloadStep(payloadLen)
		low = roundUp(low, step)
		high -= high % step
		if low > high {
			low = payloadLen + 1
			high = low
		}
		if high <= payloadLen {
			return 0
		}
		count := ((high - low) / step) + 1
		return low + rand.IntN(count)*step
	}

	return low + rand.IntN(high-low+1)
}

func smallPayloadStep(payloadLen int) int {
	switch {
	case payloadLen <= 32:
		return 2
	case payloadLen <= 96:
		return 4
	default:
		return 8
	}
}
