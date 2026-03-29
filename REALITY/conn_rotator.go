package reality

import (
	"errors"
	"io"
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

	// Jitter adds randomness to MaxLifetime to avoid synchronized rotation.
	// Actual lifetime = MaxLifetime ± rand(Jitter).
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
// jitterFn should return a value in [-1.0, 1.0] for jitter; use nil for no jitter.
func NewRotatedConn(inner net.Conn, policy RotationPolicy, jitterFn func() float64) *RotatedConn {
	deadline := time.Now().Add(policy.MaxLifetime)
	if policy.Jitter > 0 && jitterFn != nil {
		jitter := time.Duration(jitterFn() * float64(policy.Jitter))
		deadline = deadline.Add(jitter)
	}
	return &RotatedConn{
		inner:     inner,
		policy:    policy,
		createdAt: time.Now(),
		deadline:  deadline,
	}
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

func (rc *RotatedConn) LocalAddr() net.Addr              { return rc.inner.LocalAddr() }
func (rc *RotatedConn) RemoteAddr() net.Addr             { return rc.inner.RemoteAddr() }
func (rc *RotatedConn) SetDeadline(t time.Time) error    { return rc.inner.SetDeadline(t) }
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
	mu       sync.Mutex
	id       string
	conns    []*RotatedConn
	active   *RotatedConn
	dataCh   chan []byte
	closed   bool
	closeCh  chan struct{}
	policy   RotationPolicy
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
