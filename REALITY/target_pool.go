package reality

import (
	"math/rand/v2"
	"sync"
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

	// rotateInterval, when non-zero, is treated as a soft cooldown window
	// for recently picked targets instead of a deterministic time slice.
	rotateInterval time.Duration
	lastPickedAt   []time.Time
	lastPickIndex  int
}

// NewTargetPool creates a new TargetPool from a list of targets.
// If rotateInterval > 0, it acts as a soft cooldown window for recently
// picked targets; otherwise selection still uses randomized anti-repeat.
func NewTargetPool(targets []Target, rotateInterval time.Duration) *TargetPool {
	if len(targets) == 0 {
		return nil
	}
	return &TargetPool{
		targets:        targets,
		rotateInterval: rotateInterval,
		lastPickedAt:   make([]time.Time, len(targets)),
		lastPickIndex:  -1,
	}
}

// Pick selects a target for the given SNI.
// Priority:
//  1. If clientSNI matches a specific target's ServerNames, return that target.
//  2. Otherwise, choose a randomized fallback target with anti-repeat bias.
func (tp *TargetPool) Pick(clientSNI string) *Target {
	tp.mu.Lock()
	defer tp.mu.Unlock()

	if len(tp.targets) == 0 {
		return nil
	}

	// First: exact SNI match
	for i := range tp.targets {
		if tp.targets[i].ServerNames[clientSNI] {
			tp.markPickedLocked(i)
			return &tp.targets[i]
		}
	}

	idx := tp.pickFallbackIndexLocked()
	return &tp.targets[idx]
}

// PickRandom selects a random target from the pool.
func (tp *TargetPool) PickRandom() *Target {
	tp.mu.Lock()
	defer tp.mu.Unlock()

	if len(tp.targets) == 0 {
		return nil
	}
	idx := tp.pickFallbackIndexLocked()
	return &tp.targets[idx]
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
	tp.mu.Lock()
	defer tp.mu.Unlock()
	for i := range tp.targets {
		if tp.targets[i].ServerNames[sni] {
			tp.markPickedLocked(i)
			return &tp.targets[i]
		}
	}
	return nil
}

func (tp *TargetPool) pickFallbackIndexLocked() int {
	if len(tp.targets) == 1 {
		tp.markPickedLocked(0)
		return 0
	}

	now := time.Now()
	candidates := make([]int, 0, len(tp.targets))
	for i := range tp.targets {
		if tp.lastPickIndex >= 0 && len(tp.targets) > 1 && i == tp.lastPickIndex {
			continue
		}
		if tp.rotateInterval > 0 {
			last := tp.lastPickedAt[i]
			if !last.IsZero() && now.Sub(last) < tp.rotateInterval {
				continue
			}
		}
		candidates = append(candidates, i)
	}

	if len(candidates) == 0 {
		for i := range tp.targets {
			if tp.lastPickIndex >= 0 && len(tp.targets) > 1 && i == tp.lastPickIndex {
				continue
			}
			candidates = append(candidates, i)
		}
	}
	if len(candidates) == 0 {
		candidates = append(candidates, tp.lastPickIndex)
	}

	idx := candidates[rand.IntN(len(candidates))]
	tp.markPickedLocked(idx)
	return idx
}

func (tp *TargetPool) markPickedLocked(idx int) {
	if idx < 0 || idx >= len(tp.targets) {
		return
	}
	tp.lastPickIndex = idx
	tp.lastPickedAt[idx] = time.Now()
}
