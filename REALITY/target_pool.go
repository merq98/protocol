package reality

import (
	"math/rand/v2"
	"sync"
	"sync/atomic"
	"time"
)

// Target represents a single fallback destination with its associated SNI names.
type Target struct {
	// Dest is the target address in "host:port" format, e.g. "example.com:443".
	Dest string
	// ServerNames is the set of acceptable SNI names for this target.
	ServerNames map[string]bool
}

// TargetPool manages a pool of targets with rotation strategies.
// It is safe for concurrent use.
type TargetPool struct {
	targets []Target
	mu      sync.RWMutex

	// Round-robin counter
	counter atomic.Uint64

	// Time-based rotation
	rotateInterval time.Duration
	startTime      time.Time
}

// NewTargetPool creates a new TargetPool from a list of targets.
// If rotateInterval > 0, targets rotate based on time; otherwise round-robin is used.
func NewTargetPool(targets []Target, rotateInterval time.Duration) *TargetPool {
	if len(targets) == 0 {
		return nil
	}
	return &TargetPool{
		targets:        targets,
		rotateInterval: rotateInterval,
		startTime:      time.Now(),
	}
}

// Pick selects a target for the given SNI.
// Priority:
//  1. If clientSNI matches a specific target's ServerNames, return that target.
//  2. Otherwise, rotate among all targets (time-based or round-robin).
func (tp *TargetPool) Pick(clientSNI string) *Target {
	tp.mu.RLock()
	defer tp.mu.RUnlock()

	if len(tp.targets) == 0 {
		return nil
	}

	// First: exact SNI match
	for i := range tp.targets {
		if tp.targets[i].ServerNames[clientSNI] {
			return &tp.targets[i]
		}
	}

	// Second: rotation strategy
	var idx int
	if tp.rotateInterval > 0 {
		// Time-based: switch target every rotateInterval
		elapsed := time.Since(tp.startTime)
		idx = int(elapsed/tp.rotateInterval) % len(tp.targets)
	} else {
		// Round-robin
		idx = int(tp.counter.Add(1)-1) % len(tp.targets)
	}

	return &tp.targets[idx]
}

// PickRandom selects a random target from the pool.
func (tp *TargetPool) PickRandom() *Target {
	tp.mu.RLock()
	defer tp.mu.RUnlock()

	if len(tp.targets) == 0 {
		return nil
	}
	return &tp.targets[rand.IntN(len(tp.targets))]
}

// AllServerNames returns a merged map of all server names across all targets.
func (tp *TargetPool) AllServerNames() map[string]bool {
	tp.mu.RLock()
	defer tp.mu.RUnlock()

	all := make(map[string]bool)
	for _, t := range tp.targets {
		for sni := range t.ServerNames {
			all[sni] = true
		}
	}
	return all
}

// AllDests returns all unique destination addresses.
func (tp *TargetPool) AllDests() []string {
	tp.mu.RLock()
	defer tp.mu.RUnlock()

	seen := make(map[string]bool)
	var dests []string
	for _, t := range tp.targets {
		if !seen[t.Dest] {
			seen[t.Dest] = true
			dests = append(dests, t.Dest)
		}
	}
	return dests
}

// Len returns the number of targets in the pool.
func (tp *TargetPool) Len() int {
	tp.mu.RLock()
	defer tp.mu.RUnlock()
	return len(tp.targets)
}

// PickBySNI returns the target whose ServerNames contains the given SNI.
// Returns nil if no match found.
func (tp *TargetPool) PickBySNI(sni string) *Target {
	tp.mu.RLock()
	defer tp.mu.RUnlock()
	for i := range tp.targets {
		if tp.targets[i].ServerNames[sni] {
			return &tp.targets[i]
		}
	}
	return nil
}
