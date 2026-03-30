package reality

import (
	"math/rand/v2"
	"sync"
	"time"
)

// TimingNormalizer equalizes the timing of REALITY handshake responses
// between authenticated and non-authenticated clients. Without
// normalization, DPI can distinguish them by measuring the round-trip
// time of the TLS handshake:
//
//   - Non-authenticated: server proxies to real target → adds target RTT
//   - Authenticated: server handles locally → faster (or slower if crypto is heavy)
//
// The normalizer maintains a running estimate of the target RTT and
// adds artificial delays to make both paths produce similar timing.
type TimingNormalizer struct {
	mu sync.RWMutex

	// Running average of measured target RTTs (exponentially weighted).
	avgTargetRTT time.Duration

	// Smoothing factor for exponential moving average (0..1).
	// Lower = smoother, higher = more reactive. Default: 0.3.
	alpha float64

	// Minimum samples before the normalizer starts applying delays.
	minSamples int
	samples    int

	// Jitter range as a fraction of the target RTT.
	// Final delay = targetRTT ± jitter*targetRTT. Default: 0.15.
	jitter float64

	// BaseDelay is a fixed minimum delay added to all responses.
	// Simulates network latency floor. Default: 0.
	BaseDelay time.Duration

	// minJitter is the minimum absolute jitter added around the sampled RTT.
	// This prevents unnaturally flat timing when the observed RTT is small.
	minJitter time.Duration

	// spikeChance occasionally adds a small positive tail to mimic queueing
	// and scheduler hiccups seen in real proxied handshakes.
	spikeChance float64

	// recentRTTs keeps a small rolling window of live target RTT samples.
	// Delays are drawn from this empirical distribution instead of from a
	// single EMA point estimate, which reduces timing regularity.
	recentRTTs       []time.Duration
	recentRTTIndex   int
	maxRecentSamples int

	enabled bool
}

// NewTimingNormalizer creates a normalizer with sensible defaults.
func NewTimingNormalizer() *TimingNormalizer {
	return &TimingNormalizer{
		alpha:            0.3,
		minSamples:       3,
		jitter:           0.15,
		minJitter:        8 * time.Millisecond,
		spikeChance:      0.12,
		maxRecentSamples: 32,
		enabled:          true,
	}
}

// RecordTargetRTT records a measured RTT to the target. Call this after
// each proxy round-trip to keep the estimate current.
func (tn *TimingNormalizer) RecordTargetRTT(rtt time.Duration) {
	if rtt <= 0 {
		return
	}

	tn.mu.Lock()
	defer tn.mu.Unlock()

	tn.samples++
	if tn.samples == 1 {
		tn.avgTargetRTT = rtt
	} else {
		// Exponential moving average
		tn.avgTargetRTT = time.Duration(
			float64(tn.avgTargetRTT)*(1-tn.alpha) + float64(rtt)*tn.alpha,
		)
	}
	tn.recordRecentRTTLocked(rtt)
}

// TargetRTT returns the current estimated target RTT.
func (tn *TimingNormalizer) TargetRTT() time.Duration {
	tn.mu.RLock()
	defer tn.mu.RUnlock()
	return tn.avgTargetRTT
}

// Delay returns how long to sleep to normalize the timing of a locally
// handled (authenticated) response. Call this with the time already
// elapsed since the start of processing, and it returns the remaining
// time to wait.
//
// If the elapsed time already exceeds the target, returns 0.
func (tn *TimingNormalizer) Delay(elapsed time.Duration) time.Duration {
	tn.mu.RLock()
	defer tn.mu.RUnlock()

	if !tn.enabled || tn.samples < tn.minSamples {
		return 0
	}

	target := tn.sampleTargetRTTLocked() + tn.BaseDelay

	spread := tn.minJitter
	if tn.jitter > 0 {
		relativeSpread := time.Duration(float64(target) * tn.jitter)
		if relativeSpread > spread {
			spread = relativeSpread
		}
	}
	if spread > 0 {
		target += time.Duration((2*rand.Float64() - 1) * float64(spread))
	}
	if tn.spikeChance > 0 && rand.Float64() < tn.spikeChance {
		target += time.Duration(rand.Float64() * float64(maxDuration(spread, tn.minJitter)))
	}
	if target < 0 {
		target = 0
	}

	if target <= elapsed {
		return 0
	}
	return target - elapsed
}

// Sleep blocks for the appropriate duration to normalize timing.
// elapsed is the time already spent processing the handshake.
func (tn *TimingNormalizer) Sleep(elapsed time.Duration) {
	d := tn.Delay(elapsed)
	if d > 0 {
		time.Sleep(d)
	}
}

// SetEnabled enables or disables the normalizer at runtime.
func (tn *TimingNormalizer) SetEnabled(enabled bool) {
	tn.mu.Lock()
	tn.enabled = enabled
	tn.mu.Unlock()
}

// SetJitter sets the jitter fraction (0..1).
func (tn *TimingNormalizer) SetJitter(j float64) {
	tn.mu.Lock()
	tn.jitter = j
	tn.mu.Unlock()
}

// Reset clears all recorded RTT samples.
func (tn *TimingNormalizer) Reset() {
	tn.mu.Lock()
	tn.samples = 0
	tn.avgTargetRTT = 0
	tn.recentRTTs = nil
	tn.recentRTTIndex = 0
	tn.mu.Unlock()
}

func (tn *TimingNormalizer) recordRecentRTTLocked(rtt time.Duration) {
	if tn.maxRecentSamples <= 0 {
		return
	}
	if len(tn.recentRTTs) < tn.maxRecentSamples {
		tn.recentRTTs = append(tn.recentRTTs, rtt)
		return
	}
	tn.recentRTTs[tn.recentRTTIndex] = rtt
	tn.recentRTTIndex = (tn.recentRTTIndex + 1) % len(tn.recentRTTs)
}

func (tn *TimingNormalizer) sampleTargetRTTLocked() time.Duration {
	if len(tn.recentRTTs) == 0 {
		return tn.avgTargetRTT
	}
	return tn.recentRTTs[rand.IntN(len(tn.recentRTTs))]
}

func maxDuration(a, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}
