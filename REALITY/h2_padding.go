package reality

import (
	"math/rand/v2"
	"slices"
	"sync"
)

const maxTLS13InnerPlaintext = maxPlaintext + 1
const handshakeTransitionRecordCount = 3

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

	// SmallPayloadRatioRange controls the relative padding budget used for
	// small plaintexts. Instead of rounding tiny payloads into a few fixed
	// buckets, the padder samples an additive target from a floating ratio
	// range to reduce repeated padding/payload clusters.
	SmallPayloadRatioRange [2]float64

	// SmallPayloadAbsoluteJitter adds an absolute additive budget for tiny
	// payloads so records with similar payload sizes do not converge to the
	// same ratio clusters.
	SmallPayloadAbsoluteJitter [2]int
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
		enabled:                    true,
		FrameSizes:                 sizes,
		SmallFrameChance:           0.05,
		WindowJitter:               0.12,
		FullFrameChance:            0.35,
		SmallPayloadRatioRange:     [2]float64{0.45, 2.40},
		SmallPayloadAbsoluteJitter: [2]int{12, 160},
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

// TransitionPaddingBytes smooths the size transition from the encrypted
// handshake flight to the first application data records. For the first few
// application records, it may bias padding toward recent handshake sizes
// before handing off to the regular HTTP/2 profile.
func (p *H2Padder) TransitionPaddingBytes(payloadLen int, recentHandshakeSizes []int, applicationRecordIndex int) int {
	p.mu.Lock()
	defer p.mu.Unlock()

	if !p.enabled || payloadLen <= 0 || applicationRecordIndex >= handshakeTransitionRecordCount || len(recentHandshakeSizes) == 0 {
		return 0
	}

	transitionChance := []float64{0.85, 0.55, 0.30}
	if rand.Float64() > transitionChance[applicationRecordIndex] {
		return 0
	}

	candidates := make([]int, 0, len(recentHandshakeSizes))
	for _, sz := range recentHandshakeSizes {
		if sz <= payloadLen {
			continue
		}
		if sz > 3072 {
			sz = 3072
		}
		if sz > payloadLen {
			candidates = append(candidates, sz)
		}
	}
	if len(candidates) == 0 {
		return 0
	}

	anchor := candidates[len(candidates)-1]
	if len(candidates) > 1 && rand.Float64() < 0.35 {
		anchor = candidates[len(candidates)-1-rand.IntN(min(2, len(candidates)))]
	}

	jitter := max(8, int(float64(anchor)*maxFloat(0.10, p.WindowJitter)))
	low := max(payloadLen+1, anchor-jitter)
	high := min(maxTLS13InnerPlaintext, anchor+jitter)
	if high < low {
		return 0
	}
	target := low + rand.IntN(high-low+1)
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
		if target := p.pickSmallPayloadTargetLocked(payloadLen, low, high, anchor, limit); target > payloadLen {
			return target
		}
	}

	return low + rand.IntN(high-low+1)
}

func (p *H2Padder) pickSmallPayloadTargetLocked(payloadLen, low, high, anchor, limit int) int {
	ratioLow, ratioHigh := p.SmallPayloadRatioRange[0], p.SmallPayloadRatioRange[1]
	if ratioLow <= 0 {
		ratioLow = 0.35
	}
	if ratioHigh < ratioLow {
		ratioHigh = ratioLow
	}

	absLow, absHigh := p.SmallPayloadAbsoluteJitter[0], p.SmallPayloadAbsoluteJitter[1]
	if absLow < 0 {
		absLow = 0
	}
	if absHigh < absLow {
		absHigh = absLow
	}

	ratio := ratioLow
	if ratioHigh > ratioLow {
		ratio = ratioLow + rand.Float64()*(ratioHigh-ratioLow)
	}
	additive := absLow
	if absHigh > absLow {
		additive += rand.IntN(absHigh - absLow + 1)
	}

	target := payloadLen + additive + int(float64(payloadLen)*ratio)
	if payloadLen <= 24 {
		target += rand.IntN(24)
	} else if payloadLen <= 64 {
		target += rand.IntN(40)
	}

	if anchor > payloadLen && rand.Float64() < 0.20 {
		blendLow := max(payloadLen+1, anchor-max(12, anchor/5))
		blendHigh := min(limit, anchor+max(16, anchor/4))
		if blendHigh >= blendLow {
			target = blendLow + rand.IntN(blendHigh-blendLow+1)
		}
	}

	target = clampPaddingInt(target, low, high)
	if target <= payloadLen {
		return 0
	}
	return target
}

func clampPaddingInt(value, low, high int) int {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

func maxFloat(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
