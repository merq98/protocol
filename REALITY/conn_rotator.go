package reality

import (
	"errors"
	"io"
	"math"
	"math/rand/v2"
	"net"
	"sync"
	"time"
)

// RotationPolicy defines when a connection should be rotated.
type RotationPolicy struct {
	// MaxLifetime is the maximum age of a single connection.
	// After this duration, the connection is drained and replaced.
	// Default: 60s. Recommended range: 30-120s.
	MaxLifetime time.Duration

	// MaxBytes is the maximum total bytes (read+write) before rotation.
	// 0 means no byte limit. Recommended: 1-10 MB.
	MaxBytes int64

	// MinLifetime is the minimum time a connection must live before
	// it can be rotated. Prevents too-fast rotation.
	// Default: 10s.
	MinLifetime time.Duration

	// Jitter controls the spread of the sampled connection lifetime.
	// The final lifetime is drawn from a skewed distribution around
	// MaxLifetime rather than from a uniform +/- window.
	// Default: 15s.
	Jitter time.Duration
}

// DefaultRotationPolicy returns a reasonable default policy.
func DefaultRotationPolicy() RotationPolicy {
	return RotationPolicy{
		MaxLifetime: 60 * time.Second,
		MaxBytes:    5 * 1024 * 1024, // 5 MB
		MinLifetime: 10 * time.Second,
		Jitter:      15 * time.Second,
	}
}

// RotatedConn wraps a REALITY *Conn with rotation tracking.
// It monitors bytes transferred and connection age, signaling when
// the connection should be rotated.
type RotatedConn struct {
	mu        sync.Mutex
	inner     net.Conn
	policy    RotationPolicy
	createdAt time.Time
	deadline  time.Time // actual rotation deadline (with jitter applied)
	bytesIn   int64
	bytesOut  int64
	closed    bool
	onRotate  func() // callback when rotation is needed
}

// NewRotatedConn wraps an existing connection with rotation tracking.
// jitterFn can supply deterministic entropy in [-1.0, 1.0]; if nil, an
// internal random source is used.
func NewRotatedConn(inner net.Conn, policy RotationPolicy, jitterFn func() float64) *RotatedConn {
	createdAt := time.Now()
	deadline := createdAt.Add(sampleRotationLifetime(policy, jitterFn))
	return &RotatedConn{
		inner:     inner,
		policy:    policy,
		createdAt: createdAt,
		deadline:  deadline,
	}
}

func sampleRotationLifetime(policy RotationPolicy, jitterFn func() float64) time.Duration {
	base := policy.MaxLifetime
	if base <= 0 {
		base = policy.MinLifetime
	}
	if base <= 0 {
		base = 60 * time.Second
	}

	minLifetime := policy.MinLifetime
	if minLifetime <= 0 || minLifetime > base {
		minLifetime = minRotationDuration(base, 10*time.Second)
	}

	spread := policy.Jitter
	if spread < 0 {
		spread = 0
	}

	mode := sampleRotationUnit(jitterFn)
	var lifetime time.Duration
	switch {
	case mode < 0.18:
		lifetime = sampleShortRotationLifetime(minLifetime, base, jitterFn)
	case mode < 0.82:
		lifetime = sampleTypicalRotationLifetime(minLifetime, base, spread, jitterFn)
	default:
		lifetime = sampleLongRotationLifetime(base, spread, jitterFn)
	}

	maxLifetime := maxRotationDuration(base+maxRotationDuration(spread*3, base/3), minLifetime)
	return clampDuration(lifetime, minLifetime, maxLifetime)
}

func sampleShortRotationLifetime(minLifetime, base time.Duration, jitterFn func() float64) time.Duration {
	if base <= minLifetime {
		return base
	}
	span := base - minLifetime
	weight := 0.20 + math.Pow(sampleRotationUnit(jitterFn), 1.7)*0.55
	return minLifetime + time.Duration(weight*float64(span))
}

func sampleTypicalRotationLifetime(minLifetime, base, spread time.Duration, jitterFn func() float64) time.Duration {
	leftSpan := maxRotationDuration(spread, (base-minLifetime)/2)
	low := maxRotationDuration(minLifetime, base-leftSpan)
	high := base + spread/2
	if high < low {
		high = low
	}

	u1 := sampleRotationUnit(jitterFn)
	u2 := sampleRotationUnit(jitterFn)
	u3 := sampleRotationUnit(jitterFn)
	triangular := (u1 + u2 + u3) / 3
	skewed := math.Pow(triangular, 1.35)
	return low + time.Duration(skewed*float64(high-low))
}

func sampleLongRotationLifetime(base, spread time.Duration, jitterFn func() float64) time.Duration {
	tail := maxRotationDuration(spread*2, base/4)
	weight := 0.25 + math.Pow(sampleRotationUnit(jitterFn), 0.65)*1.15
	return base + time.Duration(weight*float64(tail))
}

func sampleRotationUnit(jitterFn func() float64) float64 {
	if jitterFn == nil {
		return rand.Float64()
	}
	value := (jitterFn() + 1) / 2
	if value < 0 {
		return 0
	}
	if value > 1 {
		return 1
	}
	return value
}

func clampDuration(value, low, high time.Duration) time.Duration {
	if value < low {
		return low
	}
	if value > high {
		return high
	}
	return value
}

func minRotationDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func maxRotationDuration(a, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}

// OnRotate sets a callback invoked when the connection needs rotation.
func (rc *RotatedConn) OnRotate(fn func()) {
	rc.mu.Lock()
	rc.onRotate = fn
	rc.mu.Unlock()
}

// ShouldRotate returns true if the connection has exceeded its lifetime or byte limit.
func (rc *RotatedConn) ShouldRotate() bool {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	if rc.closed {
		return false
	}
	now := time.Now()
	if now.After(rc.deadline) {
		return true
	}
	if rc.policy.MaxBytes > 0 && (rc.bytesIn+rc.bytesOut) >= rc.policy.MaxBytes {
		return now.Sub(rc.createdAt) >= rc.policy.MinLifetime
	}
	return false
}

// Age returns how long the connection has been alive.
func (rc *RotatedConn) Age() time.Duration {
	return time.Since(rc.createdAt)
}

// BytesTransferred returns total bytes read + written.
func (rc *RotatedConn) BytesTransferred() int64 {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	return rc.bytesIn + rc.bytesOut
}

func (rc *RotatedConn) Read(b []byte) (int, error) {
	n, err := rc.inner.Read(b)
	if n > 0 {
		rc.mu.Lock()
		rc.bytesIn += int64(n)
		shouldRotate := rc.shouldRotateLocked()
		fn := rc.onRotate
		rc.mu.Unlock()
		if shouldRotate && fn != nil {
			fn()
		}
	}
	return n, err
}

func (rc *RotatedConn) Write(b []byte) (int, error) {
	n, err := rc.inner.Write(b)
	if n > 0 {
		rc.mu.Lock()
		rc.bytesOut += int64(n)
		shouldRotate := rc.shouldRotateLocked()
		fn := rc.onRotate
		rc.mu.Unlock()
		if shouldRotate && fn != nil {
			fn()
		}
	}
	return n, err
}

func (rc *RotatedConn) shouldRotateLocked() bool {
	if rc.closed {
		return false
	}
	now := time.Now()
	if now.After(rc.deadline) {
		return true
	}
	if rc.policy.MaxBytes > 0 && (rc.bytesIn+rc.bytesOut) >= rc.policy.MaxBytes {
		return now.Sub(rc.createdAt) >= rc.policy.MinLifetime
	}
	return false
}

func (rc *RotatedConn) Close() error {
	rc.mu.Lock()
	rc.closed = true
	rc.mu.Unlock()
	return rc.inner.Close()
}

func (rc *RotatedConn) LocalAddr() net.Addr                { return rc.inner.LocalAddr() }
func (rc *RotatedConn) RemoteAddr() net.Addr               { return rc.inner.RemoteAddr() }
func (rc *RotatedConn) SetDeadline(t time.Time) error      { return rc.inner.SetDeadline(t) }
func (rc *RotatedConn) SetReadDeadline(t time.Time) error  { return rc.inner.SetReadDeadline(t) }
func (rc *RotatedConn) SetWriteDeadline(t time.Time) error { return rc.inner.SetWriteDeadline(t) }

// SessionManager binds multiple short-lived REALITY connections from the
// same authenticated client into a single logical session. It provides a
// multiplexed net.Conn that transparently rotates underlying connections.
type SessionManager struct {
	mu       sync.RWMutex
	sessions map[string]*Session // keyed by ClientShortId hex
	policy   RotationPolicy
}

// NewSessionManager creates a session manager with the given rotation policy.
func NewSessionManager(policy RotationPolicy) *SessionManager {
	return &SessionManager{
		sessions: make(map[string]*Session),
		policy:   policy,
	}
}

// Session represents a logical session spanning multiple rotated connections.
type Session struct {
	mu      sync.Mutex
	id      string
	conns   []*RotatedConn
	active  *RotatedConn
	dataCh  chan []byte
	closed  bool
	closeCh chan struct{}
	policy  RotationPolicy
}

// Bind adds a new REALITY connection to a session. If the session doesn't
// exist, it creates one. Returns the session and whether it's new.
func (sm *SessionManager) Bind(sessionID string, conn net.Conn, jitterFn func() float64) (*Session, bool) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	sess, exists := sm.sessions[sessionID]
	if !exists {
		sess = &Session{
			id:      sessionID,
			dataCh:  make(chan []byte, 64),
			closeCh: make(chan struct{}),
			policy:  sm.policy,
		}
		sm.sessions[sessionID] = sess
	}

	rc := NewRotatedConn(conn, sm.policy, jitterFn)
	sess.mu.Lock()
	sess.conns = append(sess.conns, rc)
	if sess.active == nil || sess.active.ShouldRotate() {
		sess.active = rc
	}
	sess.mu.Unlock()

	// Start draining data from this connection into the session channel
	go sess.drainConn(rc)

	return sess, !exists
}

// Remove removes a session by ID.
func (sm *SessionManager) Remove(sessionID string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	if sess, ok := sm.sessions[sessionID]; ok {
		sess.Close()
		delete(sm.sessions, sessionID)
	}
}

// Cleanup removes all expired sessions with no active connections.
func (sm *SessionManager) Cleanup() {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	for id, sess := range sm.sessions {
		sess.mu.Lock()
		activeConns := 0
		for _, rc := range sess.conns {
			if !rc.closed {
				activeConns++
			}
		}
		sess.mu.Unlock()
		if activeConns == 0 {
			sess.Close()
			delete(sm.sessions, id)
		}
	}
}

// drainConn reads from a rotated connection and sends data to the session channel.
func (s *Session) drainConn(rc *RotatedConn) {
	buf := make([]byte, 32*1024)
	for {
		n, err := rc.Read(buf)
		if n > 0 {
			data := make([]byte, n)
			copy(data, buf[:n])
			select {
			case s.dataCh <- data:
			case <-s.closeCh:
				return
			}
		}
		if err != nil {
			return
		}
	}
}

// Read reads from the session (from any active connection).
func (s *Session) Read(b []byte) (int, error) {
	select {
	case data, ok := <-s.dataCh:
		if !ok {
			return 0, io.EOF
		}
		n := copy(b, data)
		return n, nil
	case <-s.closeCh:
		return 0, io.EOF
	}
}

// Write writes to the currently active connection.
// If the active connection needs rotation, it switches to the next available.
func (s *Session) Write(b []byte) (int, error) {
	s.mu.Lock()
	active := s.active
	if active == nil || active.ShouldRotate() {
		// Find the next non-expired connection
		for _, rc := range s.conns {
			if !rc.closed && !rc.ShouldRotate() {
				active = rc
				s.active = rc
				break
			}
		}
	}
	s.mu.Unlock()

	if active == nil {
		return 0, errors.New("session: no active connection available")
	}
	return active.Write(b)
}

// Close closes the session and all its connections.
func (s *Session) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	close(s.closeCh)
	for _, rc := range s.conns {
		rc.Close()
	}
	return nil
}

// ActiveConns returns the number of non-closed connections in the session.
func (s *Session) ActiveConns() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for _, rc := range s.conns {
		if !rc.closed {
			count++
		}
	}
	return count
}

// SessionID returns the session identifier.
func (s *Session) SessionID() string {
	return s.id
}
