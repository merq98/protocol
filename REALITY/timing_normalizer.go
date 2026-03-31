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

	// Running baseline of measured target RTTs.
	avgTargetRTT time.Duration

	// alpha is the current smoothing factor. It is not fixed: the value is
	// periodically retuned and also perturbed per-sample based on observed RTT
	// volatility so the convergence curve does not fit a single EMA profile.
	alpha      float64
	alphaFloor float64
	alphaCeil  float64

	// Minimum samples before the normalizer starts applying delays.
	// Like alpha, this is a live profile value chosen from a bounded range.
	minSamples int
	samples    int

	minSamplesFloor int
	minSamplesCeil  int

	// jitter is the current relative spread as a fraction of the target RTT.
	// It is continuously retuned inside a configured range instead of staying
	// at a single constant like 0.15.
	jitter float64

	jitterFloor float64
	jitterCeil  float64

	retuneMinSamples  int
	retuneMaxSamples  int
	retuneAfterSample int

	// bootstrapJitter and bootstrapTailScale are used before enough live RTT
	// samples are collected. Instead of disabling normalization entirely for
	// the first few connections, the normalizer derives a wider provisional
	// delay distribution from the first observed RTT samples.
	bootstrapJitter    float64
	bootstrapTailScale float64

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
	tn := &TimingNormalizer{
		alphaFloor:         0.18,
		alphaCeil:          0.52,
		minSamplesFloor:    2,
		minSamplesCeil:     6,
		jitterFloor:        0.10,
		jitterCeil:         0.28,
		retuneMinSamples:   8,
		retuneMaxSamples:   20,
		bootstrapJitter:    0.32,
		bootstrapTailScale: 1.35,
		minJitter:          8 * time.Millisecond,
		spikeChance:        0.12,
		maxRecentSamples:   32,
		enabled:            true,
	}
	tn.retuneProfileLocked()
	return tn
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
		tn.avgTargetRTT = blendDuration(tn.avgTargetRTT, rtt, tn.sampleAlphaLocked(rtt))
	}
	tn.recordRecentRTTLocked(rtt)
	if tn.samples == 1 || tn.samples >= tn.retuneAfterSample {
		tn.retuneProfileLocked()
	}
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

	if !tn.enabled || tn.samples == 0 || tn.avgTargetRTT <= 0 {
		return 0
	}

	target := tn.sampleDelayTargetLocked() + tn.BaseDelay

	spread := tn.minJitter
	if jitter := tn.sampleDelayJitterLocked(); jitter > 0 {
		relativeSpread := time.Duration(float64(target) * jitter)
		if relativeSpread > spread {
			spread = relativeSpread
		}
	}
	if spread > 0 {
		target += time.Duration((2*rand.Float64() - 1) * float64(spread))
	}
	if spikeChance := tn.delaySpikeChanceLocked(); spikeChance > 0 && rand.Float64() < spikeChance {
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
	if j <= 0 {
		tn.jitter = 0
		tn.jitterFloor = 0
		tn.jitterCeil = 0
		tn.mu.Unlock()
		return
	}

	base := clampFloat(j, 0.02, 0.50)
	tn.jitterFloor = clampFloat(base*0.75, 0.02, 0.50)
	tn.jitterCeil = clampFloat(maxFloat(base*1.25, tn.jitterFloor), tn.jitterFloor, 0.50)
	tn.retuneProfileLocked()
	tn.mu.Unlock()
}

// Reset clears all recorded RTT samples.
func (tn *TimingNormalizer) Reset() {
	tn.mu.Lock()
	tn.samples = 0
	tn.avgTargetRTT = 0
	tn.recentRTTs = nil
	tn.recentRTTIndex = 0
	tn.retuneProfileLocked()
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

	picked := tn.recentRTTs[rand.IntN(len(tn.recentRTTs))]
	if tn.avgTargetRTT <= 0 || rand.Float64() < 0.7 {
		return picked
	}

	blend := 0.20 + rand.Float64()*0.45
	return blendDuration(picked, tn.avgTargetRTT, blend)
}

func (tn *TimingNormalizer) sampleDelayTargetLocked() time.Duration {
	if tn.samples >= tn.minSamples {
		return tn.sampleTargetRTTLocked()
	}
	return tn.bootstrapTargetRTTLocked()
}

func (tn *TimingNormalizer) sampleDelayJitterLocked() float64 {
	if tn.samples >= tn.minSamples {
		return tn.sampleJitterLocked()
	}
	jitter := tn.bootstrapJitter + tn.sampleVolatilityLocked()*0.30 + (rand.Float64()-0.5)*0.08
	return clampFloat(jitter, 0.16, 0.55)
}

func (tn *TimingNormalizer) delaySpikeChanceLocked() float64 {
	if tn.samples >= tn.minSamples {
		return tn.spikeChance
	}
	return clampFloat(tn.spikeChance*tn.bootstrapTailScale, 0.10, 0.35)
}

func (tn *TimingNormalizer) bootstrapTargetRTTLocked() time.Duration {
	base := tn.avgTargetRTT
	if base <= 0 {
		return 0
	}

	target := base
	if len(tn.recentRTTs) > 0 {
		target = tn.recentRTTs[rand.IntN(len(tn.recentRTTs))]
	}

	// Keep early auth-path handshakes from standing out as too fast by adding
	// a modest positive bias until the empirical RTT window is populated.
	biasScale := 0.10 + (float64(tn.minSamples-tn.samples) * 0.08)
	if biasScale < 0.08 {
		biasScale = 0.08
	}
	target += time.Duration(float64(maxDuration(base, 5*time.Millisecond)) * biasScale)

	if tn.samples == 1 {
		target += time.Duration(rand.Float64() * float64(maxDuration(tn.minJitter*2, base/6)))
	}

	return target
}

func (tn *TimingNormalizer) sampleAlphaLocked(rtt time.Duration) float64 {
	if tn.avgTargetRTT <= 0 {
		return tn.alpha
	}

	baseline := float64(maxDuration(tn.avgTargetRTT, time.Millisecond))
	deviation := float64(absDuration(rtt-tn.avgTargetRTT)) / baseline
	volatility := tn.sampleVolatilityLocked()
	alpha := tn.alpha + deviation*0.25 + volatility*0.20 + (rand.Float64()-0.5)*0.08
	return clampFloat(alpha, tn.alphaFloor, tn.alphaCeil)
}

func (tn *TimingNormalizer) sampleJitterLocked() float64 {
	if tn.jitterCeil <= 0 {
		return 0
	}

	volatility := tn.sampleVolatilityLocked()
	jitter := tn.jitter + volatility*0.20 + (rand.Float64()-0.5)*0.04
	return clampFloat(jitter, tn.jitterFloor, tn.jitterCeil)
}

func (tn *TimingNormalizer) retuneProfileLocked() {
	volatility := tn.sampleVolatilityLocked()

	alphaLow := clampFloat(0.18+volatility*0.16, tn.alphaFloor, tn.alphaCeil)
	alphaHigh := clampFloat(0.32+volatility*0.24, alphaLow, tn.alphaCeil)
	tn.alpha = randomFloatInRange(alphaLow, alphaHigh)

	minLow := tn.minSamplesFloor
	if volatility < 0.08 {
		minLow++
	}
	if volatility < 0.03 {
		minLow++
	}
	minLow = clampInt(minLow, tn.minSamplesFloor, tn.minSamplesCeil)
	minHigh := clampInt(minLow+2, minLow, tn.minSamplesCeil)
	tn.minSamples = randomIntInRange(minLow, minHigh)

	jitterLow := clampFloat(maxFloat(tn.jitterFloor, 0.09+volatility*0.20), 0, tn.jitterCeil)
	jitterHigh := clampFloat(jitterLow+0.06+volatility*0.12, jitterLow, tn.jitterCeil)
	tn.jitter = randomFloatInRange(jitterLow, jitterHigh)

	retuneIn := randomIntInRange(tn.retuneMinSamples, tn.retuneMaxSamples)
	tn.retuneAfterSample = tn.samples + retuneIn
}

func (tn *TimingNormalizer) sampleVolatilityLocked() float64 {
	if len(tn.recentRTTs) < 2 || tn.avgTargetRTT <= 0 {
		return 0
	}

	baseline := float64(maxDuration(tn.avgTargetRTT, time.Millisecond))
	var total float64
	for _, sample := range tn.recentRTTs {
		total += float64(absDuration(sample-tn.avgTargetRTT)) / baseline
	}
	return total / float64(len(tn.recentRTTs))
}

func blendDuration(base, sample time.Duration, alpha float64) time.Duration {
	alpha = clampFloat(alpha, 0, 1)
	return time.Duration(float64(base)*(1-alpha) + float64(sample)*alpha)
}

func absDuration(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}

func randomFloatInRange(low, high float64) float64 {
	if high <= low {
		return low
	}
	return low + rand.Float64()*(high-low)
}

func randomIntInRange(low, high int) int {
	if high <= low {
		return low
	}
	return low + rand.IntN(high-low+1)
}

func clampFloat(value, low, high float64) float64 {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

func clampInt(value, low, high int) int {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

func maxDuration(a, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}
